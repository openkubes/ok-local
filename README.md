# ok-local — OpenKubes Local Dev Environment

Local development environment for [OpenKubes](https://github.com/openkubes) — two separate K3s clusters running in Multipass VMs on your Mac, simulating the production architecture with KubeVirt for VM workloads.

```
Mac (Multipass host)
├── ok-mgmt-local  — Management cluster (CAPI, Crossplane, Argo CD)
└── ok-infra-local — Workload cluster   (KubeVirt, CDI)
```

---

## Quick Start

```bash
# Prerequisites: Multipass + kubectl installed (see docs/tutorial-prerequisites.md)
git clone https://github.com/openkubes/ok-local
cd ok-local

# Launch both VMs, install K3s on each, install KubeVirt — all in one command
make setup
```

After ~10 minutes:

```bash
# Set aliases in ~/.zshrc
alias oml="export KUBECONFIG=$(pwd)/.tunnel-mgmt.kubeconfig"
alias oil="export KUBECONFIG=$(pwd)/.tunnel-infra.kubeconfig"

oml && kubectl get nodes   # ok-mgmt-local  Ready
oil && kubectl get nodes   # ok-infra-local Ready
```

---

## Architecture

```
Mac (Multipass host)
├── ok-mgmt-local  (192.168.x.x)          localhost:6443
│   └── K3s v1.35 — management cluster
│       ├── CAPI       (Tutorial 3, coming soon)
│       ├── Crossplane (Tutorial 3, coming soon)
│       └── Argo CD    (Tutorial 3, coming soon)
│
└── ok-infra-local (192.168.x.y)          localhost:6444
    └── K3s v1.35 — workload cluster
        └── KubeVirt v1.8 + QEMU software emulation
```

### Local → Production mapping

| Local | Production | Role |
|---|---|---|
| `ok-mgmt-local` | `ok1, ok2, ok3` (Hetzner) | Management plane |
| `ok-infra-local` | `ok-infra` (Hetzner AX42-U) | VM workload plane |
| `ok-gpu-local` *(future)* | `ok-gpu` (Hetzner GEX44) | GPU node |

---

## Tutorials

| Tutorial | Description |
|---|---|
| [Tutorial 0 — Prerequisites](docs/tutorial-prerequisites.md) | Install Multipass, kubectl, set up SSH key and aliases |
| [Tutorial 1 — Management Cluster](docs/tutorial-mgmt.md) | Launch `ok-mgmt-local`, install K3s, configure kubectl access |
| [Tutorial 2 — Workload Cluster](docs/tutorial-infra.md) | Launch `ok-infra-local`, install K3s + KubeVirt |
| [KubeVirt on macOS (standalone)](docs/tutorial-basic.md) | Run a VM inside Kubernetes on your Mac — no OpenKubes required |

---

## Makefile reference

```bash
make setup          # Full setup: both VMs + K3s + KubeVirt
make clean          # Delete everything and start fresh

make up-mgmt        # Launch ok-mgmt-local VM
make up-infra       # Launch ok-infra-local VM
make install-k3s-mgmt   # Install K3s on management cluster
make install-k3s-infra  # Install K3s on workload cluster
make install-kubevirt   # Install KubeVirt on workload cluster

make nodes-mgmt     # Show nodes in management cluster
make nodes-infra    # Show nodes in workload cluster
make nodes-all      # Show nodes in both clusters

make tunnel         # Start SSH tunnel for mgmt  (localhost:6443)
make tunnel-infra   # Start SSH tunnel for infra (localhost:6444)
make tunnels        # Start both tunnels

make ssh-mgmt       # SSH into ok-mgmt-local
make ssh-infra      # SSH into ok-infra-local
make status         # Show all Multipass VMs
make help           # Show all available targets
```

---

## Related

- [openkubes/ok-rke2](https://github.com/openkubes/ok-rke2) — Production stack on Hetzner bare metal
- [openkubes/ok-linux](https://github.com/openkubes/ok-linux) — Linux node configuration
- [KubeVirt documentation](https://kubevirt.io/user-guide/)
- [K3s documentation](https://docs.k3s.io/)
