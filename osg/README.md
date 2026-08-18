# OSG plugin service on NRP

Deploys [`osg-skyportal-plugin`](https://github.com/skyportal/osg-skyportal-plugin)
as a **standalone control-plane service** in the `skyportal` namespace. It submits
one HTCondor job per analysis request to the OSPool AP `ap41.uw.osg-htc.org`,
polls, and POSTs results back to SkyPortal. The fit itself runs on an OSPool
worker — NRP only runs the submit/poll/callback loop.

The plugin repo is generic; everything NRP-specific (our image tag, namespace,
ClusterIP naming, the `michael.coughlin` / `UMN_Coughlin` OSG account, the
SciToken) lives **here** in skyportal-nrp.

Artifacts:
- `deployment.yaml` — `skyportal-osg` Deployment + ClusterIP Service on `7100`.
  Runs the osg service baked into the base image at `/skyportal/services/osg`.
- `secret.example.yaml` — config.yaml (osg params) + SciToken(s); copy to
  `secret.yaml` (gitignored) and fill in.

## Prereqs (one-time)

1. **An ap41 SciToken** for the `michael.coughlin` OSG account. Remote submission
   needs an IDTOKEN signed by the AP:
   ```sh
   ssh michael.coughlin@ap41.uw.osg-htc.org 'condor_token_fetch -lifetime 3600000' > osg.use
   ```
   (`bin/setup_ospool.py --user michael.coughlin` in the plugin repo automates the
   local install; for k8s we just need the file's contents.) **The token must stay
   fresh** — `htcondor.keepalive: true` parks a held placeholder job on the AP so
   the credmon keeps refreshing it. If the AP has never stored a credential for you,
   bootstrap once with a real `condor_submit` on ap41.
2. **An incoming bearer token** SkyPortal will send to the plugin:
   ```sh
   python3 -c "import secrets; print(secrets.token_urlsafe(32))"
   ```
3. A SkyPortal admin API token (for the register step).

## Build the image

OSG is baked into the base skyportal image (`services/osg` + htcondor); there is
no separate OSG image. Build/push it from the repo root:

```sh
make image        # ghcr.io/skyportal/skyportal:fritz-<sha>
make print-tags   # show the tag
```

## Deploy

```sh
cp osg/secret.example.yaml osg/secret.yaml
# edit osg/secret.yaml: paste osg.use contents, set incoming_bearer_token,
# adjust project_name / singularity_image / collector if OSG moved you.

make osg-secret          # kubectl -n skyportal apply -f osg/secret.yaml
make osg                 # kubectl -n skyportal apply -f osg/deployment.yaml
kubectl -n skyportal rollout status deploy/skyportal-osg
kubectl -n skyportal logs -l skyportal.role=osg --tail=100 -f
```

Healthy startup: `listening on 0.0.0.0:7100`, a `rehydrate` line (empty JOBS on a
fresh AP is fine), and — with keepalive on — a parked placeholder job.

> NRP node note: the `cph-blade*.humboldt.edu` nodes have flaky `ghcr.io` DNS
> (ImagePullBackOff). If the pod lands there, delete it to reschedule until it
> lands on a node that can pull (e.g. `gp-argo.usd.edu`, `nrp-c17.nysernet.org`).

## Register the AnalysisService in SkyPortal

`--listener-url` is the ClusterIP Service **plus the `/analysis/<name>` path**,
and `<name>` must equal `--name`:

```sh
# register_analysis_service.py lives in the plugin repo; clone it and run:
#   git clone https://github.com/skyportal/osg-skyportal-plugin && cd osg-skyportal-plugin
python3 register_analysis_service.py \
  --name nmma_osg \
  --display "NMMA (OSG/OSPool)" \
  --listener-url http://skyportal-osg:7100/analysis/nmma_osg \
  --bearer   <incoming_bearer_token> \
  --base-url https://skyportal.nrp-nautilus.io \
  --token    <skyportal-admin-token> \
  --group-ids 1
```

Then trigger an analysis on a source to smoke-test end to end.

## Verify

```sh
# in-cluster reachability (from any pod in the namespace):
kubectl -n skyportal exec deploy/skyportal-app -- curl -sf http://skyportal-osg:7100/jobs
# the plugin's token view (use the venv python — system python3 lacks the deps):
kubectl -n skyportal exec deploy/skyportal-osg -- /skyportal/.venv/bin/python services/osg/bin/check_token.py /secrets/scitokens/osg.use
```

## Open items

- **SciToken refresh** is the fragile part — confirm the AP credmon keeps the
  keepalive token alive, or wire an external renewer (htvault/oidc-agent) that
  rewrites the secret.
- Egress: the pod needs ap41 (HTCondor/CCB) + OSDF origins + back to SkyPortal.
  NRP allows egress by default; add no NetworkPolicy unless the namespace is
  default-deny.
