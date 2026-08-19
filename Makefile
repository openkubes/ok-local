.PHONY: help up up-mgmt up-infra down start delete status ssh-mgmt ssh-infra \
        kubeconfig kubeconfig-infra nodes-mgmt nodes-infra nodes-all \
        tunnel tunnel-infra tunnel-stop tunnels \
        install-k3s-mgmt install-k3s-infra \
        install-kubevirt enable-emulation install-virtctl \
        install-ollama pull-ollama-model ollama-status \
        webui-setup webui-deploy webui-status \
        setup clean cloud-init.yaml

# ─── Config ───────────────────────────────────────────────────────────────────
MGMT_VM      := ok-mgmt-local
INFRA_VM     := ok-infra-local
MGMT_IP      := $(shell multipass list --format csv 2>/dev/null | grep $(MGMT_VM) | cut -d',' -f3 | tr -d ' ')
INFRA_IP     := $(shell multipass list --format csv 2>/dev/null | grep $(INFRA_VM) | cut -d',' -f3 | tr -d ' ')
CPUS         := 4
MEMORY       := 8G
DISK         := 40G
SSH_KEY      := $(shell ls $(HOME)/.ssh/id_ed25519.pub 2>/dev/null || echo $(HOME)/.ssh/id_rsa.pub)
K3S_VERSION  := v1.35.5+k3s1

# Two separate clusters — each VM is its own K3s server.
# On macOS with Multipass, port 6443 is not directly reachable.
# All kubectl commands use tunnel kubeconfigs (SSH tunnel on localhost).
# Tunnel ports: mgmt=6443, infra=6444
KUBECONFIG_MGMT   := mgmt-local.kubeconfig
KUBECONFIG_INFRA  := infra-local.kubeconfig
TUNNEL_MGMT       := .tunnel-mgmt.kubeconfig
TUNNEL_INFRA      := .tunnel-infra.kubeconfig
KM                := KUBECONFIG=$(TUNNEL_MGMT)
KI                := KUBECONFIG=$(TUNNEL_INFRA)

OLLAMA_NAMESPACE  := ollama
OLLAMA_MANIFESTS  := ollama
OLLAMA_FILES      := $(OLLAMA_MANIFESTS)/namespace.yaml \
                     $(OLLAMA_MANIFESTS)/service.yaml \
                     $(OLLAMA_MANIFESTS)/statefulset.yaml
MODEL             ?= qwen2.5:0.5b

WEBUI_DIR              := platform/ai/open-webui/crossplane
WEBUI_CHART_VERSION    ?= 14.6.0
MGMT_KUBECONFIG        ?= $(abspath $(TUNNEL_MGMT))
INFRA_KUBECONFIG       ?= $(abspath $(KUBECONFIG_INFRA))
CLUSTER                ?= ok-infra-local
OLLAMA_ENDPOINT        ?= http://ollama.ollama.svc.cluster.local:11434
WEBUI_NAMESPACE        ?= open-webui
WEBUI_CLAIM_NAMESPACE  ?= openkubes-system

define WEBUI_FUNCTION_YAML
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.8.2
endef

define WEBUI_DEFINITION_YAML
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: openwebuiinstances.platform.openkubes.ai
spec:
  scope: LegacyCluster
  group: platform.openkubes.ai
  names:
    kind: OpenWebUIInstance
    plural: openwebuiinstances
    singular: openwebuiinstance
    shortNames:
      - owui
  claimNames:
    kind: OpenWebUIClaim
    plural: openwebuiclaims
    singular: openwebuiclaim
    shortNames:
      - owuic
  defaultCompositionRef:
    name: open-webui
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                clusterRef:
                  type: string
                  minLength: 1
                ollamaEndpoint:
                  type: string
                  minLength: 1
                namespace:
                  type: string
                  minLength: 1
              required:
                - clusterRef
                - ollamaEndpoint
                - namespace
endef

define WEBUI_COMPOSITION_YAML
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: open-webui
spec:
  compositeTypeRef:
    apiVersion: platform.openkubes.ai/v1alpha1
    kind: OpenWebUIInstance
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: open-webui-release
            base:
              apiVersion: helm.crossplane.io/v1beta1
              kind: Release
              metadata:
                name: open-webui
              spec:
                forProvider:
                  chart:
                    name: open-webui
                    repository: https://helm.openwebui.com/
                    version: "$(WEBUI_CHART_VERSION)"
                  namespace: open-webui
                  values:
                    fullnameOverride: open-webui
                    workload:
                      kind: StatefulSet
                    ollama:
                      enabled: false
                    ollamaUrls:
                      - http://ollama.ollama.svc.cluster.local:11434
                    pipelines:
                      enabled: false
                    redis:
                      enabled: false
                    persistence:
                      enabled: true
                      storageClass: local-path
                      size: 2Gi
                    service:
                      type: ClusterIP
                      port: 80
                      containerPort: 8080
                    resources:
                      requests:
                        cpu: 100m
                        memory: 512Mi
                      limits:
                        cpu: "2"
                        memory: 2Gi
                  wait: true
                  waitTimeout: 10m
                providerConfigRef:
                  name: ok-infra-local
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.clusterRef
                toFieldPath: spec.providerConfigRef.name
                policy:
                  fromFieldPath: Required
              - type: FromCompositeFieldPath
                fromFieldPath: spec.namespace
                toFieldPath: spec.forProvider.namespace
                policy:
                  fromFieldPath: Required
              - type: FromCompositeFieldPath
                fromFieldPath: spec.ollamaEndpoint
                toFieldPath: spec.forProvider.values.ollamaUrls[0]
                policy:
                  fromFieldPath: Required
endef

define WEBUI_CLAIM_YAML
apiVersion: platform.openkubes.ai/v1alpha1
kind: OpenWebUIClaim
metadata:
  name: $(CLUSTER)
  namespace: $(WEBUI_CLAIM_NAMESPACE)
spec:
  clusterRef: $(CLUSTER)
  ollamaEndpoint: $(OLLAMA_ENDPOINT)
  namespace: $(WEBUI_NAMESPACE)
endef

export WEBUI_FUNCTION_YAML
export WEBUI_DEFINITION_YAML
export WEBUI_COMPOSITION_YAML
export WEBUI_CLAIM_YAML

KUBEVIRT_VERSION  := $(shell curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)

# ─── Help ─────────────────────────────────────────────────────────────────────
help: ## Show this help
	@echo ""
	@echo "  openkubes-local — two separate K3s clusters"
	@echo ""
	@echo "  Cluster A: ok-mgmt-local  (Management — CAPI, Crossplane, Argo CD)"
	@echo "  Cluster B: ok-infra-local (Workload   — KubeVirt, CDI)"
	@echo ""
	@echo "  Aliases (add to ~/.zshrc):"
	@echo "    alias oml='ssh ubuntu@\$$(multipass list --format csv | grep ok-mgmt-local | cut -d, -f3 | tr -d \" \")'"
	@echo "    alias oil='ssh ubuntu@\$$(multipass list --format csv | grep ok-infra-local | cut -d, -f3 | tr -d \" \")'"
	@echo "    alias koml='kubectl --kubeconfig $(PWD)/$(TUNNEL_MGMT)'"
	@echo "    alias koil='kubectl --kubeconfig $(PWD)/$(TUNNEL_INFRA)'"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── VM Lifecycle ─────────────────────────────────────────────────────────────
up: up-mgmt up-infra ## Launch both VMs sequentially

up-mgmt: cloud-init.yaml ## Launch ok-mgmt-local
	@echo "🚀 Launching $(MGMT_VM)..."
	multipass launch 24.04 \
	  --name $(MGMT_VM) \
	  --cpus $(CPUS) \
	  --memory $(MEMORY) \
	  --disk $(DISK) \
	  --cloud-init cloud-init.yaml
	@echo "✅ $(MGMT_VM) is up and SSH ready"

up-infra: cloud-init.yaml ## Launch ok-infra-local
	@echo "🚀 Launching $(INFRA_VM)..."
	multipass launch 24.04 \
	  --name $(INFRA_VM) \
	  --cpus $(CPUS) \
	  --memory $(MEMORY) \
	  --disk $(DISK) \
	  --cloud-init cloud-init.yaml
	@echo "✅ $(INFRA_VM) is up and SSH ready"

down: ## Stop both VMs
	@echo "🛑 Stopping all VMs..."
	multipass stop $(MGMT_VM) $(INFRA_VM) 2>/dev/null || true
	@echo "✅ All VMs stopped"

start: ## Start both VMs
	@echo "▶️  Starting all VMs..."
	multipass start $(MGMT_VM) $(INFRA_VM) 2>/dev/null || true
	@echo "✅ All VMs started"

delete: ## Delete both VMs
	@echo "🗑️  Deleting all VMs..."
	multipass delete --purge $(MGMT_VM) 2>/dev/null || true
	multipass delete --purge $(INFRA_VM) 2>/dev/null || true
	@echo "✅ All VMs deleted"

status: ## Show status of all VMs
	multipass list

# ─── SSH ──────────────────────────────────────────────────────────────────────
ssh-mgmt: ## SSH into ok-mgmt-local
	ssh ubuntu@$(MGMT_IP)

ssh-infra: ## SSH into ok-infra-local
	ssh ubuntu@$(INFRA_IP)

# ─── K3s — two independent servers ───────────────────────────────────────────
install-k3s-mgmt: ## Install K3s server on ok-mgmt-local (management cluster)
	@echo "🐳 Installing K3s $(K3S_VERSION) on $(MGMT_VM)..."
	ssh ubuntu@$(MGMT_IP) \
	  "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) sh -s - \
	  --disable=traefik \
	  --tls-san=$(MGMT_IP)"
	@echo "⏳ Waiting for K3s API on $(MGMT_VM)..."
	@ssh ubuntu@$(MGMT_IP) "until sudo k3s kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 3; done"
	@echo "✅ K3s installed and ready on $(MGMT_VM)"
	@$(MAKE) kubeconfig

install-k3s-infra: ## Install K3s server on ok-infra-local (workload cluster)
	@echo "🐳 Installing K3s $(K3S_VERSION) on $(INFRA_VM) (standalone server)..."
	ssh ubuntu@$(INFRA_IP) \
	  "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) sh -s - \
	  --disable=traefik \
	  --tls-san=$(INFRA_IP)"
	@echo "⏳ Waiting for K3s API on $(INFRA_VM)..."
	@ssh ubuntu@$(INFRA_IP) "until sudo k3s kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 3; done"
	@echo "✅ K3s installed and ready on $(INFRA_VM)"
	@$(MAKE) kubeconfig-infra

# ─── Kubeconfig ───────────────────────────────────────────────────────────────
kubeconfig: ## Fetch kubeconfig from ok-mgmt-local and start mgmt tunnel
	@echo "📋 Fetching kubeconfig from $(MGMT_VM)..."
	ssh ubuntu@$(MGMT_IP) "sudo cat /etc/rancher/k3s/k3s.yaml" | \
	  sed 's/127\.0\.0\.1/$(MGMT_IP)/' > $(KUBECONFIG_MGMT)
	@echo "✅ Kubeconfig saved to $(KUBECONFIG_MGMT)"
	@$(MAKE) tunnel
	@echo ""
	@echo "  Management cluster:  export KUBECONFIG=$(PWD)/$(TUNNEL_MGMT)"
	@echo ""

kubeconfig-infra: ## Fetch kubeconfig from ok-infra-local and start infra tunnel
	@echo "📋 Fetching kubeconfig from $(INFRA_VM)..."
	ssh ubuntu@$(INFRA_IP) "sudo cat /etc/rancher/k3s/k3s.yaml" | \
	  sed 's/127\.0\.0\.1/$(INFRA_IP)/' > $(KUBECONFIG_INFRA)
	@echo "✅ Kubeconfig saved to $(KUBECONFIG_INFRA)"
	@$(MAKE) tunnel-infra
	@echo ""
	@echo "  Workload cluster:    export KUBECONFIG=$(PWD)/$(TUNNEL_INFRA)"
	@echo ""

# ─── SSH Tunnels (separate ports per cluster) ─────────────────────────────────
tunnel: ## Start SSH tunnel for mgmt cluster (localhost:6443)
	@echo "🔗 Starting SSH tunnel to $(MGMT_VM) → localhost:6443..."
	@pkill -f "ssh -L 6443:127.0.0.1:6443" 2>/dev/null || true
	@sleep 1
	ssh -L 6443:127.0.0.1:6443 ubuntu@$(MGMT_IP) -N -f
	@echo "✅ Mgmt tunnel on localhost:6443"
	@cat $(KUBECONFIG_MGMT) | sed 's/$(MGMT_IP)/127.0.0.1/' > $(TUNNEL_MGMT)

tunnel-infra: ## Start SSH tunnel for infra cluster (localhost:6444)
	@echo "🔗 Starting SSH tunnel to $(INFRA_VM) → localhost:6444..."
	@pkill -f "ssh -L 6444:127.0.0.1:6443" 2>/dev/null || true
	@sleep 1
	ssh -L 6444:127.0.0.1:6443 ubuntu@$(INFRA_IP) -N -f
	@echo "✅ Infra tunnel on localhost:6444"
	@cat $(KUBECONFIG_INFRA) | sed 's/$(INFRA_IP)/127.0.0.1/' | \
	  sed 's/:6443/:6444/' > $(TUNNEL_INFRA)

tunnel-stop: ## Stop all SSH tunnels
	@pkill -f "ssh -L 6443" 2>/dev/null || true
	@pkill -f "ssh -L 6444" 2>/dev/null || true
	@echo "✅ All tunnels stopped"

tunnels: tunnel tunnel-infra ## Start both SSH tunnels

# ─── Nodes ────────────────────────────────────────────────────────────────────
nodes-mgmt: ## Show nodes in management cluster (ok-mgmt-local)
	@echo "── Management cluster (ok-mgmt-local) ──"
	@if [ -f $(TUNNEL_MGMT) ]; then \
	  KUBECONFIG=$(TUNNEL_MGMT) kubectl get nodes -o wide; \
	else \
	  echo "⚠️  Run: make tunnel"; \
	fi

nodes-infra: ## Show nodes in workload cluster (ok-infra-local)
	@echo "── Workload cluster (ok-infra-local) ──"
	@if [ -f $(TUNNEL_INFRA) ]; then \
	  KUBECONFIG=$(TUNNEL_INFRA) kubectl get nodes -o wide; \
	else \
	  echo "⚠️  Run: make tunnel-infra"; \
	fi

nodes-all: nodes-mgmt nodes-infra ## Show nodes in both clusters

# ─── KubeVirt (workload cluster only) ────────────────────────────────────────
install-kubevirt: ## Install KubeVirt on ok-infra-local (workload cluster)
	@echo "🖥️  Installing KubeVirt $(KUBEVIRT_VERSION) on workload cluster..."
	$(KI) kubectl apply -f \
	  https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-operator.yaml
	$(KI) kubectl apply -f \
	  https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-cr.yaml
	@echo "⏳ Waiting for KubeVirt to be deployed..."
	$(KI) kubectl wait --for=jsonpath='{.status.phase}'=Deployed \
	  kubevirt/kubevirt -n kubevirt --timeout=300s
	@$(MAKE) enable-emulation
	@echo "✅ KubeVirt installed on workload cluster"

enable-emulation: ## Enable software emulation (required on Multipass / no nested KVM)
	@echo "⚙️  Enabling software emulation..."
	$(KI) kubectl patch kubevirt kubevirt -n kubevirt \
	  --type merge \
	  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
	@echo "✅ Software emulation enabled"

install-virtctl: ## Install virtctl CLI on ok-infra-local
	$(eval VERSION := $(shell curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt))
	@echo "📦 Installing virtctl $(VERSION)..."
	ssh ubuntu@$(INFRA_IP) "curl -LO https://github.com/kubevirt/kubevirt/releases/download/$(VERSION)/virtctl-$(VERSION)-linux-amd64 && \
	  sudo install virtctl-$(VERSION)-linux-amd64 /usr/local/bin/virtctl"
	@echo "✅ virtctl installed on $(INFRA_VM)"

# ─── Ollama (workload cluster only) ──────────────────────────────────────────
$(OLLAMA_MANIFESTS)/namespace.yaml:
	@mkdir -p $(OLLAMA_MANIFESTS)
	@printf '%s\n' \
	  'apiVersion: v1' \
	  'kind: Namespace' \
	  'metadata:' \
	  '  name: $(OLLAMA_NAMESPACE)' > $@

$(OLLAMA_MANIFESTS)/service.yaml:
	@mkdir -p $(OLLAMA_MANIFESTS)
	@printf '%s\n' \
	  'apiVersion: v1' \
	  'kind: Service' \
	  'metadata:' \
	  '  name: ollama' \
	  '  namespace: $(OLLAMA_NAMESPACE)' \
	  'spec:' \
	  '  type: ClusterIP' \
	  '  selector:' \
	  '    app.kubernetes.io/name: ollama' \
	  '  ports:' \
	  '    - name: http' \
	  '      port: 11434' \
	  '      targetPort: http' > $@

$(OLLAMA_MANIFESTS)/statefulset.yaml:
	@mkdir -p $(OLLAMA_MANIFESTS)
	@printf '%s\n' \
	  'apiVersion: apps/v1' \
	  'kind: StatefulSet' \
	  'metadata:' \
	  '  name: ollama' \
	  '  namespace: $(OLLAMA_NAMESPACE)' \
	  'spec:' \
	  '  serviceName: ollama' \
	  '  replicas: 1' \
	  '  selector:' \
	  '    matchLabels:' \
	  '      app.kubernetes.io/name: ollama' \
	  '  template:' \
	  '    metadata:' \
	  '      labels:' \
	  '        app.kubernetes.io/name: ollama' \
	  '    spec:' \
	  '      containers:' \
	  '        - name: ollama' \
	  '          image: ollama/ollama:latest' \
	  '          imagePullPolicy: IfNotPresent' \
	  '          ports:' \
	  '            - name: http' \
	  '              containerPort: 11434' \
	  '          startupProbe:' \
	  '            httpGet:' \
	  '              path: /api/tags' \
	  '              port: http' \
	  '            periodSeconds: 5' \
	  '            failureThreshold: 60' \
	  '          readinessProbe:' \
	  '            httpGet:' \
	  '              path: /api/tags' \
	  '              port: http' \
	  '            periodSeconds: 10' \
	  '          resources:' \
	  '            requests:' \
	  '              cpu: 500m' \
	  '              memory: 1Gi' \
	  '            limits:' \
	  '              cpu: "4"' \
	  '              memory: 6Gi' \
	  '          volumeMounts:' \
	  '            - name: data' \
	  '              mountPath: /root/.ollama' \
	  '  volumeClaimTemplates:' \
	  '    - metadata:' \
	  '        name: data' \
	  '      spec:' \
	  '        accessModes:' \
	  '          - ReadWriteOnce' \
	  '        storageClassName: local-path' \
	  '        resources:' \
	  '          requests:' \
	  '            storage: 10Gi' > $@

install-ollama: $(OLLAMA_FILES) ## Generate manifests and install Ollama on ok-infra-local
	@echo "✅ Ollama manifests are available in $(OLLAMA_MANIFESTS)/"
	@test -f $(TUNNEL_INFRA) || { echo "❌ Missing $(TUNNEL_INFRA); run: make tunnel-infra"; exit 1; }
	@echo "🦙 Installing Ollama on $(INFRA_VM)..."
	$(KI) kubectl apply -f $(OLLAMA_MANIFESTS)/
	@echo "⏳ Waiting for Ollama to become ready..."
	$(KI) kubectl rollout status statefulset/ollama \
	  -n $(OLLAMA_NAMESPACE) --timeout=10m
	@echo "✅ Ollama is ready on $(INFRA_VM)"

pull-ollama-model: ## Pull an Ollama model (MODEL=qwen2.5:0.5b)
	@test -f $(TUNNEL_INFRA) || { echo "❌ Missing $(TUNNEL_INFRA); run: make tunnel-infra"; exit 1; }
	@test -n "$(MODEL)" || { echo "❌ MODEL must not be empty"; exit 1; }
	@echo "📦 Pulling Ollama model $(MODEL)..."
	$(KI) kubectl exec -n $(OLLAMA_NAMESPACE) statefulset/ollama -- \
	  ollama pull "$(MODEL)"

ollama-status: ## Show Ollama workload status on ok-infra-local
	@test -f $(TUNNEL_INFRA) || { echo "❌ Missing $(TUNNEL_INFRA); run: make tunnel-infra"; exit 1; }
	$(KI) kubectl get statefulset,pods,service,pvc -n $(OLLAMA_NAMESPACE) -o wide

# ─── Open WebUI through Crossplane (management → workload cluster) ──────────
webui-setup: ## Generate and install the Open WebUI Function, XRD, and Composition
	@test -f "$(MGMT_KUBECONFIG)" || { echo "❌ Missing MGMT_KUBECONFIG: $(MGMT_KUBECONFIG)"; exit 1; }
	@test -f "$(INFRA_KUBECONFIG)" || { echo "❌ Missing INFRA_KUBECONFIG: $(INFRA_KUBECONFIG)"; exit 1; }
	@if grep -Eq 'server: https?://(localhost|127\.0\.0\.1)' "$(INFRA_KUBECONFIG)"; then \
	  echo "❌ INFRA_KUBECONFIG must use the direct infra VM address, not localhost"; \
	  exit 1; \
	fi
	@echo "🔐 Configuring Helm provider access to $(CLUSTER)..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl create secret generic infra-kubeconfig \
	  --namespace crossplane-system \
	  --from-file=kubeconfig="$(INFRA_KUBECONFIG)" \
	  --dry-run=client -o yaml | \
	  KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply -f -
	@printf '%s\n' \
	  '{"apiVersion":"helm.crossplane.io/v1beta1","kind":"ProviderConfig","metadata":{"name":"$(CLUSTER)"},"spec":{"credentials":{"source":"Secret","secretRef":{"namespace":"crossplane-system","name":"infra-kubeconfig","key":"kubeconfig"}}}}' | \
	  KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply -f -
	@mkdir -p "$(WEBUI_DIR)"
	@printf '%s\n' "$$WEBUI_FUNCTION_YAML" > "$(WEBUI_DIR)/function.yaml"
	@printf '%s\n' "$$WEBUI_DEFINITION_YAML" > "$(WEBUI_DIR)/definition.yaml"
	@printf '%s\n' "$$WEBUI_COMPOSITION_YAML" > "$(WEBUI_DIR)/composition.yaml"
	@echo "✅ Open WebUI manifests generated in $(WEBUI_DIR)/"
	@echo "📦 Installing Crossplane composition function..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply -f "$(WEBUI_DIR)/function.yaml"
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl wait \
	  --for=condition=Healthy function/function-patch-and-transform --timeout=5m
	@echo "🧩 Installing Open WebUI XRD..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply -f "$(WEBUI_DIR)/definition.yaml"
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl wait \
	  --for=condition=Established \
	  xrd/openwebuiinstances.platform.openkubes.ai --timeout=2m
	@echo "🧩 Installing Open WebUI Composition..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply -f "$(WEBUI_DIR)/composition.yaml"
	@echo "✅ Open WebUI Crossplane API is ready"

webui-deploy: ## Generate and deploy an Open WebUI claim to the workload cluster
	@test -f "$(MGMT_KUBECONFIG)" || { echo "❌ Missing MGMT_KUBECONFIG: $(MGMT_KUBECONFIG)"; exit 1; }
	@test -n "$(CLUSTER)" || { echo "❌ CLUSTER must not be empty"; exit 1; }
	@test -n "$(OLLAMA_ENDPOINT)" || { echo "❌ OLLAMA_ENDPOINT must not be empty"; exit 1; }
	@echo "📁 Ensuring claim namespace $(WEBUI_CLAIM_NAMESPACE) exists..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl create namespace \
	  "$(WEBUI_CLAIM_NAMESPACE)" --dry-run=client -o yaml | \
	  KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply -f -
	@mkdir -p "$(WEBUI_DIR)/generated"
	@printf '%s\n' "$$WEBUI_CLAIM_YAML" > "$(WEBUI_DIR)/generated/$(CLUSTER)-claim.yaml"
	@echo "✅ Open WebUI claim generated at $(WEBUI_DIR)/generated/$(CLUSTER)-claim.yaml"
	@echo "🚀 Deploying Open WebUI to $(CLUSTER)..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl apply \
	  -f "$(WEBUI_DIR)/generated/$(CLUSTER)-claim.yaml"
	@echo "⏳ Waiting for the Open WebUI claim to become ready..."
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl wait \
	  --for=condition=Ready "openwebuiclaim/$(CLUSTER)" \
	  -n "$(WEBUI_CLAIM_NAMESPACE)" --timeout=15m
	@echo "✅ Open WebUI is ready on $(CLUSTER)"

webui-status: ## Show Open WebUI Crossplane and Helm release status
	@test -f "$(MGMT_KUBECONFIG)" || { echo "❌ Missing MGMT_KUBECONFIG: $(MGMT_KUBECONFIG)"; exit 1; }
	@echo "── Open WebUI claim ──"
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl get openwebuiclaim \
	  "$(CLUSTER)" -n "$(WEBUI_CLAIM_NAMESPACE)" -o wide
	@echo "── Open WebUI composite resource ──"
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl get openwebuiinstance -o wide
	@echo "── Crossplane Helm release ──"
	@KUBECONFIG="$(MGMT_KUBECONFIG)" kubectl get release.helm.crossplane.io \
	  open-webui -o wide

# ─── Full Setup (sequential: mgmt first, then infra) ─────────────────────────
setup: ## Full setup: mgmt first (VM+K3s), then infra (VM+K3s+KubeVirt)
	@$(MAKE) up-mgmt
	@echo "⏳ Waiting 10s for cloud-init to settle..."
	@sleep 10
	@ssh-keyscan $$(multipass list --format csv 2>/dev/null | grep $(MGMT_VM) | cut -d',' -f3 | tr -d ' ') >> ~/.ssh/known_hosts 2>/dev/null || true
	@$(MAKE) install-k3s-mgmt
	@$(MAKE) up-infra
	@echo "⏳ Waiting 10s for cloud-init to settle..."
	@sleep 10
	@ssh-keyscan $$(multipass list --format csv 2>/dev/null | grep $(INFRA_VM) | cut -d',' -f3 | tr -d ' ') >> ~/.ssh/known_hosts 2>/dev/null || true
	@$(MAKE) install-k3s-infra
	@$(MAKE) install-kubevirt
	@echo ""
	@echo "🎉 openkubes-local is ready!"
	@echo ""
	@$(MAKE) nodes-all
	@echo ""
	@echo "  Switch clusters:"
	@echo "    export KUBECONFIG=$(PWD)/$(TUNNEL_MGMT)   # management"
	@echo "    export KUBECONFIG=$(PWD)/$(TUNNEL_INFRA)  # workload"
	@echo ""
	@echo "  Aliases (add to ~/.zshrc):"
	@echo "    alias oml=\"kubectl --kubeconfig $(PWD)/.tunnel-mgmt.kubeconfig\""
	@echo "    alias oil=\"kubectl --kubeconfig $(PWD)/.tunnel-infra.kubeconfig\""
	@echo ""
	@echo "  Now run:"
	@echo "    oml get nodes    # management cluster"
	@echo "    oil get nodes    # workload cluster"
	@echo "    oil get pods -n kubevirt"
	@echo ""

# ─── Cloud-Init ───────────────────────────────────────────────────────────────
cloud-init.yaml: ## Generate cloud-init.yaml with your SSH key
	@echo "📝 Generating cloud-init.yaml..."
	@printf 'package_update: true\npackage_upgrade: false\nusers:\n  - name: ubuntu\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - %s\n' "$$(cat $(SSH_KEY))" > cloud-init.yaml
	@echo "✅ cloud-init.yaml generated"

# ─── Clean ────────────────────────────────────────────────────────────────────
clean: tunnel-stop delete ## Stop tunnels, delete VMs and generated files
	rm -f $(KUBECONFIG_MGMT) $(KUBECONFIG_INFRA) $(TUNNEL_MGMT) $(TUNNEL_INFRA) cloud-init.yaml
	@echo "🧹 Cleaned."
