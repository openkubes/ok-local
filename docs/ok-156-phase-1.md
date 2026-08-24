# OK-156 Phase 1 — kagent standalone acceptance evidence

Status: **PASS**, completed on 2026-08-24 on `ok-infra-local`. This document
covers Phase 1 only. Phase 2 and Phase 3 are not claimed as complete.

## Accepted installation

| Item | Verified value |
|---|---|
| Source revisions | `openkubes@6a0a56a4140dab3d55ade4a926c09412781e1407`, `ok-cluster@03381d239454d8bb7aacc65908e8d3512ee376c1` |
| kagent charts | CRDs `0.9.12`, kagent `0.9.12`, tools `0.2.1`; OCI digests checked against `source-lock.yaml` |
| Installed services | controller, PostgreSQL, Dashboard, kmcp controller, Kubernetes tool server |
| Agent | `cluster-inspector`, Go runtime, `Ready=True`, `Accepted=True` |
| tool server | `kagent-tool-server`, `Accepted=True` |
| effective Agent tool | `k8s_describe_resource` only |
| model | Ollama `qwen3:4b`, ID `359d7dd4bcda`, 4096-token context, `KEEP_ALIVE=0s` |
| fixtures | healthy, exit-42 CrashLoopBackOff, invalid-digest ImagePullBackOff |

All workload and fixture images are digest-pinned. The exact image references,
including the Go Agent and Ollama images, are recorded in
`kagent/source-lock.yaml` and are checked against the live workload specs by
`make -C kagent verify-phase1`.

## Dashboard diagnoses and tool-call proof

The three required diagnoses were performed interactively in the kagent
Dashboard after the final fresh installation. Each run completed without human
intervention after submission, visibly called `k8s_describe_resource` with the
exact pod and namespace, and grounded its conclusion in the returned Kubernetes
description.

| Case | Dashboard session | Time | Verified conclusion |
|---|---|---:|---|
| CrashLoopBackOff | `01a03314-79bc-70ad-b4da-5f768aec34cf` | 128 s | container terminated with `Error`/exit 42, restart and BackOff evidence, not Ready |
| ImagePullBackOff | `01a03316-e231-7056-aabe-aade4a272bc6` | 106 s | container waiting with `ImagePullBackOff`; intentionally invalid digest identified |
| Healthy | `01a03319-12da-75b1-8a52-17e016551b2b` | 105 s | pod Running, container Ready, and pod readiness conditions true |

The final PostgreSQL installation retains these sessions. Sanitized exports in
`kagent/evidence/dashboard-2026-08-24/` contain the prompt, exact function call,
selected non-sensitive tool evidence, answer, duration, session ID, and a
SHA-256 hash of the unfiltered local response. Secrets, tokens, cluster IPs, and
unfiltered tool output are not stored in the repository.

## Effective authorization

The live `kubectl auth can-i` checks were executed as the tool-server
ServiceAccount and passed:

| Check | Expected | Observed |
|---|---:|---:|
| get pods | yes | yes |
| patch deployments | no | no |
| delete deployments | no | no |
| get secrets | no | no |
| wildcard verb/resource | no | no |

This is the enforcement boundary. The Agent prompt and one-tool allowlist
reduce model behavior but are not relied upon for authorization.

## Restart and clean lifecycle

`make -C kagent restart-test` restarted both `kagent-controller` and
`cluster-inspector`, waited for both rollouts, reconciled the MCP server, and
reran the complete verifier. Result: **PASS in 20 seconds**, started at
`2026-08-24T09:17:41Z`.

`make -C kagent lifecycle-test` then performed a clean uninstall. Its assertion
found no remaining kagent namespaces, CRDs, or cluster RBAC. It recreated the
same digest-pinned profile from the repository inputs and reran the full live
verification. Result: **PASS in 150 seconds**, started at
`2026-08-24T09:18:31Z`.

The final state is the fresh, successful reinstall. Ollama, Open WebUI, their
PVCs, and both VMs are explicitly outside the kagent uninstall scope.

During that fresh install the controller exited twice in its first seconds
because the bundled PostgreSQL Service was not yet accepting connections. The
previous-container log records `database migration failed` with `connection
refused`; it does not show an OOM or configuration failure. Kubernetes restarted
the controller, Helm waited for readiness, and all subsequent health, session,
and MCP operations succeeded. The pinned chart exposes probe overrides but no
controller init-container hook, so this transient evaluation-database ordering
behavior is recorded rather than hidden behind an out-of-chart mutation.

## Performance and resource evidence

Idle snapshot after Dashboard acceptance:

| Workload | CPU | Memory |
|---|---:|---:|
| cluster-inspector Agent | 1m | 8 MiB |
| kagent controller | 1m | 21 MiB |
| kmcp controller | 2m | 13 MiB |
| PostgreSQL | 6m | 37 MiB |
| Kubernetes tool server | 1m | 10 MiB |
| Dashboard UI | 1m | 115 MiB |
| Ollama, model unloaded | 1m | 169 MiB |
| complete node | 81m | 2795 MiB |

A separate 59.110-second healthy-pod diagnosis sampled the node and Ollama
every five seconds. It completed with the exact `k8s_describe_resource` call
and a grounded healthy conclusion.

| Peak during probe | CPU | Memory |
|---|---:|---:|
| complete 4-CPU node | 3837m | 6246 MiB |
| Ollama | 3613m | 3620 MiB |

Persistent storage is 500 MiB for kagent PostgreSQL, 10 GiB for Ollama, and
2 GiB for Open WebUI. The Dashboard acceptance response times were 128, 106,
and 105 seconds. These CPU-only timings and peaks are local-environment
measurements, not production sizing guidance.

## Local model boundary

`qwen2.5:0.5b` was rejected after selecting the wrong Kubernetes resource in a
live diagnosis. `qwen3:4b` passed all three required Dashboard cases when the
prompt provided resource type, exact resource name, and namespace separately.
Bare fixture names can be interpreted as symptoms by this small model, so the
structured prompt format is part of the documented local procedure.

Broad namespace event requests exceeded the practical context/time envelope.
The accepted Agent is deliberately limited to targeted resource descriptions.
The Ollama 4096-token context and immediate unload prevent the earlier
exit-137/OOM condition observed with the default larger context.

## Phase 1 requirement audit

| Ticket requirement | Evidence | Result |
|---|---|---|
| pinned kagent Helm installation | source/chart/image locks plus live verifier | PASS |
| PostgreSQL/controller/Dashboard/tool server | live available Deployments and retained sessions | PASS |
| read-only Agent and three fixtures | Go Agent, one-tool policy, live fixture verification | PASS |
| diagnoses through Dashboard | three reviewed Dashboard sessions | PASS |
| tool calls in history | exact function calls in PostgreSQL/exported records | PASS |
| effective read-only identity | five live `auth can-i` checks | PASS |
| clean uninstall and identical reinstall | 150-second lifecycle test | PASS |
| controller/Agent restart and recovery | 20-second restart test plus full verifier | PASS |

Phase 1 is therefore complete against every requested ticket item. Phase 2
remains separately blocked by the unpublished OpenKubes images documented in
the Phase 0 report.
