# Cutover via logical replication (the viable path)

**Why this, not one-go dump/restore:** the timed benchmark proved a one-go
`pg_restore` of the 148 GB dump onto NRP Ceph runs **>12 h and doesn't finish** —
the index rebuild (partitioned `localizationtiles` + `photometry`) is the wall on
networked Ceph. So the bulk copy + index build **cannot** live inside a
maintenance window. Logical replication moves all of that **live, before
cutover**, leaving only a short drain+promote at the end.

```
Cloud SQL fritz-psql14 (PG18, publisher)  ──logical replication──►  NRP postgres:18 (subscriber, Ceph)
        stays live on GCP                    initial sync + CDC          builds the 12h of indexes LIVE
                                                                         ▼
                                          short cutover: drain → promote → flip DNS (minutes)
```

Target on NRP: **plain `postgres:18` StatefulSet on `rook-ceph-block`** (Zalando
can't do PG18; LINSTOR can't be co-located here — see 15/notes).

## The connectivity problem (solve first)

Cloud SQL `fritz-psql14` is **private-IP only** (`10.49.1.19`) and NRP compute has
scattered, unpredictable egress IPs — so public-IP + authorized-networks
allowlisting is impractical. Use the **Cloud SQL Auth Proxy** on NRP instead: it
tunnels to Cloud SQL via the Admin API + a GCP service-account key (works from
anywhere, no VPC peering). The NRP subscriber connects to the proxy, not directly.

- Run `gcr.io/cloud-sql-connectors/cloud-sql-proxy` as a Deployment+Service in the
  `skyportal` namespace, with a GCP SA key (roles/cloudsql.client) mounted.
- Subscriber `CONNECTION` host = the proxy Service; the proxy → Cloud SQL.

## Phase 0 — source prep on Cloud SQL (no downtime)

1. Flags (needs a restart — schedule it): `cloudsql.logical_decoding=on`,
   `max_replication_slots` and `max_wal_senders` ≥ a few. `wal_level` becomes
   `logical`.
2. A replication role: `CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD '…';`
   and grant `SELECT` on all tables (Cloud SQL: `cloudsqlsuperuser` grants).
3. Publication: `CREATE PUBLICATION fritz_pub FOR ALL TABLES;`
4. **Replica identity audit** — every table needs a PK or `REPLICA IDENTITY FULL`
   for UPDATE/DELETE to replicate. SkyPortal is mostly PK'd; audit and fix any
   that aren't (this is the same property the bigint-PK work cared about).

## Phase 1 — subscriber initial sync on NRP (LIVE, ~12h, no downtime)

1. Stand up `postgres:18` on `rook-ceph-block` (the StatefulSet; size to the
   ~482 GB+ we saw restored, with headroom).
2. **Create the schema at Fritz's alembic head** so the DB matches the app you'll
   run (`make db_init` + `alembic upgrade head` at the matching skyportal commit —
   see 06 §"App & integration alignment"; this is what avoids re-running the
   reverted bigint migration).
3. To keep the initial COPY fast, drop the heavy secondary indexes first, then:
   ```sql
   CREATE SUBSCRIPTION fritz_sub
     CONNECTION 'host=cloud-sql-proxy port=5432 dbname=fritz-1 user=repl password=…'
     PUBLICATION fritz_pub WITH (copy_data = true, streaming = on);
   ```
   Initial `COPY` of all tables begins (this is the bulk transfer).
4. After initial COPY completes, **rebuild the dropped indexes** — this is the
   ~12 h, but it runs while Fritz serves users on GCP and CDC keeps flowing.
5. **Monitor**: `pg_stat_subscription` (subscriber) and, on Cloud SQL,
   `pg_replication_slots` lag. ⚠️ A stalled subscriber makes the slot **retain
   WAL on Cloud SQL → grows prod disk**. Alert on slot lag and be ready to drop
   the slot if the subscriber falls hopelessly behind.

## Phase 2 — during the sync window
- **Freeze schema changes on Fritz** (no `alembic upgrade` on GCP deploys) — DDL
  does NOT replicate and a mismatch breaks replication. Or apply each migration to
  both sides in lockstep.
- **Pre-seed the filesystem** (thumbnails 400 GB + persistentdata 200 GB) per
  06 §"Filesystem data" — incremental rsync, so only the final delta lands at
  cutover.

## Phase 3 — cutover (minutes)
1. Announce; **stop Fritz writers** on GCP (scale app+workers to 0).
2. **Let replication drain** — wait until subscriber lag = 0
   (`pg_stat_subscription.latest_end_lsn` caught up).
3. **Resync sequences** — logical replication does NOT copy sequence values;
   `setval()` each from the source (`pg_sequences` on Cloud SQL).
4. **Promote**: `DROP SUBSCRIPTION fritz_sub;` on NRP (now standalone).
5. **Final filesystem delta** rsync.
6. Point the NRP app at the NRP DB (secrets.yaml), scale it up, smoke-test;
   re-point babamul to Fritz's streams/filters (06 §3).
7. **Flip `fritz.science` A record** → `131.193.183.215` (TTL lowered a day prior).
8. Take a base backup to the Central S3 bucket (PITR anchor).

## Rollback
Keep Cloud SQL live and read-only until NRP is proven. Before the DNS flip,
aborting is just "revert secrets, scale Fritz back up on GCP." After the flip,
flip the A record back to `35.244.192.22`.

## Caveats recap
- Replica identity on every table; sequences resync at cutover; DDL frozen during
  the window; large objects not replicated (SkyPortal uses files, not pg LOs — OK);
  stuck-slot WAL retention threatens Cloud SQL disk — monitor it.
