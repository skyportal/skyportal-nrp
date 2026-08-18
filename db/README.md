# Production Postgres on NRP (CloudNativePG)

Replaces the chart's single-pod `skyportal-postgres` StatefulSet with a
[CloudNativePG](https://cloudnative-pg.io/) (CNPG) managed cluster that adds the
production-DB layer Cloud SQL gave us for free: an **HA replica with automated
failover**, **continuous backup + point-in-time recovery to S3**, guaranteed
(non-preempted) QoS, and a transaction-mode pooler.

The cluster is named **`skyportal-db`** so it runs *alongside* the chart's
`skyportal-postgres` — you migrate the data, cut the app over, then retire the
old one. Nothing here is wired into the app until you change the secret (step 4).

| File | What |
|------|------|
| `01-s3-credentials.example.yaml` | Ceph RGW (S3) key pair for backups → `skyportal-db-s3` Secret |
| `02-app-credentials.example.yaml` | Password for the `skyportal` role → `skyportal-db-app` Secret |
| `03-cluster.yaml` | The CNPG `Cluster` (HA, WAL volume, tuned params, S3 backup) |
| `04-scheduledbackup.yaml` | Daily base backup (WAL archiving is in the Cluster) |
| `05-pooler.yaml` | PgBouncer transaction pooler (`skyportal-db-pooler-rw`) |
| `06-migration-runbook.md` | Timed trial (= Ceph benchmark) + one-go `pg_dump`/`pg_restore` cutover |
| `07-restore-job.yaml` | In-cluster Job: GCS-fetch dump → parallel `pg_restore` + analyze |
| `07-gcs-credentials.example.yaml` | GCP SA key for the Job's GCS fetch → `skyportal-db-gcs` Secret |

All commands assume `-n skyportal --context nautilus`.

## 0. Prerequisite: the CNPG operator

CNPG is a cluster-scoped operator (installs CRDs). On a shared cluster it may
already be present — check first, and only install if not (coordinate with NRP
admins, since CRD install is cluster-wide):

```bash
kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 && echo "CNPG present" || \
  kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
```

(Check for the current release tag; pin whatever the cluster standardizes on.)

## 1. Size it before you apply

Edit `03-cluster.yaml` for reality — these are the fields that matter:
- **`storage.size`** — production is ~700 GB today (photometry heap + indexes);
  set with headroom for growth, bloat, and the pending bigint rewrite (1500Gi
  placeholder).
- **`resources`** — requests==limits for Guaranteed QoS; size to your allocated
  node. `shared_buffers` is set to ~25% of the 32Gi memory placeholder.
- **Backups (09-backup.yaml)** — NRP uses portal S3 tokens, not OBC. Generate a
  token at the User Portal `/s3token/` (Central pool; admins confirmed ~1 TB is
  fine), create the `skyportal-db-backups` bucket, and use the in-cluster Central
  endpoint `http://rook-ceph-rgw-centrals3.rook-central`.
- **`instances`** — 2 (primary + 1 standby). Bump to 3 and enable
  `postgresql.synchronous` for zero-data-loss failover.

> **Benchmark Ceph RBD first.** The test instance only ever saw a 100Gi babamul
> volume. Postgres on networked RBD at ~1 TB under real query load is the biggest
> unknown in the whole move — validate throughput/latency before cutover.

## 2. Secrets

```bash
cp 01-s3-credentials.example.yaml 01-s3-credentials.yaml   # fill NRP S3 token (portal, Central)
cp 02-app-credentials.example.yaml 02-app-credentials.yaml # password == skyportal-secrets postgres-password
kubectl apply -f 01-s3-credentials.yaml
kubectl apply -f 02-app-credentials.yaml
```

The `skyportal-db-app` password **must equal** `postgres-password` /
`database.password` in `../secrets.yaml`, or the app can't authenticate.
`*.yaml` here is gitignored (see below) — only the `.example` files are committed.

## 3. Create the cluster

```bash
kubectl apply -f 03-cluster.yaml
kubectl apply -f 04-scheduledbackup.yaml
kubectl apply -f 05-pooler.yaml            # optional but recommended

# Watch it come up (initdb -> primary -> standby joins):
kubectl get cluster skyportal-db -w
kubectl cnpg status skyportal-db           # if the `cnpg` kubectl plugin is installed
```

## 4. Migrating the data

For the **one-go `pg_dump`/`pg_restore` path — and the timed trial you should run
first to get the real downtime number + benchmark Ceph — follow
[`06-migration-runbook.md`](06-migration-runbook.md). Summary of the options by
downtime tolerance:

- **Fresh (no data)** — the default `bootstrap.initdb` gives an empty DB. Run
  SkyPortal's schema against it (`make db_init` + `migration_manager`/
  `alembic upgrade head`). Use this to validate the cluster before a real move.
- **Bulk copy at bootstrap** — swap `initdb` for the commented `initdb.import`
  (microservice) block in `03-cluster.yaml`; CNPG runs `pg_dump`/`pg_restore`
  from the source over the network. Downtime ≈ dump+restore+reindex (hours at
  ~1 TB). Fine for a long maintenance window.
- **Low-downtime (recommended for prod)** — logical replication / GCP DMS into
  the empty cluster: initial bulk load runs live, then a short cutover.
  Caveats: every table needs a replica identity (relevant to the bigint-PK
  work), sequences resync manually, DDL isn't replicated. Cutover = stop writers,
  let replication drain, promote, flip step 5.

**After any migration**: resync sequences if needed, then take an immediate base
backup (`kubectl cnpg backup skyportal-db`) so PITR has a fresh anchor.

## 5. Cut the app over

In `../secrets.yaml`, point the app at CNPG and re-apply:

```yaml
database:
  host: skyportal-db-pooler-rw   # or skyportal-db-rw if you skipped 05-pooler
  port: 5432
  user: skyportal
  database: skyportal
  password: "<same as skyportal-db-app>"
```

```bash
kubectl apply -f ../secrets.yaml
kubectl rollout restart deployment/skyportal-app deployment/skyportal-workers
```

Verify the app is healthy against the new DB, then **retire the chart Postgres**.
The chart has no `postgres.enabled` toggle, so either:
- scale it down: `kubectl scale statefulset skyportal-postgres --replicas=0`, or
- (cleaner, worth upstreaming) guard `templates/postgres.yaml` +
  the postgres `Service` with `{{- if .Values.postgres.enabled }}` and set
  `postgres.enabled: false` in `values-nrp.yaml`.

Keep the old volume until the new DB is verified in production — that's the
rollback.

## Restore / PITR drill (do this before you rely on it)

Recovery is a *new* Cluster that bootstraps from the S3 store:

```yaml
spec:
  bootstrap:
    recovery:
      source: skyportal-db
      # recoveryTarget: { targetTime: "2026-07-15 18:00:00+00" }   # for PITR
  externalClusters:
    - name: skyportal-db
      barmanObjectStore:
        destinationPath: s3://skyportal-db-backups/
        endpointURL: http://rook-ceph-rgw-centrals3.rook-central
        s3Credentials:
          accessKeyId:     { name: skyportal-db-s3, key: ACCESS_KEY_ID }
          secretAccessKey: { name: skyportal-db-s3, key: ACCESS_SECRET_KEY }
```

A backup you haven't restored is a hope, not a backup — run this drill once into
a throwaway namespace and confirm row counts before trusting it.

## NRP notes
- **Guaranteed QoS** (requests==limits) keeps the DB pods off the preemption
  list — important on this shared platform. Confirm your namespace actually gets
  the reserved CPU/mem you request.
- **Backups live off the cluster** (Ceph RGW S3), so a node/RBD incident — or the
  ">6 months untouched → reclaimed" volume policy — isn't fatal.
- **Storage class** is `rook-ceph-block` (RWO); there is no `-west` block class,
  the unsuffixed pool is the default (per the top-level README).
