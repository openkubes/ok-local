#!/usr/bin/env bash
# Prove GC reclamation and zot scrub integrity on the local composition.

set -euo pipefail

for command_name in crane curl jq kubectl oras; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done

LOCAL_PORT="${LOCAL_PORT:-5051}"
REG="localhost:${LOCAL_PORT}"
REG_SCHEME="${REG_SCHEME:-http}"
NAMESPACE="${NAMESPACE:-ok-registry}"
RELEASE="${RELEASE:-zot}"
RESULTS_DIR="${RESULTS_DIR:-contract/tests/results-lifecycle}"
GC_TIMEOUT="${GC_TIMEOUT:-180}"
SCRUB_TIMEOUT="${SCRUB_TIMEOUT:-180}"
GC_SETTLE_DELAY="${GC_SETTLE_DELAY:-12}"
: "${ADMIN_USER:?set ADMIN_USER}"
: "${ADMIN_PASS:?set ADMIN_PASS}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%M%Sz)}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zot-lifecycle.XXXXXX")"
PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

case "$RESULTS_DIR" in
  /*) ;;
  *) RESULTS_DIR="${PWD}/${RESULTS_DIR}" ;;
esac
RUN_RESULTS_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "$RUN_RESULTS_DIR"
exec > >(tee "${RUN_RESULTS_DIR}/summary.log") 2>&1

ORAS_FLAGS=()
if [[ "$REG_SCHEME" == "http" ]]; then
  ORAS_FLAGS+=(--plain-http)
fi

# Keep the lifecycle repositories lexically ahead of accumulated smoke and
# conformance evidence. zot scans repositories in storage order during startup
# GC, so this makes the bounded local proof deterministic even after many runs.
DISPOSABLE_REPO="000-lifecycle/disposable-${RUN_ID}"
RETAINED_REPO="000-lifecycle/retained-${RUN_ID}"
DISPOSABLE_REF="${REG}/${DISPOSABLE_REPO}:proof"
RETAINED_REF="${REG}/${RETAINED_REPO}:proof"

pass() { echo "  PASS: $*"; }
status_for() {
  local status
  if status="$(curl -sS -o /dev/null -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" "$1" 2>/dev/null)"; then
    printf '%s' "$status"
  else
    printf '000'
  fi
}
start_port_forward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  SERVICE="$(kubectl -n "$NAMESPACE" get service \
    --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=zot" \
    -o jsonpath='{.items[0].metadata.name}')"
  test -n "$SERVICE"
  kubectl -n "$NAMESPACE" port-forward "service/${SERVICE}" \
    "${LOCAL_PORT}:5000" >> "$WORKDIR/port-forward.log" 2>&1 &
  PF_PID=$!
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if [[ "$(status_for "${REG_SCHEME}://${REG}/v2/")" == 200 ]]; then
      return
    fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      cat "$WORKDIR/port-forward.log" >&2
      return 1
    fi
    sleep 1
  done
  echo "timed out waiting for lifecycle port-forward" >&2
  return 1
}

start_port_forward

printf '%s' "$ADMIN_PASS" | crane auth login "$REG" \
  --username "$ADMIN_USER" --password-stdin
printf '%s' "$ADMIN_PASS" | oras login "$REG" \
  --username "$ADMIN_USER" --password-stdin "${ORAS_FLAGS[@]}"

printf 'disposable lifecycle payload %s\n' "$RUN_ID" > "$WORKDIR/disposable.txt"
printf 'retained lifecycle payload %s\n' "$RUN_ID" > "$WORKDIR/retained.txt"

echo "1. Push disposable and retained artifacts"
(
  cd "$WORKDIR"
  oras push "$DISPOSABLE_REF" --artifact-type application/vnd.openkubes.lifecycle.v1 \
    "disposable.txt:application/octet-stream" "${ORAS_FLAGS[@]}" >/dev/null
  oras push "$RETAINED_REF" --artifact-type application/vnd.openkubes.lifecycle.v1 \
    "retained.txt:application/octet-stream" "${ORAS_FLAGS[@]}" >/dev/null
)

DISPOSABLE_MANIFEST="$(crane digest "$DISPOSABLE_REF")"
RETAINED_MANIFEST="$(crane digest "$RETAINED_REF")"
DISPOSABLE_BLOB="$(crane manifest "$DISPOSABLE_REF" | jq -r '.layers[0].digest')"
RETAINED_BLOB="$(crane manifest "$RETAINED_REF" | jq -r '.layers[0].digest')"

test "$(status_for "${REG_SCHEME}://${REG}/v2/${DISPOSABLE_REPO}/blobs/${DISPOSABLE_BLOB}")" = 200
test "$(status_for "${REG_SCHEME}://${REG}/v2/${RETAINED_REPO}/blobs/${RETAINED_BLOB}")" = 200
pass "both blobs are initially reachable"

echo "2. Delete only the disposable manifest"
crane delete "${REG}/${DISPOSABLE_REPO}@${DISPOSABLE_MANIFEST}"
test "$(status_for "${REG_SCHEME}://${REG}/v2/${DISPOSABLE_REPO}/manifests/${DISPOSABLE_MANIFEST}")" = 404
pass "disposable manifest deleted"

echo "3. Wait for garbage collection to reclaim the orphan"
sleep "$GC_SETTLE_DELAY"
kubectl -n "$NAMESPACE" rollout restart "statefulset/${RELEASE}"
kubectl -n "$NAMESPACE" rollout status "statefulset/${RELEASE}" --timeout=120s
start_port_forward
POD="$(kubectl -n "$NAMESPACE" get pod \
  --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=zot" \
  -o jsonpath='{.items[0].metadata.name}')"
test -n "$POD"
deadline=$((SECONDS + GC_TIMEOUT))
while (( SECONDS < deadline )); do
  disposable_status="$(status_for "${REG_SCHEME}://${REG}/v2/${DISPOSABLE_REPO}/blobs/${DISPOSABLE_BLOB}")"
  retained_status="$(status_for "${REG_SCHEME}://${REG}/v2/${RETAINED_REPO}/blobs/${RETAINED_BLOB}")"
  if [[ "$disposable_status" == 404 && "$retained_status" == 200 ]]; then
    break
  fi
  sleep 5
done
test "${disposable_status:-}" = 404
test "${retained_status:-}" = 200
pass "GC reclaimed the orphan and preserved the referenced blob"

echo "4. Wait for scrub to verify the retained repository"
deadline=$((SECONDS + SCRUB_TIMEOUT))
scrub_marker="scrub successfully completed for /var/lib/registry/${RETAINED_REPO}"
while (( SECONDS < deadline )); do
  kubectl -n "$NAMESPACE" logs "$POD" --since=10m > "$WORKDIR/zot.log"
  if grep -Fq "$scrub_marker" "$WORKDIR/zot.log"; then
    break
  fi
  sleep 5
done
grep -Fq "$scrub_marker" "$WORKDIR/zot.log"
if grep -F "\"image\":\"${RETAINED_REPO}\"" "$WORKDIR/zot.log" | \
    grep -Fq '"status":"affected"'; then
  echo "scrub reported affected content for ${RETAINED_REPO}" >&2
  exit 1
fi
test "$(status_for "${REG_SCHEME}://${REG}/v2/${RETAINED_REPO}/blobs/${RETAINED_BLOB}")" = 200
pass "scrub completed without affecting retained content"

{
  echo "disposable=${REG}/${DISPOSABLE_REPO}@${DISPOSABLE_MANIFEST}"
  echo "disposable_blob=${DISPOSABLE_BLOB}"
  echo "retained=${REG}/${RETAINED_REPO}@${RETAINED_MANIFEST}"
  echo "retained_blob=${RETAINED_BLOB}"
  echo "gc=PASS"
  echo "scrub=PASS"
  echo "result=PASS"
} > "${RUN_RESULTS_DIR}/results.env"

echo "Lifecycle contract complete: PASS"
echo "Evidence: ${RUN_RESULTS_DIR}"
