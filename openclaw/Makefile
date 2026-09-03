SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ROOT := $(abspath ..)
KUBECONFIG := $(ROOT)/.tunnel-infra.kubeconfig
KUBECTL := kubectl --kubeconfig $(KUBECONFIG)
SOURCES := $(abspath .sources)
OPENKUBES := $(SOURCES)/openkubes
OPENKUBES_REPO := https://github.com/openkubes/openkubes.git
OPENKUBES_REV := 15d339517b4b79ff1bee5584ac5e5d60c29ff178
CHART := $(OPENKUBES)/platform/ai/openclaw/charts/openclaw
TOKEN_FILE := $(abspath .token)
WEBUI_PASSWORD_FILE := $(abspath .webui-password)
WEBUI_BACKUP_FILE := $(abspath .webui-config-backup.json)
EVIDENCE_FILE := $(abspath evidence/phase2-acceptance.json)
NS := openclaw

.PHONY: help sources preflight model render install reconcile harden-agent-serviceaccounts configure-webui status verify restart-test lifecycle-test uninstall verify-clean

help:
	@echo "OK-156 Phase 2 — OpenClaw -> MCP adapter -> facade -> kagent"
	@echo "  make preflight       validate pinned sources, manifests and cluster"
	@echo "  make model           pull the pinned Qwen3 4B instruct variant"
	@echo "  make install         install the complete read-only Phase-2 path"
	@echo "  make verify          run static, live, RBAC and MCP checks"
	@echo "  make restart-test    prove recovery after rolling restarts"
	@echo "  make lifecycle-test  uninstall and reinstall identically"
	@echo "  make uninstall       remove only Phase-2 resources"

$(OPENKUBES)/.git:
	@mkdir -p "$(SOURCES)"
	@git init -q "$(OPENKUBES)"
	@git -C "$(OPENKUBES)" remote add origin "$(OPENKUBES_REPO)"

sources: $(OPENKUBES)/.git
	@git -C "$(OPENKUBES)" fetch -q --depth=1 origin "$(OPENKUBES_REV)"
	@git -C "$(OPENKUBES)" checkout -q --detach --force "$(OPENKUBES_REV)"
	@test "$$(git -C "$(OPENKUBES)" rev-parse HEAD)" = "$(OPENKUBES_REV)"
	@test -f "$(CHART)/Chart.yaml"
	@git -C "$(OPENKUBES)" apply --recount "$(abspath patches/openclaw-mcp-only.patch)"

preflight: sources
	@test -r "$(KUBECONFIG)"
	@test "$$(kubectl --kubeconfig "$(KUBECONFIG)" config current-context)" = default
	@$(KUBECTL) get node ok-infra-local >/dev/null
	@$(KUBECTL) -n ollama exec statefulset/ollama -- ollama show qwen3:4b >/dev/null
	@test "$$( $(KUBECTL) -n open-webui get statefulset open-webui -o jsonpath='{.spec.template.spec.containers[0].image}' )" = "ghcr.io/open-webui/open-webui:0.9.5@sha256:e045bde3b004cc7f8c319412345eb56c87ea6ac57031534a31ca37ad5424beb3"
	@$(KUBECTL) -n open-webui rollout status statefulset/open-webui --timeout=5m
	@$(MAKE) --no-print-directory render

model:
	@$(KUBECTL) -n ollama exec statefulset/ollama -- ollama pull qwen3:4b-instruct-2507-q4_K_M

render: sources
	@$(KUBECTL) create --dry-run=client --validate=false -f manifests/namespace.yaml -f manifests/provider.yaml -f manifests/agents.yaml -f manifests/transport.yaml >/dev/null
	@helm template openclaw "$(CHART)" --namespace "$(NS)" -f values.yaml --set gateway.token=render-only >/dev/null
	@python3 scripts/verify_phase2.py --static-only

$(TOKEN_FILE):
	@umask 077; openssl rand -hex 24 > "$(TOKEN_FILE)"

$(WEBUI_PASSWORD_FILE):
	@umask 077; openssl rand -base64 36 > "$(WEBUI_PASSWORD_FILE)"

configure-webui: $(TOKEN_FILE) $(WEBUI_PASSWORD_FILE)
	@python3 scripts/configure_openwebui.py --kubeconfig "$(KUBECONFIG)" \
		--gateway-token-file "$(TOKEN_FILE)" --password-file "$(WEBUI_PASSWORD_FILE)" \
		--backup-file "$(WEBUI_BACKUP_FILE)"

install: preflight model $(TOKEN_FILE) $(WEBUI_PASSWORD_FILE)
	@$(KUBECTL) apply -f manifests/namespace.yaml
	@$(KUBECTL) apply -f manifests/provider.yaml
	@$(KUBECTL) -n platform-diagnostics rollout status deployment/platform-diagnostics-tools --timeout=3m
	@$(MAKE) --no-print-directory reconcile
	@$(KUBECTL) apply -f manifests/agents.yaml
	@$(MAKE) --no-print-directory harden-agent-serviceaccounts
	@$(KUBECTL) apply -f manifests/transport.yaml
	@$(KUBECTL) -n platform-diagnostics rollout status deployment/platform-diagnostics --timeout=5m
	@$(KUBECTL) -n platform-diagnostics rollout status deployment/platform-diagnostics-mcp-adapter --timeout=3m
	@helm upgrade --install openclaw "$(CHART)" --kubeconfig "$(KUBECONFIG)" --namespace "$(NS)" -f values.yaml --set gateway.token="$$(cat "$(TOKEN_FILE)")"
	@$(KUBECTL) -n openclaw rollout status deployment/openclaw --timeout=5m
	@$(MAKE) --no-print-directory configure-webui
	@$(MAKE) --no-print-directory verify

reconcile:
	@$(KUBECTL) -n platform-diagnostics annotate remotemcpserver/platform-diagnostics-tools openkubes.io/reconcile-at="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
	@$(KUBECTL) -n platform-diagnostics wait --for=condition=Accepted remotemcpserver/platform-diagnostics-tools --timeout=2m

harden-agent-serviceaccounts:
	@for name in openkubes-platform-agent kubernetes-agent cilium-agent observability-agent; do \
		for attempt in $$(seq 1 60); do \
			$(KUBECTL) -n platform-diagnostics get serviceaccount/$$name >/dev/null 2>&1 && break; \
			sleep 2; \
		done; \
		$(KUBECTL) -n platform-diagnostics patch serviceaccount/$$name --type=merge \
			-p '{"automountServiceAccountToken":false}' >/dev/null; \
		for attempt in $$(seq 1 60); do \
			$(KUBECTL) -n platform-diagnostics get deployment/$$name >/dev/null 2>&1 && break; \
			sleep 2; \
		done; \
		$(KUBECTL) -n platform-diagnostics rollout restart deployment/$$name >/dev/null; \
	done
	@for name in openkubes-platform-agent kubernetes-agent cilium-agent observability-agent; do \
		$(KUBECTL) -n platform-diagnostics rollout status deployment/$$name --timeout=5m; \
	done

status:
	@$(KUBECTL) get pods,svc -n platform-diagnostics
	@$(KUBECTL) get pods,svc -n openclaw
	@$(KUBECTL) get agents,modelconfigs,remotemcpservers -n platform-diagnostics

verify:
	@python3 scripts/verify_phase2.py --kubeconfig "$(KUBECONFIG)" \
		--webui-password-file "$(WEBUI_PASSWORD_FILE)" --evidence-output "$(EVIDENCE_FILE)"

restart-test:
	@$(KUBECTL) -n platform-diagnostics rollout restart deployment/platform-diagnostics-tools deployment/platform-diagnostics deployment/platform-diagnostics-mcp-adapter
	@$(MAKE) --no-print-directory harden-agent-serviceaccounts
	@$(KUBECTL) -n openclaw rollout restart deployment/openclaw
	@$(KUBECTL) -n platform-diagnostics rollout status deployment/platform-diagnostics-tools --timeout=5m
	@$(KUBECTL) -n platform-diagnostics rollout status deployment/platform-diagnostics --timeout=5m
	@$(KUBECTL) -n platform-diagnostics rollout status deployment/platform-diagnostics-mcp-adapter --timeout=5m
	@$(KUBECTL) -n openclaw rollout status deployment/openclaw --timeout=5m
	@$(MAKE) --no-print-directory reconcile
	@python3 scripts/verify_phase2.py --kubeconfig "$(KUBECONFIG)" --skip-e2e \
		--webui-password-file "$(WEBUI_PASSWORD_FILE)"

lifecycle-test:
	@$(MAKE) --no-print-directory uninstall verify-clean install

uninstall:
	@if test -f "$(WEBUI_PASSWORD_FILE)"; then \
		python3 scripts/configure_openwebui.py --kubeconfig "$(KUBECONFIG)" \
			--password-file "$(WEBUI_PASSWORD_FILE)" --backup-file "$(WEBUI_BACKUP_FILE)" --restore; \
	fi
	@helm uninstall openclaw --kubeconfig "$(KUBECONFIG)" -n openclaw --ignore-not-found
	@$(KUBECTL) delete -f manifests/transport.yaml --ignore-not-found
	@$(KUBECTL) delete -f manifests/agents.yaml --ignore-not-found
	@$(KUBECTL) delete -f manifests/provider.yaml --ignore-not-found
	@$(KUBECTL) delete -f manifests/namespace.yaml --ignore-not-found

verify-clean:
	@! $(KUBECTL) get namespace openclaw >/dev/null 2>&1
	@! $(KUBECTL) get namespace platform-diagnostics >/dev/null 2>&1
