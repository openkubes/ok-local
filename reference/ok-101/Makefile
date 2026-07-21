SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

MGMT_NAME ?= ok-mgmt-local
INFRA_NAME ?= ok-infra-local
K3S_VERSION ?= v1.35.5+k3s1
MGMT_CPUS ?= 4
MGMT_MEMORY ?= 8G
MGMT_DISK ?= 40G
INFRA_CPUS ?= 4
INFRA_MEMORY ?= 8G
INFRA_DISK ?= 40G

MGMT_KUBECONFIG := $(CURDIR)/mgmt-local.kubeconfig
INFRA_KUBECONFIG := $(CURDIR)/infra-local.kubeconfig
MGMT_TUNNEL_KUBECONFIG := $(CURDIR)/.tunnel-mgmt.kubeconfig
INFRA_TUNNEL_KUBECONFIG := $(CURDIR)/.tunnel-infra.kubeconfig
CLOUD_INIT := $(CURDIR)/cloud-init.yaml

.PHONY: help setup _setup prerequisites tutorial-0 tutorial-1 tutorial-2 tutorial-3 tutorial-4 tutorials \
        up-mgmt install-k3s-mgmt kubeconfig tunnel tunnel-mgmt nodes-mgmt ssh-mgmt \
        up-infra install-k3s-infra kubeconfig-infra tunnel-infra \
        nodes-infra nodes-all ssh-infra tunnels \
        install-capi capi-secret install-crossplane install-crossplane-providers \
        crossplane-provider-configs crossplane-examples status clean

help:
	@printf '%s\n' \
	  'OpenKubes local tutorial runner' \
	  '' \
	  'Main command:' \
	  '  make setup          Run prerequisites and Tutorials 1-4' \
	  '  make tutorials      Alias for make setup' \
	  '' \
	  'Individual tutorials:' \
	  '  make tutorial-0     Check/install prerequisites' \
	  '  make tutorial-1     Create management cluster' \
	  '  make tutorial-2     Create workload K3s cluster' \
	  '  make tutorial-3     Install CAPI/CAPK and configure infra access' \
	  '  make tutorial-4     Install Crossplane + providers/examples' \
	  '' \
	  'Maintenance:' \
	  '  make status         Show VM and cluster status' \
	  '  make tunnels        Restart both SSH tunnels' \
	  '  make clean          Delete VMs and generated files'

# -----------------------------------------------------------------------------
# Main entry points
# -----------------------------------------------------------------------------

# Keep this recipe on one physical line so Apple's older system make can run it
# even though the rest of this file intentionally uses .ONESHELL with GNU Make.
setup:
	@command -v gmake >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 || { echo 'ERROR: Homebrew is required to install GNU Make.'; exit 1; }; echo '==> Installing modern GNU Make'; brew install make; }; exec gmake --no-print-directory _setup

_setup: tutorial-4
	@echo 'OK: setup completed (Tutorials 0-4).'

tutorials: setup

# -----------------------------------------------------------------------------
# Tutorial 0 - Prerequisites
# -----------------------------------------------------------------------------

tutorial-0: prerequisites

prerequisites:
	@echo '==> Tutorial 0: checking prerequisites'
	if ! command -v brew >/dev/null 2>&1; then
		echo 'ERROR: Homebrew is required.'
		echo 'Install it with:'
		echo '/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
		exit 1
	fi
	for pkg in multipass kubectl helm clusterctl; do
		if ! command -v "$$pkg" >/dev/null 2>&1; then
			echo "Installing $$pkg..."
			brew install "$$pkg"
		fi
	done
	if ! command -v git >/dev/null 2>&1; then
		echo 'ERROR: git is required.'
		exit 1
	fi
	if [ ! -f "$$HOME/.ssh/id_ed25519.pub" ] && [ ! -f "$$HOME/.ssh/id_rsa.pub" ]; then
		echo 'Generating SSH key at ~/.ssh/id_ed25519'
		mkdir -p "$$HOME/.ssh"
		ssh-keygen -t ed25519 -f "$$HOME/.ssh/id_ed25519" -N ''
	fi
	mkdir -p "$$HOME/.ssh"
	chmod 700 "$$HOME/.ssh"
	if ! grep -q '^Host 192\.168\.2\.\*' "$$HOME/.ssh/config" 2>/dev/null; then
		cat >> "$$HOME/.ssh/config" <<'SSHCFG'
	
	# Multipass VMs
	Host 192.168.2.*
	  IdentityFile ~/.ssh/id_ed25519
	  User ubuntu
	  StrictHostKeyChecking accept-new
	SSHCFG
		chmod 600 "$$HOME/.ssh/config"
	fi
	echo 'OK: prerequisites are available.'

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------

define get_mgmt_ip
multipass list --format csv | awk -F, '$$1 == "$(MGMT_NAME)" {gsub(/ /, "", $$3); print $$3; exit}'
endef

define get_infra_ip
multipass list --format csv | awk -F, '$$1 == "$(INFRA_NAME)" {gsub(/ /, "", $$3); print $$3; exit}'
endef

$(CLOUD_INIT):
	KEY_FILE="$$HOME/.ssh/id_ed25519.pub"
	if [ ! -f "$$KEY_FILE" ]; then KEY_FILE="$$HOME/.ssh/id_rsa.pub"; fi
	PUBKEY="$$(cat "$$KEY_FILE")"
	cat > "$@" <<EOF_CLOUD
	#cloud-config
	users:
	  - default
	  - name: ubuntu
	    groups: [adm, sudo]
	    shell: /bin/bash
	    sudo: ALL=(ALL) NOPASSWD:ALL
	    ssh_authorized_keys:
	      - $$PUBKEY
	package_update: true
	packages:
	  - curl
	  - jq
	  - socat
	  - conntrack
	EOF_CLOUD

# -----------------------------------------------------------------------------
# Tutorial 1 - Management cluster
# -----------------------------------------------------------------------------

tutorial-1: prerequisites up-mgmt install-k3s-mgmt kubeconfig nodes-mgmt
	@echo 'OK: Tutorial 1 completed.'

up-mgmt: $(CLOUD_INIT)
	@echo '==> Launching $(MGMT_NAME)'
	if multipass info "$(MGMT_NAME)" >/dev/null 2>&1; then
		echo 'VM already exists; starting it if needed.'
		multipass start "$(MGMT_NAME)" >/dev/null 2>&1 || true
	else
		multipass launch 24.04 \
			--name "$(MGMT_NAME)" \
			--cpus "$(MGMT_CPUS)" \
			--memory "$(MGMT_MEMORY)" \
			--disk "$(MGMT_DISK)" \
			--cloud-init "$(CLOUD_INIT)"
	fi
	for i in $$(seq 1 60); do
		MGMT_IP="$$( $(get_mgmt_ip) )"
		if [ -n "$$MGMT_IP" ]; then
			ssh-keygen -R "$$MGMT_IP" >/dev/null 2>&1 || true
			ssh-keyscan -H "$$MGMT_IP" >> "$$HOME/.ssh/known_hosts" 2>/dev/null || true
			if ssh -o BatchMode=yes -o ConnectTimeout=3 "ubuntu@$$MGMT_IP" true 2>/dev/null; then
				echo "OK: $(MGMT_NAME) is reachable at $$MGMT_IP"
				exit 0
			fi
		fi
		sleep 5
	done
	echo 'ERROR: management VM did not become SSH-ready.'
	exit 1

install-k3s-mgmt:
	@echo '==> Installing K3s on $(MGMT_NAME)'
	MGMT_IP="$$( $(get_mgmt_ip) )"
	test -n "$$MGMT_IP"
	ssh "ubuntu@$$MGMT_IP" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$(K3S_VERSION)' sh -s - server --disable traefik --tls-san '$$MGMT_IP'"
	for i in $$(seq 1 60); do
		if ssh "ubuntu@$$MGMT_IP" "sudo k3s kubectl get node $(MGMT_NAME) --no-headers 2>/dev/null | grep -q ' Ready '"; then
			echo 'OK: management K3s node is Ready.'
			exit 0
		fi
		sleep 5
	done
	echo 'ERROR: management K3s node did not become Ready.'
	exit 1

kubeconfig: tunnel-mgmt

kubeconfig-mgmt:
	MGMT_IP="$$( $(get_mgmt_ip) )"
	ssh "ubuntu@$$MGMT_IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' > "$(MGMT_KUBECONFIG)"
	sed -i '' "s/127.0.0.1/$$MGMT_IP/g" "$(MGMT_KUBECONFIG)"
	cp "$(MGMT_KUBECONFIG)" "$(MGMT_TUNNEL_KUBECONFIG)"
	sed -i '' 's#https://[^:]*:6443#https://127.0.0.1:6443#' "$(MGMT_TUNNEL_KUBECONFIG)"
	chmod 600 "$(MGMT_KUBECONFIG)" "$(MGMT_TUNNEL_KUBECONFIG)"

# Alias retained for Tutorial 1 wording.
tunnel: tunnel-mgmt

tunnel-mgmt: kubeconfig-mgmt
	@echo '==> Ensuring management SSH tunnel on localhost:6443'
	MGMT_IP="$$( $(get_mgmt_ip) )"
	if KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl --request-timeout=3s get --raw=/readyz >/dev/null 2>&1; then
		echo 'OK: existing management tunnel is healthy; reusing it.'
		exit 0
	fi
	PIDS="$$(lsof -nP -iTCP:6443 -sTCP:LISTEN -t 2>/dev/null || true)"
	for pid in $$PIDS; do
		cmd="$$(ps -p "$$pid" -o command= 2>/dev/null || true)"
		if [[ "$$cmd" == *ssh* ]]; then
			echo "Stopping stale SSH listener on port 6443 (PID $$pid)."
			kill "$$pid" 2>/dev/null || true
		else
			echo "ERROR: port 6443 is occupied by a non-SSH process (PID $$pid): $$cmd"
			echo 'Stop that process or set a different local port in the Makefile.'
			exit 1
		fi
	done
	sleep 1
	ssh -fNT -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
		-L 127.0.0.1:6443:127.0.0.1:6443 "ubuntu@$$MGMT_IP"
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl --request-timeout=10s get --raw=/readyz >/dev/null
	echo 'OK: management tunnel ready.'

nodes-mgmt:
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl get nodes

ssh-mgmt:
	MGMT_IP="$$( $(get_mgmt_ip) )"
	exec ssh "ubuntu@$$MGMT_IP"

# -----------------------------------------------------------------------------
# Tutorial 2 - Workload K3s cluster (without KubeVirt)
# -----------------------------------------------------------------------------

tutorial-2: tutorial-1 up-infra install-k3s-infra nodes-all
	@echo 'OK: Tutorial 2 completed.'

up-infra: $(CLOUD_INIT)
	@echo '==> Launching $(INFRA_NAME)'
	if multipass info "$(INFRA_NAME)" >/dev/null 2>&1; then
		multipass start "$(INFRA_NAME)" >/dev/null 2>&1 || true
	else
		multipass launch 24.04 \
			--name "$(INFRA_NAME)" \
			--cpus "$(INFRA_CPUS)" \
			--memory "$(INFRA_MEMORY)" \
			--disk "$(INFRA_DISK)" \
			--cloud-init "$(CLOUD_INIT)"
	fi
	for i in $$(seq 1 60); do
		INFRA_IP="$$( $(get_infra_ip) )"
		if [ -n "$$INFRA_IP" ]; then
			ssh-keygen -R "$$INFRA_IP" >/dev/null 2>&1 || true
			ssh-keyscan -H "$$INFRA_IP" >> "$$HOME/.ssh/known_hosts" 2>/dev/null || true
			if ssh -o BatchMode=yes -o ConnectTimeout=3 "ubuntu@$$INFRA_IP" true 2>/dev/null; then
				echo "OK: $(INFRA_NAME) is reachable at $$INFRA_IP"
				exit 0
			fi
		fi
		sleep 5
	done
	echo 'ERROR: infra VM did not become SSH-ready.'
	exit 1

install-k3s-infra:
	@echo '==> Installing standalone K3s on $(INFRA_NAME)'
	INFRA_IP="$$( $(get_infra_ip) )"
	ssh "ubuntu@$$INFRA_IP" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$(K3S_VERSION)' sh -s - server --disable traefik --tls-san '$$INFRA_IP'"
	for i in $$(seq 1 60); do
		if ssh "ubuntu@$$INFRA_IP" "sudo k3s kubectl get node $(INFRA_NAME) --no-headers 2>/dev/null | grep -q ' Ready '"; then
			break
		fi
		sleep 5
	done
	$(MAKE) kubeconfig-infra

kubeconfig-infra:
	INFRA_IP="$$( $(get_infra_ip) )"
	ssh "ubuntu@$$INFRA_IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' > "$(INFRA_KUBECONFIG)"
	sed -i '' "s/127.0.0.1/$$INFRA_IP/g" "$(INFRA_KUBECONFIG)"
	cp "$(INFRA_KUBECONFIG)" "$(INFRA_TUNNEL_KUBECONFIG)"
	sed -i '' 's#https://[^:]*:6443#https://127.0.0.1:6444#' "$(INFRA_TUNNEL_KUBECONFIG)"
	chmod 600 "$(INFRA_KUBECONFIG)" "$(INFRA_TUNNEL_KUBECONFIG)"
	$(MAKE) tunnel-infra

# Do not depend on kubeconfig-infra here, otherwise make would recurse forever.
tunnel-infra:
	@echo '==> Ensuring infra SSH tunnel on localhost:6444'
	INFRA_IP="$$( $(get_infra_ip) )"
	if KUBECONFIG="$(INFRA_TUNNEL_KUBECONFIG)" kubectl --request-timeout=3s get --raw=/readyz >/dev/null 2>&1; then
		echo 'OK: existing infra tunnel is healthy; reusing it.'
		exit 0
	fi
	PIDS="$$(lsof -nP -iTCP:6444 -sTCP:LISTEN -t 2>/dev/null || true)"
	for pid in $$PIDS; do
		cmd="$$(ps -p "$$pid" -o command= 2>/dev/null || true)"
		if [[ "$$cmd" == *ssh* ]]; then
			echo "Stopping stale SSH listener on port 6444 (PID $$pid)."
			kill "$$pid" 2>/dev/null || true
		else
			echo "ERROR: port 6444 is occupied by a non-SSH process (PID $$pid): $$cmd"
			echo 'Stop that process or set a different local port in the Makefile.'
			exit 1
		fi
	done
	sleep 1
	ssh -fNT -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
		-L 127.0.0.1:6444:127.0.0.1:6443 "ubuntu@$$INFRA_IP"
	KUBECONFIG="$(INFRA_TUNNEL_KUBECONFIG)" kubectl --request-timeout=10s get --raw=/readyz >/dev/null
	echo 'OK: infra tunnel ready.'

nodes-infra:
	KUBECONFIG="$(INFRA_TUNNEL_KUBECONFIG)" kubectl get nodes

nodes-all:
	@echo '--- Management cluster ---'
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl get nodes
	@echo '--- Workload cluster ---'
	KUBECONFIG="$(INFRA_TUNNEL_KUBECONFIG)" kubectl get nodes

ssh-infra:
	INFRA_IP="$$( $(get_infra_ip) )"
	exec ssh "ubuntu@$$INFRA_IP"

tunnels: tunnel-mgmt tunnel-infra

# -----------------------------------------------------------------------------
# Tutorial 3 - CAPI/CAPK configuration (without test VM)
# -----------------------------------------------------------------------------

tutorial-3: tutorial-2 install-capi capi-secret
	@echo 'OK: Tutorial 3 completed.'

install-capi:
	@echo '==> Installing CAPI and CAPK on management cluster'
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" clusterctl init \
		--infrastructure kubevirt \
		--bootstrap kubeadm \
		--control-plane kubeadm
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl wait --for=condition=Available deployment --all -A --timeout=10m

capi-secret:
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl create secret generic kubevirt-infra-kubeconfig \
		-n capk-system \
		--from-file=kubeconfig="$(INFRA_KUBECONFIG)" \
		--dry-run=client -o yaml | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -

# -----------------------------------------------------------------------------
# Tutorial 4 - Crossplane
# -----------------------------------------------------------------------------

tutorial-4: tutorial-3 install-crossplane install-crossplane-providers crossplane-provider-configs crossplane-examples
	@echo 'OK: Tutorial 4 completed.'

install-crossplane:
	@echo '==> Installing Crossplane'
	helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update
	helm repo update
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" helm upgrade --install crossplane \
		crossplane-stable/crossplane \
		--namespace crossplane-system \
		--create-namespace \
		--wait

install-crossplane-providers:
	printf '%s\n' '{"apiVersion":"pkg.crossplane.io/v1","kind":"Provider","metadata":{"name":"provider-kubernetes"},"spec":{"package":"xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1"}}' | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -
	printf '%s\n' '{"apiVersion":"pkg.crossplane.io/v1","kind":"Provider","metadata":{"name":"provider-helm"},"spec":{"package":"xpkg.upbound.io/crossplane-contrib/provider-helm:v1.2.0"}}' | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -
	for i in $$(seq 1 90); do
		HEALTHY="$$(KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl get providers.pkg.crossplane.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Healthy")].status}{"\n"}{end}' 2>/dev/null || true)"
		echo "$$HEALTHY"
		if echo "$$HEALTHY" | grep -q 'provider-kubernetes=True' && echo "$$HEALTHY" | grep -q 'provider-helm=True'; then
			exit 0
		fi
		sleep 5
	done
	echo 'ERROR: Crossplane providers did not become healthy.'
	exit 1

crossplane-provider-configs:
	KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl create secret generic infra-kubeconfig \
		-n crossplane-system \
		--from-file=kubeconfig="$(INFRA_KUBECONFIG)" \
		--dry-run=client -o yaml | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -
	printf '%s\n' '{"apiVersion":"kubernetes.crossplane.io/v1alpha1","kind":"ProviderConfig","metadata":{"name":"ok-infra-local"},"spec":{"credentials":{"source":"Secret","secretRef":{"namespace":"crossplane-system","name":"infra-kubeconfig","key":"kubeconfig"}}}}' | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -
	printf '%s\n' '{"apiVersion":"helm.crossplane.io/v1beta1","kind":"ProviderConfig","metadata":{"name":"ok-infra-local"},"spec":{"credentials":{"source":"Secret","secretRef":{"namespace":"crossplane-system","name":"infra-kubeconfig","key":"kubeconfig"}}}}' | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -

crossplane-examples:
	printf '%s\n' '{"apiVersion":"kubernetes.crossplane.io/v1alpha2","kind":"Object","metadata":{"name":"ok-test-namespace"},"spec":{"providerConfigRef":{"name":"ok-infra-local"},"forProvider":{"manifest":{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"ok-crossplane-test"}}}}}' | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -
	printf '%s\n' '{"apiVersion":"helm.crossplane.io/v1beta1","kind":"Release","metadata":{"name":"podinfo"},"spec":{"providerConfigRef":{"name":"ok-infra-local"},"forProvider":{"chart":{"name":"podinfo","repository":"https://stefanprodan.github.io/podinfo","version":"6.7.1"},"namespace":"default","values":{"replicaCount":1}}}}' | KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl apply -f -
	for i in $$(seq 1 90); do
		OBJ_READY="$$(KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl get object ok-test-namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
		REL_READY="$$(KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl get release.helm.crossplane.io podinfo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
		if [ "$$OBJ_READY" = 'True' ] && [ "$$REL_READY" = 'True' ]; then
			echo 'OK: Crossplane namespace and Helm release are ready.'
			exit 0
		fi
		sleep 5
	done
	echo 'ERROR: Crossplane examples did not become ready.'
	exit 1

status:
	multipass list
	@echo ''
	if [ -f "$(MGMT_TUNNEL_KUBECONFIG)" ]; then KUBECONFIG="$(MGMT_TUNNEL_KUBECONFIG)" kubectl get nodes; fi
	@echo ''
	if [ -f "$(INFRA_TUNNEL_KUBECONFIG)" ]; then KUBECONFIG="$(INFRA_TUNNEL_KUBECONFIG)" kubectl get nodes; fi

clean:
	@echo '==> Removing local environment'
	pkill -f '127.0.0.1:6443:127.0.0.1:6443' >/dev/null 2>&1 || true
	pkill -f '127.0.0.1:6444:127.0.0.1:6443' >/dev/null 2>&1 || true
	multipass delete "$(MGMT_NAME)" >/dev/null 2>&1 || true
	multipass delete "$(INFRA_NAME)" >/dev/null 2>&1 || true
	multipass purge >/dev/null 2>&1 || true
	rm -f "$(CLOUD_INIT)" "$(MGMT_KUBECONFIG)" "$(INFRA_KUBECONFIG)" \
		"$(MGMT_TUNNEL_KUBECONFIG)" "$(INFRA_TUNNEL_KUBECONFIG)"
	echo 'OK: local environment removed.'
