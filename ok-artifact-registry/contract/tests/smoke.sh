#!/usr/bin/env bash
# registry-default (zot) — Phase-1 contract smoke test (OK-137, ok-local)
#
# Proves the ENVELOPE-INVARIANT parts of the Artifact Registry Contract
# (ADR-Platform-028 §4). This is DEV evidence, NOT §8 acceptance evidence —
# OIDC (ADR-020), backup/restore against prod storage, and workload-pull on
# ok-shared are Phase 2 (OK-138).
#
# Prerequisites (install locally):
#   crane   — github.com/google/go-containerregistry
#   oras    — oras.land            (referrers / SBOM attach + discover)
#   helm    — OCI push/pull
#   syft    — anchore/syft         (SBOM generation)
#   cosign  — sigstore/cosign      (signature; optional)
#   curl    — metrics endpoint check
#
# Usage:
#   export REG=localhost:5050            # port-forwarded zot (see Makefile)
#   export CI_USER=ci CI_PASS=...        # machine push identity
#   export PULL_USER=puller PULL_PASS=...# read-only identity
#   ./smoke.sh
set -euo pipefail

REG="${REG:-localhost:5050}"
NS="openkubes/staging"           # namespace path per ADR-028 §4.4
IMG_REF="${REG}/${NS}/alpine:3.20"
REG_SCHEME="${REG_SCHEME:-http}"
HELM_REGISTRY_FLAGS=()
if [[ "$REG_SCHEME" == "http" ]]; then
  HELM_REGISTRY_FLAGS+=(--plain-http)
fi
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zot-smoke.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
RESULTS_DIR="${RESULTS_DIR:-contract/tests/results-smoke}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%M%Sz)}"
case "$RESULTS_DIR" in
  /*) ;;
  *) RESULTS_DIR="${PWD}/${RESULTS_DIR}" ;;
esac
RUN_RESULTS_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_RESULTS_DIR"
exec > >(tee "${RUN_RESULTS_DIR}/summary.log") 2>&1
: "${ADMIN_USER:?set ADMIN_USER}"; : "${ADMIN_PASS:?set ADMIN_PASS}"
: "${CI_USER:?set CI_USER}"; : "${CI_PASS:?set CI_PASS}"
: "${PULL_USER:?set PULL_USER}"; : "${PULL_PASS:?set PULL_PASS}"

pass(){ echo "  ✅ $*"; }
step(){ echo; echo "▶ $*"; }

step "0. login (machine identity — ADR-028 §4.5 separated creds)"
printf '%s' "$CI_PASS" | crane auth login "$REG" \
  --username "$CI_USER" --password-stdin
printf '%s' "$CI_PASS" | oras login "$REG" \
  --username "$CI_USER" --password-stdin
pass "authenticated as $CI_USER"

# --- §8.1 image push/pull ---------------------------------------------------
step "1. OCI image push + pull  (§8.1)"
crane copy alpine:3.20 "$IMG_REF"            # push (copy from Docker Hub)
crane pull "$IMG_REF" "$WORKDIR/alpine.tar"
pass "image push/pull ok"

# --- §8.4 immutable-digest reference ----------------------------------------
step "2. resolve + pull by immutable digest  (§8.4)"
DIGEST="$(crane digest "$IMG_REF")"
echo "  digest: $DIGEST"
crane pull "${REG}/${NS}/alpine@${DIGEST}" "$WORKDIR/alpine-by-digest.tar"
pass "pull-by-digest ok — this is the canonical release identity"

# --- §8.2 OCI Helm chart push/pull ------------------------------------------
step "3. OCI Helm chart push + pull  (§8.2)"
printf '%s' "$CI_PASS" | helm registry login "$REG" \
  --username "$CI_USER" --password-stdin "${HELM_REGISTRY_FLAGS[@]}"
helm create "$WORKDIR/demo" >/dev/null
helm package "$WORKDIR/demo" -d "$WORKDIR" >/dev/null
helm push "$WORKDIR/demo-0.1.0.tgz" \
  "oci://${REG}/openkubes/charts" "${HELM_REGISTRY_FLAGS[@]}"
mkdir -p "$WORKDIR/pullchart"
helm pull "oci://${REG}/openkubes/charts/demo" \
  --version 0.1.0 -d "$WORKDIR/pullchart" "${HELM_REGISTRY_FLAGS[@]}"
pass "helm OCI push/pull ok"

# --- §8.5 SBOM + Referrers API ----------------------------------------------
step "4. attach SBOM + discover via Referrers API  (§8.5, §4.6)"
syft "$IMG_REF" -o spdx-json > "$WORKDIR/sbom.spdx.json"
(
  cd "$WORKDIR"
  oras attach --artifact-type application/spdx+json "$IMG_REF" \
    "sbom.spdx.json:application/json"
)
echo "  referrers for $IMG_REF:"
oras discover --format tree "$IMG_REF"
pass "SBOM attached + discoverable via Referrers API"

# --- signature (optional) ---------------------------------------------------
step "5. (optional) signature as a referrer"
if command -v cosign >/dev/null; then
  (
    cd "$WORKDIR"
    COSIGN_PASSWORD="" cosign generate-key-pair
    COSIGN_PASSWORD="" cosign sign --yes --key cosign.key "$IMG_REF"
  ) || echo "  cosign signing skipped — local registry/key setup rejected it"
else
  echo "  cosign not installed — skipping (add in your run)"
fi

# --- read-only identity check (§4.5) ----------------------------------------
step "6. verify read-only identity can pull but cannot push  (§4.5)"
printf '%s' "$PULL_PASS" | crane auth login "$REG" \
  --username "$PULL_USER" --password-stdin
crane pull "$IMG_REF" "$WORKDIR/alpine-as-puller.tar"
pass "puller successfully read an existing image"

if crane copy alpine:3.20 "${REG}/${NS}/should-fail:latest" 2>/dev/null; then
  echo "  ❌ puller was able to push — accessControl is wrong"
  exit 1
else
  pass "puller correctly denied write"
fi

step "7. verify metrics endpoint  (§8.7 partial)"
METRICS="$(curl -fsS -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "${REG_SCHEME}://${REG}/metrics")"
grep -Eq '(^# (HELP|TYPE) |^zot_)' <<<"$METRICS"
pass "metrics endpoint returned Prometheus data"

{
  echo "image=${REG}/${NS}/alpine@${DIGEST}"
  echo "image_push_pull=PASS"
  echo "helm_push_pull=PASS"
  echo "pull_by_digest=PASS"
  echo "referrers_sbom=PASS"
  echo "puller_read_only=PASS"
  echo "metrics=PASS"
  echo "result=PASS"
} > "${RUN_RESULTS_DIR}/results.env"

echo
echo "Phase-1 smoke complete. Record results in OK-137."
echo "GC and scrub/storage-integrity remain separate checks; see README.md."
echo "Evidence: ${RUN_RESULTS_DIR}"
