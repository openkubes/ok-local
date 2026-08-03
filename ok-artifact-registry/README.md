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
├── compositions/zot/
│   ├── values-local.yaml           # curated zot Helm values (ok-local)
│   └── config.reference.json       # the zot config, standalone for review
└── contract/tests/
    ├── smoke.sh                     # envelope-invariant contract smoke test
    └── README.md                    # checklist mapping + GC/scrub/conformance
```

Curated per ADR-028 §6: OCI core, authn/authz, metrics, GC, storage-integrity
(scrub), search/discovery. **No** sync, **no** UI, **no** embedded scanning.

## Prerequisites

- `ok-local` up and reachable: `make setup` in the `ok-local` repo, then
  `oil && kubectl get nodes` (the workload cluster context).
- CLIs on your Mac: `helm`, `kubectl`, `crane`, `oras`, `syft`, `htpasswd`
  (apache2-utils), and optionally `cosign`.

## Run

```bash
# 1. point kubectl at the local cluster (from the ok-local repo aliases)
oil                              # export KUBECONFIG for ok-infra-local

# 2. from THIS directory:
make repo                        # add the zot helm chart repo
make secret                      # create htpasswd Secret (admin/ci/puller)
make deploy                      # helm install zot with values-local.yaml
make status                      # pods/svc/pvc healthy?

# 3. in a second shell, expose the registry:
make port-forward                # localhost:5000 -> zot

# 4. back in the first shell, run the contract smoke test:
make smoke                       # image + helm push/pull, digest, referrers+SBOM

# 5. OCI conformance + GC/scrub checks:
#    see contract/tests/README.md
```

Dev credentials default to `*-local-dev` and can be overridden:
`make deploy CI_PASS=... ADMIN_PASS=...`. **Never** reuse these on `ok-shared`.

## What "done" means for Phase 1 (OK-137)

The zot config + values + tests demonstrate the envelope-invariant contract
behaviour and are ready to promote to `ok-shared`. Record notes/screens in
OK-137. The Phase-2 delta (OIDC via Keycloak/ADR-020, cert-manager TLS/ADR-010,
Vault secrets/ADR-025, prod storage, backup/restore, upgrade/rollback,
release-scale offline transfer, DR runbook) lives in OK-138.

## Promoting to ok-shared (later)

Keep this exact layout; add a sibling `values-ok-shared.yaml` that swaps:
htpasswd → Keycloak OIDC, ClusterIP+port-forward → ingress + cert-manager TLS,
`local-path` → production storage, and wires backup/restore. The contract tests
in `contract/tests/` should pass unchanged — that is the point of the contract.
