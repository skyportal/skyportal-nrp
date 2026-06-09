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
