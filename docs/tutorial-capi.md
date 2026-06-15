# Tutorial 3: CAPI on ok-mgmt-local — Managing VMs from the Management Cluster

This tutorial installs **Cluster API (CAPI)** and the **KubeVirt infrastructure provider (CAPK)** on `ok-mgmt-local`. You will then use the management cluster to create and manage a virtual machine running on `ok-infra-local` — demonstrating the core OpenKubes architecture: one cluster manages another.

## What you will build

```
ok-mgmt-local (management cluster)
  └── CAPI + CAPK
        └── manages →  ok-infra-local (workload cluster)
                            └── KubeVirt VM running Ubuntu
```

This mirrors the production setup where the management cluster controls infrastructure on bare metal worker nodes.

## Prerequisites

- Tutorial 1 completed (`ok-mgmt-local` running, tunnel on `localhost:6443`)
- Tutorial 2 completed (`ok-infra-local` running with KubeVirt, tunnel on `localhost:6444`)
- `clusterctl` installed (`brew install clusterctl`)
- `virtctl` installed (`brew install virtctl` or via KubeVirt releases)

Verify:
```bash
clusterctl version   # v1.12+
virtctl version --client
```

---

## Step 1 — Install CAPI on ok-mgmt-local

```bash
oml
```

Initialize CAPI with the KubeVirt infrastructure provider:

```bash
clusterctl init \
  --infrastructure kubevirt \
  --bootstrap kubeadm \
  --control-plane kubeadm
```

This installs:
- `cert-manager` — required by CAPI for webhook certificates
- `cluster-api` — core CAPI controllers
- `bootstrap-kubeadm` — bootstraps K8s nodes
- `control-plane-kubeadm` — manages control plane lifecycle
- `infrastructure-kubevirt` (CAPK) — creates VMs via KubeVirt

Expected output:
```
Installing cert-manager version="v1.20.1"
Installing provider="cluster-api" version="v1.13.2"
Installing provider="bootstrap-kubeadm" version="v1.13.2"
Installing provider="control-plane-kubeadm" version="v1.13.2"
Installing provider="infrastructure-kubevirt" version="v0.11.2"
Your management cluster has been initialized successfully!
```

Verify all pods are running:
```bash
kubectl get pods -A | grep -E "capi|capk|cert"
```

---

## Step 2 — Connect CAPK to ok-infra-local

CAPK needs a kubeconfig to reach `ok-infra-local` directly. We use `infra-local.kubeconfig` which points to the VM's IP — reachable from within the mgmt cluster since both VMs are on the same Multipass network.

> **Important:** Do NOT use `.tunnel-infra.kubeconfig` here. That kubeconfig points to `localhost:6444` — which from inside `ok-mgmt-local` would mean the mgmt VM itself, not the infra VM.

```bash
kubectl create secret generic kubevirt-infra-kubeconfig \
  -n capk-system \
  --from-file=kubeconfig=infra-local.kubeconfig
```

Verify the secret:
```bash
kubectl get secret kubevirt-infra-kubeconfig -n capk-system
```

---

## Step 3 — Deploy a VM on ok-infra-local via kubectl

Now switch to the workload cluster and create a VM directly using KubeVirt:

```bash
oil
```

Create `test-vm.yaml`:

```bash
cat > test-vm.yaml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ok-test-vm
  namespace: default
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 1
        devices:
          disks:
            - name: containerdisk
              disk: {}
          interfaces:
            - name: default
              masquerade: {}
        memory:
          guest: 1Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/containerdisks/ubuntu:22.04
EOF

kubectl apply -f test-vm.yaml
```

Watch the VM start:
```bash
kubectl get vm,vmi -A -w
```

Expected output:
```
NAMESPACE   NAME          AGE   STATUS    READY
default     ok-test-vm    90s   Running   True
```

---

## Step 4 — Understand the difference: direct vs CAPI-managed

You just created a VM directly on `ok-infra-local`. This works but has no lifecycle management — no declarative cluster definition, no machine health checks, no automated remediation.

**With CAPI**, the management cluster owns the VM lifecycle:

| | Direct KubeVirt | CAPI + CAPK |
|---|---|---|
| Who creates the VM | You (kubectl on infra) | CAPI controller on mgmt |
| VM definition lives in | ok-infra-local | ok-mgmt-local |
| Health monitoring | Manual | Automatic via MachineHealthCheck |
| Scaling | Manual | MachineDeployment replicas |
| Production use | Dev/test | Production |

For a full CAPI-managed workload cluster see the notes at the end of this tutorial.

---

## Step 5 — Verify from both clusters

```bash
# From management cluster — see CAPI components
oml
kubectl get pods -A | grep -E "capi|capk"
kubectl get ns | grep -E "capi|capk|cert"

# From workload cluster — see the running VM
oil
kubectl get vm,vmi -A
```

---

## Step 6 — Connect to the VM console

```bash
oil
# Get the VM IP
kubectl get vmi ok-test-vm -o jsonpath='{.status.interfaces[0].ipAddress}'

# Connect via virtctl (run on ok-infra-local)
ssh ubuntu@<INFRA_IP> "virtctl console ok-test-vm"
```

Press `Enter` to trigger the login prompt.

To exit the console:

| Keyboard layout | Shortcut |
|---|---|
| US | `Ctrl + ]` |
| German (Mac) | `Ctrl + Option + 6` |

---

## Cleanup

```bash
# Delete the test VM
oil
kubectl delete vm ok-test-vm

# Remove CAPI from mgmt (optional — keep for Tutorial 4)
oml
clusterctl delete --all
```

---

## Notes: Full CAPI workload cluster (advanced)

To create a full Kubernetes cluster managed by CAPI on `ok-infra-local`, the following is needed beyond this tutorial:

1. A container disk image with the target Kubernetes version pre-installed — use `quay.io/capk/ubuntu-2404-container-disk:v1.32.1` (not `v1.31.0` which no longer exists)
2. Enough RAM on `ok-infra-local` — each VM needs ~2Gi, plan for control-plane + workers
3. A CNI (Calico or Flannel) installed after the cluster bootstraps
4. The `infraClusterSecretRef` patch on the `KubevirtCluster` resource pointing to the `kubevirt-infra-kubeconfig` secret

A full working example will be covered in Tutorial 4.

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


**`'kubeconfig' key is missing` in CAPK logs**
The secret was created with key `value` instead of `kubeconfig`. Recreate:
```bash
kubectl create secret generic kubevirt-infra-kubeconfig \
  -n capk-system \
  --from-file=kubeconfig=infra-local.kubeconfig \
  --dry-run=client -o yaml | kubectl apply -f -
```

**`no matches for kind "VirtualMachineInstance"` in CAPK logs**
CAPK cannot reach `ok-infra-local`. Check:
```bash
# Test connectivity from mgmt to infra IP
INFRA_IP=$(cat infra-local.kubeconfig | grep server | awk -F'/' '{print $3}' | cut -d: -f1)
ssh ubuntu@<MGMT_IP> "curl -sk https://${INFRA_IP}:6443/healthz"
```

**VM stuck in `ImagePullBackOff`**
The container disk image tag does not exist. Use a verified tag:
```bash
# Working image for Ubuntu 22.04
image: quay.io/containerdisks/ubuntu:22.04

# Working CAPK image for K8s v1.32.1
image: quay.io/capk/ubuntu-2404-container-disk:v1.32.1
```

---

## Quick reference

| Command | What it does |
|---|---|
| `clusterctl init --infrastructure kubevirt` | Install CAPI + CAPK on mgmt |
| `clusterctl version` | Show installed provider versions |
| `kubectl get pods -n capk-system` | Show CAPK controller status |
| `kubectl logs -n capk-system -l control-plane=controller-manager` | CAPK controller logs |
| `kubectl get vm,vmi -A` | Show all VMs on current cluster |
| `clusterctl delete --all` | Remove all CAPI providers |
