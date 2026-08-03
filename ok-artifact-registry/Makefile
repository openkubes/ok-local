# registry-default (zot) — ok-local Phase 1 (OK-137)
# DEV convenience only. ok-shared (Phase 2 / OK-138) uses its own values + flow.

SHELL       := /usr/bin/env bash
RELEASE     ?= zot
NAMESPACE   ?= ok-registry
VALUES      ?= compositions/zot/values-local.yaml
CHART       ?= project-zot/zot

# Dev credentials — override on the CLI; NEVER reuse on ok-shared.
ADMIN_USER  ?= admin
ADMIN_PASS  ?= admin-local-dev
CI_USER     ?= ci
CI_PASS     ?= ci-local-dev
PULL_USER   ?= puller
PULL_PASS   ?= puller-local-dev

.PHONY: help repo secret deploy port-forward smoke conformance status clean

help: ## Show targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

repo: ## Add + update the zot helm repo
	helm repo add project-zot https://zotregistry.dev/helm-charts
	helm repo update

secret: ## Create the htpasswd Secret (admin/ci/puller) — not committed
	@command -v htpasswd >/dev/null || { echo "install apache2-utils (htpasswd)"; exit 1; }
	@umask 077; \
	htpasswd -nbB $(ADMIN_USER) '$(ADMIN_PASS)'  > /tmp/ok-htpasswd; \
	htpasswd -nbB $(CI_USER)    '$(CI_PASS)'    >> /tmp/ok-htpasswd; \
	htpasswd -nbB $(PULL_USER)  '$(PULL_PASS)'  >> /tmp/ok-htpasswd
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NAMESPACE) create secret generic zot-htpasswd \
	  --from-file=htpasswd=/tmp/ok-htpasswd \
	  --dry-run=client -o yaml | kubectl apply -f -
	@rm -f /tmp/ok-htpasswd
	@echo "zot-htpasswd created in $(NAMESPACE)"

deploy: ## helm upgrade --install zot with local values
	@AUTH=$$(printf '%s:%s' '$(ADMIN_USER)' '$(ADMIN_PASS)' | base64 | tr -d '\n'); \
	helm upgrade --install $(RELEASE) $(CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f $(VALUES) \
	  --set-string authHeader=$$AUTH
	kubectl -n $(NAMESPACE) rollout status deploy/$(RELEASE)-zot --timeout=120s || \
	kubectl -n $(NAMESPACE) rollout status statefulset/$(RELEASE)-zot --timeout=120s

port-forward: ## Forward localhost:5000 -> zot service
	kubectl -n $(NAMESPACE) port-forward svc/$(RELEASE)-zot 5000:5000

smoke: ## Run the contract smoke test (needs `make port-forward` in another shell)
	REG=localhost:5000 \
	CI_USER=$(CI_USER) CI_PASS='$(CI_PASS)' \
	PULL_USER=$(PULL_USER) PULL_PASS='$(PULL_PASS)' \
	  bash contract/tests/smoke.sh

conformance: ## Run OCI Distribution conformance (see contract/tests/README.md)
	@echo "See contract/tests/README.md → 'OCI Distribution conformance (§8.9)'"

status: ## Show pods, svc, pvc
	kubectl -n $(NAMESPACE) get pods,svc,pvc

clean: ## Uninstall release + delete namespace
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	-kubectl delete namespace $(NAMESPACE)
