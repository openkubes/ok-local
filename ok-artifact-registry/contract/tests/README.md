# Contract tests — Phase 1 (ok-local, OK-137)

These tests prove the **envelope-invariant** behaviour of the Artifact Registry
Contract (ADR-Platform-028 §4) on a local K3s cluster. They are **dev evidence,
not §8 acceptance evidence** — the gating §8 run happens on `ok-shared` (OK-138).

## Files

- `smoke.sh` — push/pull image + Helm chart, pull-by-digest, SBOM attach +
  Referrers discovery, and the read-only-identity denial check.
- (add) `conformance` — OCI Distribution Spec conformance (§8.9), see below.

## Checklist mapping (OK-137 → §8)

| OK-137 item | Covered by | ADR §8 |
|---|---|---|
| image push/pull | `smoke.sh` step 1 | §8.1 |
| Helm push/pull | `smoke.sh` step 3 | §8.2 |
| pull by digest | `smoke.sh` step 2 | §8.4 |
| SBOM/signature via Referrers | `smoke.sh` steps 4–5 | §8.5 |
| separated human/machine creds | `smoke.sh` steps 0, 6 | §4.5 |
| metrics | `curl $REG/metrics` (needs metrics ext) | §8.7 (partial) |
| garbage collection | see "GC check" below | §4.7 |
| storage integrity (scrub) | see "Scrub check" below | §4.7 |
| OCI conformance | conformance runner below | §8.9 |

> Not covered locally (Phase 2 / ok-shared, OK-138): OIDC (ADR-020),
> backup/restore against prod storage, workload-pull, upgrade/rollback,
> release-scale offline transfer, DR runbook.

## OCI Distribution conformance (§8.9)

Run the upstream conformance suite against local zot:

```bash
docker run --rm --network host \
  -e OCI_ROOT_URL="http://localhost:5000" \
  -e OCI_NAMESPACE="openkubes/conformance/test" \
  -e OCI_USERNAME="$CI_USER" -e OCI_PASSWORD="$CI_PASS" \
  -e OCI_TEST_PULL=1 -e OCI_TEST_PUSH=1 \
  -e OCI_TEST_CONTENT_DISCOVERY=1 -e OCI_TEST_CONTENT_MANAGEMENT=1 \
  ghcr.io/opencontainers/distribution-spec/conformance:main
```

Keep the generated `report.html` as evidence.

## GC check (§4.7)

1. Push a throwaway tag, then delete the manifest.
2. Trigger/await GC (config: `gcDelay: 1h`) or restart to force a cycle.
3. Confirm the referenced blob is reclaimed **but** blobs still reachable from a
   retained manifest/index/SBOM referrer are **not** removed.

## Scrub check (§4.7 storage integrity)

zot's `scrub` extension runs on the configured `interval`. Check pod logs for a
scrub cycle and confirm it reports blob integrity without deleting reachable
content.
