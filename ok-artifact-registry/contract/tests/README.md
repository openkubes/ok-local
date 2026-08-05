# Contract tests — Phase 1 (ok-local, OK-137)

These tests prove the **envelope-invariant** behaviour of the Artifact Registry
Contract (ADR-Platform-028 §4) on a local K3s cluster. They are **dev evidence,
not §8 acceptance evidence** — the gating §8 run happens on `ok-shared` (OK-138).

## Files

- `smoke.sh` — push/pull image + Helm chart, pull-by-digest, SBOM attach +
  Referrers discovery, metrics, and the read-only-identity denial check.
- `offline-transfer.sh` — OCI-layout export, SHA-256 verification, import, and
  pull-by-digest identity verification.
- `lifecycle.sh` — controlled orphan/referenced-blob GC check and startup scrub
  verification against the retained repository.
- `conformance.sh` — OCI Distribution Spec conformance (§8.9).

## Checklist mapping (OK-137 → §8)

| OK-137 item | Covered by | ADR §8 |
|---|---|---|
| image push/pull | `smoke.sh` step 1 | §8.1 |
| Helm push/pull | `smoke.sh` step 3 | §8.2 |
| pull by digest | `smoke.sh` step 2 | §8.4 |
| SBOM/signature via Referrers | `smoke.sh` steps 4–5 | §8.5 |
| separated human/machine creds | `smoke.sh` steps 0, 6 | §4.5 |
| metrics | `smoke.sh` step 7 | §8.7 (partial) |
| garbage collection | `lifecycle.sh` step 3 | §4.7 |
| storage integrity (scrub) | `lifecycle.sh` step 4 | §4.7 |
| offline-transfer mechanics | `offline-transfer.sh` | §4.9 |
| GitOps wiring | root Kustomization + Argo CD Application | §4.9 |
| OCI conformance | conformance runner below | §8.9 |

> Not covered locally (Phase 2 / ok-shared, OK-138): OIDC (ADR-020),
> backup/restore against prod storage, workload-pull, upgrade/rollback,
> release-scale offline transfer, DR runbook.

## OCI Distribution conformance (§8.9)

Run the upstream conformance suite against local zot while `make port-forward`
is active:

```bash
make conformance
```

The runner uses the admin identity because content-management tests require
delete permission. It reaches the host port-forward through
`host.docker.internal`, assigns unique repositories for every run, and writes
`report.html`, `junit.xml`, and `results.yaml` to a timestamped directory under
`contract/tests/results/`. Those generated files are git-ignored; attach them
to OK-137 as local evidence.

The default conformance image is pinned by digest to the exact upstream suite
used for the recorded result. It can be overridden deliberately, for example:

```bash
make conformance \
  CONFORMANCE_IMAGE=ghcr.io/opencontainers/distribution-spec/conformance:main
```

## Offline-transfer mechanics (§4.9)

The test exports the complete multi-platform image into an OCI image layout,
archives and verifies it with SHA-256, imports the verified layout into a new
repository, and pulls the imported content by the original immutable digest:

```bash
make offline-transfer
```

## GC and storage integrity (§4.7)

The lifecycle test manages its own port-forward on `localhost:5051`. It creates
unique disposable and retained artifacts, deletes only the disposable manifest,
waits past `gcDelay`, and performs a controlled StatefulSet restart. The test
then confirms the orphaned blob is gone, the referenced blob remains, and zot's
startup scrub completed without reporting the retained repository as affected.
The isolated lifecycle repository sorts ahead of accumulated test evidence so
startup GC reaches it deterministically within the bounded timeout.

```bash
KUBECONFIG=../.tunnel-infra.kubeconfig make lifecycle
```

Run the complete suite in this order while the regular `make port-forward` is
active; lifecycle is intentionally last because it restarts zot:

```bash
KUBECONFIG=../.tunnel-infra.kubeconfig make contract
```
