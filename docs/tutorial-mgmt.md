# Tutorial 1: openkubes-local — Management Cluster Setup

This tutorial walks you through setting up `ok-mgmt-local`, the local management cluster for OpenKubes. It runs K3s inside a Multipass VM on your Mac and serves as the control plane for the OpenKubes stack (CAPI, Crossplane, Argo CD).

## What you will build

```
Mac
└── ok-mgmt-local (Multipass VM)
    ├── K3s v1.35.5 — lightweight Kubernetes
    ├── SSH tunnel → localhost:6443
    └── kubectl access via .tunnel-mgmt.kubeconfig
```

## Prerequisites

- macOS (Intel or Apple Silicon)
- [Multipass](https://multipass.run/) installed (`brew install multipass`)
- `kubectl` installed (`brew install kubectl`)
- SSH key at `~/.ssh/id_rsa.pub`
- This repo cloned: `git clone https://github.com/openkubes/ok-local`

---

## Step 1 — Launch the management VM

```bash
cd ok-local
make up-mgmt
```

This will:
- Generate `cloud-init.yaml` with your SSH public key
- Launch a Multipass VM (`ok-mgmt-local`) with 4 CPUs, 8GB RAM, 40GB disk
- Wait until SSH is reachable (host key accepted automatically)

Expected output:
```
✅ ok-mgmt-local is up and SSH ready
```

> **Note:** Multipass returns as soon as the VM boots, but cloud-init still runs in the background. The SSH wait loop ensures your key is injected before proceeding.

---

## Step 2 — Install K3s

```bash
make install-k3s-mgmt
```

This installs K3s `v1.35.5+k3s1` on the VM with:
- Traefik disabled (we use our own ingress later)
- TLS SAN set to the VM's IP (required for external kubectl access)

The Makefile polls until the node is `Ready` before continuing.

Expected output:
```
✅ K3s installed and ready on ok-mgmt-local
```

> **Why no `--kubelet-arg=feature-gates`?** The `DevicePlugins` feature gate was removed in Kubernetes 1.35 and causes a crash loop if passed. K3s handles device plugins natively.

---

## Step 3 — Fetch kubeconfig and start SSH tunnel

```bash
make kubeconfig
```

This:
1. Fetches `/etc/rancher/k3s/k3s.yaml` from the VM
2. Replaces `127.0.0.1` with the VM's IP → saves to `mgmt-local.kubeconfig`
3. Starts an SSH tunnel: `localhost:6443` → VM port `6443`
4. Creates `.tunnel-mgmt.kubeconfig` (points to `127.0.0.1:6443`)

Expected output:
```
✅ Kubeconfig saved to mgmt-local.kubeconfig
✅ Mgmt tunnel on localhost:6443

  Management cluster:  export KUBECONFIG=/path/to/.tunnel-mgmt.kubeconfig
```

> **Why a tunnel?** On macOS, Multipass VMs are on a private bridge network. Port 6443 on the VM is not directly reachable from the Mac — the SSH tunnel bridges the gap.

---

## Step 4 — Verify the cluster

```bash
make nodes-mgmt
```

Expected output:
```
── Management cluster (ok-mgmt-local) ──
NAME            STATUS   ROLES           AGE   VERSION
ok-mgmt-local   Ready    control-plane   ...   v1.35.5+k3s1
```

---

## Step 5 — Set up aliases

Add these to your `~/.zshrc` for quick access:

```bash
alias oml="kubectl --kubeconfig ~/path/to/ok-local/.tunnel-mgmt.kubeconfig"
```

Then:
```bash
source ~/.zshrc

# Now run:
oml get nodes
oml get pods -A
```

---

## Troubleshooting

**SSH hangs after VM launch**
The host key prompt blocks the connection. Fix:
```bash
MGMT_IP=$(multipass list --format csv | grep ok-mgmt-local | cut -d',' -f3 | tr -d ' ')
ssh-keyscan $MGMT_IP >> ~/.ssh/known_hosts
```

**K3s stuck in `activating`**
K3s needs 30–60 seconds to fully start after installation. The `make install-k3s-mgmt` target polls automatically. If you run kubectl manually too early, just wait.

**`connection refused` on port 6443**
The SSH tunnel is not running. Restart it:
```bash
make tunnel
```

**K3s crash loop (`restart counter` keeps climbing)**
Check for invalid flags:
```bash
ssh ubuntu@<VM_IP> "sudo journalctl -u k3s -n 50 --no-pager | grep error"
```
The most common cause is passing removed feature gates (e.g. `DevicePlugins` in K3s 1.35+).

---

## What's next

- **Tutorial 2:** Setting up `ok-infra-local` as a separate workload cluster with KubeVirt
- **Tutorial 3:** Installing CAPI and Crossplane on the management cluster

---

## Quick reference

| Command | What it does |
|---|---|
| `make up-mgmt` | Launch the management VM |
| `make install-k3s-mgmt` | Install K3s on the management VM |
| `make kubeconfig` | Fetch kubeconfig + start SSH tunnel |
| `make tunnel` | (Re)start the SSH tunnel |
| `make nodes-mgmt` | Show nodes in the management cluster |
| `make ssh-mgmt` | SSH into the management VM |
| `make clean` | Delete VMs, tunnels and generated files |
