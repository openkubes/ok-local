#!/usr/bin/env bash
# Prove the offline-transfer mechanics: export, verify, import, pull by digest.

set -euo pipefail

for command_name in crane oras shasum tar; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done

REG="${REG:-localhost:5050}"
RESULTS_DIR="${RESULTS_DIR:-contract/tests/results-offline}"
: "${CI_USER:?set CI_USER}"
: "${CI_PASS:?set CI_PASS}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%M%Sz)}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zot-offline.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

case "$RESULTS_DIR" in
  /*) ;;
  *) RESULTS_DIR="${PWD}/${RESULTS_DIR}" ;;
esac
RUN_RESULTS_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_RESULTS_DIR"
exec > >(tee "${RUN_RESULTS_DIR}/summary.log") 2>&1

SOURCE_REF="${REG}/openkubes/offline/source/alpine:${RUN_ID}"
DEST_REF="${REG}/openkubes/offline/imported/alpine:${RUN_ID}"
ARCHIVE="${WORKDIR}/alpine.tar"
EXPORT_LAYOUT="${WORKDIR}/export-layout"
VERIFY_LAYOUT="${WORKDIR}/verify-layout"
PULLED_LAYOUT="${WORKDIR}/pulled-layout"

pass() { echo "  PASS: $*"; }

printf '%s' "$CI_PASS" | crane auth login "$REG" \
  --username "$CI_USER" --password-stdin
printf '%s' "$CI_PASS" | oras login "$REG" \
  --username "$CI_USER" --password-stdin --plain-http

echo "1. Seed source artifact"
crane copy alpine:3.20 "$SOURCE_REF"
SOURCE_DIGEST="$(crane digest "$SOURCE_REF")"
pass "source digest ${SOURCE_DIGEST}"

echo "2. Export immutable source"
oras cp --from-plain-http --to-oci-layout \
  "${SOURCE_REF%:*}@${SOURCE_DIGEST}" "${EXPORT_LAYOUT}:${RUN_ID}"
EXPORTED_DIGEST="$(oras resolve --oci-layout "${EXPORT_LAYOUT}:${RUN_ID}")"
test "$EXPORTED_DIGEST" = "$SOURCE_DIGEST"
tar -C "$EXPORT_LAYOUT" -cf "$ARCHIVE" .
(
  cd "$WORKDIR"
  shasum -a 256 alpine.tar > alpine.tar.sha256
  shasum -a 256 -c alpine.tar.sha256
)
ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
mkdir -p "$VERIFY_LAYOUT"
tar -C "$VERIFY_LAYOUT" -xf "$ARCHIVE"
VERIFIED_DIGEST="$(oras resolve --oci-layout "${VERIFY_LAYOUT}:${RUN_ID}")"
test "$VERIFIED_DIGEST" = "$SOURCE_DIGEST"
pass "OCI layout digest and transfer archive SHA-256 verified"

echo "3. Import the verified archive"
oras cp --from-oci-layout --to-plain-http \
  "${VERIFY_LAYOUT}:${RUN_ID}" "$DEST_REF"
IMPORTED_DIGEST="$(oras resolve --plain-http "$DEST_REF")"
test "$IMPORTED_DIGEST" = "$SOURCE_DIGEST"
pass "import preserved manifest digest"

echo "4. Pull the imported artifact by immutable digest"
oras cp --from-plain-http --to-oci-layout \
  "${DEST_REF%:*}@${IMPORTED_DIGEST}" "${PULLED_LAYOUT}:verified"
PULLED_DIGEST="$(oras resolve --oci-layout "${PULLED_LAYOUT}:verified")"
test "$PULLED_DIGEST" = "$SOURCE_DIGEST"
pass "pull-by-digest preserved content identity"

{
  echo "source=${SOURCE_REF%:*}@${SOURCE_DIGEST}"
  echo "archive_sha256=${ARCHIVE_SHA256}"
  echo "destination=${DEST_REF%:*}@${IMPORTED_DIGEST}"
  echo "result=PASS"
} > "${RUN_RESULTS_DIR}/results.env"

echo "Offline-transfer mechanics complete: PASS"
echo "Evidence: ${RUN_RESULTS_DIR}"
