# OK-156 Phase 2: OpenClaw diagnostics consumer

This directory installs the complete read-only diagnostics path on `ok-local`:

```text
Open WebUI -> OpenClaw -> MCP adapter -> HTTP facade -> kagent -> Kubernetes API
```

OpenClaw is a contract consumer only. It has no Kubernetes RBAC, no mounted
ServiceAccount token, no `kubectl`, and can reach diagnostics only through the
three MCP tools. Kubernetes read access exists exclusively in the scoped kagent
tools pod, under a ServiceAccount limited to `get`, `list`, and `watch`; Secrets
and all write verbs are excluded.

The pinned upstream chart receives the small, committed patch in `patches/`.
It adds a global OpenClaw tool allowlist containing only the three generated MCP
tool names. Besides tightening the consumer boundary, this keeps the prompt and
Ollama KV cache within the resources available on `ok-local`.

## Selected images

The two OpenKubes images requested for this installation are pinned by both tag
and immutable multi-architecture index digest:

- `ghcr.io/openkubes/platform-diagnostics-mcp-adapter:0.1.0@sha256:a291bc1706a630c0b5c2452fd940440fb7e8b895bcc9582148f723dc07dd7029`
- `ghcr.io/openkubes/platform-diagnostics-facade:0.1.7@sha256:9babaeb0ebaf49c281d31b9aa184de821d7d0c64d8c60e50a8564e0da94a0cf3`

All other runtime images and source revisions are recorded in
`source-lock.yaml`.

Open WebUI chart `14.6.0` and image `0.9.5` are also pinned. The image uses an
immutable ARM64 manifest digest, matching the `ok-local` host architecture.
The chart-managed Redis `7.4.2-alpine3.21` side service is pinned by its verified
ARM64 digest as well.

## Compatibility note

Adapter `0.1.0` and facade `0.1.7` implement the older
`1.0.0-draft` diagnostics contract. They expose the required three functions,
but predate the later Contract-Consumer bearer token, request ID, and invocation
ID checks. Therefore this deployment does not pretend to provide that newer
application-level authentication. It still enforces the available boundaries:

- OpenClaw, the adapter, and the facade receive no Kubernetes credential.
- Only the scoped kagent tools ServiceAccount can read Kubernetes resources.
- The adapter has a namespace-selected ingress NetworkPolicy. Whether that
  policy is enforced depends on the CNI installed in the target cluster.

Moving to the newer authenticated contract requires published compatible image
versions; it must not be simulated by supplying unsupported environment values.

## Usage

Prerequisites are the completed Phase 0 and Phase 1 installation, the existing
Ollama service with the base `qwen3:4b` model, and Helm, kubectl, Git, OpenSSL,
and Python 3. `make install` additionally pulls the versioned official
`qwen3:4b-instruct-2507-q4_K_M` variant used by both Phase-2 consumers.

```bash
cd openclaw
make preflight
make install
make status
make verify
```

`make install` creates a random OpenClaw gateway token in `.token` with mode
`0600`. The file is ignored by Git and the token is never printed by the normal
workflow.

The install also creates a random password in `.webui-password` for the local
`ok156-e2e@localhost.local` acceptance operator. Open WebUI authentication stays
enabled. The operator configures Open WebUI's authenticated OpenAI-compatible
proxy to call the OpenClaw ClusterIP service with the gateway token. The previous
Open WebUI provider configuration is backed up locally in
`.webui-config-backup.json`; both files are mode `0600` and ignored by Git.
`make uninstall` restores that configuration and removes the acceptance
operator before deleting Phase-2 resources.

`ok-local` runs the Qwen3 4B Instruct 2507 Q4_K_M model on CPU. The non-thinking
variant is intentional: kagent 0.9.12 cannot forward Ollama's top-level
`think: false` API field, and the default thinking model can exhaust the local
CPU timeout before emitting a tool call. A full diagnosis performs serial LLM
turns and may take several minutes. The 30-minute consumer budget and 5-minute
per-request model keep-alive are intentional; they avoid false timeouts and
repeated model reloads while still releasing memory after the diagnostic burst.
OpenClaw's `diagnostics.stuckSessionAbortMs` is aligned to 30 minutes as well;
the default six-minute no-token watchdog incorrectly classifies long CPU prompt
prefill as a stuck model call.
OpenClaw and the Phase-2 kagent ModelConfig both use a 10240-token context so
Ollama reuses one runner; different context sizes would retain duplicate KV
caches and exceed the pod's 6 GiB memory limit. The root Ollama generator also
enables Flash Attention, `q8_0` KV-cache quantization, and one loaded model at a
time. For qwen3 this halves KV memory with negligible quality impact and prevents
KV growth from OOM-killing the server. `LLAMA_ARG_CACHE_RAM=512` bounds the
separate llama.cpp prompt cache to 512 MiB and `LLAMA_ARG_CTX_CHECKPOINTS=0`
disables context checkpoints, preventing unbounded growth while retaining useful
prefix caching on this CPU-only cluster.

The contract-facing kagent front agent calls the scoped read-only tools directly.
It exposes only `k8s_get_resources`; detailed workload observations are collected
by the facade through the same scoped read-only tool service. The facade calls
the Agent's A2A service directly because kagent 0.9.12's controller proxy has a
fixed 180-second upstream deadline, shorter than CPU inference on `ok-local`.
The specialist Agents remain installed as optional internal capabilities, but
the local CPU profile does not chain additional LLM delegations for normal
contract calls. This avoids long nested agent loops without changing RBAC or the
external three-function contract.

The verification proves:

- exact digest-pinned images and one ready replica per component;
- the facade health and readiness endpoints;
- exactly `get_platform_health`, `investigate_workload`, and
  `collect_diagnostic_evidence` on the MCP consumer path;
- provider read access and negative checks for writes and Secrets;
- absence of a Kubernetes token and `kubectl` in OpenClaw;
- authenticated Open WebUI proxying to OpenClaw rather than a direct test-only
  call to the OpenClaw gateway;
- all three contract functions through Open WebUI, OpenClaw, MCP, the facade and
  kagent;
- all three fixtures: healthy, ImagePullBackOff, and CrashLoopBackOff;
- exact cluster, namespace and workload argument preservation;
- per-scenario response times and sampled CPU/memory maxima.

The sanitized acceptance record is written to
`evidence/phase2-acceptance.json`. It contains timings, answer hashes, selected
contract sources and resource maxima, but no prompts, raw Kubernetes logs,
credentials, tokens or response bodies.

## Security and network boundaries

| Boundary | Credential / identity | Permitted path |
|---|---|---|
| Human or acceptance operator -> Open WebUI | Open WebUI login token | Open WebUI HTTP API only |
| Open WebUI -> OpenClaw | OpenClaw gateway token | `openclaw.openclaw.svc:18789/v1` |
| OpenClaw -> MCP adapter | No Kubernetes credential | The three allowlisted MCP functions only |
| MCP adapter -> facade | No Kubernetes credential; legacy contract has no bearer token | HTTP diagnostics endpoints only |
| Facade -> kagent / tool service | No Kubernetes credential | A2A agent endpoint and read-only MCP service |
| Tool service -> Kubernetes API | `platform-diagnostics/platform-diagnostics-tools` ServiceAccount | Explicit `get`, `list`, `watch`; no Secrets or writes |

The adapter ingress policy accepts traffic only from namespaces labelled
`openkubes.io/diagnostics-consumer=true`; the `openclaw` namespace has that
label. Open WebUI never connects to the adapter directly. DNS, OpenClaw-to-Ollama,
facade-to-kagent and tool-service-to-Kubernetes paths remain cluster-internal.
The Kubernetes NetworkPolicy is effective only when the target CNI enforces it;
RBAC remains the hard Kubernetes authorization boundary.

These credentials are deliberately different:

- the Open WebUI login token authenticates the consumer/user;
- the OpenClaw gateway token authenticates Open WebUI to OpenClaw;
- a later diagnostics Contract-Consumer bearer token is not implemented by the
  selected legacy adapter/facade images;
- the Kubernetes API ServiceAccount token exists only in the tool-service pod;
- each kagent Agent has a separate ServiceAccount with no Kubernetes read RBAC
  and mounts only an audience-limited (`aud: kagent`) token used to authenticate
  to kagent itself.

Recovery and clean lifecycle checks are available separately because they
restart or remove Phase-2 resources:

```bash
make restart-test
make lifecycle-test
```

To remove Phase 2 without touching the Phase-1 `kagent` installation or Ollama:

```bash
make uninstall
make verify-clean
```
