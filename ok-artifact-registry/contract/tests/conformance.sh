#!/usr/bin/env bash
# Run the upstream OCI Distribution Spec conformance suite against local zot.

set -euo pipefail

command -v docker >/dev/null || {
  echo "docker is required for the OCI conformance suite" >&2
  exit 1
}

REG="${REG:-host.docker.internal:5050}"
REG_SCHEME="${REG_SCHEME:-http}"
CONFORMANCE_IMAGE="${CONFORMANCE_IMAGE:-ghcr.io/opencontainers/distribution-spec/conformance:main}"
CONFORMANCE_PLATFORM="${CONFORMANCE_PLATFORM:-linux/amd64}"
RESULTS_DIR="${RESULTS_DIR:-contract/tests/results}"

: "${ADMIN_USER:?set ADMIN_USER}"
: "${ADMIN_PASS:?set ADMIN_PASS}"

case "$RESULTS_DIR" in
  /*) ;;
  *) RESULTS_DIR="${PWD}/${RESULTS_DIR}" ;;
esac

# OCI repository names must be lowercase; keep the timestamp sortable.
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%M%Sz)}"
RUN_RESULTS_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_RESULTS_DIR"

case "$REG_SCHEME" in
  http) DEFAULT_OCI_TLS=disabled ;;
  https) DEFAULT_OCI_TLS=enabled ;;
  *) echo "REG_SCHEME must be http or https" >&2; exit 1 ;;
esac

export OCI_REGISTRY="$REG"
export OCI_TLS="${OCI_TLS:-$DEFAULT_OCI_TLS}"
export OCI_REPO1="${OCI_REPO1:-openkubes/conformance/${RUN_ID}}"
export OCI_REPO2="${OCI_REPO2:-openkubes/conformance-cross/${RUN_ID}}"
export OCI_USERNAME="$ADMIN_USER"
export OCI_PASSWORD="$ADMIN_PASS"
export OCI_VERSION="${OCI_VERSION:-stable}"
export OCI_RESULTS_DIR=/results
export OCI_LOG="${OCI_LOG:-warn}"

# Explicitly exercise every API in the four contract categories. Optional
# upload-cancel and tag-parameter behavior retain the stable-suite defaults.
export OCI_API_PULL=true
export OCI_API_PUSH=true
export OCI_API_BLOBS_ATOMIC=true
export OCI_API_BLOBS_DELETE=true
export OCI_API_BLOBS_MOUNT_ANONYMOUS=true
export OCI_API_MANIFESTS_ATOMIC=true
export OCI_API_MANIFESTS_DELETE=true
export OCI_API_TAGS_ATOMIC=true
export OCI_API_TAGS_DELETE=true
export OCI_API_TAGS_LIST=true
export OCI_API_REFERRER=true

echo "OCI conformance target: ${REG_SCHEME}://${OCI_REGISTRY}"
echo "OCI conformance repositories: ${OCI_REPO1}, ${OCI_REPO2}"
echo "Evidence directory: ${RUN_RESULTS_DIR}"

docker run --rm \
  --platform "$CONFORMANCE_PLATFORM" \
  --add-host host.docker.internal:host-gateway \
  -v "${RUN_RESULTS_DIR}:/results" \
  -e OCI_REGISTRY \
  -e OCI_TLS \
  -e OCI_REPO1 \
  -e OCI_REPO2 \
  -e OCI_USERNAME \
  -e OCI_PASSWORD \
  -e OCI_VERSION \
  -e OCI_RESULTS_DIR \
  -e OCI_LOG \
  -e OCI_API_PULL \
  -e OCI_API_PUSH \
  -e OCI_API_BLOBS_ATOMIC \
  -e OCI_API_BLOBS_DELETE \
  -e OCI_API_BLOBS_MOUNT_ANONYMOUS \
  -e OCI_API_MANIFESTS_ATOMIC \
  -e OCI_API_MANIFESTS_DELETE \
  -e OCI_API_TAGS_ATOMIC \
  -e OCI_API_TAGS_DELETE \
  -e OCI_API_TAGS_LIST \
  -e OCI_API_REFERRER \
  "$CONFORMANCE_IMAGE"
