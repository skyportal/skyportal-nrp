# One-go migration runbook (Cloud SQL → NRP)

> ⚠️ **SUPERSEDED for the real cutover.** The timed trial below proved a one-go
> `pg_restore` onto NRP Ceph runs **>12 h and does not finish** (index-rebuild
> wall). Use **[`16-logical-replication.md`](16-logical-replication.md)** for the
> actual migration. This doc is retained for the dump/restore mechanics and the
> App/Filesystem/DNS sections, which logical replication reuses.

## (superseded) one-go dump/restore

Logical `pg_dump`/`pg_restore` cutover. Two uses of the same procedure:

1. **Timed trial (do this FIRST)** — non-destructive, no outage. Produces the real
   downtime number *and* is the Ceph-RBD benchmark we've been flagging.
2. **Production cutover** — the real one-go, in a maintenance window sized from the
   trial.

> There is no physical shortcut: Cloud SQL gives no base backup you can restore
> onto your own Postgres, so you pay to reload data **and rebuild every index**
> (~214 GB of indexes) inside the window. Expect **8–24 h**; the trial replaces
> that guess with a measurement.

## Names & topology (CONFIRM before running)

| | Source | Target |
|---|---|---|
| Where | Cloud SQL `fritz-psql14` (GCP `skyportal-206621`, us-west2-a) | CNPG `skyportal-db` on NRP |
| Version | **POSTGRES_18** (ZONAL, 1800 GB PD-SSD) | **PG 18** (must be ≥ source) |
| **Database** | **`fritz-1`** | **`skyportal`** |
| Role | `skyportal` (creds in `fritz-deploy` SOPS `config.yaml`) | `skyportal` |
| Reach | **private IP `10.49.1.19` only** → dump via a GCP VM in-VPC or Cloud SQL Auth Proxy | in-cluster `skyportal-db-rw:5432` |

⚠️ **Two mismatches confirmed from discovery, both baked into the steps below:**
- **DB name differs** (`fritz-1` → `skyportal`): dump the `fritz-1` database and
  restore its *contents* into `skyportal` with `--no-owner --no-privileges`.
- **Source is PG 18**: use **PG 18 client tools** and a **PG 18** target. A PG 17
  target cannot restore a PG 18 dump.

The NRP ingress (future `fritz.science` target) is **`131.193.183.215`**.

**Recommended topology:** dump on a **GCP VM in Cloud SQL's region** (fast, low
latency) to local SSD → push the dump dir to **GCS** → run `pg_restore` from a
**Job/pod inside NRP** (in-cluster network to `skyportal-db-rw`, pulling the dump
from GCS). Simpler alternative: one migrator host that can reach both, if its
link to NRP is fast enough. Use **PG 18 client tools** (source and target are both PG 18).

Scratch space needed: ≥ ~1.5× the compressed dump size on both the dump host and
wherever the restore reads from.

**The in-cluster restore half (GCS-fetch → `pg_restore` → analyze) is packaged as
[`07-restore-job.yaml`](07-restore-job.yaml)** — run that instead of the manual
`pg_restore`/`vacuumdb` steps below. It defaults to the throwaway `skyportal_trial`
DB for the trial; set `TARGET_DB=skyportal` for the real cutover. The manual
commands below are the reference for what the Job does.

---

## Phase 0 — one-time prep (no downtime)

**Measure the source** (sets expectations + scratch sizing):
```sql
-- against fritz-1
SELECT pg_size_pretty(pg_database_size('fritz-1'));
SELECT relname, pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_indexes_size(c.oid)) AS idx
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r'
ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20;
SHOW server_version;          -- confirm target major >= this
```

**Extensions must exist on the target image.** List them on the source and make
sure the CNPG image has them (stock contrib is fine; a non-contrib ext ⇒ custom
image):
```sql
SELECT extname, extversion FROM pg_extension ORDER BY 1;
```

**Tune the target for bulk load** (temporary — revert after). Set on the CNPG
`Cluster` (`spec.postgresql.parameters`) or per-session; the load-critical ones:
```
maintenance_work_mem = 4GB        # fast index builds (the dominant cost)
max_parallel_maintenance_workers = 4
synchronous_commit = off          # load only
max_wal_size = 16GB
autovacuum = off                  # during load; RE-ENABLE after
```

---

## Phase 1 — TIMED TRIAL (run against prod, no outage)

`pg_dump` takes a consistent snapshot, so this needs **no downtime** — but it
holds a long read transaction (ACCESS SHARE), so run **off-peak**: it adds read
load and briefly defers vacuum/DDL on prod. Restore into a **scratch** DB
(`skyportal_trial`) so the real target is untouched.

Record wall-clock at each checkpoint into the table below.

```bash
# --- T0: start ---
SRC="-h $SRC_HOST -U skyportal -d fritz-1"      # password via PGPASSWORD / .pgpass
J=8                                              # ~= vCPUs on dump/restore host

# 1) Parallel directory-format dump.  -Z0 (no compression) if disk/net is fast;
#    -Z1 if the link is the bottleneck.
pg_dump $SRC -Fd -j $J -Z0 --no-owner --no-privileges -f /scratch/fritz_dump
# --- T1: dump done ---  ; record:  du -sh /scratch/fritz_dump

# 2) (if dumping off-cluster) move to where the restore runs
gsutil -m rsync -r /scratch/fritz_dump gs://<bucket>/fritz_dump
# ...pull into the restore pod / node...
# --- T2: transfer done ---

# 3) Create the scratch target DB
psql -h skyportal-db-rw -U skyportal -d skyportal -c "CREATE DATABASE skyportal_trial OWNER skyportal;"

# 4) Parallel restore (data COPY, then index/constraint builds — the long pole)
pg_restore -h skyportal-db-rw -U skyportal -d skyportal_trial \
  -j $J --no-owner --no-privileges /scratch/fritz_dump
# --- T3: restore done ---

# 5) Stats + validation (queries are unusable until ANALYZE)
vacuumdb -h skyportal-db-rw -U skyportal -d skyportal_trial --analyze-in-stages -j $J
#    row-count spot check vs source on the biggest tables:
psql $SRC -c "SELECT count(*) FROM photometry;"
psql -h skyportal-db-rw -U skyportal -d skyportal_trial -c "SELECT count(*) FROM photometry;"
# --- T4: done ---
```

**Timing sheet — fill in on the trial:**

| Checkpoint | What | Wall-clock | Notes |
|---|---|---|---|
| T1−T0 | dump | | dump size = ___ |
| T2−T1 | transfer | | skip if in-place |
| T3−T2 | **restore (data+indexes)** | | the dominant cost |
| T4−T3 | analyze + validate | | |
| **total** | | | |

**Also capture during the restore (this is the Ceph benchmark):** node `iostat`
/ disk latency on the Postgres PVC, and `SELECT phase, blocks_done, blocks_total
FROM pg_stat_progress_create_index;` to watch index builds. **Bonus stress test:**
`kubectl delete pod skyportal-db-1` (a standby) mid-restore and confirm the
cluster stays healthy — that's the preemption-survival signal.

**Projected cutover downtime ≈ (dump) + (transfer) + (restore) + (analyze+verify)**
— in the real cutover the dump counts as downtime because writes are stopped.

Drop the scratch DB when done: `DROP DATABASE skyportal_trial;`

---

## Phase 2 — PRODUCTION CUTOVER (the real one-go)

Schedule a window = trial total × ~1.5 safety factor. Announce it. DNS is flipped
**last** so rollback stays trivial.

1. **Stop writers.** Put Fritz in maintenance; scale app + workers to 0 so nothing
   writes to Cloud SQL:
   ```bash
   # on the GCP/GKE side
   kubectl scale deploy/<fritz-web> deploy/<fritz-workers> --replicas=0
   ```
2. **Final dump** — same `pg_dump` as the trial (now exact, since writes stopped).
3. **Restore into the REAL `skyportal` DB** on CNPG (ensure it's empty first),
   same parallel `pg_restore`. Sequences come across in the dump — no manual
   resync needed (that caveat is only for logical replication, not dump/restore).
4. **Post-restore:** `vacuumdb --analyze-in-stages`; then
   `alembic upgrade head` via the app pod (should be a no-op if schema matched);
   revert the Phase-0 load tuning (`autovacuum=on`, `synchronous_commit=on`).
5. **Smoke test** against `skyportal-db-rw`: API `/api/sysinfo`, Google login, a
   few representative queries, a source page with photometry.
6. **Cut the app over:** set `database.host: skyportal-db-pooler-rw` (or
   `skyportal-db-rw`) in `../secrets.yaml`, `kubectl apply`, scale the NRP app +
   workers up, confirm healthy against the new DB.
7. **Immediate base backup** for a fresh PITR anchor:
   `kubectl cnpg backup skyportal-db`.
8. **DNS flip** (see the `ingress/` work): change `fritz.science` A record →
   NRP ingress IP. TTL already lowered a day prior.

## App & integration alignment (the DB is not plug-and-play)

The restored DB carries Fritz's schema; app and DB are coupled. Get these right
or the app won't come up cleanly.

1. **Match the NRP app image to Fritz's skyportal commit.** skyportal runs
   `alembic upgrade head` on boot, so build/deploy the NRP app from the **same
   skyportal commit Fritz production runs** → the head already matches the
   restored DB and the upgrade is a **no-op**. This is what avoids re-running the
   reverted photometry→bigint migration: Fritz's DB is int4, and if the NRP image
   carried that migration it would fire the hours-long `ALTER … TYPE bigint` on
   first boot. **Confirm, don't assume:** `SELECT version_num FROM
   alembic_version;` on the restored DB and match the image's head to it. (The
   commit = the skyportal submodule pinned by Fritz's deployed appVersion.)
2. **DB role + name.** The dump is from db `fritz-1` owned by role `postgres`;
   restore the cutover into db `skyportal` with `--no-owner`, then either point
   the app at user `postgres` or create a `skyportal` role with access. Match
   `database.{host,database,user,password}` in `../secrets.yaml`.
3. **Re-point babamul.** Its `services.external.babamul.params.ingest` references
   `stream_ids`/`filter_ids`/`group_ids` from the OLD NRP test DB — those IDs
   don't exist in Fritz's data. After the app is up on the Fritz DB, aim babamul
   at Fritz's own streams/filters/groups (or create a babamul filter there), then
   `rollout restart deployment/skyportal-workers`.
4. **Users/login.** Fritz users carry `oauth_uid`, so they log in normally; an
   NRP-bootstrapped admin won't exist unless you're already a Fritz user.

## Filesystem data — SEPARATE track (pg_dump does NOT include it)

`pg_dump` moves only the relational DB. Fritz's web pod mounts two on-disk data
volumes that must be migrated separately (confirmed from the prod deployment):

| Fritz mount | PVC | Size | Contents | NRP target |
|---|---|---|---|---|
| `/skyportal/static/thumbnails` | `thumbnail-cache` | 400 Gi | cutout PNGs | `skyportal-data` cephfs, `static/thumbnails` subPath |
| `/skyportal/persistentdata` | `persistent-cache` | 200 Gi | analysis outputs, uploaded products, attachments | `skyportal-data` cephfs |

~600 GB total. The NRP `skyportal-data` cephfs PVC (100 Gi today) must **grow to
~600 GB+** first. `persistentdata` is NOT regenerable (must copy); thumbnails
could in theory be re-fetched but copying the 400 GB is far cheaper than
backfilling old objects.

**Why it's easier than the DB:** these are plain files, so the copy is
**incremental** (`gcloud storage rsync` / `rsync`). Unlike the DB (full
dump+restore inside the window), you **pre-seed the bulk days ahead** while Fritz
runs, then a **fast final delta** at cutover — adds almost nothing to downtime.

**Consistency:** the files and the DB must represent the same point. Do the final
delta in the same window as the DB cutover (a Thumbnail row's `file_uri` / an
analysis path must resolve to a copied file, or you get broken cutouts / missing
products).

**Transport** (same GCS hop + the fritz-ci key; the node-scope 403 applies here
too — auth the upload with the SA key, not node scopes):
```bash
# Pre-seed (run days ahead, repeatable; from a GKE pod mounting the two PVCs):
gcloud storage rsync -r /skyportal/static/thumbnails gs://fritz-db-exports/fs/thumbnails
gcloud storage rsync -r /skyportal/persistentdata    gs://fritz-db-exports/fs/persistentdata
# Final delta: re-run the same two rsyncs at cutover (only changed files move).
# Pull into NRP (a pod mounting skyportal-data cephfs):
gcloud storage rsync -r gs://fritz-db-exports/fs/thumbnails    /mnt/static/thumbnails
gcloud storage rsync -r gs://fritz-db-exports/fs/persistentdata /mnt/persistentdata
# Fix ownership on NRP (kubelet subPath is root:root; app is uid 1000):
#   chown -R 1000:1000 /mnt/static/thumbnails /mnt/persistentdata
```

So the real cutover is **three parallel tracks**: DB (dump/restore — the long
pole), filesystem (pre-seed + delta — cheap), and DNS/TLS.

## Rollback
- **Before the DNS flip:** if restore/verify fails, abort — revert `secrets.yaml`
  to the Cloud SQL host, scale Fritz back up on GCP. Nothing user-visible changed.
- **After the DNS flip:** flip the A record back to `35.244.192.22`; Cloud SQL is
  still live. **Keep Cloud SQL running (read-only) until NRP is proven** — that's
  the real rollback. Don't decommission it same-day.

## Notes
- `--no-owner --no-privileges` handles the `fritz-1`→`skyportal` name/role gap;
  objects end up owned by the connecting `skyportal` role.
- Don't compress (`-Z0`) if CPU-bound and disk/net is fast — the restore, not the
  dump, is your bottleneck.
- If the tail is index-build time on non-critical indexes, you *can* bring the
  site up and build those `CONCURRENTLY` afterward — only for indexes the app can
  briefly live without.
