# skyportal-nrp

NRP Nautilus deployment of SkyPortal — an overlay (values + manifests + Makefile) on the generic
chart [skyportal-k8s-deploy](https://github.com/skyportal/skyportal-k8s-deploy). Namespace
**`skyportal`** on the `nautilus` kube-context; live at `https://skyportal.nrp-nautilus.io`.
Use explicit **`--context nautilus -n skyportal`** — this repo touches two clusters.

> This repo is **public**. Real secrets live in the k8s Secret and in the private
> [skyportal-nrp-deploy](https://github.com/skyportal/skyportal-nrp-deploy); only `*.example.*`
> files are committed here.

```
values-nrp.yaml          # storage classes, ingress, image tag, worker list, resources
secrets.example.yaml     # -> secrets.yaml (gitignored): DB pw, app.secret_key, OAuth, GCN, SMTP, Hermes
.env.example             # -> .env (gitignored)
Makefile                 # CHART=../skyportal-k8s-deploy/chart; image / install / upgrade / logs
skyportal/               # submodule, pinned; the image is built from exactly this commit
.github/workflows/       # build-image.yml (publishes to GHCR), validate.yml (helm + kubeconform)
db/                      # CloudNativePG cluster, backups, benchmarks, demo restore + runbooks
osg/                     # OSG plugin as a standalone Deployment
observability/           # Grafana (Prometheus sidecar itself comes from the chart)
loadtest/                # k6 job
```

**The chart is on a non-default branch.** `skyportal-k8s-deploy`'s default branch (`master`) still
holds the older kustomize layout with no `chart/` directory — the Helm chart lives on
**`modernize-helm-chart`**. Clone accordingly:

```bash
git clone -b modernize-helm-chart git@github.com:skyportal/skyportal-k8s-deploy.git ../skyportal-k8s-deploy
```

## Image

Built by [`.github/workflows/build-image.yml`](.github/workflows/build-image.yml) on push, natively
on amd64 runners, and published to **`ghcr.io/skyportal/skyportal-nrp`** (public package). The tag is
`sp-<skyportal submodule short sha>`.

```bash
make print-tags        # what the current submodule commit maps to
make image             # same tag, built locally (needs docker + ghcr login)
```

Both the Makefile and the workflow use `git rev-parse --short=7` deliberately. `--short` alone is
*adaptive* — a large local clone picks 8 chars where a CI runner picks 7, so the two produce
different tags for the same commit and `values-nrp.yaml` ends up pointing at an image that was never
pushed.

Bumping the app is: update the `skyportal` submodule → push (CI builds) → set `image.tag` in
`values-nrp.yaml` **and** the image in [`osg/deployment.yaml`](osg/deployment.yaml) → `make upgrade`.
The OSG deployment runs the same image and is not managed by Helm, so it drifts silently if missed.

Cross-building locally on an arm64 Mac works but is slow, and fails confusingly when Docker's VM disk
fills: truncated downloads surface as `At least one invalid signature was encountered` from apt.
Prefer CI.

## Deploy

```bash
make secrets     # kubectl apply -f secrets.yaml   (see skyportal-nrp-deploy)
make install     # or: make upgrade
make status
make logs ROLE=app
```

Migrations are **not** run at startup — `db_migrate` is a separate target. After deploying a new
image:

```bash
APP=$(kubectl --context nautilus -n skyportal get pod -l skyportal.role=app -o jsonpath='{.items[0].metadata.name}')
kubectl --context nautilus -n skyportal exec $APP -c skyportal -- bash -c \
  'cd /skyportal && source .venv/bin/activate && PYTHONPATH=. python -m alembic -x config=/etc/skyportal/config.yaml current'
```

Pass a **single** `-x config=` — Alembic collapses repeated keys to the last one, so the usual
three-file `FLAGS` silently drops the database block and falls back to `localhost`.

## Database

The app talks to **`skyportal-demo-db`** (a plain `postgres:18` Deployment on an 800Gi
`rook-ceph-block` PVC), not the chart's `skyportal-postgres`. It is restored from a Fritz dump in
`gs://fritz-db-exports/demo/` by [`db/17-demo-restore.yaml`](db/17-demo-restore.yaml) — see
[`db/README.md`](db/README.md) for the CloudNativePG cluster, backups and PITR, benchmarks, and the
migration runbook.

> **`synchronous_commit=off`** is still set in the restore manifest. It is load tuning that was never
> reverted (the runbook says to turn it back on post-load), and it is the most likely cause of the
> August 2026 incident where the volume survived but Postgres would not start:
> `PANIC: could not locate a valid checkpoint record`. There are **no backups of this database** —
> the PITR design in `db/` targets the CNPG cluster, which was never cut over to.

Recovery from that state is a rebuild: scale the deployment to 0, rename `pgdata` aside, scale up
(Postgres re-initialises), then re-run the restore Job. Scale `skyportal-app` and `skyportal-workers`
to 0 for the duration — otherwise the app's connections wedge `pg_restore` behind lock convoys.

## Users, invitations, email

`invitations.enabled: true`, with SMTP via the shared Fritz gmail account, so invitation mail arrives
**from `fritz.astro.marshal@gmail.com`** — tell invitees to check spam. Invites expire after
**3 days** (`days_until_expiry`); Fritz uses 7.

## Sharing with Fritz over HERMES

Sources flow **Fritz → NRP** through [HERMES](https://hermes.lco.global) on SCiMMA's Kafka.

| Side | What |
|------|------|
| Fritz | sharing service `NRP Share (Hermes)`, group `NRP Share`, streams **ZTF Public + LSST** |
| NRP | `hermes_skyportal_sync` worker → group `HERMES Shared`, saved by bot `hermes-bot` |

Publishing is **event-driven on save**, not a backfill, and needs three things together: the sharing
service has `enable_sharing_with_hermes`, the group has `auto_share_to_hermes`, **and the saving user
is registered as an auto-publisher** on that sharing-service group. Missing the third is silent — no
submission row is created at all.

Config lives under `app.hermes` in the secret. The consumer refuses to start unless
`scimma_username`, `scimma_password`, `kafka_server`, `topic`, `bot_user_id` and `group_ids` are all
set. Notes that cost time:

- The credential is a **SCiMMA Hopskotch credential** created at
  [my.hop.scimma.org](https://my.hop.scimma.org/hopauth/) — username + password, password shown once.
  It is *not* the "SCiMMA Auth Credential" on the HERMES profile page, whose password HERMES keeps to
  itself, and not your CILogon login.
- SCiMMA restricts **consumer group names** to your username prefix. The service builds
  `<username>-<topic>-monitor`, which passes; anything else gets `GROUP_AUTHORIZATION_FAILED`, which
  reads like a topic permission error but is not.
- Photometry import is skipped unless `instrument_tns_ids` is set **and** the matching instruments
  carry a `tns_id`. Neither is populated by a restore. IDs are in
  [`skyportal/utils/tns.py`](https://github.com/skyportal/skyportal/blob/main/skyportal/utils/tns.py)
  — `ztf: 196`, `lsst: 287`.
- Keep incoming and outgoing groups **separate**. A group that both receives and auto-shares
  republishes what it just received, straight back to the same topic.

NRP → Fritz is not live: NRP has no HERMES API token, and Fritz runs no sync consumer.

## NRP specifics (what bit us)

- **Storage:** `rook-ceph-block` (RWO, Postgres) + `rook-cephfs` (RWX, data). There is **no `-west`**
  class — the docs' "west = default" is the unsuffixed pool; the `-central`/us-central pool is full.
  NRP reclaims volumes untouched for >6 months (with notice to admins).
- **Ingress/TLS:** `haproxy`; `*.nrp-nautilus.io` gets a wildcard cert automatically, so
  `ingress.tls.clusterIssuer: ""` (no cert-manager).
- **`server.port: 443` is mandatory** — split workers poll `server.host:server.port/api/sysinfo`
  through the ingress (hairpin); the default `5000` hangs the whole worker tier with
  "Waiting for the app to start…". (nginx listens on a separate `ports.app`, so 443 is safe.)
- **Admin first login** errors `'NoneType'…contact_email` until `users.oauth_uid` is backfilled
  (`initial_setup` leaves it null):
  `UPDATE users u SET oauth_uid = s.uid FROM usersocialauths s WHERE s.user_id = u.id;`
- **Cross-node pod networking is unreliable.** The OSG Service is headless and its pods have
  `podAffinity` onto the app node, because the app could reach pod IPs but not the ClusterIP VIP.
- **GCN** has its own NRP credentials (`client_group_id: skyportal-nrp`), not Fritz's.

## Thumbnails — two gotchas

- **PanSTARRS:** `Obj.panstarrs_url` scrapes `ps1images.stsci.edu` server-side, but treats an
  empty/None `app.ps1_cutout_url` as "skip" → returns the `currently_unavailable` placeholder
  (SDSS/Legacy-Survey are direct URLs, so they're unaffected). Set
  `app.ps1_cutout_url: http://ps1images.stsci.edu/cgi-bin/ps1cutouts` in the secret config.
- **File permissions:** cutout PNGs are written to `static/thumbnails`, a shared `rook-cephfs`
  subPath. The kubelet creates it `root:root` and `fsGroup: 1000` does **not** chown subPaths, so
  uid-1000 pods get `[Errno 13] Permission denied`. Fix once with a root pod:
  `chown -R 1000:1000 /mnt/thumbnails` (PVC `skyportal-data` mounted at `/mnt`).

The `thumbnail_queue` worker re-runs an anti-join over every obj against every thumbnail every few
seconds and never converges on a Fritz-sized database. Consider dropping it from
`roles.workers.enabled` unless thumbnails are actively being backfilled.

## Retired

**babamul** alert ingestion (ZTF/LSST via the babamul broker plugin, baked into an overlay image) is
no longer deployed — it is absent from `roles.workers.enabled` and from the image. The plugin needed
baking in because NRP pods cannot resolve `github.com`, which remains true of anything that clones at
startup. Git history has the details if it is ever revived.
