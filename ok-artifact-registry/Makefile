# registry-default (zot) — ok-local Phase 1 (OK-137)
# DEV convenience only. ok-shared (Phase 2 / OK-138) uses its own values + flow.

SHELL       := /usr/bin/env bash
RELEASE     ?= zot
NAMESPACE   ?= ok-registry
VALUES      ?= compositions/zot/values-local.yaml
CHART       ?= project-zot/zot
CHART_VERSION ?= 0.1.122
CONFORMANCE_IMAGE ?= ghcr.io/opencontainers/distribution-spec/conformance@sha256:ad756107873b1478603b6ed9024d868eb1b2adeba5bf3c0d2bceebad517f7f36
PORT         ?= 5050
CONFORMANCE_REG ?= host.docker.internal:$(PORT)
CONFORMANCE_RESULTS ?= contract/tests/results
REG          ?= localhost:$(PORT)
LIFECYCLE_PORT ?= 5051

# Dev credentials — override on the CLI; NEVER reuse on ok-shared.
ADMIN_USER  ?= admin
ADMIN_PASS  ?= admin-local-dev
CI_USER     ?= ci
CI_PASS     ?= ci-local-dev
PULL_USER   ?= puller
PULL_PASS   ?= puller-local-dev

.PHONY: help repo secret deploy port-forward smoke offline-transfer lifecycle \
	conformance contract gitops-render verify status clean

help: ## Show targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

repo: ## Add + update the zot helm repo
	helm repo add project-zot https://zotregistry.dev/helm-charts
	helm repo update

secret: ## Create the htpasswd Secret (admin/ci/puller) — not committed
	@command -v htpasswd >/dev/null || { echo "install apache2-utils (htpasswd)"; exit 1; }
	@set -euo pipefail; \
	umask 077; \
	secret_file="$$(mktemp "$${TMPDIR:-/tmp}/ok-htpasswd.XXXXXX")"; \
	trap 'rm -f "$$secret_file"' EXIT; \
	htpasswd -nbB $(ADMIN_USER) '$(ADMIN_PASS)'  > "$$secret_file"; \
	htpasswd -nbB $(CI_USER)    '$(CI_PASS)'    >> "$$secret_file"; \
	htpasswd -nbB $(PULL_USER)  '$(PULL_PASS)'  >> "$$secret_file"; \
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl -n $(NAMESPACE) create secret generic zot-htpasswd \
	  --from-file=htpasswd="$$secret_file" \
	  --dry-run=client -o yaml | kubectl apply -f -; \
	echo "zot-htpasswd created in $(NAMESPACE)"

deploy: ## helm upgrade --install zot with local values
	@AUTH=$$(printf '%s:%s' '$(ADMIN_USER)' '$(ADMIN_PASS)' | base64 | tr -d '\n'); \
	helm upgrade --install $(RELEASE) $(CHART) \
	  --version $(CHART_VERSION) \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f $(VALUES) \
	  --set-string authHeader=$$AUTH
	kubectl -n $(NAMESPACE) rollout status statefulset \
	  --selector app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=zot \
	  --timeout=120s

port-forward: ## Forward localhost:5050 -> zot service
	@SERVICE=$$(kubectl -n $(NAMESPACE) get service \
	  --selector app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/name=zot \
	  -o jsonpath='{.items[0].metadata.name}'); \
	test -n "$$SERVICE" || { echo "zot service for release $(RELEASE) not found"; exit 1; }; \
	kubectl -n $(NAMESPACE) port-forward "service/$$SERVICE" $(PORT):5000

smoke: ## Run the contract smoke test (needs `make port-forward` in another shell)
	@REG=$(REG) \
	ADMIN_USER=$(ADMIN_USER) ADMIN_PASS='$(ADMIN_PASS)' \
	CI_USER=$(CI_USER) CI_PASS='$(CI_PASS)' \
	PULL_USER=$(PULL_USER) PULL_PASS='$(PULL_PASS)' \
	  bash contract/tests/smoke.sh

offline-transfer: ## Prove export, checksum, import, and pull-by-digest
	@REG=$(REG) CI_USER=$(CI_USER) CI_PASS='$(CI_PASS)' \
	  bash contract/tests/offline-transfer.sh

lifecycle: ## Prove GC reclamation and scrub integrity (needs kubectl context)
	@LOCAL_PORT=$(LIFECYCLE_PORT) NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) \
	ADMIN_USER=$(ADMIN_USER) ADMIN_PASS='$(ADMIN_PASS)' \
	  bash contract/tests/lifecycle.sh

conformance: ## Run OCI Distribution conformance and write local evidence
	@REG=$(CONFORMANCE_REG) \
	ADMIN_USER=$(ADMIN_USER) ADMIN_PASS='$(ADMIN_PASS)' \
	CONFORMANCE_IMAGE=$(CONFORMANCE_IMAGE) \
	RESULTS_DIR=$(CONFORMANCE_RESULTS) \
	  bash contract/tests/conformance.sh

contract: ## Run the complete local contract suite in the documented order
	$(MAKE) smoke
	$(MAKE) offline-transfer
	$(MAKE) conformance
	$(MAKE) lifecycle

gitops-render: ## Render the Argo/Kustomize composition locally
	kubectl kustomize . --enable-helm >/dev/null

verify: ## Validate shell, JSON, Helm, and GitOps rendering locally
	bash -n contract/tests/smoke.sh contract/tests/offline-transfer.sh \
	  contract/tests/lifecycle.sh contract/tests/conformance.sh
	python3 -m json.tool compositions/zot/config.reference.json >/dev/null
	helm template $(RELEASE) $(CHART) \
	  --version $(CHART_VERSION) \
	  --namespace $(NAMESPACE) \
	  -f $(VALUES) \
	  --set-string authHeader=dGVzdDp0ZXN0 >/dev/null
	$(MAKE) gitops-render

status: ## Show pods, svc, pvc
	kubectl -n $(NAMESPACE) get pods,svc,pvc

clean: ## Uninstall release + delete namespace
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	-kubectl delete namespace $(NAMESPACE)
