# Tutorial 2: openkubes-local — Workload Cluster Setup (ok-infra-local)

This tutorial sets up `ok-infra-local` — a separate K3s cluster that acts as the local workload plane. It runs KubeVirt with software emulation, simulating the Hetzner `ok-infra` bare metal node locally on your Mac.

## What you will build

```
Mac
├── ok-mgmt-local (192.168.2.x) ← already running from Tutorial 1
└── ok-infra-local (192.168.2.y)
    ├── K3s v1.35.5 — standalone server (not joined to mgmt)
    ├── KubeVirt v1.8.3 — VM workloads via QEMU software emulation
    ├── SSH tunnel → localhost:6444
    └── kubectl access via .tunnel-infra.kubeconfig
```

## Prerequisites

- Tutorial 1 completed (`ok-mgmt-local` is running)
- Makefile from Tutorial 1 in place
- `kubectl` installed

---

## Step 1 — Launch the workload VM

```bash
make up-infra
```

When `Launched: ok-infra-local` appears, accept the SSH host key:

```bash
INFRA_IP=$(multipass list --format csv | grep ok-infra-local | cut -d',' -f3 | tr -d ' ')
ssh-keyscan $INFRA_IP >> ~/.ssh/known_hosts
```

> **Why manually?** Multipass assigns a new IP each time. The host key prompt blocks automated SSH — `ssh-keyscan` pre-registers the key so all subsequent commands run unattended.

---

## Step 2 — Install K3s as standalone server

```bash
make install-k3s-infra
```

This installs K3s as an **independent server** — not joined to `ok-mgmt-local`. Each cluster is completely separate.

The Makefile polls until the node is `Ready` before continuing, then fetches the kubeconfig and starts the SSH tunnel on `localhost:6444`.

Expected output:
```
✅ K3s installed and ready on ok-infra-local
✅ Infra tunnel on localhost:6444

  Workload cluster:  export KUBECONFIG=/path/to/.tunnel-infra.kubeconfig
```

> **Why a separate cluster?** This mirrors the production architecture: `ok-mgmt-local` is the management plane (CAPI, Crossplane, Argo CD), `ok-infra-local` is the workload plane where VMs run. Two clusters, one manages the other.

> **Why port 6444?** The mgmt tunnel already occupies `localhost:6443`. Each cluster gets its own port: mgmt=6443, infra=6444.

---

## Step 3 — Verify the workload cluster

```bash
export KUBECONFIG=$(PWD)/.tunnel-infra.kubeconfig
kubectl get nodes
```

Expected output:
```
NAME             STATUS   ROLES           AGE   VERSION
ok-infra-local   Ready    control-plane   ...   v1.35.5+k3s1
```

Or use the alias from Tutorial 1:
```bash
oil get nodes
```

---

## Step 4 — Install KubeVirt

```bash
make install-kubevirt
```

This installs KubeVirt on the **workload cluster** (`ok-infra-local`) only, using `.tunnel-infra.kubeconfig`. It:

1. Deploys the KubeVirt operator
2. Applies the KubeVirt CR
3. Waits until `phase=Deployed` (up to 5 minutes)
4. Enables software emulation

Expected output:
```
✅ Software emulation enabled
✅ KubeVirt installed on workload cluster
```

> **Why software emulation?** Multipass VMs on macOS do not expose `/dev/kvm` — nested KVM virtualization is not available. Setting `useEmulation: true` forces KubeVirt to use QEMU in pure software mode. This is slower but works perfectly for API testing and manifest validation.

---

## Step 5 — Verify both clusters

```bash
make nodes-all
```

Expected output:
```
── Management cluster (ok-mgmt-local) ──
NAME            STATUS   ROLES           AGE   VERSION
ok-mgmt-local   Ready    control-plane   ...   v1.35.5+k3s1

── Workload cluster (ok-infra-local) ──
NAME             STATUS   ROLES           AGE   VERSION
ok-infra-local   Ready    control-plane   ...   v1.35.5+k3s1
```

---

## Step 6 — Set up aliases

Add to `~/.zshrc`:

```bash
alias oml="kubectl --kubeconfig ~/path/to/ok-local/.tunnel-mgmt.kubeconfig"
alias oil="kubectl --kubeconfig ~/path/to/ok-local/.tunnel-infra.kubeconfig"
```

```bash
source ~/.zshrc

# Now run:
oml get nodes          # management cluster
oil get nodes          # workload cluster
oil get pods -n kubevirt
```

---

## Troubleshooting

**`multipass shell` fails with `No route to host`**
This is a known bug in Multipass on recent macOS versions — the internal Multipass SSH key stops working. Use direct SSH instead:
```bash
# Instead of: multipass shell ok-mgmt-local
ssh ubuntu@<VM_IP>

# Or use the Makefile targets:
make ssh-mgmt
make ssh-infra
```
All tutorials in this repo use direct SSH — `multipass shell` is never required.


**`connection refused` on K3s install**
K3s needs 30–60 seconds after `systemd: Starting k3s` before the API is ready. The `make install-k3s-infra` target polls automatically — just wait.

**KubeVirt pods stuck in `Pending`**
Check events:
```bash
oil get pods -n kubevirt
oil describe pod -n kubevirt <pod-name>
```
Usually resolves within 2–3 minutes as images are pulled.

**Tunnel lost after Mac sleep**
Restart both tunnels:
```bash
make tunnels
```

**Start fresh**
```bash
make clean
# Then follow Tutorial 1 and Tutorial 2 again
```

---

## What's next

- **Tutorial 3:** Installing CAPI and Crossplane on `ok-mgmt-local`
- Deploy a test VM on `ok-infra-local` using KubeVirt

---

## Quick reference

| Command | What it does |
|---|---|
| `make up-infra` | Launch the workload VM |
| `make install-k3s-infra` | Install K3s as standalone server |
| `make kubeconfig-infra` | Fetch kubeconfig + start infra tunnel |
| `make tunnel-infra` | (Re)start the infra SSH tunnel (localhost:6444) |
| `make install-kubevirt` | Install KubeVirt on workload cluster |
| `make enable-emulation` | Enable QEMU software emulation |
| `make install-virtctl` | Install virtctl CLI on ok-infra-local |
| `make nodes-infra` | Show nodes in workload cluster |
| `make nodes-all` | Show nodes in both clusters |
| `make ssh-infra` | SSH into the workload VM |
