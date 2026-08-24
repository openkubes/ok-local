#!/usr/bin/env python3
"""Verify the live OK-156 Phase-1 contract without changing the cluster."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from typing import Any


EXPECTED_IMAGES = {
    ("ollama", "statefulset", "ollama", "ollama"): "docker.io/ollama/ollama@sha256:9d30908e41144b1f1da89b9d8e33c07e4aeb43ff41a8660241b1686e2cc330ad",
    ("kagent", "deployment", "kagent-controller", "controller"): "ghcr.io/kagent-dev/kagent/controller:0.9.12@sha256:d1ea7b70bb8d97de9f0774d44b598971c944b3ab4e88294b0bb78e59d1a63c15",
    ("kagent", "deployment", "cluster-inspector", "kagent"): "ghcr.io/kagent-dev/kagent/golang-adk:0.9.12@sha256:058ca9fc1a9ac994dde3354a7df56f5a6b93222572eda40ba295da2f0b6c101b",
    ("kagent", "deployment", "kagent-tools", "tools"): "ghcr.io/kagent-dev/kagent/tools:0.2.1@sha256:50b431281d3e32666f27a292962fd486aabaac157083a844d037c12137e353aa",
    ("kagent", "deployment", "kagent-ui", "ui"): "ghcr.io/kagent-dev/kagent/ui:0.9.12@sha256:1d5ada8d7f65a6b9ad28232463f9fd670c4c20875baa1c8008aaa1f1f988382e",
    ("kagent", "deployment", "kagent-kmcp-controller-manager", "manager"): "ghcr.io/kagent-dev/kmcp/controller:0.3.0@sha256:86ab878da25a639358aad18933c6b99e06a7ac34a801dc17fd657db0f28cee28",
    ("kagent", "deployment", "kagent-postgresql", "postgresql"): "docker.io/library/postgres:18.3-alpine@sha256:54451ecb8ab38c24c3ec123f2fd501303a3a1856a5c66e98cecf2460d5e1e9d7",
    ("kagent-lab", "deployment", "crashloop", "crashloop"): "docker.io/library/busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662",
    ("kagent-lab", "deployment", "healthy", "healthy"): "registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a",
    ("kagent-lab", "deployment", "imagepull", "imagepull"): "registry.k8s.io/pause@sha256:0000000000000000000000000000000000000000000000000000000000000000",
}


def command(args: list[str], *, check: bool = True) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr}")
    return result.stdout.strip()


def condition(resource: dict[str, Any], name: str) -> str | None:
    for item in resource.get("status", {}).get("conditions", []):
        if item.get("type") == name:
            return item.get("status")
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kubeconfig", required=True)
    args = parser.parse_args()
    kubectl = ["kubectl", "--kubeconfig", args.kubeconfig]
    failures: list[str] = []

    def get(namespace: str, kind: str, name: str) -> dict[str, Any]:
        return json.loads(command(kubectl + ["-n", namespace, "get", kind, name, "-o", "json"]))

    node = json.loads(command(kubectl + ["get", "node", "ok-infra-local", "-o", "json"]))
    if condition(node, "Ready") != "True":
        failures.append("ok-infra-local is not Ready")

    releases = json.loads(command(["helm", "--kubeconfig", args.kubeconfig, "-n", "kagent", "list", "-o", "json"]))
    release_charts = {item["name"]: item["chart"] for item in releases}
    if release_charts.get("kagent") != "kagent-0.9.12":
        failures.append(f"unexpected kagent chart: {release_charts.get('kagent')}")
    if release_charts.get("kagent-crds") != "kagent-crds-0.9.12":
        failures.append(f"unexpected kagent-crds chart: {release_charts.get('kagent-crds')}")

    for (namespace, kind, name, container_name), expected in EXPECTED_IMAGES.items():
        resource = get(namespace, kind, name)
        images = {item["name"]: item["image"] for item in resource["spec"]["template"]["spec"]["containers"]}
        actual = images.get(container_name)
        if actual != expected:
            failures.append(f"{namespace}/{kind}/{name} image is {actual!r}, expected {expected!r}")

    ollama = get("ollama", "statefulset", "ollama")
    env = {item["name"]: item.get("value") for item in ollama["spec"]["template"]["spec"]["containers"][0].get("env", [])}
    if env.get("OLLAMA_CONTEXT_LENGTH") != "4096":
        failures.append("OLLAMA_CONTEXT_LENGTH is not 4096")
    if env.get("OLLAMA_KEEP_ALIVE") != "0s":
        failures.append("OLLAMA_KEEP_ALIVE is not 0s")
    models = command(kubectl + ["-n", "ollama", "exec", "statefulset/ollama", "--", "ollama", "list"])
    if "qwen3:4b" not in models or "359d7dd4bcda" not in models:
        failures.append("qwen3:4b with expected model ID is not installed")

    model = get("kagent", "modelconfig", "default-model-config")
    if model.get("spec", {}).get("model") != "qwen3:4b":
        failures.append("ModelConfig does not select qwen3:4b")
    if model.get("spec", {}).get("ollama", {}).get("options", {}).get("num_ctx") != "4096":
        failures.append("ModelConfig num_ctx is not 4096")

    agent = get("kagent", "agent", "cluster-inspector")
    declarative = agent.get("spec", {}).get("declarative", {})
    if declarative.get("runtime") != "go":
        failures.append("cluster-inspector does not use the Go runtime")
    tool_names = declarative.get("tools", [{}])[0].get("mcpServer", {}).get("toolNames", [])
    if tool_names != ["k8s_describe_resource"]:
        failures.append(f"unexpected Agent tool allowlist: {tool_names}")
    for name in ("Accepted", "Ready"):
        if condition(agent, name) != "True":
            failures.append(f"cluster-inspector {name} is not True")

    mcp = get("kagent", "remotemcpserver", "kagent-tool-server")
    if condition(mcp, "Accepted") != "True":
        failures.append("kagent-tool-server Accepted is not True")

    for deployment in ("kagent-controller", "kagent-tools", "kagent-ui", "kagent-postgresql", "kagent-kmcp-controller-manager", "cluster-inspector"):
        if condition(get("kagent", "deployment", deployment), "Available") != "True":
            failures.append(f"deployment {deployment} is not Available")

    fixture_pods: dict[str, dict[str, Any]] = {}
    fixture_events: dict[str, list[dict[str, Any]]] = {}
    for app in ("crashloop", "imagepull"):
        pods: list[dict[str, Any]] = []
        events: list[dict[str, Any]] = []
        for _ in range(24):
            pods = json.loads(command(kubectl + ["-n", "kagent-lab", "get", "pods", "-l", f"app={app}", "-o", "json"]))["items"]
            if len(pods) == 1:
                uid = pods[0]["metadata"]["uid"]
                events = json.loads(command(kubectl + ["-n", "kagent-lab", "get", "events", "--field-selector", f"involvedObject.uid={uid}", "-o", "json"]))["items"]
                if any(item.get("reason") == "BackOff" for item in events):
                    break
            time.sleep(5)
        if len(pods) != 1:
            failures.append(f"expected one {app} pod, found {len(pods)}")
            continue
        fixture_pods[app] = pods[0]
        fixture_events[app] = events
        if not any(item.get("reason") == "BackOff" for item in events):
            failures.append(f"{app} has no BackOff event")

    if "crashloop" in fixture_pods:
        status = fixture_pods["crashloop"].get("status", {}).get("containerStatuses", [{}])[0]
        terminated = status.get("state", {}).get("terminated") or status.get("lastState", {}).get("terminated", {})
        if status.get("restartCount", 0) < 2 or terminated.get("exitCode") != 42:
            failures.append("crashloop does not show repeated exit code 42 failures")

    if "imagepull" in fixture_pods:
        status = fixture_pods["imagepull"].get("status", {}).get("containerStatuses", [{}])[0]
        reason = status.get("state", {}).get("waiting", {}).get("reason")
        if reason not in {"ErrImagePull", "ImagePullBackOff"}:
            failures.append(f"imagepull waiting reason is {reason!r}")

    healthy_pods = json.loads(command(kubectl + ["-n", "kagent-lab", "get", "pods", "-l", "app=healthy", "-o", "json"]))["items"]
    if len(healthy_pods) != 1 or healthy_pods[0].get("status", {}).get("phase") != "Running" or not healthy_pods[0].get("status", {}).get("containerStatuses", [{}])[0].get("ready"):
        failures.append("healthy fixture is not Running and Ready")

    identity = "--as=system:serviceaccount:kagent:kagent-tools"
    access_checks = [
        (["get", "pods", "--all-namespaces"], "yes"),
        (["patch", "deployments", "--all-namespaces"], "no"),
        (["delete", "deployments", "--all-namespaces"], "no"),
        (["get", "secrets", "--all-namespaces"], "no"),
        (["*", "*", "--all-namespaces"], "no"),
    ]
    for permission, expected in access_checks:
        actual = command(kubectl + ["auth", "can-i", *permission, identity], check=False)
        if actual != expected:
            failures.append(f"auth can-i {' '.join(permission)} returned {actual!r}, expected {expected!r}")

    if failures:
        print("Phase-1 verification FAILED:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("Phase-1 verification PASS")
    print("- pinned charts and all Phase-1 workload images")
    print("- qwen3:4b with 4096-token context and immediate unload")
    print("- Go Agent and targeted read-only tool allowlist")
    print("- CrashLoopBackOff, ImagePullBackOff, and healthy fixtures")
    print("- reads allowed; writes, Secrets, and wildcards denied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
