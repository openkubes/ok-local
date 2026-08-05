# ok-artifact-registry — `registry-default` (zot), Phase 1 on ok-local

Starter scaffold for **OK-137**: develop and prove the **envelope-invariant**
parts of the Artifact Registry Contract (ADR-Platform-028) with zot on
`ok-local`, before promoting to `ok-shared` for the gating §8 run (OK-138).

> ⚠️ **Guardrail.** Everything here is **development evidence, not §8 acceptance
> evidence.** Local OIDC, backup/restore, and workload-pull do **not** count
> toward acceptance — those are proven on `ok-shared` in Phase 2 (OK-138). This
> work does not move ADR-028 to `Accepted`.

## Layout

```
ok-artifact-registry/
├── README.md                       # this runbook
├── Makefile                        # repo / secret / deploy / smoke / clean
├── kustomization.yaml              # GitOps rendering (pinned Helm + patches)
├── compositions/zot/
│   ├── values-local.yaml           # curated zot Helm values (ok-local)
│   └── config.reference.json       # the zot config, standalone for review
├── gitops/
│   ├── README.md                    # secret boundary + bootstrap runbook
│   └── argocd/application.yaml     # delivery to registered ok-infra-local
└── contract/tests/
    ├── smoke.sh                     # OCI, authz, referrers, metrics
    ├── offline-transfer.sh          # export / verify / import / digest pull
    ├── lifecycle.sh                 # GC reclamation + scrub integrity
    ├── conformance.sh               # OCI Distribution conformance
    └── README.md                    # checklist mapping + test details
```

Curated per ADR-028 §6: OCI core, authn/authz, metrics, GC, storage-integrity
(scrub), search/discovery. **No** sync, **no** UI, **no** embedded scanning.

## Prerequisites

- `ok-local` up and reachable: `make setup` in the `ok-local` repo. The commands
  below use its generated `.tunnel-infra.kubeconfig` directly and do not depend
  on a shell alias.
- CLIs on your Mac: `helm`, `kubectl`, `crane`, `oras`, `syft`, `jq`,
  `htpasswd` (apache2-utils), `docker` (for conformance), and optionally
  `cosign`.

## Run

```bash
# Shell 1: starting in the directory that contains the ok-local checkout,
# ensure its workload-cluster tunnel is running and select that cluster.
cd ok-local
multipass info ok-infra-local    # must exist and report State: Running
# If it does not exist, stop here and run `make setup` first.
make tunnel-infra
export KUBECONFIG="$PWD/.tunnel-infra.kubeconfig"
kubectl get nodes                # ok-infra-local must be Ready
cd ok-artifact-registry

# Install and inspect zot.
make repo                        # add the zot helm chart repo
make secret                      # create htpasswd Secret (admin/ci/puller)
make deploy                      # helm install zot with values-local.yaml
make status                      # pods/svc/pvc healthy?

# Shell 2: again start in the directory containing ok-local, select the same
# cluster, enter this repository, then keep the blocking port-forward running.
cd ok-local
export KUBECONFIG="$PWD/.tunnel-infra.kubeconfig"
cd ok-artifact-registry
make port-forward                # localhost:5050 -> zot

# Back in Shell 1, run the tests while Shell 2 remains open.
make smoke                       # image + helm push/pull, digest, referrers+SBOM

# 5. verify an offline transfer through an OCI layout archive:
make offline-transfer

# 6. OCI conformance (uses the admin identity because it tests deletion):
make conformance

# 7. GC + scrub (manages localhost:5051 and restarts zot once):
KUBECONFIG=../.tunnel-infra.kubeconfig make lifecycle

# 8. validate Helm and GitOps rendering:
make verify
```

Dev credentials default to `*-local-dev` and can be overridden:
`make deploy CI_PASS=... ADMIN_PASS=...`. **Never** reuse these on `ok-shared`.

The chart is pinned to `0.1.122`, while the zot image is deliberately overridden
to `v2.1.20`. That patch release fixes the Referrers API, empty-blob, and digest
validation failures found in the first local conformance run. Inline storage
deduplication is disabled in this contract composition because the OCI content
management checks require a blob deleted from one mounted repository to become
unavailable there immediately. GC still reclaims unreferenced blobs after its
configured delay.

The aggressive GC and scrub intervals are local-test settings. `lifecycle.sh`
creates one disposable and one retained artifact, waits past the GC delay,
restarts zot deterministically, and proves that GC removes only the orphan while
the startup scrub validates the retained repository. Its isolated test namespace
sorts ahead of accumulated evidence repositories so the bounded startup check is
repeatable after any number of prior runs. Phase 2 re-tunes these intervals for
the shared environment.

## GitOps

The root Kustomization inflates the pinned Helm chart and applies TCP health
probes so no probe credential needs to be committed. The static local
`zot-htpasswd` Secret remains an out-of-band prerequisite. See
`gitops/README.md` for Argo CD bootstrap details. `make gitops-render` validates
the exact manifests locally.

## What "done" means for Phase 1 (OK-137)

The zot config + values + tests demonstrate the envelope-invariant contract
behaviour and are ready to promote to `ok-shared`. Local evidence and the
ticket-ready summary are recorded under `evidence/OK-137.md`. The Phase-2 delta
(OIDC via Keycloak/ADR-020, cert-manager TLS/ADR-010,
Vault secrets/ADR-025, prod storage, backup/restore, upgrade/rollback,
release-scale offline transfer, DR runbook) lives in OK-138.

## Promoting to ok-shared (later)

Keep this exact layout; add a sibling `values-ok-shared.yaml` that swaps:
htpasswd → Keycloak OIDC, ClusterIP+port-forward → ingress + cert-manager TLS,
`local-path` → production storage, and wires backup/restore. The contract tests
in `contract/tests/` should pass unchanged — that is the point of the contract.
