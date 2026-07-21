SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

KUBE_CONTEXT ?= docker-desktop
CROSSPLANE_VERSION ?= 2.3.3
TRAEFIK_CHART_VERSION ?= 40.2.0

PREFLIGHT_DIR := $(CURDIR)
STATE_DIR := $(PREFLIGHT_DIR)/.state
VALUES_FILE := $(STATE_DIR)/rmf-values.yaml
CREDENTIALS_FILE := $(STATE_DIR)/credentials.env
MANIFEST_DIR := $(PREFLIGHT_DIR)/manifests
SCRIPT_DIR := $(PREFLIGHT_DIR)/scripts
KUBECTL := kubectl --context "$(KUBE_CONTEXT)"
HELM := helm --kube-context "$(KUBE_CONTEXT)"

.PHONY: help check repos platform providers provider-configs podinfo \
        values-web values-simulation \
        apply-values rmf-namespace rmf wait-web retry-keycloak \
        setup simulation pause-simulation verify-web status credentials \
        cleanup cleanup-crds cleanup-all

help:
	@printf '%s\n' \
	  'Docker Desktop Crossplane/OpenRMF preflight' \
	  '' \
	  'Main targets:' \
	  '  make setup              Install and verify the stable web-only profile' \
	  '  make simulation         Enable and wait for rmf-sim' \
	  '  make pause-simulation   Return to the web-only profile' \
	  '  make verify-web         Recheck pods, PVCs, and browser routes' \
	  '  make credentials        Print disposable test login credentials' \
	  '  make status             Show all preflight resources' \
	  '  make cleanup            Remove named workloads and Helm releases' \
	  '  make cleanup-all        Also remove CRDs created after make check' \
	  '' \
	  'Override the context with KUBE_CONTEXT=<name> when necessary.'

check:
	@for command_name in docker kubectl helm openssl curl; do
		command -v "$$command_name" >/dev/null 2>&1 || { echo "ERROR: $$command_name is required." >&2; exit 1; }
	done
	docker version >/dev/null
	kubectl config get-contexts "$(KUBE_CONTEXT)" -o name | grep -qx "$(KUBE_CONTEXT)" || {
		echo "ERROR: kubectl context $(KUBE_CONTEXT) does not exist." >&2
		exit 1
	}
	$(KUBECTL) get nodes
	architectures="$$( $(KUBECTL) get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -u )"
	if [ "$$architectures" != 'amd64' ]; then
		echo "ERROR: this chart requires amd64 nodes; found: $$architectures" >&2
		exit 1
	fi
	mkdir -p "$(STATE_DIR)"
	chmod 0700 "$(STATE_DIR)"
	if [ ! -f "$(STATE_DIR)/preexisting-crds.txt" ]; then
		$(KUBECTL) get crd -o name | sort > "$(STATE_DIR)/preexisting-crds.txt"
	fi
	@echo 'OK: Docker Desktop preflight checks passed.'

repos:
	helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
	helm repo add traefik https://traefik.github.io/charts --force-update
	helm repo update crossplane-stable traefik

platform:
	$(HELM) upgrade --install crossplane crossplane-stable/crossplane \
		--namespace crossplane-system \
		--create-namespace \
		--version "$(CROSSPLANE_VERSION)" \
		--wait \
		--timeout 10m
	$(HELM) upgrade --install traefik traefik/traefik \
		--namespace kube-system \
		--version "$(TRAEFIK_CHART_VERSION)" \
		--wait \
		--timeout 10m

providers:
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/provider-packages.yaml"
	$(KUBECTL) wait \
		provider.pkg.crossplane.io/provider-kubernetes \
		provider.pkg.crossplane.io/provider-helm \
		--for=condition=Healthy \
		--timeout=10m

provider-configs:
	$(KUBECTL) config view --raw --minify \
		| $(KUBECTL) create secret generic docker-desktop-kubeconfig \
			--namespace crossplane-system \
			--from-file=kubeconfig=/dev/stdin \
			--dry-run=client -o yaml \
		| $(KUBECTL) apply -f -
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/provider-configs.yaml"

podinfo:
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/namespace-objects.yaml"
	$(KUBECTL) wait object/ok-docker-test-namespace \
		--for=condition=Ready --timeout=5m
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/podinfo-release.yaml"
	$(KUBECTL) wait release.helm.crossplane.io/podinfo-docker-test \
		--for=condition=Ready --timeout=10m

values-web:
	"$(SCRIPT_DIR)/generate-values.sh" false

values-simulation:
	"$(SCRIPT_DIR)/generate-values.sh" true

apply-values:
	test -s "$(VALUES_FILE)"
	$(KUBECTL) create secret generic rmf-docker-test-values \
		--namespace crossplane-system \
		--from-file=values.yaml="$(VALUES_FILE)" \
		--dry-run=client -o yaml \
		| $(KUBECTL) apply -f -

rmf-namespace:
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/namespace-objects.yaml"
	$(KUBECTL) wait object/rmf-docker-test-namespace \
		--for=condition=Ready --timeout=5m

rmf:
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/rmf-release.yaml"

retry-keycloak:
	$(KUBECTL) delete job/keycloak-setup-retry \
		--namespace rmf-docker-test --ignore-not-found
	$(KUBECTL) apply -f "$(MANIFEST_DIR)/keycloak-setup-retry.yaml"
	$(KUBECTL) wait job/keycloak-setup-retry \
		--namespace rmf-docker-test \
		--for=condition=Complete \
		--timeout=10m
	$(KUBECTL) rollout restart deployment/rmf-web-rmf-server \
		--namespace rmf-docker-test

wait-web:
	@echo 'Waiting for Keycloak and the database-backed web services.'
	for attempt in $$(seq 1 120); do
		missing=0
		for deployment_name in keycloak keycloak-db rmf-web-dashboard rmf-web-rmf-server rmf-web-rmf-server-db; do
			$(KUBECTL) get "deployment/$$deployment_name" \
				--namespace rmf-docker-test >/dev/null 2>&1 || missing=1
		done
		if [ "$$missing" -eq 0 ]; then break; fi
		if [ "$$attempt" -eq 120 ]; then
			echo 'ERROR: OpenRMF deployments were not created within 10 minutes.' >&2
			exit 1
		fi
		sleep 5
	done
	$(KUBECTL) rollout status deployment/keycloak \
		--namespace rmf-docker-test --timeout=10m
	jwt_bytes="$$( $(KUBECTL) get configmap/jwt-pub-key \
		--namespace rmf-docker-test \
		-o go-template='{{ len (index .data "jwt-pub-key.pub") }}' 2>/dev/null || printf '0' )"
	if [ "$$jwt_bytes" -eq 0 ]; then
		echo 'JWT ConfigMap is empty; retrying the short Keycloak setup Job.'
		$(MAKE) --no-print-directory retry-keycloak
	fi
	for deployment_name in keycloak keycloak-db rmf-web-dashboard rmf-web-rmf-server rmf-web-rmf-server-db; do
		$(KUBECTL) rollout status "deployment/$$deployment_name" \
			--namespace rmf-docker-test --timeout=10m
	done

setup:
	@$(MAKE) --no-print-directory check
	@$(MAKE) --no-print-directory repos
	@$(MAKE) --no-print-directory platform
	@$(MAKE) --no-print-directory providers
	@$(MAKE) --no-print-directory provider-configs
	@$(MAKE) --no-print-directory podinfo
	@$(MAKE) --no-print-directory values-web
	@$(MAKE) --no-print-directory apply-values
	@$(MAKE) --no-print-directory rmf-namespace
	@$(MAKE) --no-print-directory rmf
	@$(MAKE) --no-print-directory wait-web
	@$(MAKE) --no-print-directory verify-web
	@echo 'OK: web-only Docker Desktop preflight completed.'

simulation:
	@$(MAKE) --no-print-directory values-simulation
	@$(MAKE) --no-print-directory apply-values
	$(KUBECTL) annotate release.helm.crossplane.io/rmf-docker-test \
		preflight.openkubes.ai/reconcile-at="$$(date -u +%s)" --overwrite
	for attempt in $$(seq 1 120); do
		if $(KUBECTL) get deployment/rmf-sim --namespace rmf-docker-test >/dev/null 2>&1; then break; fi
		sleep 5
	done
	$(KUBECTL) rollout status deployment/rmf-sim \
		--namespace rmf-docker-test --timeout=20m
	@echo 'OK: rmf-sim is running. Use make pause-simulation before browser testing on a 2-CPU node if ingress becomes unstable.'

pause-simulation:
	@$(MAKE) --no-print-directory values-web
	@$(MAKE) --no-print-directory apply-values
	$(KUBECTL) annotate release.helm.crossplane.io/rmf-docker-test \
		preflight.openkubes.ai/reconcile-at="$$(date -u +%s)" --overwrite
	$(KUBECTL) wait deployment/rmf-sim --namespace rmf-docker-test \
		--for=delete --timeout=10m || true
	$(KUBECTL) wait pod --namespace kube-system \
		--selector app.kubernetes.io/name=traefik \
		--for=condition=Ready --timeout=5m

verify-web:
	$(KUBECTL) get release.helm.crossplane.io/rmf-docker-test
	$(KUBECTL) get pods,pvc --namespace rmf-docker-test
	test "$$( $(KUBECTL) get pvc --namespace rmf-docker-test \
		-o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u )" = 'Bound'
	curl --noproxy '*' -4 -kfsS --connect-timeout 10 \
		--resolve rmf.test:443:127.0.0.1 \
		https://rmf.test/dashboard >/dev/null
	curl --noproxy '*' -4 -kfsS --connect-timeout 10 \
		--resolve rmf.test:443:127.0.0.1 \
		https://rmf.test/rmf/api/v1/docs >/dev/null
	@echo 'OK: dashboard and API documentation routes are reachable.'

status:
	$(KUBECTL) get providers.pkg.crossplane.io
	$(KUBECTL) get \
		providerconfigs.kubernetes.crossplane.io,providerconfigs.helm.crossplane.io
	$(KUBECTL) get \
		objects.kubernetes.crossplane.io,releases.helm.crossplane.io
	$(KUBECTL) get pods,pvc --namespace rmf-docker-test
	$(KUBECTL) get pods --namespace ok-crossplane-docker-test
	$(KUBECTL) get service/traefik --namespace kube-system

credentials:
	@test -s "$(CREDENTIALS_FILE)" || { echo 'Run make setup first.' >&2; exit 1; }
	@printf '%s\n' 'Disposable test credentials:'
	@sed -n \
		-e 's/^RMF_ADMIN_PASSWORD=/  Dashboard admin: admin \/ /p' \
		-e 's/^KEYCLOAK_ADMIN_PASSWORD=/  Keycloak admin: admin \/ /p' \
		"$(CREDENTIALS_FILE)"

cleanup:
	-$(KUBECTL) delete \
		release.helm.crossplane.io/rmf-docker-test \
		release.helm.crossplane.io/podinfo-docker-test \
		--ignore-not-found --wait --timeout=10m
	-$(KUBECTL) delete \
		object.kubernetes.crossplane.io/rmf-docker-test-namespace \
		object.kubernetes.crossplane.io/ok-docker-test-namespace \
		--ignore-not-found --wait --timeout=10m
	-$(KUBECTL) delete \
		providerconfig.kubernetes.crossplane.io/ok-infra-docker-test \
		providerconfig.helm.crossplane.io/ok-infra-docker-test \
		--ignore-not-found
	-$(KUBECTL) delete provider.pkg.crossplane.io/provider-kubernetes \
		provider.pkg.crossplane.io/provider-helm --ignore-not-found
	-$(KUBECTL) delete secret/docker-desktop-kubeconfig \
		secret/rmf-docker-test-values \
		--namespace crossplane-system --ignore-not-found
	@if $(HELM) status crossplane --namespace crossplane-system >/dev/null 2>&1; then \
		$(HELM) uninstall crossplane --namespace crossplane-system --wait --timeout 10m; \
	fi
	@if $(HELM) status traefik --namespace kube-system >/dev/null 2>&1; then \
		$(HELM) uninstall traefik --namespace kube-system --wait --timeout 10m; \
	fi
	-$(KUBECTL) delete namespace rmf-docker-test ok-crossplane-docker-test \
		crossplane-system --ignore-not-found --wait --timeout=10m
	@echo 'Named preflight resources removed. Generated local credentials remain in .state.'

cleanup-crds:
	@test -f "$(STATE_DIR)/preexisting-crds.txt" || {
		echo 'ERROR: no pre-install CRD snapshot; refusing broad CRD cleanup.' >&2
		exit 1
	}
	current_crds="$$(mktemp)"
	created_crds="$$(mktemp)"
	trap 'rm -f "$$current_crds" "$$created_crds"' EXIT
	$(KUBECTL) get crd -o name | sort > "$$current_crds"
	comm -13 "$(STATE_DIR)/preexisting-crds.txt" "$$current_crds" \
		| grep -E '(crossplane\.io|traefik\.io|hub\.traefik\.io)$$' \
		> "$$created_crds" || true
	if [ -s "$$created_crds" ]; then
		xargs $(KUBECTL) delete < "$$created_crds"
	else
		echo 'No preflight-created Crossplane or Traefik CRDs remain.'
	fi

cleanup-all:
	@$(MAKE) --no-print-directory cleanup
	@$(MAKE) --no-print-directory cleanup-crds
