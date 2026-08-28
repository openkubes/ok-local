#!/usr/bin/env python3
"""Static and live acceptance checks for OK-156 Phase 2."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
WEBUI_EMAIL = "ok156-e2e@localhost.local"
WEBUI_URL = "http://openclaw.openclaw.svc.cluster.local:18789/v1"
WEBUI_IMAGE = "ghcr.io/open-webui/open-webui:0.9.5@sha256:e045bde3b004cc7f8c319412345eb56c87ea6ac57031534a31ca37ad5424beb3"
WEBUI_REDIS_IMAGE = "redis:7.4.2-alpine3.21@sha256:02419de7eddf55aa5bcf49efb74e88fa8d931b4d77c07eff8a6b2144472b6952"
EXPECTED_IMAGES = {
    "platform-diagnostics-mcp-adapter": "ghcr.io/openkubes/platform-diagnostics-mcp-adapter:0.1.0@sha256:a291bc1706a630c0b5c2452fd940440fb7e8b895bcc9582148f723dc07dd7029",
    "platform-diagnostics": "ghcr.io/openkubes/platform-diagnostics-facade:0.1.7@sha256:9babaeb0ebaf49c281d31b9aa184de821d7d0c64d8c60e50a8564e0da94a0cf3",
    "platform-diagnostics-tools": "ghcr.io/kagent-dev/kagent/tools:0.2.1@sha256:50b431281d3e32666f27a292962fd486aabaac157083a844d037c12137e353aa",
    "openclaw": "ghcr.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c",
}
TOOLS = {
    "get_platform_health",
    "investigate_workload",
    "collect_diagnostic_evidence",
}


def fail(message: str) -> None:
    raise AssertionError(message)


def static_checks() -> None:
    transport = (ROOT / "manifests/transport.yaml").read_text()
    provider = (ROOT / "manifests/provider.yaml").read_text()
    agents = (ROOT / "manifests/agents.yaml").read_text()
    values = (ROOT / "values.yaml").read_text()
    lock = (ROOT / "source-lock.yaml").read_text()
    verifier = (ROOT / "scripts/verify_phase2.py").read_text()
    root_makefile = (REPO_ROOT / "Makefile").read_text()

    rendered_inputs = "\n".join((transport, provider, values))
    for name, image in EXPECTED_IMAGES.items():
        if name == "openclaw":
            present = (
                "repository: ghcr.io/openclaw/openclaw" in values
                and "2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c" in values
            )
        else:
            present = image in rendered_inputs
        if not present:
            fail(f"missing digest-pinned image: {image}")
    if "contractVersion: 1.0.0-draft" not in values:
        fail("the selected legacy images must be declared as contract 1.0.0-draft")
    if "DIAGNOSTICS_BEARER_TOKEN" in transport:
        fail("adapter 0.1.0 does not implement the later bearer-token contract")
    if transport.count("automountServiceAccountToken: false") != 2:
        fail("facade and adapter must both disable ServiceAccount token mounting")
    if provider.count("name: platform-diagnostics-tools") < 4:
        fail("the Kubernetes-reading tool pod must use its dedicated ServiceAccount")
    if "name: openkubes-platform-agent\n  namespace: platform-diagnostics\nautomountServiceAccountToken: true" in provider:
        fail("the front Agent must not share the tool-service Kubernetes identity")
    phase2_makefile = (ROOT / "Makefile").read_text()
    if "harden-agent-serviceaccounts" not in phase2_makefile or "automountServiceAccountToken\":false" not in phase2_makefile:
        fail("kagent Agent ServiceAccounts must disable Kubernetes API token automounting")
    if agents.count("runtime: go") != 4:
        fail("all four agents must explicitly use the supported Go runtime")
    for forbidden in ("secrets", "create", "update", "patch", "delete"):
        if f"verbs: [{forbidden}" in provider or f", {forbidden}" in provider:
            fail(f"forbidden RBAC verb/resource found: {forbidden}")
    if "1.0.0-draft" not in lock:
        fail("compatibility contract note is missing from source-lock.yaml")
    if "qwen3:4b-instruct-2507-q4_K_M" not in provider or "qwen3:4b-instruct-2507-q4_K_M" not in values:
        fail("both Phase-2 model consumers must use the bounded Qwen3 4B instruct variant")
    if "http://openkubes-platform-agent.platform-diagnostics.svc.cluster.local:8080" not in transport:
        fail("facade must avoid the kagent 0.9.12 controller proxy deadline")
    if WEBUI_IMAGE.split(":", 1)[1] not in root_makefile or WEBUI_IMAGE.split("@", 1)[1] not in lock:
        fail("Open WebUI image must be digest-pinned in the root generator and source lock")
    if WEBUI_REDIS_IMAGE.split(":", 1)[1] not in root_makefile or WEBUI_REDIS_IMAGE.split("@", 1)[1] not in lock:
        fail("Open WebUI Redis image must be digest-pinned in the root generator and source lock")
    for required_case in ("healthy workload", "ImagePullBackOff workload", "CrashLoopBackOff workload", "diagnostic evidence"):
        if required_case not in verifier:
            fail(f"missing strict E2E scenario: {required_case}")
    print("PASS static: all digests, scenarios, legacy contract and credential boundaries")


class Cluster:
    def __init__(self, kubeconfig: str) -> None:
        self.base = ["kubectl", "--kubeconfig", kubeconfig]

    def run(self, *args: str, check: bool = True) -> str:
        result = subprocess.run(
            [*self.base, *args], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, check=False,
        )
        if check and result.returncode:
            fail(f"kubectl {' '.join(args)} failed:\n{result.stdout}")
        return result.stdout.strip()

    def deployment(self, namespace: str, name: str) -> dict:
        return json.loads(self.run("-n", namespace, "get", "deployment", name, "-o", "json"))

    def statefulset(self, namespace: str, name: str) -> dict:
        return json.loads(self.run("-n", namespace, "get", "statefulset", name, "-o", "json"))


def assert_deployment(cluster: Cluster, namespace: str, name: str, image: str) -> dict:
    deployment = cluster.deployment(namespace, name)
    status = deployment.get("status", {})
    if status.get("availableReplicas") != 1:
        fail(f"{namespace}/{name} is not available with exactly one replica")
    actual = deployment["spec"]["template"]["spec"]["containers"][0]["image"]
    if actual != image:
        fail(f"{namespace}/{name} image mismatch: {actual}")
    return deployment


def assert_all_pod_images_pinned(cluster: Cluster) -> None:
    for namespace in ("open-webui", "openclaw", "platform-diagnostics"):
        pods = json.loads(cluster.run("-n", namespace, "get", "pods", "-o", "json"))
        for pod in pods.get("items", []):
            spec = pod.get("spec", {})
            for container in [*spec.get("initContainers", []), *spec.get("containers", [])]:
                image = container.get("image", "")
                if "@sha256:" not in image:
                    fail(f"unpinned live image in {namespace}/{pod['metadata']['name']}: {image}")


def can_i(
    cluster: Cluster,
    verb: str,
    resource: str,
    namespace: str | None = None,
    service_account: str = "system:serviceaccount:platform-diagnostics:platform-diagnostics-tools",
) -> bool:
    args = [
        "auth", "can-i", verb, resource,
        f"--as={service_account}",
    ]
    if namespace:
        args += ["-n", namespace]
    return cluster.run(*args, check=False) == "yes"


WEBUI_CHAT = r'''
import json
import sys
import urllib.request

data = json.load(sys.stdin)

def request(path, body, token=None, timeout=30):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        "http://127.0.0.1:8080" + path,
        data=json.dumps(body).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read())

session = request("/api/v1/auths/signin", {"email": data["email"], "password": data["password"]})
result = request(
    "/openai/chat/completions",
    {"model": "openclaw/default", "messages": [{"role": "user", "content": data["prompt"]}], "stream": False},
    session["token"],
    timeout=1800,
)
print(json.dumps(result))
'''


def parse_cpu(value: str) -> int:
    return int(value[:-1]) if value.endswith("m") else int(float(value) * 1000)


def parse_memory(value: str) -> int:
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024}
    for suffix, multiplier in units.items():
        if value.endswith(suffix):
            return int(float(value[: -len(suffix)]) * multiplier)
    return int(value) // (1024 * 1024)


def sample_metrics(cluster: Cluster, maxima: dict[str, dict[str, int]]) -> None:
    output = cluster.run("top", "pods", "-A", "--no-headers", check=False)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        namespace, pod, cpu, memory = fields[:4]
        if namespace not in {"ollama", "open-webui", "openclaw", "platform-diagnostics"}:
            continue
        component = f"{namespace}/{pod}"
        values = maxima.setdefault(component, {"cpu_millicores": 0, "memory_mib": 0})
        values["cpu_millicores"] = max(values["cpu_millicores"], parse_cpu(cpu))
        values["memory_mib"] = max(values["memory_mib"], parse_memory(memory))


def chat_via_openwebui(cluster: Cluster, prompt: str, password: str) -> tuple[str, float, dict[str, dict[str, int]]]:
    payload = json.dumps({"email": WEBUI_EMAIL, "password": password, "prompt": prompt})
    command = [
        *cluster.base, "-n", "open-webui", "exec", "-i", "statefulset/open-webui", "-c", "open-webui",
        "--", "python", "-c", WEBUI_CHAT,
    ]
    holder: dict[str, subprocess.CompletedProcess[str]] = {}

    def invoke() -> None:
        holder["result"] = subprocess.run(
            command, input=payload, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    started = time.monotonic()
    maxima: dict[str, dict[str, int]] = {}
    worker = threading.Thread(target=invoke, daemon=True)
    worker.start()
    while worker.is_alive():
        sample_metrics(cluster, maxima)
        worker.join(5)
    duration = time.monotonic() - started
    result = holder["result"]
    if result.returncode:
        fail(f"Open WebUI request failed: {result.stderr.strip() or result.stdout.strip()}")
    if not maxima:
        fail("resource metrics were unavailable during the Open WebUI request")
    response = json.loads(result.stdout)
    return response["choices"][0]["message"]["content"], duration, maxima


def assert_answer(
    name: str,
    answer: str,
    source: str,
    required: tuple[str, ...],
    required_any: tuple[str, ...],
    forbidden: tuple[str, ...],
) -> None:
    normalized = answer.lower()
    expected_source = f"Source: platform-diagnostics/{source}"
    if answer.count("Source: platform-diagnostics/") != 1:
        fail(f"{name} answer must contain exactly one diagnostics source:\n{answer}")
    if expected_source not in answer:
        fail(f"{name} answer has the wrong source (expected {expected_source}):\n{answer}")
    missing = [term for term in required if term.lower() not in normalized]
    if missing:
        fail(f"{name} answer is missing expected facts {missing}:\n{answer}")
    if required_any and not any(term.lower() in normalized for term in required_any):
        fail(f"{name} answer needs one of {list(required_any)}:\n{answer}")
    present = [term for term in forbidden if term.lower() in normalized]
    if present:
        fail(f"{name} answer contains failure/default markers {present}:\n{answer}")


def live_checks(cluster: Cluster, e2e: bool, password: str, evidence_output: pathlib.Path | None) -> None:
    facade = assert_deployment(cluster, "platform-diagnostics", "platform-diagnostics", EXPECTED_IMAGES["platform-diagnostics"])
    adapter = assert_deployment(cluster, "platform-diagnostics", "platform-diagnostics-mcp-adapter", EXPECTED_IMAGES["platform-diagnostics-mcp-adapter"])
    assert_deployment(cluster, "platform-diagnostics", "platform-diagnostics-tools", EXPECTED_IMAGES["platform-diagnostics-tools"])
    openclaw = assert_deployment(cluster, "openclaw", "openclaw", EXPECTED_IMAGES["openclaw"])
    webui = cluster.statefulset("open-webui", "open-webui")
    if webui.get("status", {}).get("readyReplicas") != 1:
        fail("Open WebUI does not have exactly one ready replica")
    webui_image = webui["spec"]["template"]["spec"]["containers"][0]["image"]
    if webui_image != WEBUI_IMAGE:
        fail(f"Open WebUI image mismatch: {webui_image}")
    redis = cluster.deployment("open-webui", "open-webui-redis")
    redis_image = redis["spec"]["template"]["spec"]["containers"][0]["image"]
    if redis_image != WEBUI_REDIS_IMAGE:
        fail(f"Open WebUI Redis image mismatch: {redis_image}")
    assert_all_pod_images_pinned(cluster)

    tool_pods = json.loads(cluster.run(
        "-n", "platform-diagnostics", "get", "pods",
        "--field-selector", "spec.serviceAccountName=platform-diagnostics-tools", "-o", "json",
    )).get("items", [])
    if len(tool_pods) != 1 or tool_pods[0]["metadata"].get("labels", {}).get("app.kubernetes.io/name") != "platform-diagnostics-tools":
        fail("the Kubernetes-reading ServiceAccount must be used only by the tool-server pod")

    for name, deployment in (("facade", facade), ("adapter", adapter), ("openclaw", openclaw)):
        if deployment["spec"]["template"]["spec"].get("automountServiceAccountToken") is not False:
            fail(f"{name} mounts a Kubernetes ServiceAccount token")

    if not can_i(cluster, "get", "pods", "kagent-lab"):
        fail("provider ServiceAccount cannot read pods")
    for verb, resource in (("create", "pods"), ("patch", "deployments.apps"), ("delete", "pods"), ("get", "secrets"), ("list", "secrets")):
        if can_i(cluster, verb, resource, "kagent-lab"):
            fail(f"provider ServiceAccount unexpectedly may {verb} {resource}")
    if can_i(cluster, "*", "*", service_account="system:serviceaccount:platform-diagnostics:platform-diagnostics-tools"):
        fail("provider ServiceAccount unexpectedly has wildcard access")
    agent_accounts = (
        "system:serviceaccount:platform-diagnostics:openkubes-platform-agent",
        "system:serviceaccount:platform-diagnostics:kubernetes-agent",
        "system:serviceaccount:platform-diagnostics:cilium-agent",
        "system:serviceaccount:platform-diagnostics:observability-agent",
    )
    for account in (
        "system:serviceaccount:openclaw:openclaw",
        "system:serviceaccount:platform-diagnostics:default",
        *agent_accounts,
    ):
        if can_i(cluster, "get", "pods", "kagent-lab", account):
            fail(f"non-tool ServiceAccount unexpectedly may read pods: {account}")

    agent_pods = json.loads(cluster.run(
        "-n", "platform-diagnostics", "get", "pods",
        "-l", "app.kubernetes.io/managed-by=kagent", "-o", "json",
    ))
    if len(agent_pods.get("items", [])) != 4:
        fail("expected exactly four kagent-managed Agent pods")
    for pod in agent_pods["items"]:
        spec = pod["spec"]
        mounts = [
            mount
            for container in spec.get("containers", [])
            for mount in container.get("volumeMounts", [])
        ]
        if any(mount.get("mountPath") == "/var/run/secrets/kubernetes.io/serviceaccount" for mount in mounts):
            fail(f"agent pod mounts a Kubernetes API token: {pod['metadata']['name']}")
        projected = [
            source.get("serviceAccountToken", {})
            for volume in spec.get("volumes", [])
            for source in volume.get("projected", {}).get("sources", [])
            if "serviceAccountToken" in source
        ]
        if len(projected) != 1 or projected[0].get("audience") != "kagent":
            fail(f"agent pod must retain only the audience-limited kagent token: {pod['metadata']['name']}")

    cluster.run(
        "-n", "openclaw", "exec", "deployment/openclaw", "-c", "openclaw", "--", "sh", "-c",
        "test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token && ! command -v kubectl",
    )
    health = cluster.run(
        "-n", "openclaw", "exec", "deployment/openclaw", "-c", "openclaw", "--", "node", "-e",
        "Promise.all(['healthz','readyz'].map(p=>fetch('http://platform-diagnostics.platform-diagnostics.svc.cluster.local:8080/'+p).then(r=>{if(!r.ok)process.exit(1);return r.text()}))).then(x=>console.log(x.join(' ')))",
    )
    if "ok" not in health.lower():
        fail(f"facade health endpoints returned unexpected output: {health}")

    probe = cluster.run(
        "-n", "openclaw", "exec", "deployment/openclaw", "-c", "openclaw", "--",
        "node", "dist/index.js", "mcp", "probe", "platform-diagnostics", "--json",
    )
    probe_data = json.loads(probe)
    server = probe_data.get("servers", {}).get("platform-diagnostics", {})
    actual_tools = {
        name.removeprefix("platform-diagnostics__")
        for name in probe_data.get("tools", [])
    }
    if server.get("tools") != 3 or actual_tools != TOOLS:
        fail(f"MCP tool surface must be exactly {sorted(TOOLS)}, got {sorted(actual_tools)}\n{probe}")
    print("PASS live: Open WebUI, workloads, exact MCP surface, health and credential boundaries")

    if not e2e:
        return
    scenarios = (
        (
            "platform health",
            "Function=get_platform_health. Use the literal argument cluster=ok-infra-local. Call exactly this function once.",
            "get_platform_health",
            ("ok-infra-local", "healthy"),
            (),
            ("context deadline", "timed out", "provider unavailable", "cluster unavailable", "degraded", "node-pool", "etcd"),
        ),
        (
            "healthy workload",
            "Function=investigate_workload. Literal arguments: cluster=ok-infra-local, namespace=kagent-lab, workload=healthy, time_range=PT1H. Call exactly once.",
            "investigate_workload",
            ("healthy", "ready"),
            (),
            ("workload default", "no matching pods", "provider unavailable", "timed out"),
        ),
        (
            "ImagePullBackOff workload",
            "Function=investigate_workload. Literal arguments: cluster=ok-infra-local, namespace=kagent-lab, workload=imagepull, time_range=PT1H. Call exactly once.",
            "investigate_workload",
            ("imagepull", "pending"),
            ("imagepullbackoff", "errimagepull"),
            ("workload default", "no matching pods", "provider unavailable", "timed out"),
        ),
        (
            "CrashLoopBackOff workload",
            "Function=investigate_workload. Literal arguments: cluster=ok-infra-local, namespace=kagent-lab, workload=crashloop, time_range=PT1H. Call exactly once.",
            "investigate_workload",
            ("crashloop",),
            ("crashloopbackoff", "backoff", "restart", "exit code 42"),
            ("workload default", "workload kagent", "no matching pods", "provider unavailable", "timed out"),
        ),
        (
            "diagnostic evidence",
            "Function=collect_diagnostic_evidence. Literal arguments: cluster=ok-infra-local, namespace=kagent-lab, workload=imagepull, time_range=PT1H. Call exactly once.",
            "collect_diagnostic_evidence",
            ("imagepull", "events"),
            ("describe", "evidence"),
            ("workload default", "workload kagent", "no matching pods", "provider unavailable", "timed out"),
        ),
    )
    evidence = {
        "schema": "ok156-phase2-evidence-v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "entrypoint": "authenticated Open WebUI /openai/chat/completions",
        "scenarios": [],
        "resource_maxima": {},
    }
    for name, prompt, source, required, required_any, forbidden in scenarios:
        answer, duration, maxima = chat_via_openwebui(cluster, prompt, password)
        assert_answer(name, answer, source, required, required_any, forbidden)
        evidence["scenarios"].append({
            "name": name,
            "source": source,
            "duration_seconds": round(duration, 3),
            "answer_sha256": hashlib.sha256(answer.encode()).hexdigest(),
            "result": "PASS",
        })
        for component, values in maxima.items():
            current = evidence["resource_maxima"].setdefault(component, {"cpu_millicores": 0, "memory_mib": 0})
            current["cpu_millicores"] = max(current["cpu_millicores"], values["cpu_millicores"])
            current["memory_mib"] = max(current["memory_mib"], values["memory_mib"])
        print(f"PASS e2e via Open WebUI: {name} ({duration:.1f}s)")
    if evidence_output:
        evidence_output.parent.mkdir(parents=True, exist_ok=True)
        evidence_output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
        print(f"PASS evidence: {evidence_output}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kubeconfig")
    parser.add_argument("--static-only", action="store_true")
    parser.add_argument("--skip-e2e", action="store_true")
    parser.add_argument("--webui-password-file")
    parser.add_argument("--evidence-output")
    args = parser.parse_args()
    try:
        static_checks()
        if not args.static_only:
            if not args.kubeconfig:
                fail("--kubeconfig is required for live checks")
            if not args.webui_password_file:
                fail("--webui-password-file is required for live checks")
            password = pathlib.Path(args.webui_password_file).read_text().strip()
            if not password:
                fail("Open WebUI E2E password file is empty")
            live_checks(
                Cluster(args.kubeconfig),
                not args.skip_e2e,
                password,
                pathlib.Path(args.evidence_output) if args.evidence_output else None,
            )
    except (AssertionError, KeyError, OSError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
