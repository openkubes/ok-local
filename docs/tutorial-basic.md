# KubeVirt on macOS with Multipass

This tutorial shows you how to run virtual machines inside Kubernetes on your Mac — no cloud account, no bare metal server required. We use **Multipass** to create a lightweight Ubuntu VM, install **K3s** (a minimal Kubernetes distribution), and then run **KubeVirt** to launch a VM inside that cluster.

By the end you will have a real Ubuntu VM running inside Kubernetes on your Mac, accessible via console.

---

## How it works

```
Your Mac
└── Multipass VM (Ubuntu 24.04, 4 CPUs, 8GB RAM)
    └── K3s (Kubernetes)
        └── KubeVirt
            └── Ubuntu VM ← a virtual machine running inside Kubernetes
```

KubeVirt extends Kubernetes with a `VirtualMachine` resource type. Instead of running containers, it runs full VMs — managed by Kubernetes like any other workload.

On macOS, Multipass VMs do not expose `/dev/kvm`, so KubeVirt runs in **software emulation mode** (QEMU without hardware acceleration). This is slower than bare metal but works perfectly for learning and testing.

---

## Prerequisites

- macOS 12 or later — **Intel Mac recommended** (see Apple Silicon note below)
- [Multipass](https://multipass.run/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/) installed
- SSH key at `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`)

Install with Homebrew:

```bash
brew install multipass kubectl
```

> **⚠️ Apple Silicon (M1/M2/M3) Note:** KubeVirt with software emulation (`useEmulation=true`) does not currently work on Apple Silicon Multipass VMs. The QEMU `host-passthrough` CPU mode is not supported on aarch64. This is a [known KubeVirt limitation](https://github.com/kubevirt/kubevirt/issues/11917). This tutorial is tested and supported on **Intel Mac only**. Apple Silicon support is tracked and will be updated when a workaround is available.

---

## Step 1 — Launch a Multipass VM

First generate a cloud-init file that injects your SSH key into the VM at boot:

```bash
cat > /tmp/cloud-init.yaml << EOF
package_update: true
package_upgrade: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)
EOF
```

Launch the VM:

```bash
multipass launch 24.04 \
  --name kubevirt-local \
  --cpus 4 \
  --memory 8G \
  --disk 40G \
  --cloud-init /tmp/cloud-init.yaml
```

Get the VM IP and accept the SSH host key:

```bash
export VM_IP=$(multipass list --format csv | grep kubevirt-local | cut -d',' -f3 | tr -d ' ')
echo "VM IP: $VM_IP"

ssh-keyscan $VM_IP >> ~/.ssh/known_hosts
```

---

## Step 2 — Install K3s

SSH into the VM:

```bash
ssh ubuntu@$VM_IP
```

Inside the VM, install K3s. We disable Traefik (not needed here) and set `--tls-san` so the TLS certificate is valid for the VM's IP — required for kubectl access from the Mac:

```bash
export VM_IP=$(hostname -I | awk '{print $1}')

curl -sfL https://get.k3s.io | sh -s - \
  --disable=traefik \
  --tls-san=${VM_IP}
```

Wait ~30 seconds, then verify the node is ready:

```bash
sudo k3s kubectl get nodes
# NAME             STATUS   ROLES           AGE   VERSION
# kubevirt-local   Ready    control-plane   ...   v1.35.x
```

Exit back to your Mac:

```bash
exit
```

---

## Step 3 — Connect kubectl from your Mac

Fetch the kubeconfig and replace `127.0.0.1` with the VM IP:

```bash
ssh ubuntu@$VM_IP "sudo cat /etc/rancher/k3s/k3s.yaml" | \
  sed "s/127\.0\.0\.1/$VM_IP/" > kubevirt-local.kubeconfig
```

Start an SSH tunnel so kubectl can reach port 6443:

```bash
ssh -L 6443:127.0.0.1:6443 ubuntu@$VM_IP -N -f
```

Create a tunnel kubeconfig pointing to localhost:

```bash
cat kubevirt-local.kubeconfig | sed "s/$VM_IP/127.0.0.1/" > .tunnel.kubeconfig
export KUBECONFIG=$(pwd)/.tunnel.kubeconfig
```

Verify:

```bash
kubectl get nodes
# NAME             STATUS   ROLES           AGE   VERSION
# kubevirt-local   Ready    control-plane   ...   v1.35.x
```

> **Why a tunnel?** On macOS, Multipass VMs are on a private bridge network. Port 6443 on the VM is not directly reachable from your Mac — the SSH tunnel bridges the gap cleanly.

---

## Step 4 — Install KubeVirt

Get the latest stable version and apply the operator and CR:

```bash
export KUBEVIRT_VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
echo "Installing KubeVirt $KUBEVIRT_VERSION"

kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
```

Wait until KubeVirt is fully deployed (1–3 minutes):

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Deployed \
  kubevirt/kubevirt -n kubevirt --timeout=300s
```

---

## Step 5 — Enable software emulation

Multipass VMs do not provide `/dev/kvm`. Tell KubeVirt to use QEMU software emulation instead.

First detect your Mac architecture:

```bash
MAC_ARCH=$(ssh ubuntu@$VM_IP "uname -m")
echo "VM architecture: $MAC_ARCH"
```

Then apply the correct emulation config:

```bash
# For Intel Mac (x86_64)
if [ "$MAC_ARCH" = "x86_64" ]; then
  kubectl patch kubevirt kubevirt -n kubevirt \
    --type merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
fi

# For Apple Silicon (aarch64) — needs explicit CPU config
if [ "$MAC_ARCH" = "aarch64" ]; then
  kubectl patch kubevirt kubevirt -n kubevirt \
    --type merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true},"emulatedMachines":["virt*"]}}}'
fi
```

Verify:

```bash
kubectl get kubevirt kubevirt -n kubevirt \
  -o jsonpath='{.spec.configuration.developerConfiguration}'
# {"useEmulation":true}
```

---

## Step 6 — Install virtctl

`virtctl` is the KubeVirt CLI for starting, stopping, and connecting to VMs. The binary is architecture-specific — this step detects Intel (amd64) or Apple Silicon (arm64) automatically:

```bash
# Detect VM architecture
ARCH=$(ssh ubuntu@$VM_IP "uname -m")
if [ "$ARCH" = "aarch64" ]; then
  VIRTCTL_ARCH=arm64
else
  VIRTCTL_ARCH=amd64
fi

# Install virtctl on the VM
ssh ubuntu@$VM_IP "
  curl -LO https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${VIRTCTL_ARCH}
  sudo install virtctl-${KUBEVIRT_VERSION}-linux-${VIRTCTL_ARCH} /usr/local/bin/virtctl
  sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml virtctl version
"
```

---

## Step 7 — Deploy a VM inside Kubernetes

Create a `VirtualMachine` manifest using an official Ubuntu 22.04 container disk image:

```bash
cat > vm-ubuntu.yaml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu-vm
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: ubuntu-vm
    spec:
      domain:
        cpu:
          model: host-model
        devices:
          disks:
            - name: containerdisk
              disk: {}
            - name: cloudinitdisk
              disk: {}
          interfaces:
            - name: default
              masquerade: {}
        memory:
          guest: 1500Mi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/containerdisks/ubuntu:22.04
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: linux
              chpasswd: { expire: False }
              ssh_pwauth: True
EOF

kubectl apply -f vm-ubuntu.yaml
```

Watch the VM start (takes 1–3 minutes while the image is pulled):

```bash
kubectl get vm -w
# NAME        AGE   STATUS    READY
# ubuntu-vm   ...   Running   True
```

---

## Step 8 — Connect to the VM console

```bash
ssh ubuntu@$VM_IP "virtctl console ubuntu-vm"
```

Press `Enter` a few times to trigger the login prompt.

**Credentials:**
- Username: `ubuntu`
- Password: `linux`

You are now inside a virtual machine running inside Kubernetes on your Mac.

To exit the console:

| Keyboard layout | Shortcut |
|---|---|
| US | `Ctrl + ]` |
| German (Mac) | `Ctrl + Option + 6` |

---

## Useful commands

```bash
# VM status
kubectl get vm
kubectl get vmi

# Stop / start the VM
ssh ubuntu@$VM_IP "virtctl stop ubuntu-vm"
ssh ubuntu@$VM_IP "virtctl start ubuntu-vm"

# Delete the VM
kubectl delete vm ubuntu-vm

# KubeVirt pods
kubectl get pods -n kubevirt

# Restart SSH tunnel if lost after Mac sleep
pkill -f "ssh -L 6443"
ssh -L 6443:127.0.0.1:6443 ubuntu@$VM_IP -N -f
```

---

## Clean up

```bash
# Delete the VM
kubectl delete vm ubuntu-vm

# Stop the tunnel
pkill -f "ssh -L 6443"

# Delete the Multipass VM
multipass delete --purge kubevirt-local

# Remove generated files
rm kubevirt-local.kubeconfig .tunnel.kubeconfig vm-ubuntu.yaml /tmp/cloud-init.yaml
```

---

## What's next

This tutorial runs KubeVirt on a single node. For a more complete local setup that mirrors a production Kubernetes infrastructure — with separate management and workload clusters, Cluster API, Crossplane, and Argo CD — see the **OpenKubes** project:

👉 [github.com/openkubes](https://github.com/openkubes)

OpenKubes provides a fully automated local dev environment (`ok-local`) and a production-ready stack on Hetzner bare metal (`ok-rke2`).

---

## Troubleshooting

**`multipass shell` fails with `No route to host`**
This is a known bug in Multipass on recent macOS versions — the internal Multipass SSH key stops working. Use direct SSH instead:
```bash
# Instead of: multipass shell kubevirt-local
ssh ubuntu@<VM_IP>
```
All tutorials in this repo use direct SSH — `multipass shell` is never required.

**`Permission denied (publickey)` when SSH-ing**
macOS may pick the wrong SSH key. Fix by adding to `~/.ssh/config`:
```bash
cat >> ~/.ssh/config << 'EOF'

# Multipass VMs
Host 192.168.2.*
  IdentityFile ~/.ssh/id_ed25519
  User ubuntu
  StrictHostKeyChecking accept-new
EOF
```
Or explicitly specify the key: `ssh -i ~/.ssh/id_ed25519 ubuntu@<VM_IP>`
