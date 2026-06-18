# OSG-plugin *service* image for NRP (the submit/poll/callback control plane).
#
# This recipe lives in the deploy repo (skyportal-nrp); the generic plugin code
# lives in the separate osg-skyportal-plugin checkout, which is the BUILD CONTEXT
# (the COPYs below read from it). Pattern mirrors babamul: base on the SkyPortal
# image (so baselayer + tornado/requests are already present, and base layers are
# cached on NRP nodes), add the HTCondor bindings, bake the plugin, run main.py.
#
# Build + push (linux/amd64; context = the plugin checkout). Bump the tag on any
# change — never reuse :amd64-osgN silently:
#   docker buildx build --platform linux/amd64 \
#     -f osg/Dockerfile \
#     -t ghcr.io/skyportal/skyportal:amd64-osg1 --push \
#     /Users/mcoughlin/Code/ZTF/osg-skyportal-plugin
ARG BASE=ghcr.io/skyportal/skyportal:amd64
FROM ${BASE}

# SkyPortal runs from a uv-managed venv at /skyportal/.venv (python 3.12) that
# already has tornado/requests/pyyaml; the bare `python3` on PATH is the system
# 3.11 with none of the deps. So: install into that venv and run it explicitly.
# baselayer lives in the checkout — PYTHONPATH=/skyportal makes it importable.
ENV PYTHONPATH=/skyportal

# HTCondor bindings (provides `htcondor2`, which main.py imports) into the
# skyportal venv via uv (/usr/bin/uv; the venv has no pip). The venv is owned by
# the build user, so no USER root needed.
RUN uv pip install --python /skyportal/.venv/bin/python --no-cache "htcondor>=24.0"

# The plugin runs as its own long-lived process (NOT a baselayer-supervised
# external service): copy just the plugin into its own dir and run it directly.
# `import osdf` resolves from this dir; config is read by load_env() from the
# baked config.yaml.defaults merged over the mounted config.yaml (secret).
WORKDIR /osg-skyportal-plugin
COPY main.py osdf.py fiesta_wrapper.py fiesta_bridge.py register_analysis_service.py config.yaml.defaults ./
COPY bin/ ./bin/

# Fail the build early if the runtime isn't importable in the final image.
RUN /skyportal/.venv/bin/python -c "import htcondor2, tornado, requests; from baselayer.app.env import load_env; print('osg service image OK')"

EXPOSE 7100
CMD ["/skyportal/.venv/bin/python", "main.py"]
