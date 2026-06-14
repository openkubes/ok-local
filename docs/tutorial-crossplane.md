# Tutorial 4: Crossplane on ok-mgmt-local — Infrastructure as Kubernetes Resources

This tutorial installs **Crossplane** on `ok-mgmt-local` with two providers:
- `provider-kubernetes` — manage Kubernetes resources on remote clusters
- `provider-helm` — deploy Helm charts on remote clusters

You will use `ok-mgmt-local` to create a Namespace and deploy a Helm release on `ok-infra-local` — without ever running `kubectl` directly against the infra cluster.

## What you will build

```
ok-mgmt-local (Crossplane)
  ├── provider-kubernetes → ok-infra-local
  │     └── creates Namespace: ok-crossplane-test
  └── provider-helm → ok-infra-local
        └── deploys Helm release: podinfo
```

This is the core Crossplane pattern: **infrastructure as Kubernetes resources**, managed declaratively from the management cluster.

## Prerequisites

- Tutorial 1 completed (`ok-mgmt-local` running)
- Tutorial 2 completed (`ok-infra-local` running with KubeVirt)
- `helm` installed (`brew install helm`)

---

## Step 1 — Install Crossplane

```bash
oml
```

Add the Crossplane Helm repo and install:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane \
  crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --wait
```

Verify:
```bash
kubectl get pods -n crossplane-system
# NAME                                      READY   STATUS    RESTARTS   AGE
# crossplane-68fd767f68-kmx7q               1/1     Running   0          30s
# crossplane-rbac-manager-cd9d9cb67-r26vd   1/1     Running   0          30s
```

---

## Step 2 — Install providers

Install `provider-kubernetes` and `provider-helm`:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1
EOF

cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v1.2.0
EOF
```

Wait until both are healthy (1-3 minutes while images are pulled):

```bash
kubectl get providers.pkg.crossplane.io -w
# NAME                  INSTALLED   HEALTHY
# provider-kubernetes   True        True
# provider-helm         True        True
```

> **Note:** Use `xpkg.upbound.io` for both providers — not `xpkg.crossplane.io`. The registry paths differ between providers and versions.

---

## Step 3 — Connect providers to ok-infra-local

Both providers need a kubeconfig to reach `ok-infra-local`. We use `infra-local.kubeconfig` which points directly to the VM's IP — reachable from within the mgmt cluster since both VMs are on the same Multipass network.

> **Important:** Do NOT use `.tunnel-infra.kubeconfig` here. That points to `localhost:6444` which from inside `ok-mgmt-local` would mean the VM itself, not `ok-infra-local`.

```bash
# Shared secret for both providers
kubectl create secret generic infra-kubeconfig \
  -n crossplane-system \
  --from-file=kubeconfig=infra-local.kubeconfig

# ProviderConfig for provider-kubernetes
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: ok-infra-local
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: infra-kubeconfig
      key: kubeconfig
EOF

# ProviderConfig for provider-helm
cat <<EOF | kubectl apply -f -
apiVersion: helm.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: ok-infra-local
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: infra-kubeconfig
      key: kubeconfig
EOF
```

---

## Step 4 — Create a Namespace on ok-infra-local

Use `provider-kubernetes` to create a Namespace on the infra cluster — from the mgmt cluster:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha2
kind: Object
metadata:
  name: ok-test-namespace
spec:
  providerConfigRef:
    name: ok-infra-local
  forProvider:
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: ok-crossplane-test
EOF
```

Verify it was created:

```bash
# On mgmt — Object status
kubectl get object ok-test-namespace
# NAME                KIND        PROVIDERCONFIG   SYNCED   READY
# ok-test-namespace   Namespace   ok-infra-local   True     True

# On infra — Namespace exists
oil
kubectl get ns ok-crossplane-test
# NAME                 STATUS   AGE
# ok-crossplane-test   Active   10s
```

---

## Step 5 — Deploy a Helm release on ok-infra-local

Use `provider-helm` to deploy `podinfo` on the infra cluster:

```bash
oml

cat <<EOF | kubectl apply -f -
apiVersion: helm.crossplane.io/v1beta1
kind: Release
metadata:
  name: podinfo
spec:
  providerConfigRef:
    name: ok-infra-local
  forProvider:
    chart:
      name: podinfo
      repository: https://stefanprodan.github.io/podinfo
      version: "6.7.1"
    namespace: default
    values:
      replicaCount: 1
EOF
```

Watch the release deploy:

```bash
kubectl get release.helm.crossplane.io -w
# NAME      NAMESPACE   CHART     VERSION   SYNCED   READY   STATE      REVISION   DESCRIPTION
# podinfo   default     podinfo   6.7.1     True     True    deployed   1          Install complete
```

Verify on infra:

```bash
oil
kubectl get pods -n default | grep podinfo
# podinfo-b9b97b99f-xxxxx   1/1   Running   0   30s

kubectl get svc -n default | grep podinfo
# podinfo   ClusterIP   10.43.x.x   <none>   9898/TCP,9999/TCP   30s
```

---

## What just happened

You managed infrastructure on `ok-infra-local` entirely from `ok-mgmt-local` — no direct `kubectl` access to the infra cluster needed:

| Resource | Created by | Lives on |
|---|---|---|
| `ok-crossplane-test` Namespace | `Object` on mgmt | `ok-infra-local` |
| `podinfo` Helm release | `Release` on mgmt | `ok-infra-local` |

This is the Crossplane model: **your management cluster is the source of truth** for everything running on workload clusters.

---

## Cleanup

```bash
oml
kubectl delete release.helm.crossplane.io podinfo
kubectl delete object ok-test-namespace

# Remove providers (optional)
kubectl delete provider.pkg.crossplane.io provider-helm provider-kubernetes
kubectl delete secret infra-kubeconfig -n crossplane-system

# Uninstall Crossplane (optional)
helm uninstall crossplane -n crossplane-system
```

---

## Troubleshooting

**Provider stuck in `HEALTHY: False`**
Check the package image tag — not all versions exist on all registries:
```bash
kubectl describe providers.pkg.crossplane.io provider-helm | grep Message
```
Use verified versions:
- `provider-kubernetes`: `xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1`
- `provider-helm`: `xpkg.upbound.io/crossplane-contrib/provider-helm:v1.2.0`

**Release fails with `ServiceAccount exists`**
K3s pre-installs `metrics-server` — Helm cannot take ownership of existing resources. Use a different app (e.g. `podinfo`) or add `--force` to the Helm values.

**Object/Release stuck in `SYNCED: False`**
Check if `ok-infra-local` is reachable from `ok-mgmt-local`:
```bash
INFRA_IP=$(grep server infra-local.kubeconfig | awk -F/ '{print $3}' | cut -d: -f1)
ssh ubuntu@$(grep server mgmt-local.kubeconfig | awk -F/ '{print $3}' | cut -d: -f1) \
  "curl -sk https://${INFRA_IP}:6443/healthz"
# ok
```

---

## Quick reference

| Command | What it does |
|---|---|
| `kubectl get providers.pkg.crossplane.io` | Show installed Crossplane providers |
| `kubectl get object` | Show all managed Kubernetes objects |
| `kubectl get release.helm.crossplane.io` | Show all managed Helm releases |
| `kubectl describe object <name>` | Debug sync issues |
| `kubectl describe release <name>` | Debug Helm release issues |
| `helm list -n crossplane-system` | Show Crossplane Helm installation |
