# ok-artifact-registry — zot Phase 1 on ok-local

This repository contains the curated zot composition, tests, GitOps wiring,
documentation, and operational runbook for **OK-137**. Phase 1 proves the
envelope-invariant parts of the Artifact Registry Contract
(ADR-Platform-028 §4) on the `ok-infra-local` K3s cluster before promotion to
`ok-shared` in OK-138.

> Everything recorded here is Phase-1 development evidence, not
> ADR-Platform-028 §8 acceptance evidence. OIDC, production TLS and ingress,
> production storage, backup/restore, workload pull, upgrade/rollback, and DR
> are validated on `ok-shared` in Phase 2.

## Repository layout

```text
ok-artifact-registry/
├── README.md                       # documentation and Phase-1 runbook
├── Makefile                        # deployment, validation, and cleanup
├── kustomization.yaml              # pinned Helm render and probe patches
├── compositions/zot/
│   ├── values-local.yaml           # curated ok-local Helm values
│   └── config.reference.json       # standalone zot config for review
├── contract/tests/
│   ├── smoke.sh                    # OCI, authz, Referrers, metrics
│   ├── offline-transfer.sh         # export, verify, import, digest pull
│   ├── lifecycle.sh                # GC and scrub integrity
│   └── conformance.sh              # OCI Distribution conformance
├── evidence/OK-137.md              # durable result and handover summary
└── gitops/
    ├── namespace.yaml
    └── argocd/application.yaml
```

## Architecture and design

| Component | Phase-1 choice |
|---|---|
| Runtime | K3s v1.35.5+k3s1 on `ok-infra-local` |
| Registry | zot v2.1.20 |
| Helm chart | `project-zot/zot` 0.1.122 |
| Storage | 8 GiB `local-path` PVC |
| Exposure | ClusterIP plus localhost port-forward on 5050 |
| Authentication | out-of-band htpasswd Secret |
| Authorization | admin, machine writer (`ci`), read-only `puller` |
| Metadata | OCI Referrers with SPDX JSON SBOM |
| Observability | authenticated Prometheus metrics endpoint |
| Lifecycle | garbage collection plus periodic scrub |
| Delivery | Helm rendered through Kustomize; Argo CD Application |

The `zot-htpasswd` Secret is created by `make secret` and is never stored in
Git. `admin` has content-management and metrics access, `ci` represents a
machine publisher, and `puller` can read but cannot write. Phase 2 replaces
these static credentials with the platform identity and secret integrations.

Immutable manifest digests are the canonical artifact identity. Tests confirm
that image pull and offline export/import preserve the same digest. SPDX JSON is
attached as an OCI Referrer; the smoke test asserts both the resolved subject
digest and the returned `application/spdx+json` descriptor.

Inline storage deduplication is disabled so repository-local delete semantics
remain observable to the conformance suite. The short GC and scrub intervals
are aggressive local-test settings, not production recommendations.

## Requirement coverage

| OK-137 requirement | Proof |
|---|---|
| curated zot composition on K3s | Helm deployment plus pod, Service, and PVC status |
| OCI image push and pull | `smoke.sh` step 1 |
| OCI Helm chart push and pull | `smoke.sh` step 3 |
| pull by immutable digest | `smoke.sh` step 2 |
| SBOM/signature via Referrers | asserted SPDX Referrer in `smoke.sh` step 4 |
| separated human/machine credentials | `smoke.sh` steps 0 and 6 |
| metrics endpoint | `smoke.sh` step 7 |
| garbage collection | `lifecycle.sh` step 3 |
| storage-integrity check | `lifecycle.sh` step 4 |
| offline-transfer mechanics | `offline-transfer.sh` |
| GitOps wiring | root Kustomization plus Argo CD Application |
| contract and OCI conformance tests | `make contract` and `make verify` |

## Phase-1 runbook

### 1. Prerequisites

Required local commands:

```bash
for command_name in multipass kubectl helm crane oras syft jq htpasswd docker; do
  command -v "$command_name" || exit 1
done
docker info >/dev/null
```

The checkout is expected to have this layout:

```text
ok-local/
└── ok-artifact-registry/
```

Starting in the directory containing `ok-local`:

```bash
cd ok-local
multipass info ok-infra-local    # must exist and report State: Running
```

If the VM does not exist, stop and run `make setup` before continuing.

### 2. Select the workload cluster

From the `ok-local` root:

```bash
make tunnel-infra
export KUBECONFIG="$PWD/.tunnel-infra.kubeconfig"
kubectl get nodes                # ok-infra-local must be Ready
cd ok-artifact-registry
```

Do not continue if the API on `127.0.0.1:6444` is unreachable.

### 3. Install zot

```bash
make repo
make secret
make deploy
make status
```

Expected status:

- `pod/zot-0`: `1/1 Running`;
- `service/zot`: port `5000/TCP`;
- `persistentvolumeclaim/zot-pvc-zot-0`: `Bound`, 8 GiB.

The default `*-local-dev` credentials are local test credentials. Override them
on every relevant Make invocation if required. Never reuse them on `ok-shared`.

### 4. Start the registry port-forward

In a second shell, start again in the directory containing `ok-local` and keep
the blocking port-forward running:

```bash
cd ok-local
export KUBECONFIG="$PWD/.tunnel-infra.kubeconfig"
cd ok-artifact-registry
make port-forward
```

Expected: `localhost:5050` forwards to zot's in-cluster port 5000. Port 5050
avoids the macOS Control Center service that can occupy port 5000.

### 5. Run the contract suite with isolated client credentials

Back in the first shell, create one run identifier and an isolated Docker
configuration. The subshell removes the credential directory on exit:

```bash
export OK137_RUN_ID="$(date -u +%Y%m%dt%H%M%Sz)"
OK137_DOCKER_CONFIG="$(mktemp -d /tmp/ok137-docker-config.XXXXXX)"

(
  export RUN_ID="$OK137_RUN_ID"
  export DOCKER_CONFIG="$OK137_DOCKER_CONFIG"
  trap 'rm -rf "$DOCKER_CONFIG"' EXIT

  make contract
  make verify
)
```

`make contract` deliberately executes in this order:

1. smoke — image and Helm push/pull, digest, asserted Referrer, credentials,
   denied write, and metrics;
2. offline transfer — export, checksum verification, import, and digest pull;
3. pinned OCI Distribution conformance suite;
4. lifecycle — garbage collection and scrub.

Lifecycle restarts zot. The second-shell port-forward may terminate afterward;
restart it only if more registry access is needed.

### 6. Verify the results

The output must show:

- smoke: `result=PASS`;
- offline transfer: `result=PASS`;
- lifecycle: `gc=PASS`, `scrub=PASS`, `result=PASS`;
- OCI conformance: 848 pass, 0 fail, 0 error, 4 skip, 2 disabled;
- `make verify`: shell, JSON, Helm, and Kustomize validation successful.

Inspect the machine-readable results:

```bash
cat "contract/tests/results-smoke/$OK137_RUN_ID/results.env"
cat "contract/tests/results-offline/$OK137_RUN_ID/results.env"
cat "contract/tests/results-lifecycle/$OK137_RUN_ID/results.env"
head -2 "contract/tests/results/$OK137_RUN_ID/junit.xml"
```

If the pinned conformance image is intentionally updated and the applicable
test count changes, record the new observed totals instead of copying the
numbers above.

### 7. Record and attach evidence

Update `evidence/OK-137.md` with the run ID and exact results. Generated result
directories are intentionally git-ignored. Upload these nine files to OK-137:

```text
contract/tests/results-smoke/<RUN_ID>/summary.log
contract/tests/results-smoke/<RUN_ID>/results.env
contract/tests/results-offline/<RUN_ID>/summary.log
contract/tests/results-offline/<RUN_ID>/results.env
contract/tests/results-lifecycle/<RUN_ID>/summary.log
contract/tests/results-lifecycle/<RUN_ID>/results.env
contract/tests/results/<RUN_ID>/results.yaml
contract/tests/results/<RUN_ID>/junit.xml
contract/tests/results/<RUN_ID>/report.html
```

The Jira handover comment must include:

- commit SHA and summary;
- files changed and why;
- exact test commands and PASS/FAIL results;
- exact smoke, offline, lifecycle, and conformance results;
- attached evidence files;
- remaining risks;
- the Phase-1-only scope statement.

Keep OK-137 In Progress until the evidence is attached and the handover comment
is published.

## GitOps

The root `kustomization.yaml` inflates the pinned Helm chart and replaces HTTP
health probes with TCP probes, so no probe credential is committed. Validate the
render locally with `make gitops-render` or `make verify`.

The static `zot-htpasswd` Secret is an out-of-band prerequisite:

```bash
KUBECONFIG=../.tunnel-infra.kubeconfig make secret
```

Argo CD must enable Kustomize's `--enable-helm` build option. Once Argo CD is
installed on `ok-mgmt-local`, `ok-infra-local` is registered, and the change is
on `main`, bootstrap the Application with:

```bash
kubectl --kubeconfig ../.tunnel-mgmt.kubeconfig apply \
  -f gitops/argocd/application.yaml
```

The Application points to `main`; pushing only a feature branch does not deploy
the composition.

## Troubleshooting

### `ssh ubuntu@` has no host

`ok-infra-local` does not exist or has no Multipass IP. Run `multipass list`.
If the VM is absent, run `make setup` from the `ok-local` root.

### Kubernetes refuses `127.0.0.1:6444`

Restart the workload-cluster tunnel:

```bash
cd ok-local
make tunnel-infra
export KUBECONFIG="$PWD/.tunnel-infra.kubeconfig"
kubectl get nodes
```

### Registry returns `403` on localhost

Confirm that clients use `localhost:5050`, not port 5000, and check the second
shell for a successful `make port-forward`. A response from port 5000 on macOS
may come from Control Center rather than zot.

### Port-forward ends after lifecycle

This is expected because lifecycle restarts the StatefulSet. Run
`make port-forward` again if further registry operations are required.

### A test fails after an interrupted run

Run the suite with a new `OK137_RUN_ID` and a new temporary Docker config. Do
not reuse an incomplete evidence directory.

## Optional teardown

```bash
make clean
```

This deletes the `ok-registry` namespace and its local registry data. It does
not delete the two Multipass VMs. Upload required evidence before teardown.

## Promotion to ok-shared

Promotion retains the OCI contract and test intent while replacing htpasswd
with platform identity, port-forwarding with ingress and managed TLS,
`local-path` with production storage, and local lifecycle tuning with shared
policies. The formal acceptance run belongs to OK-138.
