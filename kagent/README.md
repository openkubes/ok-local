# OK-156 — Phase 1: kagent standalone (read-only)

This directory contains the reproducible Phase 1 installation and acceptance
workflow for kagent on `ok-infra-local`. It installs the PostgreSQL-backed
kagent controller, Dashboard, Go Agent, read-only Kubernetes tool server, and
the three required diagnostic fixtures.

The exact OK-129 source revisions, Helm chart digests, workload image digests,
fixture image digests, and local model settings are recorded in
[`source-lock.yaml`](source-lock.yaml).

## Security boundary

The `cluster-inspector` Agent exposes only `k8s_describe_resource`. Its effective
Kubernetes identity is the `kagent-tools` ServiceAccount, which may read normal
Kubernetes resources but may not write resources, read Secrets, or use wildcard
permissions. `make verify-kagent` checks this boundary against the live API
server; prompts and tool descriptions are not treated as security controls.

## Prerequisites

Run commands from the `ok-local` repository root. The `ok-infra-local` VM, its
K3s API tunnel, and Ollama must already be available. Apply the pinned Ollama
configuration and pull the selected model once:

```bash
make install-ollama
make -C kagent model-pull
```

The Phase 1 profile uses `qwen3:4b` (model ID `359d7dd4bcda`) with a 4096-token
context and `OLLAMA_KEEP_ALIVE=0s`. These limits prevent the 4B model and prompt
cache from exhausting the 6 GiB Ollama container limit on the local CPU VM.

Run the non-mutating checks before installation:

```bash
make -C kagent preflight
make -C kagent access-test
make -C kagent access-summary
make -C kagent chart-lock-check
make -C kagent render-check
```

These commands fetch the two pinned source revisions into the ignored
`kagent/.sources/` directory, build the pinned Python environment, verify the
cluster/model boundary, verify the OCI chart digests, and render all inputs.

## Install and verify

```bash
make -C kagent install
make -C kagent status
make -C kagent verify-kagent
```

`install` is idempotent. It also pins the fixture images, applies the targeted
describe-only Agent policy, reconciles the MCP server after its Deployment is
ready, and runs the complete live verifier. A successful verification ends
with `Phase 1 verification PASS` and proves:

- the expected Helm releases, image digests, model, and runtime settings;
- controller, PostgreSQL, Dashboard, Go Agent, and tool-server availability;
- Agent and `RemoteMCPServer` acceptance;
- one healthy fixture, one repeatedly failing exit-42 fixture, and one
  intentionally unpullable fixture;
- read access is allowed while writes, Secrets, and wildcards are denied.

K3s may temporarily display the repeatedly failing pod as `Error` between
restarts. The verifier checks the stronger evidence: repeated exit code 42 and
`BackOff` events. This is the expected CrashLoopBackOff behavior.

## Dashboard acceptance

Start the Dashboard port-forward:

```bash
make -C kagent dashboard
```

Open `http://127.0.0.1:8080`, select `cluster-inspector`, and use the current pod
names returned by:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig -n kagent-lab get pods
```

For each fixture, send a prompt in this form:

```text
Resource type: pod. Resource name: <pod-name>. Namespace: kagent-lab.
Determine whether this pod is healthy and cite exact Kubernetes evidence.
Use the Kubernetes tool before answering.
```

Confirm in the Dashboard history that each answer contains a visible
`k8s_describe_resource` call with the exact pod name and that the answer reports:

- the crash fixture's exit code 42, restart/BackOff evidence, and not-ready state;
- the image-pull fixture's `ImagePullBackOff` and invalid image digest;
- the healthy fixture's Running state, ready container, and ready conditions.

If port 8080 is already occupied, forward the UI directly on another local
port, for example:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig -n kagent \
  port-forward service/kagent-ui 18080:8080
```

The reviewed Dashboard runs and tool-call records are stored as sanitized JSON
under [`evidence/dashboard-2026-08-24`](evidence/dashboard-2026-08-24). The
exporter intentionally retains only diagnostic lines needed for acceptance:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig -n kagent \
  port-forward service/kagent-controller 18083:8083

# Run this in a second terminal while the controller port-forward is active.
python3 kagent/scripts/export_dashboard_evidence.py \
  --base-url http://127.0.0.1:18083 \
  --output-dir kagent/evidence/dashboard-2026-08-24 \
  --case crashloop=<session-id>:<duration-seconds> \
  --case imagepull=<session-id>:<duration-seconds> \
  --case healthy=<session-id>:<duration-seconds>
```

## Restart and lifecycle acceptance

Verify controller and Agent recovery without changing the profile:

```bash
make -C kagent restart-test
```

Verify clean removal followed by an identical fresh installation:

```bash
make -C kagent lifecycle-test
```

The lifecycle target removes the fixtures, releases, namespaces, CRDs, cluster
RBAC, and kagent PostgreSQL PVC; asserts that no kagent namespace/CRD/cluster
RBAC remains; then reinstalls and reruns the full Phase 1 verifier. Ollama,
Open WebUI, their PVCs, and the VMs remain outside this cleanup scope.

To leave kagent removed instead of reinstalled:

```bash
make -C kagent uninstall
make -C kagent verify-clean
```

## Tested local result

On 2026-08-24 all three Dashboard diagnoses passed. Controller/Agent restart
and recovery took 20 seconds, and clean uninstall plus identical reinstall took
150 seconds. A separate grounded probe completed in 59.1 seconds; during it the
4-CPU node peaked at 3837 millicores and 6246 MiB, while Ollama peaked at 3613
millicores and 3620 MiB. See
[`docs/ok-156-phase-1.md`](../docs/ok-156-phase-1.md) for the complete acceptance
record and the local model limitations.
