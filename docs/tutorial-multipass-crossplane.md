# Tutorial: Deploy OpenRMF on Multipass through Crossplane

This tutorial uses the `ok-local` Makefile and continues the management/infra
cluster workflow from Tutorials 1, 2, and 4. It documents the OpenRMF-specific
values, ingress, Crossplane Release, validation, and cleanup steps.

The resulting test has two Multipass VMs:

```text
workstation
  |-- 127.0.0.1:6443 --> ok-mgmt-local  (K3s + Crossplane)
  |                         |
  |                         `-- provider-kubernetes/provider-helm
  |                                   |
  |                                   v
  `-- 127.0.0.1:6444 --> ok-infra-local (K3s + Traefik + OpenRMF)
```

RKE2 is not required. The repository uses K3s to provide the two
Kubernetes clusters. Crossplane runs only on `ok-mgmt-local`; OpenRMF runs only
on `ok-infra-local`.

A compact preflight was also validated on WSL2 with Docker Desktop Kubernetes
using 2 CPUs and 4 GiB RAM. Crossplane, both providers, Traefik, the OpenRMF web
stack, and `rmf-sim` all scheduled and started on that node. This proves that
24 GiB RAM is not an OpenRMF hard minimum. The compact test uses one Kubernetes
cluster as both the management and target cluster, however, so it does not
replace the final two-VM test of Multipass networking, kubeconfig transfer,
and SSH tunnels or establish a recommended steady-state allocation.

## 1. Important behavior of the repository Makefile

Read these points before running it:

- Run commands from the cloned `ok-local` repository root.
- The Makefile's `setup` target also installs KubeVirt on infra. KubeVirt is
  not required for OpenRMF; use the individual VM and K3s targets below for a
  smaller test environment.
- The Makefile disables packaged Traefik on both clusters. This guide installs
  Traefik separately on the infra cluster because the OpenRMF chart requires
  its `IngressRoute` and `Middleware` CRDs.
- Tutorial 4's Crossplane example deploys `podinfo`; it does not deploy
  OpenRMF. This guide adds the OpenRMF `Release` after the example succeeds.
- Generated kubeconfigs contain administrator credentials and are ignored by
  this repository. Do not commit or share them.

## 2. What must be supplied or changed

The VM defaults are near the top of `Makefile`. Supply chart values through
the gitignored generated overlay described in section 5.

| Value | Where it is set | Required test value | Reason |
|---|---|---|---|
| `MGMT_VM` | Makefile default | `ok-mgmt-local` | Hosts Crossplane. |
| `INFRA_VM` | Makefile default | `ok-infra-local` | Hosts OpenRMF and ingress. |
| `CPUS`, `MEMORY`, `DISK` | Makefile defaults, per VM | `4`, `8G`, `40G` | Start with the repository values; increase only after an observed resource failure. |
| `K3S_VERSION` | Makefile default | `v1.35.5+k3s1` | Keep the repository's tested version unless the owner approves an upgrade. |
| Traefik chart | This guide | `40.2.0` | Supplies ingress because packaged Traefik is disabled. |
| Crossplane providers | Tutorial 4 | Kubernetes `v0.14.1`, Helm `v1.2.0` | Keep Tutorial 4's versions for this test. |
| Helm ProviderConfig | Tutorial 4 | `ok-infra-local` | Makes the provider on management deploy into infra. |
| OpenRMF chart | Crossplane `Release` below | `1.0.0` release asset | Crossplane cannot read a chart directory from the workstation. |
| `hostName` | Local RMF values overlay | `rmf.test` | Local hostname for Traefik routes. |
| `baseUrl` | Local RMF values overlay | `https://rmf.test` | Browser, Keycloak, dashboard, and API redirects must agree. |
| Four passwords | Local RMF values overlay | Four distinct generated values | Empty credentials are rejected during Helm rendering. |
| Workstation hosts entry | `/etc/hosts` | `<INFRA_VM_IP> rmf.test` | Traffic goes to infra, not to the management VM. |

## 3. Workstation prerequisites

The repository is macOS-oriented and expects Make, Multipass, `kubectl`, Helm,
Git, SSH, curl, and OpenSSL:

```bash
brew install --cask multipass
brew install kubectl helm openssl
```

With its defaults, the Makefile allocates the following logical VM capacity:

- 8 virtual CPUs in total;
- 16 GiB VM RAM in total;
- 80 GiB virtual disk in total.

These are allocations, not a statement that OpenRMF itself consumes those
resources. Virtual CPUs need not be dedicated physical cores, and Multipass
disks are normally thin-provisioned. In the validated WSL + Docker preflight,
all application pods, including `rmf-sim`, scheduled and started on a single
2-CPU/4-GiB node. Start with the repository defaults for the two-VM handoff
and increase them only if the actual run shows scheduling, OOM, or
disk-pressure failures.

The Makefile expects a usable `~/.ssh/id_ed25519.pub` or
`~/.ssh/id_rsa.pub`. Create one before starting if neither exists.

## 4. Architecture preflight

Run:

```bash
uname -m
```

Continue only when the host can create an `amd64` Multipass guest. On an Intel
Mac, the result is normally `x86_64`. On Apple Silicon, it is normally `arm64`,
and Multipass normally launches an ARM64 Ubuntu guest.

This is an OpenRMF image limitation, not a K3s or Crossplane limitation. As of
2026-07-21, every custom application image referenced by the chart publishes a
single `linux/amd64` manifest and no `linux/arm64` variant:

- `rmf-deployment/rmf`
- `rmf-deployment/rmf-site`
- `rmf-deployment/rmf-sim`
- `rmf-deployment/dashboard`
- `rmf-deployment/keycloak-setup`
- `rmf-deployment/api-server-metrics`

An ARM64 node therefore cannot select a compatible image. Depending on the
container runtime, the pull or container start fails; a forced pull commonly
ends with `exec format error` because an ARM64 Linux kernel cannot execute the
x86-64 binaries. Multipass does not automatically add x86 emulation inside the
guest.

Use an x86-64 workstation/VM for this test, or first build and publish ARM64 or
multi-architecture variants of all six images. Emulation is not part of this
smoke-test procedure.

### Validated WSL + Docker preflight

The following compact environment was exercised on 2026-07-21 before the
Multipass handoff:

The tested automation and manifests are preserved in
[`reference/docker-desktop-crossplane`](../reference/docker-desktop-crossplane/README.md).

| Item | Validated value |
|---|---|
| Host | WSL2 `linux/amd64` |
| Kubernetes | Docker Desktop `v1.32.2` |
| Docker allocation | 2 CPUs, approximately 4 GiB RAM |
| Crossplane | `2.3.3` (the unpinned Makefile install resolved to this version on the test date) |
| provider-kubernetes | `v0.14.1` |
| provider-helm | `v1.2.0` |
| Traefik | Helm chart `40.2.0` |
| OpenRMF chart | `1.0.0` |

The Docker Desktop kubeconfig was stored in the management cluster as a Secret
and used by ProviderConfigs, matching Tutorial 4's credential flow. The
namespace and `podinfo` checks reconciled as `Synced=True, Ready=True`. The
dashboard and Keycloak HTTPS routes were reached successfully; the API route
reached Uvicorn; both PVCs bound; and `rmf-sim` scheduled and started on the
same node. The 2-CPU profile is a compact compatibility check, not the
recommended allocation for a stable demonstration.

This is a useful low-cost check for chart rendering, package compatibility,
Crossplane `valuesFrom`, image architecture, storage, and application startup.
It does not prove that one Multipass VM can reach the other VM's Kubernetes API.

## 5. Create the local OpenRMF values overlay

From the repository root, generate this ignored file:

```text
reference/docker-desktop-crossplane/.state/rmf-values.yaml
```

The helper creates four independent passwords and fills the tested template:

```bash
./reference/docker-desktop-crossplane/scripts/generate-values.sh true
export RMF_VALUES_FILE="$PWD/reference/docker-desktop-crossplane/.state/rmf-values.yaml"
```

The generated content is equivalent to the following (passwords are filled
automatically):

```yaml
hostName: rmf.test
baseUrl: https://rmf.test

ENABLE_RMF_SIM: true
ENABLE_RMF: false

ingress:
  provider: traefik
  className: traefik

tls:
  enabled: true
  useTraefikDefaultCertificate: true

monitoring:
  enabled: false

rmf_web:
  API_SERVER_DB_PASSWD: "<GENERATED_RMF_DB_PASSWORD>"
  ADMIN_PASSWD: "<GENERATED_RMF_ADMIN_PASSWORD>"

keycloak:
  KEYCLOAK_ADMIN_PASSWD: "<GENERATED_KEYCLOAK_ADMIN_PASSWORD>"
  KEYCLOAK_DB_PASSWD: "<GENERATED_KEYCLOAK_DB_PASSWORD>"
```

The resulting value behavior is:

| Chart value | Why this test changes it |
|---|---|
| `hostName`, `baseUrl` | Replace the production hostname and keep all redirects on the workstation-resolvable `rmf.test` name. |
| `ENABLE_RMF_SIM: true` | Run the simulation smoke-test profile. |
| `ENABLE_RMF: false` | Do not run real/core mode alongside simulation mode. |
| `ingress.provider`, `ingress.className` | Render Traefik CRDs for the Traefik installation on infra. |
| `tls.useTraefikDefaultCertificate: true` | Avoid requiring cert-manager and a public ACME challenge. A browser warning is expected. |
| `monitoring.enabled: false` | Avoid requiring Prometheus Operator CRDs and a monitoring stack. |
| Four passwords | Supply required local credentials without changing shared defaults. |

Do not change `global.REGISTRY_RMF`, `rmf_web.API_SERVER_REGISTRY`, or
`global.DEPLOYMENT_IMAGE_TAG` for this test. The chart currently points to the
published images and their `latest` tag.

## 6. Validate the overlay before creating VMs

From the repository root, confirm that the generated state is ignored:

```bash
git check-ignore -v \
  reference/docker-desktop-crossplane/.state/rmf-values.yaml
```

The command must identify the reference bundle's `.state/` rule. Then check
that no placeholder remains:

```bash
if grep -n '<GENERATED_' \
  "${RMF_VALUES_FILE}"; then
  echo "Replace every password placeholder before continuing" >&2
  exit 1
fi
```

Download the published chart, then render and lint it locally:

```bash
curl -fL \
  https://github.com/openkubes/rmf_deployment_template/releases/download/openrmf-deployment-v1.0.0/openrmf-deployment-1.0.0.tgz \
  -o /tmp/openrmf-deployment-1.0.0.tgz
helm lint /tmp/openrmf-deployment-1.0.0.tgz -f "${RMF_VALUES_FILE}"
```

```bash
helm template rmf /tmp/openrmf-deployment-1.0.0.tgz \
  --namespace rmf \
  -f "${RMF_VALUES_FILE}" \
  > /tmp/rmf-multipass-rendered.yaml
```

Confirm that the local profile did not render cert-manager or monitoring
resources:

```bash
if grep -En '^kind: (Certificate|ServiceMonitor)$|namespace: monitoring' \
  /tmp/rmf-multipass-rendered.yaml; then
  echo "Unexpected production-only resources were rendered" >&2
  exit 1
fi
```

The rendered file contains secret data. Remove it after validation:

```bash
rm /tmp/rmf-multipass-rendered.yaml /tmp/openrmf-deployment-1.0.0.tgz
```

## 7. Create the management and infra clusters without KubeVirt

From the repository root, create only the clusters required by this tutorial:

```bash
make up-mgmt
make install-k3s-mgmt
make up-infra
make install-k3s-infra
```

If Tutorials 1 and 2 are already complete, restart the VMs and tunnels instead.
`make setup` also installs KubeVirt, which is not required here.

Verify the actual guest architectures:

```bash
multipass exec ok-mgmt-local -- dpkg --print-architecture
multipass exec ok-infra-local -- dpkg --print-architecture
```

Both commands must print `amd64`.

Define context-specific paths for the remaining workstation commands:

```bash
export OK_LOCAL_ROOT="$PWD"
export MGMT_KUBECONFIG="${OK_LOCAL_ROOT}/.tunnel-mgmt.kubeconfig"
export INFRA_KUBECONFIG="${OK_LOCAL_ROOT}/.tunnel-infra.kubeconfig"
```

Verify both APIs:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl get nodes -o wide
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get nodes -o wide
```

If a tunnel is no longer running, restart both from the repository root:

```bash
make tunnels
```

## 8. Install Traefik on the infra cluster

The Makefile installs infra K3s with `--disable traefik`, so install Traefik
only against `INFRA_KUBECONFIG`:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  helm upgrade --install traefik traefik/traefik \
    --namespace kube-system \
    --version 40.2.0 \
    --wait \
    --timeout 10m
```

The chart creates a `LoadBalancer` Service exposing `web` on 80 and
`websecure` on 443. K3s ServiceLB, which the Makefile does not disable,
publishes those ports on the infra VM.

Validate all required facilities on infra:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl -n kube-system rollout status deployment/traefik --timeout=10m
```

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get crd ingressroutes.traefik.io middlewares.traefik.io
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl -n kube-system get service traefik
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get storageclass
```

Do not continue unless Traefik is ready, its Service exposes 80/443, and
`local-path` is the default StorageClass.

## 9. Install Crossplane and validate remote reconciliation

Complete [Tutorial 4](tutorial-crossplane.md) through its `podinfo` validation.
That tutorial:

1. installs Crossplane on management;
2. installs provider-kubernetes and provider-helm;
3. stores `infra-local.kubeconfig` as `crossplane-system/infra-kubeconfig` on
   management;
4. creates both ProviderConfigs as `ok-infra-local`; and
5. deploys a test namespace and `podinfo` Release to infra.

Verify the split explicitly:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get providers.pkg.crossplane.io
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get providerconfigs.helm.crossplane.io
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get object ok-test-namespace
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get release.helm.crossplane.io podinfo
```

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get namespace ok-crossplane-test
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get pods -l app.kubernetes.io/name=podinfo
```

The managed resources on management must report `Ready=True` and
`Synced=True`, and their concrete Kubernetes resources must exist on infra.

## 10. Store the RMF values on the management cluster

Provider-helm reads `valuesFrom` Secrets from the cluster where the provider
runs. Therefore the values Secret belongs on **management**, even though the
Helm release is installed on **infra**.

Run from the repository root, using the absolute kubeconfig path established
above:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl -n crossplane-system create secret generic rmf-crossplane-values \
    --from-file=values.yaml="${RMF_VALUES_FILE}" \
    --dry-run=client -o yaml \
  | KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f -
```

Confirm only the Secret metadata; do not print its contents:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl -n crossplane-system get secret rmf-crossplane-values
```

This prevents passwords from appearing in the Crossplane `Release` object,
but a Kubernetes Secret is not encryption by itself. This is acceptable only
for the disposable local test.

## 11. Create the RMF namespace on infra through Crossplane

Apply this object to management:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f - <<'EOF'
apiVersion: kubernetes.crossplane.io/v1alpha2
kind: Object
metadata:
  name: rmf-namespace
spec:
  providerConfigRef:
    name: ok-infra-local
  forProvider:
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: rmf
EOF
```

Wait for Crossplane and verify the result on infra:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl wait object/rmf-namespace --for=condition=Ready --timeout=5m
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get namespace rmf
```

## 12. Deploy OpenRMF to infra through Crossplane

The provider cannot read the chart directory on the workstation. Use the
published chart 1.0.0 release asset:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f - <<'EOF'
apiVersion: helm.crossplane.io/v1beta1
kind: Release
metadata:
  name: rmf
spec:
  providerConfigRef:
    name: ok-infra-local
  forProvider:
    chart:
      url: https://github.com/openkubes/rmf_deployment_template/releases/download/openrmf-deployment-v1.0.0/openrmf-deployment-1.0.0.tgz
    namespace: rmf
    skipCreateNamespace: true
    wait: true
    waitTimeout: 20m
    valuesFrom:
      - secretKeyRef:
          name: rmf-crossplane-values
          namespace: crossplane-system
          key: values.yaml
          optional: false
EOF
```

Observe Crossplane from management:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get release.helm.crossplane.io rmf -w
```

In another workstation terminal, observe the actual workloads on infra:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get pods,pvc -n rmf -w
```

The first installation can take time because the simulation image is large.

## 13. Validate the deployment

Management-side reconciliation:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get release.helm.crossplane.io rmf
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl describe release.helm.crossplane.io rmf
```

The Release must report both `Ready=True` and `Synced=True`.

Infra-side application state:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get pods,pvc,svc -n rmf
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get ingressroute,middleware -n rmf
```

Expected steady state:

- `keycloak-db`, `keycloak`, `rmf-web-rmf-server-db`,
  `rmf-web-rmf-server`, `rmf-web-dashboard`, and `rmf-sim` are running;
- both PostgreSQL PVCs are `Bound`;
- the `keycloak-setup` Job completed, although it may disappear after its TTL;
- no `Certificate` or `ServiceMonitor` resources were created.

If the setup Job still exists:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl -n rmf logs job/keycloak-setup
```

## 14. Configure workstation access

Find the IPv4 address of `ok-infra-local`:

```bash
multipass info ok-infra-local
```

Add the following entry to `/etc/hosts`, replacing the placeholder with the
infra VM address, not the management address:

```text
<INFRA_VM_IP> rmf.test
```

Open:

- `https://rmf.test/dashboard`
- `https://rmf.test/auth`
- `https://rmf.test/rmf/api/v1`

A certificate warning is expected because the local values use Traefik's
self-signed default certificate.

Command-line checks:

```bash
curl -kI https://rmf.test/dashboard
curl -kI https://rmf.test/auth
```

Update `/etc/hosts` if Multipass assigns a different infra address after a
restart.

## 15. Troubleshooting

### A kubeconfig stops responding

From the repository root:

```bash
make tunnels
```

Then repeat both `kubectl get nodes` checks. Port 6443 is management and port
6444 is infra.

### Crossplane Release is not ready

Inspect the managed resource and provider on management:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl describe release.helm.crossplane.io rmf
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get pods -n crossplane-system
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get events -A --sort-by=.lastTimestamp
```

Common causes are an unreachable infra API, inability to download the chart,
an invalid values file, missing namespace, or insufficient infra memory/disk.

### Keycloak setup times out during the first pull

The setup Job has a fixed 120-second active deadline. On the validated
2-CPU/4-GiB Docker test, the first image pulls plus Keycloak's initial Quarkus
build exceeded that deadline even though the node had no memory pressure. Once
the images were cached and Keycloak was ready, the same setup completed in a
few seconds.

Check the evidence before increasing VM memory:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl -n rmf logs job/keycloak-setup
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl -n rmf get deployment keycloak
```

After Keycloak becomes ready, trigger another Helm reconciliation using the
annotation command in section 16. Then verify that `jwt-pub-key` contains data
and the API server becomes ready. Do not rely on the Crossplane Release
condition alone; always perform the infra-side pod and endpoint checks in
sections 13-14.

### Pods remain Pending

Run against infra:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get nodes
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get storageclass
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl get pvc -n rmf
KUBECONFIG="${INFRA_KUBECONFIG}" kubectl describe pvc -n rmf
```

The K3s `local-path` StorageClass must exist and be the default.

### Pods show `ImagePullBackOff`

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl describe pod -n rmf <POD_NAME>
```

Confirm outbound access to Docker Hub, Quay, GHCR, and the Crossplane package
registry.

### Pods show `exec format error`

```bash
multipass exec ok-infra-local -- dpkg --print-architecture
```

An `arm64` result is incompatible with the current custom RMF images. Recreate
the test on `amd64` or publish multi-architecture images.

### Browser cannot connect

Run against infra:

```bash
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get pods,svc -n kube-system
KUBECONFIG="${INFRA_KUBECONFIG}" \
  kubectl get ingressroute,middleware -n rmf
```

Also confirm that `rmf.test` resolves to the current infra VM IP. A timeout
indicates VM networking, firewall, or ServiceLB trouble. An HTTP 404 normally
indicates a hostname or Traefik route mismatch.

## 16. Apply later values changes

Edit the gitignored overlay in the repository, lint it again, and replace the
Secret on management:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl -n crossplane-system create secret generic rmf-crossplane-values \
    --from-file=values.yaml="${RMF_VALUES_FILE}" \
    --dry-run=client -o yaml \
  | KUBECONFIG="${MGMT_KUBECONFIG}" kubectl apply -f -
```

Watch reconciliation:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl get release.helm.crossplane.io rmf -w
```

If the provider does not reconcile immediately, annotate the managed resource:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl annotate release.helm.crossplane.io rmf \
    smoke-test.openkubes.ai/reconcile-at="$(date -u +%s)" --overwrite
```

## 17. Scoped cleanup

First delete the Crossplane Helm Release from management and allow it to
uninstall OpenRMF from infra:

```bash
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl delete release.helm.crossplane.io rmf
KUBECONFIG="${MGMT_KUBECONFIG}" \
  kubectl delete object rmf-namespace
```

For a disposable test, delete only the two OK-101 VMs:

```bash
multipass delete --purge ok-mgmt-local ok-infra-local
```

Remove the `rmf.test` entry from `/etc/hosts`. Generated kubeconfigs and local
credentials should be retained only while their administrator access is
needed. The repository's `make clean` deletes the two named VMs and generated
kubeconfig files; it does not invoke a global Multipass purge.

## 18. References

- [Jira OK-101](https://kubernauts.atlassian.net/browse/OK-101)
- [K3s networking services](https://docs.k3s.io/networking/networking-services)
- [K3s packaged components](https://docs.k3s.io/installation/packaged-components)
- [Crossplane installation](https://docs.crossplane.io/latest/get-started/install/)
- [Crossplane provider-helm](https://github.com/crossplane-contrib/provider-helm)
- [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart)
