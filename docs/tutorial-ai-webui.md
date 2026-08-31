# Runbook: Installing and Verifying OK-156 Locally

## Purpose

This runbook describes how to install and verify all parts of OK-156 from a fresh clone of the `ok-local` repository.


The complete diagnostic path is:

```text
Open WebUI
  → OpenClaw
  → MCP adapter
  → Platform Diagnostics facade
  → kagent
  → read-only Kubernetes tool server
  → Kubernetes API
```

---

## 1. Install Ollama

### 1.1 Deploy Ollama

```bash
cd ok-local
make install-ollama
```

The generated files under `ollama/` are ignored by Git.

### 1.2 Verify Ollama

```bash
make ollama-status
```

Alternatively:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n ollama get pods
```

The Ollama pod must be `Running` and ready.

### 1.3 Pull the kagent model

```bash
cd kagent
make -C kagent model-pull
```

This downloads the pinned `qwen3:4b` model. The download is approximately 2.5 GB.

Verify the model:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n ollama exec statefulset/ollama -- ollama list
```

The output must contain:

```text
qwen3:4b
```

---

## 2. Install Open WebUI

### 2.1 Install the Crossplane definition and composition

```bash
cd ok-local
make webui-setup
```

This generates local files under `platform/`. The directory is ignored by Git.

### 2.2 Deploy Open WebUI

```bash
make webui-deploy
```

The deployment can take several minutes.

### 2.3 Verify Open WebUI

```bash
make webui-status
```

Verify the workloads directly:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n open-webui get pods
```

Expected workloads include:

```text
open-webui-0          Running
open-webui-redis-*    Running
```

## 3. Run the kagent Preflight Checks

```bash
cd kagent
make -C kagent preflight
make -C kagent access-test
make -C kagent access-summary
make -C kagent chart-lock-check
make -C kagent render-check
```

These checks validate:

- Pinned source revisions
- Helm chart digests
- Container image digests
- The read-only access profile
- Kubernetes connectivity
- Ollama and the required model
- Manifest rendering

All commands must complete successfully.

## 4. Install kagent

```bash
make -C kagent install
```

This installs:

- kagent CRDs
- kagent controller
- PostgreSQL
- kagent Dashboard
- kagent Go Agent
- Read-only Kubernetes tool server
- `cluster-inspector`
- Healthy fixture
- ImagePullBackOff fixture
- CrashLoopBackOff fixture

## 5. Check the kagent Status

```bash
make -C kagent status
```

## 6. Verify kagent

```bash
make -C kagent verify-kagent
```

Expected final message:

```text
Phase 1 verification PASS
```

The verification proves:

- Required deployments are ready
- Container images are pinned
- All three diagnostic fixtures exist
- Kubernetes read access works
- Write operations are denied
- Secret access is denied
- Wildcard RBAC permissions are denied

Phase 1 is now complete.

---


## 7. Run the Openclaw Preflight Check

```bash
make -C openclaw preflight
```

The preflight check validates:

- Prerequisites are available
- `ok-infra-local` is reachable
- Open WebUI is ready
- Ollama and the base model are available
- Sources and images are pinned
- Manifests can be rendered
- Credential boundaries are correctly configured

## 8. Install Openclaw

```bash
make -C openclaw install
```

This command automatically performs the following operations:

1. Downloads the provided model.
2. Installs the read-only Kubernetes tool server.
3. Installs the dedicated tool ServiceAccount and RBAC.
4. Installs the four kagent Agents.
5. Disables Kubernetes API token auto-mounting for the Agents.
6. Installs the Platform Diagnostics facade.
7. Installs the MCP adapter.
8. Installs OpenClaw.
9. Creates the local Open WebUI acceptance user.
10. Configures Open WebUI to use OpenClaw.
11. Runs the complete Openclaq verification.

The command can take approximately 30–40 minutes because the local model runs on CPU.

## 9. Check the Openclaw Status

```bash
make -C openclaw status
```

Verify the Platform Diagnostics workloads:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n platform-diagnostics get pods
```

Verify OpenClaw:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n openclaw get pods
```

All pods must be `Running` and ready.

---

# Openclaw Verification

## 10. Run the Complete Verification

```bash
make -C openclaw verify
```

The test uses the real application path:

```text
Open WebUI
  → OpenClaw
  → MCP
  → Platform Diagnostics facade
  → kagent
  → Kubernetes API
```

The test can take approximately 30 minutes.

Expected final output:

```text
PASS static: all digests, scenarios, legacy contract and credential boundaries
PASS live: Open WebUI, workloads, exact MCP surface, health and credential boundaries
PASS e2e via Open WebUI: platform health
PASS e2e via Open WebUI: healthy workload
PASS e2e via Open WebUI: ImagePullBackOff workload
PASS e2e via Open WebUI: CrashLoopBackOff workload
PASS e2e via Open WebUI: diagnostic evidence
PASS evidence
```

The verification checks:

- Exactly three MCP functions are exposed
- Platform health works
- Healthy fixture diagnosis works
- ImagePullBackOff diagnosis works
- CrashLoopBackOff diagnosis works
- Diagnostic evidence collection works
- Kubernetes RBAC boundaries are correct
- Kubernetes token mounts are correct
- OpenClaw does not contain `kubectl`
- OpenClaw has no Kubernetes ServiceAccount token
- Container image digests are exact
- Response times are recorded
- CPU and memory maxima are recorded

---

# Manual Open WebUI Test

## 11. Start a Port Forward

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n open-webui port-forward service/open-webui 8080:80
```

Keep this terminal open.

## 12. Open Open WebUI

Open the following URL:

[http://localhost:8080](http://localhost:8080)

Use the following email address:

```text
ok156-e2e@localhost.local
```

Display the locally generated password:

```bash
cat openclaw/.webui-password
```

Select the following model:

```text
openclaw/default
```

## 13. Test Platform Health

```text
Check the health of cluster ok-infra-local.
```

## 14. Test the Healthy Fixture

```text
Investigate the healthy workload in namespace kagent-lab on cluster ok-infra-local.
```

## 15. Test the ImagePullBackOff Fixture

```text
Investigate the imagepull workload in namespace kagent-lab on cluster ok-infra-local.
```

## 16. Test the CrashLoopBackOff Fixture

```text
Investigate the crashloop workload in namespace kagent-lab on cluster ok-infra-local.
```

A response can take several minutes.

---

# Security Verification

## 17. Verify That the Tool Server Can Read Pods

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  auth can-i get pods \
  -n kagent-lab \
  --as=system:serviceaccount:platform-diagnostics:platform-diagnostics-tools
```

Expected result:

```text
yes
```

## 18. Verify That the OpenKubes Agent Cannot Read Pods

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  auth can-i get pods \
  -n kagent-lab \
  --as=system:serviceaccount:platform-diagnostics:openkubes-platform-agent
```

Expected result:

```text
no
```

## 19. Verify That OpenClaw Cannot Read Pods

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  auth can-i get pods \
  -n kagent-lab \
  --as=system:serviceaccount:openclaw:openclaw
```

Expected result:

```text
no
```

## 20. Verify That OpenClaw Has No Kubernetes Token or kubectl

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n openclaw exec deployment/openclaw -c openclaw -- \
  sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token && ! command -v kubectl'
```

The command must finish without output and return exit code `0`.

Check the exit code:

```bash
echo $?
```

Expected result:

```text
0
```

---

# Stability Verification

## 21. Run the Rolling Restart Test

```bash
make -C openclaw restart-test
```

The test restarts:

- Kubernetes tool server
- Four kagent Agents
- Platform Diagnostics facade
- MCP adapter
- OpenClaw

Expected final output:

```text
PASS static
PASS live
```

## 22. Run the Clean Lifecycle Test

```bash
make -C openclaw lifecycle-test
```

The lifecycle test:

1. Removes Phase 2 completely.
2. Verifies that Phase 2 was removed cleanly.
3. Reinstalls Phase 2 from the committed files.
4. Runs the complete end-to-end verification again.

The following components are not removed:

- Multipass virtual machines
- K3s
- Crossplane
- Ollama
- Open WebUI

---

# Acceptance Evidence

## 23. Inspect the Phase 2 Evidence

The sanitized Phase 2 evidence is stored at:

```text
openclaw/evidence/phase2-acceptance.json
```

Display it with:

```bash
jq . openclaw/evidence/phase2-acceptance.json
```

The evidence contains:

- Scenario names
- PASS or FAIL results
- Response hashes
- Response durations
- Maximum CPU consumption
- Maximum memory consumption
- The authenticated Open WebUI entry point

The evidence does not contain:

- Passwords
- Tokens
- Prompts
- Full model responses
- Kubernetes logs
- Kubernetes Secrets

---

# Git Safety Verification

## 24. Inspect the Working Tree

```bash
git status --short
```

The following local files and directories must not appear:

```text
*.kubeconfig
.tunnel-*
ollama/
platform/
kagent/.sources/
kagent/.venv/
kagent/.access.local/
openclaw/.sources/
openclaw/.token
openclaw/.webui-password
openclaw/.webui-config-backup.json
```

## 25. Preview What Git Would Stage

```bash
git add --dry-run .
```

The output must not contain:

- Kubeconfig files
- Tokens
- Passwords
- Local source checkouts
- Python virtual environments
- Generated Ollama manifests
- Generated Open WebUI manifests
- Temporary files
- Editor files
- Build caches

> `openclaw/evidence/phase2-acceptance.json` is intentionally versioned. It can appear as modified after a new acceptance run because it contains the latest sanitized test evidence.

---

# Troubleshooting

## Kubernetes API Is Not Reachable

Example error:

```text
Unable to connect to the server
```

Restart the virtual machines and tunnels:

```bash
make start
make tunnel-stop
make tunnels
make nodes-all
```

## An SSH Tunnel Already Exists

Stop the old tunnels:

```bash
make tunnel-stop
```

Start them again:

```bash
make tunnels
```

## Ollama Is Missing

```bash
cd ok-local
make install-ollama
make ollama-status
```

## The Required Model Is Missing

```bash
make -C kagent model-pull
make -C openclaw model
```

Verify the models:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n ollama exec statefulset/ollama -- ollama list
```

## Open WebUI Is Missing

```bash
cd ok-local
make webui-setup
make webui-deploy
make webui-status
```

## kagent Is Missing

```bash
make -C kagent install
make -C kagent verify-kagent
```

## Openclaw Is Partially Installed

The normal installation target is repeatable:

```bash
make -C openclaw install
```

For a complete clean reinstallation:

```bash
make -C openclaw lifecycle-test
```

## Local Port 8080 Is Already in Use

Use another local port:

```bash
kubectl --kubeconfig .tunnel-infra.kubeconfig \
  -n open-webui port-forward service/open-webui 18080:80
```

Open:

[http://localhost:18080](http://localhost:18080)

---

# Cleanup

## Remove Phase 2 Only

```bash
make -C openclaw uninstall
make -C openclaw verify-clean
```

This keeps:

- kagent
- Ollama
- Open WebUI
- Crossplane
- Kubernetes clusters
- Multipass virtual machines

## Remove kagent

```bash
make -C kagent uninstall
make -C kagent verify-clean
```

## Stop the Virtual Machines

```bash
make down
```

## Delete the Complete Local Environment

> **Warning:** This removes the local Multipass environment.

```bash
make clean
```

---
