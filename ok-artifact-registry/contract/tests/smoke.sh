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
#
# Usage:
#   export REG=localhost:5000            # port-forwarded zot (see Makefile)
#   export CI_USER=ci CI_PASS=...        # machine push identity
#   export PULL_USER=puller PULL_PASS=...# read-only identity
#   ./smoke.sh
set -euo pipefail

REG="${REG:-localhost:5000}"
NS="openkubes/staging"           # namespace path per ADR-028 §4.4
IMG_REF="${REG}/${NS}/alpine:3.20"
: "${CI_USER:?set CI_USER}"; : "${CI_PASS:?set CI_PASS}"
: "${PULL_USER:?set PULL_USER}"; : "${PULL_PASS:?set PULL_PASS}"

pass(){ echo "  ✅ $*"; }
step(){ echo; echo "▶ $*"; }

step "0. login (machine identity — ADR-028 §4.5 separated creds)"
crane auth login "$REG" -u "$CI_USER" -p "$CI_PASS"
oras login "$REG" -u "$CI_USER" -p "$CI_PASS"
pass "authenticated as $CI_USER"

# --- §8.1 image push/pull ---------------------------------------------------
step "1. OCI image push + pull  (§8.1)"
crane copy alpine:3.20 "$IMG_REF"            # push (copy from Docker Hub)
crane pull "$IMG_REF" /tmp/alpine.tar
pass "image push/pull ok"

# --- §8.4 immutable-digest reference ----------------------------------------
step "2. resolve + pull by immutable digest  (§8.4)"
DIGEST="$(crane digest "$IMG_REF")"
echo "  digest: $DIGEST"
crane pull "${REG}/${NS}/alpine@${DIGEST}" /tmp/alpine-by-digest.tar
pass "pull-by-digest ok — this is the canonical release identity"

# --- §8.2 OCI Helm chart push/pull ------------------------------------------
step "3. OCI Helm chart push + pull  (§8.2)"
helm registry login "$REG" -u "$CI_USER" -p "$CI_PASS"
# TODO: point at a real chart; placeholder creates a trivial one.
helm create /tmp/demo >/dev/null
helm package /tmp/demo -d /tmp >/dev/null
helm push /tmp/demo-0.1.0.tgz "oci://${REG}/openkubes/charts"
helm pull "oci://${REG}/openkubes/charts/demo" --version 0.1.0 -d /tmp/pullchart
pass "helm OCI push/pull ok"

# --- §8.5 SBOM + Referrers API ----------------------------------------------
step "4. attach SBOM + discover via Referrers API  (§8.5, §4.6)"
syft "$IMG_REF" -o spdx-json > /tmp/sbom.spdx.json
oras attach --artifact-type application/spdx+json "$IMG_REF" \
  /tmp/sbom.spdx.json:application/json
echo "  referrers for $IMG_REF:"
oras discover -o tree "$IMG_REF"
pass "SBOM attached + discoverable via Referrers API"

# --- signature (optional) ---------------------------------------------------
step "5. (optional) signature as a referrer"
if command -v cosign >/dev/null; then
  cosign generate-key-pair || true   # dev key; ok-shared uses managed keys
  COSIGN_PASSWORD="" cosign sign --yes --key cosign.key "$IMG_REF" || \
    echo "  (cosign sign needs a tty/key setup — wire up in your run)"
else
  echo "  cosign not installed — skipping (add in your run)"
fi

# --- read-only identity check (§4.5) ----------------------------------------
step "6. verify read-only identity cannot push  (§4.5)"
crane auth login "$REG" -u "$PULL_USER" -p "$PULL_PASS"
if crane copy alpine:3.20 "${REG}/${NS}/should-fail:latest" 2>/dev/null; then
  echo "  ❌ puller was able to push — accessControl is wrong"; exit 1
else
  pass "puller correctly denied write"
fi

echo; echo "Phase-1 smoke complete. Record results in OK-137."
echo "Remember: GC (§4.7), scrub/storage-integrity, and metrics are checked"
echo "separately — see contract/tests/README.md for those steps."
