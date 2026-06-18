# skyportal-nrp — NRP Nautilus overlay on the skyportal-k8s-deploy chart.
NS      ?= skyportal
RELEASE ?= skyportal
CHART   ?= ../skyportal-k8s-deploy/chart   # sibling clone (or a submodule)
VALUES  ?= values-nrp.yaml
SECRETS ?= secrets.yaml
ROLE    ?= app

.PHONY: help secrets lint template install upgrade uninstall status logs osg-secret osg osg-logs

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
