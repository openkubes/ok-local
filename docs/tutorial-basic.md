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

> **⚠️ Apple Silicon (M1/M2/M3) Note:** KubeVirt's admission webhook only allows `host-passthrough` on ARM64 — but QEMU emulation does not support it. The workaround is to set `cpu.model: max` in the VM manifest (see Step 7). This is a [known KubeVirt limitation](https://github.com/kubevirt/kubevirt/issues/11917).

---

## Step 1 — Launch a Multipass VM

This is a **disposable local development VM**, not a production setup. Run these steps in the same macOS terminal, with Multipass and Python 3 installed. Each fenced block defines and runs a shell function: errors return from that function instead of terminating your interactive shell. If you see a STOP message, **do not execute the next block**. Ensure your Mac has sufficient memory and disk space.

First check that you have a matching SSH key pair and generate cloud-init in a private temporary directory. Stop if the key check fails:

```bash
ok_step1_cloud_init() {
if [ -f "$HOME/.ssh/id_ed25519.pub" ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
  SSH_PUB="$HOME/.ssh/id_ed25519.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ] && [ -f "$HOME/.ssh/id_rsa" ]; then
  SSH_PUB="$HOME/.ssh/id_rsa.pub"
else
  echo 'Generate an SSH key pair first.' >&2; return 1
fi
ssh-keygen -lf "$SSH_PUB" >/dev/null || return 1
CLOUD_INIT_DIR="$(mktemp -d)" || return 1
CLOUD_INIT_FILE="$CLOUD_INIT_DIR/cloud-init.yaml"
cat > "$CLOUD_INIT_FILE" <<EOF
package_update: true
package_upgrade: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$SSH_PUB")
EOF
[ -s "$CLOUD_INIT_FILE" ] || return 1
chmod 600 "$CLOUD_INIT_FILE" || return 1
}
ok_step1_cloud_init || printf '%s\n' 'Step 1 block failed. STOP: resolve the issue before continuing.' >&2
```

**Security note:** `NOPASSWD:ALL` grants passwordless sudo *inside this development VM*. Do not use this convenience in production. Cloud-init contains the public, never the private, SSH key.

Launch only if the named instance does not already exist; inspect existing VMs manually instead of overwriting them:

```bash
ok_step1_launch() {
if multipass info kubevirt-local >/dev/null 2>&1; then
  echo 'kubevirt-local already exists. Stop and inspect it.' >&2; return 1
fi
multipass launch 24.04 \
  --name kubevirt-local \
  --cpus 4 \
  --memory 8G \
  --disk 40G \
  --cloud-init "$CLOUD_INIT_FILE" || return 1
}
ok_step1_launch || printf '%s\n' 'Step 1 block failed. STOP: resolve the issue before continuing.' >&2
```

Confirm the VM is running with `multipass info kubevirt-local` before continuing. Remove the temporary cloud-init directory only after successful provisioning and inspection.

Get the VM address from its structured Multipass instance data instead of searching a CSV table:

```bash
ok_step1_address() {
VM_IP="$(multipass info kubevirt-local --format json | python3 -c '
import ipaddress, json, sys
ips = json.load(sys.stdin)["info"]["kubevirt-local"]["ipv4"]
valid = [ip for ip in ips if ipaddress.ip_address(ip).version == 4
         and not ipaddress.ip_address(ip).is_loopback]
if len(valid) != 1: raise SystemExit("Expected exactly one IPv4 address")
print(valid[0])
')" || return 1
[ -n "$VM_IP" ] || return 1
echo "VM IP: $VM_IP"
}
ok_step1_address || printf '%s\n' 'Step 1 block failed. STOP: resolve the issue before continuing.' >&2
```

**Do not blindly trust `ssh-keyscan`.** Compare the key seen over the network against the host key obtained through the trusted local Multipass control channel, then add it only if no entry for that IP already exists:

```bash
ok_step1_host_key() {
EXPECTED="$(multipass exec kubevirt-local -- sudo cat /etc/ssh/ssh_host_ed25519_key.pub)" || return 1
SCANNED="$(ssh-keyscan -T 5 -t ed25519 "$VM_IP" 2>/dev/null)" || return 1
EXPECTED_KEY="$(printf '%s\n' "$EXPECTED" | awk 'NR==1 {print $1 " " $2}')"
SCANNED_KEY="$(printf '%s\n' "$SCANNED" | awk 'NR==1 {print $2 " " $3}')"
if [ -z "$EXPECTED_KEY" ] || [ "$EXPECTED_KEY" != "$SCANNED_KEY" ]; then
  echo 'SSH host key mismatch: investigate before proceeding.' >&2; return 1
fi
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"; chmod 600 "$HOME/.ssh/known_hosts"
if ssh-keygen -F "$VM_IP" -f "$HOME/.ssh/known_hosts" >/dev/null; then
  echo 'Existing known_hosts entry: verify manually; do not overwrite.' >&2; return 1
fi
printf '%s\n' "$SCANNED" >> "$HOME/.ssh/known_hosts" || return 1
}
ok_step1_host_key || printf '%s\n' 'Step 1 block failed. STOP: resolve the issue before continuing.' >&2
```

This check assumes the local Multipass management channel and VM are trusted; it is not a production host-identity policy.

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

Create a `VirtualMachine` manifest using an official Ubuntu 22.04 container disk image.

> **Apple Silicon users:** Change `cpu.model` from `host-model` to `max` (see comment in the manifest).

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
          model: host-model   # Intel: use host-model / Apple Silicon: use max
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
