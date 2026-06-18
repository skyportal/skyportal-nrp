# skyportal-nrp

NRP Nautilus deployment of SkyPortal — a thin overlay (values + secrets + Makefile) on the
generic chart [skyportal-k8s-deploy](https://github.com/skyportal/skyportal-k8s-deploy).
Namespace **`skyportal`** on the `nautilus` kube-context; live at
`https://skyportal.nrp-nautilus.io`. Use explicit **`--context nautilus -n skyportal`**.

```
values-nrp.yaml       # rook-ceph-block / rook-cephfs storage, haproxy ingress, host, image tag
secrets.example.yaml  # -> secrets.yaml (gitignored): DB pw, app.secret_key, server.*, Google OAuth
.env.example          # -> .env (gitignored): GOOGLE_OAUTH2_*, ADMIN_EMAIL, GCN_CLIENT_*
Makefile              # CHART=../skyportal-k8s-deploy/chart; make install / status / logs ROLE=...
```

## Deploy

Generic walkthrough + gotchas live in the chart's README; the NRP-specific sequence:

```bash
git clone git@github.com:skyportal/skyportal-k8s-deploy.git ../skyportal-k8s-deploy

# 1. Image — build linux/amd64 (cluster is x86; arm64 -> CrashLoop "exec format error"), push to
#    ghcr, and set the package PUBLIC. From a skyportal checkout with baselayer #424:
docker buildx build --platform linux/amd64 -t ghcr.io/skyportal/skyportal:<tag> --push .
#    set image.tag=<tag> in values-nrp.yaml

# 2. Secrets — cp secrets.example.yaml secrets.yaml; fill DB pw, app.secret_key, the Google
#    key+secret, and server.host=skyportal.nrp-nautilus.io / server.port: 443 / server.ssl: True.
make install                          # applies secrets.yaml, then helm install -f values-nrp.yaml

# 3. Schema + admin (in the app pod; PATH=/usr/sbin for the nginx dep-check)
K="kubectl --context nautilus -n skyportal"
APP=$($K get pod -l skyportal.role=app -o jsonpath='{.items[0].metadata.name}')
$K exec "$APP" -- bash -lc 'cd /skyportal && . .venv/bin/activate && export PATH=/usr/sbin:$PATH && make db_init && make db_create_tables'
$K exec "$APP" -- bash -lc 'cd /skyportal && . .venv/bin/activate && export PATH=/usr/sbin:$PATH && PYTHONPATH=. python skyportal/initial_setup.py $FLAGS --adminusername=<your-google-email>'
$K exec skyportal-postgres-0 -- psql -U skyportal -d skyportal -c \
  "UPDATE users u SET oauth_uid = s.uid FROM usersocialauths s WHERE s.user_id = u.id;"
#    Then Login -> Google at https://skyportal.nrp-nautilus.io as Super admin.
```

## NRP specifics (what bit us)

- **Storage:** `rook-ceph-block` (RWO, Postgres) + `rook-cephfs` (RWX, data). There is **no `-west`**
  class — the docs' "west = default" is the unsuffixed pool; the `-central`/us-central pool is full.
  NRP reclaims volumes untouched for >6 months (with notice to admins).
- **Ingress/TLS:** `haproxy`; `*.nrp-nautilus.io` gets a wildcard cert automatically, so
  `ingress.tls.clusterIssuer: ""` (no cert-manager).
- **`server.port: 443` is mandatory** — split workers poll `server.host:server.port/api/sysinfo`
  through the ingress (hairpin); the default `5000` hangs the whole worker tier with
  "Waiting for the app to start…". (nginx listens on a separate `ports.app`, so 443 is safe.)
- **Admin first login** errors `'NoneType'…contact_email` until the `oauth_uid` UPDATE above
  (`initial_setup` leaves `users.oauth_uid` null).
- **GCN:** keep `GCN_CLIENT_*` in `.env`; add `gcn.client_id` / `client_secret` / `client_group_id`
  and the `notice_types` (15 voevent + 3 json — copy from `fritz-deploy/deploy.py`) to the secret
  config.yaml, then restart the workers. `gcn_service` then ingests live events.
- Secrets live only in the k8s Secret + gitignored `.env` — never in the repo.

## Alert ingestion (babamul)

Live ZTF/LSST alerts come from the babamul broker via the
[babamul-skyportal-plugin](https://github.com/skyportal/babamul-skyportal-plugin) (a SkyPortal
external service). **NRP pods can't resolve `github.com`, so the plugin is baked into the image**
instead of cloned at startup — otherwise `setup_services` fails to clone, hits `KeyError: 'babamul'`,
and CrashLoops the whole workers pod.

```bash
# 1. Bake an overlay image (base + plugin at services.paths[-1] = /skyportal/services; strip repo/rev
#    from the plugin's config.yaml.defaults so it's treated as present-not-cloned -> no clone, no KeyError).
git clone https://github.com/skyportal/babamul-skyportal-plugin.git babamul
( cd babamul && rm -rf .git && sed -i '' '/^[[:space:]]*repo:/d; /^[[:space:]]*rev:/d' config.yaml.defaults )
printf 'FROM ghcr.io/skyportal/skyportal:amd64\nCOPY --chown=skyportal:skyportal babamul /skyportal/services/babamul\n' > Dockerfile
docker buildx build --platform linux/amd64 -t ghcr.io/skyportal/skyportal:amd64-babamul3 --push .  # bump the tag each rebuild to force a re-pull
#    values-nrp.yaml pins image.tag (currently amd64-babamul3) and lists `babamul` in roles.workers.enabled.
#    Never `--set image.tag=amd64` on upgrade (it drops babamul).

# 2. Streams + filter + access (run once in the app pod, via the models): create `ZTF Public` and
#    `LSST` streams, a `babamul` Filter on the ZTF stream in the Sitewide group (id 1), attach both
#    streams to group 1, and give each scanning user group-1 membership + stream access. Without a
#    filter, alerts ingest as Objs+photometry only and never reach the scanning page.

# 3. Secret config `services.external.babamul.params` (creds + ingest targets — note: NO repo/rev,
#    the plugin is baked), then restart the workers:
#      kafka:  {host: kaboom.caltech.edu, port: 9093, username, password, sasl_mechanism: SCRAM-SHA-512,
#               topics: [babamul.ztf.no-lsst-match.hosted, babamul.ztf.lsst-match.hosted]}
#      ingest: {filter_ids: [<babamul filter>], group_ids: [1], ztf_stream_ids: [<ZTF Public>], lsst_stream_ids: [<LSST>]}
#      api:    {base_url: https://babamul.caltech.edu/api/babamul, token: <BABAMUL_API_TOKEN>}  # cutout thumbnails
$K rollout restart deployment/skyportal-workers    # re-reads from earliest (offsets are never committed)
```

Per alert the plugin creates an Obj, fetches its **new/ref/sub cutout thumbnails** from the babamul
API (the `api` block above), ingests photometry (ZTF, plus the LSST `survey_matches` object linked
via a SuperObj), and registers a Candidate under each `filter_ids`. Notes: workers use
`strategy: Recreate` (single instance — no duplicate queues/gcn); the plugin dedupes photometry by
SkyPortal's `(origin, mjd, fluxerr, flux)` upsert key (babamul repeats the current detection in
prv_candidates). Cutouts are fetched only on **first sight** of an Obj — to backfill existing
objects, loop the plugin's `add_cutout_thumbnails` with a **fresh `DBSession()` per object** (sharing
one session cascades `Can't operate on closed transaction`).

## Thumbnails — two gotchas

- **PanSTARRS:** `Obj.panstarrs_url` scrapes `ps1images.stsci.edu` server-side, but treats an
  empty/None `app.ps1_cutout_url` as "skip" → returns the `currently_unavailable` placeholder
  (SDSS/Legacy-Survey are direct URLs, so they're unaffected). Set
  `app.ps1_cutout_url: http://ps1images.stsci.edu/cgi-bin/ps1cutouts` in the secret config.
- **File permissions:** cutout PNGs are written to `static/thumbnails`, a shared `rook-cephfs`
  subPath. The kubelet creates it `root:root` and `fsGroup: 1000` does **not** chown subPaths, so
  uid-1000 pods get `[Errno 13] Permission denied`. Fix once with a root pod:
  `chown -R 1000:1000 /mnt/thumbnails` (PVC `skyportal-data` mounted at `/mnt`).
