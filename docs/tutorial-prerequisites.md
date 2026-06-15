# Tutorial 0: Prerequisites — Setting up your Mac for openkubes-local

This tutorial covers everything you need to install and configure on your Mac before running the openkubes-local setup. No Kubernetes knowledge required — just a Mac and a terminal.

## What you need

| Tool | Purpose | Min version |
|---|---|---|
| macOS | Host OS | 12+ |
| Multipass | Lightweight Ubuntu VMs | 1.14+ |
| kubectl | Kubernetes CLI | 1.28+ |
| Git | Clone the repo | any |
| SSH key | VM access via cloud-init | — |

---

## Step 1 — Install Homebrew

If you don't have Homebrew yet:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Verify:
```bash
brew --version
```

---

## Step 2 — Install Multipass

Multipass runs lightweight Ubuntu VMs on macOS using the native Hypervisor framework.

```bash
brew install multipass
```

Verify:
```bash
multipass version
multipass list
# No instances found.
```

> **Note:** Multipass requires macOS to allow it in System Settings → Privacy & Security. You may see a prompt on first launch.

---

## Step 3 — Install kubectl

```bash
brew install kubectl
```

Verify:
```bash
kubectl version --client
```

---

## Step 4 — Generate an SSH key (if you don't have one)

The VMs are configured via cloud-init which injects your public key at boot. Check if you already have one:

```bash
cat ~/.ssh/id_ed25519.pub
```

If not, generate one:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

> **Why Ed25519?** macOS generates `id_ed25519` by default since Ventura. The Makefile automatically detects `id_ed25519.pub` first, falling back to `id_rsa.pub`.

---

## Step 5 — Clone the repository

```bash
git clone https://github.com/openkubes/ok-local
cd ok-local
```

---


## Step 5 — Configure SSH for Multipass VMs

Add a Multipass entry to `~/.ssh/config` so SSH automatically uses the right key and accepts new hosts:

```bash
cat >> ~/.ssh/config << 'SSHEOF'

# Multipass VMs
Host 192.168.2.*
  IdentityFile ~/.ssh/id_ed25519
  User ubuntu
  StrictHostKeyChecking accept-new
SSHEOF
```

> **Why this is needed:** macOS may have multiple SSH keys and pick the wrong one automatically. This config ensures Multipass VMs always use `id_ed25519` without needing `-i ~/.ssh/id_ed25519` every time.

> **Note:** If Multipass assigns IPs in a different range (e.g. `192.168.64.*` on Apple Silicon), adjust the `Host` line accordingly.

---

## Step 6 — Set up shell aliases

Add these to your `~/.zshrc` (or `~/.bashrc`):

```bash
# Multipass shortcut
alias ml="multipass list"

# openkubes-local kubectl aliases
alias oml="kubectl --kubeconfig ~/path/to/ok-local/.tunnel-mgmt.kubeconfig"
alias oil="kubectl --kubeconfig ~/path/to/ok-local/.tunnel-infra.kubeconfig"
```

Replace `~/path/to/ok-local` with the actual path where you cloned the repo.

Apply:
```bash
source ~/.zshrc
```

---

## Step 7 — Verify everything

```bash
multipass version    # Multipass 1.x.x
kubectl version --client  # Client Version: v1.x.x
cat ~/.ssh/id_ed25519.pub     # ssh-rsa AAAA...
ls ok-local/Makefile      # Makefile exists
```

---

## Architecture overview

```
Mac (Multipass host)
├── ok-mgmt-local  (Multipass VM)
│   ├── K3s — management cluster
│   ├── CAPI, Crossplane, Argo CD  ← Tutorial 3
│   └── SSH tunnel → localhost:6443
│
└── ok-infra-local (Multipass VM)
    ├── K3s — workload cluster (standalone)
    ├── KubeVirt + QEMU software emulation
    └── SSH tunnel → localhost:6444
```

### Why two separate clusters?

This mirrors the production OpenKubes architecture:

| Local | Production | Role |
|---|---|---|
| `ok-mgmt-local` | `ok1, ok2, ok3` (Hetzner) | Management plane |
| `ok-infra-local` | `ok-infra` (Hetzner AX42-U) | VM workload plane |

The management cluster controls the workload cluster — it doesn't run VMs itself.

### Why Multipass?

Multipass gives you real Ubuntu VMs (not containers) with minimal overhead. Each VM gets its own IP, its own kernel, and behaves exactly like a bare metal server — making the local setup a faithful replica of production.

### Why SSH tunnels?

On macOS, Multipass VMs live on a private bridge network (`192.168.x.x`). The K3s API server on port 6443 is not directly reachable from the Mac. SSH tunnels bridge the gap cleanly without requiring any network reconfiguration.

---

## What's next

- **Tutorial 1:** Setting up `ok-mgmt-local` (management cluster)
- **Tutorial 2:** Setting up `ok-infra-local` (workload cluster + KubeVirt)
- **Tutorial 3:** Installing CAPI and Crossplane on the management cluster
