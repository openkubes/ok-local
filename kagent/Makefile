SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

ROOT              := $(abspath ..)
SOURCES           := $(abspath .sources)
VENV              := $(abspath .venv)
OPENKUBES_SOURCE  := $(SOURCES)/openkubes
OK_CLUSTER_SOURCE := $(SOURCES)/ok-cluster
UPSTREAM_DIR      := $(OK_CLUSTER_SOURCE)/ok-kagent/kagent

OPENKUBES_REPO    := https://github.com/openkubes/openkubes.git
OPENKUBES_REV     := 6a0a56a4140dab3d55ade4a926c09412781e1407
OK_CLUSTER_REPO   := https://github.com/openkubes/ok-cluster.git
OK_CLUSTER_REV    := 03381d239454d8bb7aacc65908e8d3512ee376c1

KUBECONFIG        := $(ROOT)/.tunnel-infra.kubeconfig
EXPECTED_CTX      := default
EXPECTED_NODE     := ok-infra-local
OLLAMA_URL        ?= http://ollama.ollama.svc.cluster.local:11434
OLLAMA_MODEL      := qwen3:4b

VALUES_TMPL       := $(abspath values.yaml.tmpl)
VALUES_LOCAL      := $(abspath .values.local.yaml)
ACCESS_CONFIG     := $(abspath access-config.yaml)
ACCESS_OUT        := $(abspath .access.local)
AGENT_PATCH       := $(abspath agent-diagnostics-patch.yaml)

KAGENT_VERSION    := 0.9.12
TOOLS_VERSION     := 0.2.1
CHART_ROOT        := oci://ghcr.io/kagent-dev/kagent/helm
KAGENT_CRDS_DIGEST := sha256:85174e69eab19e05fcf82dbfda86e8e84c2be97a52c645d60cf1ae51ccbca977
KAGENT_CHART_DIGEST := sha256:ec0dacc1a76edbd190a554757c8bdb193ccb0b35deeb35f6d7a7e7ffc76d99fd

BUSYBOX_IMAGE     := docker.io/library/busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
PAUSE_IMAGE       := registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a
MISSING_IMAGE     := registry.k8s.io/pause@sha256:0000000000000000000000000000000000000000000000000000000000000000

export PATH := $(VENV)/bin:$(PATH)

UPSTREAM_VARS = \
	OPENKUBES_DIR="$(OPENKUBES_SOURCE)" \
	OK_CLUSTER_DIR="$(ROOT)" \
	KUBECONFIG="$(KUBECONFIG)" \
	EXPECTED_CTX="$(EXPECTED_CTX)" \
	VALUES_TMPL="$(VALUES_TMPL)" \
	VALUES_LOCAL="$(VALUES_LOCAL)" \
	ACCESS_CONFIG="$(ACCESS_CONFIG)" \
	ACCESS_OUT="$(ACCESS_OUT)"

.PHONY: help sources venv source-check cluster-check preflight access-summary \
	access-test chart-lock-check render-check model-pull model-check install fixture-images \
	agent-policy mcp-reconcile status verify-access verify-kagent restart-test lifecycle-test dashboard \
	logs uninstall verify-clean clean-generated

help: ## Show the safe OK-156 Phase-1 workflow
	@echo "OK-156 — kagent Standalone on ok-infra-local (read-only)"
	@echo ""
	@echo "Preparation only (no cluster changes):"
	@echo "  make preflight       Fetch pinned sources and run prerequisite checks"
	@echo "  make access-test     Run the pinned OK-129 access tests"
	@echo "  make access-summary  Show the generated read-only boundary"
	@echo "  make chart-lock-check Verify the expected OCI chart digests"
	@echo "  make render-check    Render Helm and Kustomize inputs locally"
	@echo ""
	@echo "Cluster-changing targets (run only after review):"
	@echo "  make model-pull      Pull the pinned Ollama model"
	@echo "  make install         Install the pinned read-only profile"
	@echo "  make verify-access   Prove read yes; writes/Secrets/wildcards no"
	@echo "  make verify-kagent   Verify the complete live kagent contract"
	@echo "  make restart-test    Restart Controller and Agent and verify recovery"
	@echo "  make lifecycle-test  Clean-uninstall and identically reinstall"
	@echo "  make status          Show releases, workloads and agent resources"
	@echo "  make dashboard       Open a local port-forward on localhost:8080"
	@echo "  make uninstall       Remove the Phase-1 installation"

$(OPENKUBES_SOURCE)/.git:
	@mkdir -p "$(SOURCES)"
	@git init -q "$(OPENKUBES_SOURCE)"
	@git -C "$(OPENKUBES_SOURCE)" remote add origin "$(OPENKUBES_REPO)"

$(OK_CLUSTER_SOURCE)/.git:
	@mkdir -p "$(SOURCES)"
	@git init -q "$(OK_CLUSTER_SOURCE)"
	@git -C "$(OK_CLUSTER_SOURCE)" remote add origin "$(OK_CLUSTER_REPO)"

sources: $(OPENKUBES_SOURCE)/.git $(OK_CLUSTER_SOURCE)/.git ## Fetch exact source revisions
	@git -C "$(OPENKUBES_SOURCE)" fetch -q --depth=1 origin "$(OPENKUBES_REV)"
	@git -C "$(OPENKUBES_SOURCE)" checkout -q --detach "$(OPENKUBES_REV)"
	@git -C "$(OK_CLUSTER_SOURCE)" fetch -q --depth=1 origin "$(OK_CLUSTER_REV)"
	@git -C "$(OK_CLUSTER_SOURCE)" checkout -q --detach "$(OK_CLUSTER_REV)"
	@$(MAKE) --no-print-directory source-check

$(VENV)/bin/python:
	@python3 -m venv "$(VENV)"

venv: $(VENV)/bin/python requirements.txt ## Create the pinned local Python environment
	@"$(VENV)/bin/python" -m pip install --quiet --disable-pip-version-check -r requirements.txt

source-check:
	@test "$$(git -C "$(OPENKUBES_SOURCE)" rev-parse HEAD)" = "$(OPENKUBES_REV)"
	@test "$$(git -C "$(OK_CLUSTER_SOURCE)" rev-parse HEAD)" = "$(OK_CLUSTER_REV)"
	@test -f "$(OPENKUBES_SOURCE)/research/kagent-standalone/kustomization.yaml"
	@test -f "$(UPSTREAM_DIR)/Makefile"
	@echo "Pinned source pair verified."

cluster-check:
	@test -r "$(KUBECONFIG)" || { echo "ERROR: missing $(KUBECONFIG)"; exit 1; }
	@test "$$(kubectl --kubeconfig "$(KUBECONFIG)" config current-context)" = "$(EXPECTED_CTX)" || { \
		echo "ERROR: unexpected kubeconfig context"; exit 1; }
	@kubectl --kubeconfig "$(KUBECONFIG)" get node "$(EXPECTED_NODE)" >/dev/null
	@echo "Target verified: $(EXPECTED_NODE) via $(KUBECONFIG)"

preflight: sources venv cluster-check ## Run Phase-1 prerequisites without changing the cluster
	@OLLAMA_URL="$(OLLAMA_URL)" $(MAKE) -C "$(UPSTREAM_DIR)" preflight $(UPSTREAM_VARS)
	@$(MAKE) --no-print-directory model-check

access-test: sources venv ## Run the coupled source tests
	@$(MAKE) -C "$(UPSTREAM_DIR)" access-test $(UPSTREAM_VARS)

access-summary: sources venv ## Render and display the read-only access boundary
	@$(MAKE) -C "$(UPSTREAM_DIR)" access-summary $(UPSTREAM_VARS)

chart-lock-check: ## Verify the OCI chart versions resolve to the locked digests
	@output="$$(helm show chart "$(CHART_ROOT)/kagent-crds" --version "$(KAGENT_VERSION)" 2>&1)"; \
	  actual="$$(printf '%s\n' "$$output" | awk '/^Digest:/ {print $$2}')"; \
	  test "$$actual" = "$(KAGENT_CRDS_DIGEST)" || { echo "ERROR: kagent-crds digest $$actual"; exit 1; }
	@output="$$(helm show chart "$(CHART_ROOT)/kagent" --version "$(KAGENT_VERSION)" 2>&1)"; \
	  actual="$$(printf '%s\n' "$$output" | awk '/^Digest:/ {print $$2}')"; \
	  test "$$actual" = "$(KAGENT_CHART_DIGEST)" || { echo "ERROR: kagent digest $$actual"; exit 1; }
	@echo "Pinned OCI chart digests verified."

render-check: sources venv chart-lock-check ## Render all Phase-1 inputs locally; do not apply them
	@OLLAMA_URL="$(OLLAMA_URL)" $(MAKE) -C "$(UPSTREAM_DIR)" render-values render-access $(UPSTREAM_VARS)
	@helm template kagent-crds "$(CHART_ROOT)/kagent-crds" \
		--version "$(KAGENT_VERSION)" --namespace kagent >/dev/null
	@helm template kagent "$(CHART_ROOT)/kagent" \
		--version "$(KAGENT_VERSION)" --namespace kagent \
		--values "$(VALUES_LOCAL)" \
		--values "$(ACCESS_OUT)/values-access.yaml" >/dev/null
	@kubectl kustomize "$(OPENKUBES_SOURCE)/research/kagent-standalone" >/dev/null
	@echo "Render check passed: Helm and Kustomize inputs are valid."

model-pull: cluster-check ## Pull the selected model into the existing Ollama PVC
	@$(MAKE) -C "$(ROOT)" pull-ollama-model MODEL="$(OLLAMA_MODEL)"

model-check: cluster-check ## Verify the selected Ollama model and bounded server settings
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace ollama exec statefulset/ollama -- \
		ollama show "$(OLLAMA_MODEL)" >/dev/null || { echo "ERROR: run 'make -C kagent model-pull'"; exit 1; }
	@test "$$(kubectl --kubeconfig "$(KUBECONFIG)" --namespace ollama get statefulset ollama \
		-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OLLAMA_CONTEXT_LENGTH")].value}')" = "4096"
	@test "$$(kubectl --kubeconfig "$(KUBECONFIG)" --namespace ollama get statefulset ollama \
		-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OLLAMA_KEEP_ALIVE")].value}')" = "0s"
	@echo "Ollama model and bounded runtime settings verified."

install: preflight ## Install the pinned read-only standalone profile
	@OLLAMA_URL="$(OLLAMA_URL)" $(MAKE) -C "$(UPSTREAM_DIR)" install $(UPSTREAM_VARS)
	@$(MAKE) --no-print-directory fixture-images
	@$(MAKE) --no-print-directory agent-policy
	@$(MAKE) --no-print-directory mcp-reconcile
	@$(MAKE) --no-print-directory verify-kagent

fixture-images: cluster-check
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab scale \
		deployment/crashloop deployment/imagepull --replicas=0
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab wait \
		--for=delete pod --selector=app=crashloop --timeout=2m
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab wait \
		--for=delete pod --selector=app=imagepull --timeout=2m
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab set image \
		deployment/crashloop crashloop="$(BUSYBOX_IMAGE)"
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab set image \
		deployment/healthy healthy="$(PAUSE_IMAGE)"
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab set image \
		deployment/imagepull imagepull="$(MISSING_IMAGE)"
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab scale \
		deployment/crashloop deployment/imagepull --replicas=1
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent-lab rollout status \
		deployment/healthy --timeout=2m
	@echo "Fixture images pinned; the missing digest intentionally remains unpullable."

# Keep model output bounded on the small CPU-only VM. This narrows the Agent to
# targeted describe calls; the tool-server RBAC remains independently read-only.
agent-policy: cluster-check
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent patch \
		agent cluster-inspector --type=merge --patch-file "$(AGENT_PATCH)"
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent rollout status \
		deployment/cluster-inspector --timeout=3m
	@echo "Targeted describe-only policy applied; tool-server RBAC remains read-only."

# The 0.9.12 controller can reconcile the RemoteMCPServer once before the
# freshly installed tool server is listening and retain Accepted=False. Wait
# for the executing server first, then update metadata to request a fresh,
# non-destructive reconciliation of the same spec.
mcp-reconcile: cluster-check
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent wait \
		--for=condition=Available deployment/kagent-tools --timeout=2m
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent annotate \
		remotemcpserver/kagent-tool-server \
		openkubes.io/reconcile-at="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
	@kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent wait \
		--for=condition=Accepted remotemcpserver/kagent-tool-server --timeout=2m
	@echo "RemoteMCPServer accepted after tool-server readiness."

status: sources venv cluster-check
	@$(MAKE) -C "$(UPSTREAM_DIR)" status $(UPSTREAM_VARS)

verify-access: sources venv cluster-check
	@$(MAKE) -C "$(UPSTREAM_DIR)" verify-access $(UPSTREAM_VARS)

verify-kagent: cluster-check
	@python3 scripts/verify_phase1.py --kubeconfig "$(KUBECONFIG)"

restart-test: cluster-check ## Restart Controller and Agent and verify recovery
	@started="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SECONDS=0; \
	  kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent rollout restart \
	    deployment/kagent-controller deployment/cluster-inspector; \
	  kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent rollout status \
	    deployment/kagent-controller --timeout=5m; \
	  kubectl --kubeconfig "$(KUBECONFIG)" --namespace kagent rollout status \
	    deployment/cluster-inspector --timeout=5m; \
	  $(MAKE) --no-print-directory mcp-reconcile; \
	  $(MAKE) --no-print-directory verify-kagent; \
	  printf 'Restart recovery PASS started=%s duration_seconds=%s\n' "$$started" "$$SECONDS"

lifecycle-test: cluster-check ## Clean-uninstall and identically reinstall Phase 1
	@started="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SECONDS=0; \
	  $(MAKE) --no-print-directory uninstall; \
	  $(MAKE) --no-print-directory install; \
	  printf 'Lifecycle PASS started=%s duration_seconds=%s\n' "$$started" "$$SECONDS"

dashboard: sources venv cluster-check
	@$(MAKE) -C "$(UPSTREAM_DIR)" dashboard $(UPSTREAM_VARS)

logs: sources venv cluster-check
	@$(MAKE) -C "$(UPSTREAM_DIR)" logs $(UPSTREAM_VARS)

uninstall: sources venv cluster-check
	@$(MAKE) -C "$(UPSTREAM_DIR)" uninstall $(UPSTREAM_VARS)

verify-clean: sources venv cluster-check
	@$(MAKE) -C "$(UPSTREAM_DIR)" verify-clean $(UPSTREAM_VARS)

clean-generated: ## Remove only locally generated, Git-ignored render output
	@python3 -c 'import pathlib,shutil; [shutil.rmtree(path, ignore_errors=True) for path in (pathlib.Path(".access.local"),)]; pathlib.Path(".values.local.yaml").unlink(missing_ok=True)'
