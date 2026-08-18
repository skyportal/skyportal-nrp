# skyportal-nrp — NRP Nautilus overlay on the skyportal-k8s-deploy chart.
NS      ?= skyportal
RELEASE ?= skyportal
CHART   ?= ../skyportal-k8s-deploy/chart   # sibling clone (or a submodule)
VALUES  ?= values-nrp.yaml
SECRETS ?= secrets.yaml
ROLE    ?= app

REGISTRY      ?= ghcr.io/skyportal/skyportal-nrp
SKYPORTAL_SHA := $(shell git -C skyportal rev-parse --short HEAD 2>/dev/null)
# Same scheme the CI workflow uses, so a local build and a CI build of the same
# submodule commit produce the same tag.
BASE_TAG      ?= sp-$(SKYPORTAL_SHA)
PLATFORM      ?= linux/amd64

.PHONY: help secrets lint template install upgrade uninstall status logs osg-secret osg osg-logs image print-tags

help:
	@echo "skyportal-nrp (NS=$(NS), CHART=$(CHART)):"
	@echo "  secrets / lint / template / install / upgrade / uninstall / status / logs ROLE=..."
	@echo "  CHART must point at the skyportal-k8s-deploy chart (default: sibling clone)."

secrets:
	kubectl apply -n $(NS) -f $(SECRETS)

lint:
	helm lint $(CHART) -f $(VALUES)

template:
	helm template $(RELEASE) $(CHART) -f $(VALUES)

install: secrets
	helm install $(RELEASE) $(CHART) -n $(NS) -f $(VALUES)

upgrade:
	helm upgrade $(RELEASE) $(CHART) -n $(NS) -f $(VALUES)

uninstall:
	helm uninstall $(RELEASE) -n $(NS)

status:
	kubectl get pods,svc,ingress,pvc,statefulset -n $(NS)

logs:
	kubectl logs -n $(NS) -l skyportal.role=$(ROLE) --tail=200 -f

# --- OSG plugin service (standalone Deployment, see osg/README.md) ---
osg-secret:
	kubectl apply -n $(NS) -f osg/secret.yaml

osg:
	kubectl apply -n $(NS) -f osg/deployment.yaml

osg-logs:
	kubectl logs -n $(NS) -l skyportal.role=osg --tail=200 -f

# --- Image (from the pinned skyportal submodule; needs docker + ghcr login) ---
# OSG is baked into the base image (services/osg); no separate overlay.
image:  ## build+push the base skyportal image at the pinned commit
	docker buildx build --platform $(PLATFORM) -t $(REGISTRY):$(BASE_TAG) --push skyportal

print-tags:  ## show the image tag for the pinned commit
	@echo "base: $(REGISTRY):$(BASE_TAG)"
