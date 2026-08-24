#!/usr/bin/env python3
"""Run one grounded A2A probe while sampling local CPU and memory usage."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen


def run(args: list[str]) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{result.stderr}")
    return result.stdout.strip()


def quantity(value: str) -> int:
    if value.endswith("Mi"):
        return int(value[:-2])
    if value.endswith("m"):
        return int(value[:-1])
    return int(value)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--base-url", default="http://127.0.0.1:18083")
    parser.add_argument("--pod", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    kubectl = ["kubectl", "--kubeconfig", args.kubeconfig]
    samples: list[dict[str, object]] = []
    stop = threading.Event()

    def sample() -> None:
        while not stop.is_set():
            captured_at = datetime.now(timezone.utc).isoformat()
            node = run(kubectl + ["top", "node", "ok-infra-local", "--no-headers"]).split()
            ollama = run(kubectl + ["top", "pod", "ollama-0", "-n", "ollama", "--no-headers"]).split()
            samples.append({
                "captured_at": captured_at,
                "node_cpu_millicores": quantity(node[1]),
                "node_memory_mib": quantity(node[3]),
                "ollama_cpu_millicores": quantity(ollama[1]),
                "ollama_memory_mib": quantity(ollama[2]),
            })
            stop.wait(5)

    message_id = f"ok156-resource-{int(time.time())}"
    prompt = (
        f"Resource type: pod. Resource name: {args.pod}. Namespace: kagent-lab. "
        "Determine whether this pod is healthy and cite exact Kubernetes evidence. "
        "Use the Kubernetes tool before answering."
    )
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": message_id,
        "method": "message/send",
        "params": {
            "message": {
                "role": "user",
                "messageId": message_id,
                "parts": [{"kind": "text", "text": prompt}],
            }
        },
    }).encode()

    monitor = threading.Thread(target=sample, daemon=True)
    started_at = datetime.now(timezone.utc)
    monitor.start()
    try:
        request = Request(
            f"{args.base_url}/api/a2a/kagent/cluster-inspector",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with urlopen(request, timeout=240) as response:
            raw = response.read()
    finally:
        stop.set()
        monitor.join(timeout=15)
    finished_at = datetime.now(timezone.utc)

    payload = json.loads(raw)
    result = payload.get("result", {})
    if result.get("status", {}).get("state") != "completed":
        raise RuntimeError(f"A2A probe did not complete: {payload}")

    tool_call: dict[str, object] = {}
    answer = ""
    for event in result.get("history", []):
        for part in event.get("parts", []):
            data = part.get("data", {})
            if data.get("name") == "k8s_describe_resource" and "args" in data:
                tool_call = {"name": data["name"], "args": data["args"]}
            if part.get("kind") == "text" and event.get("role") == "agent":
                answer = part.get("text", "")
    if tool_call.get("args", {}).get("resource_name") != args.pod or not answer:
        raise RuntimeError("A2A probe did not produce the expected grounded result")

    record = {
        "message_id": message_id,
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "duration_seconds": round((finished_at - started_at).total_seconds(), 3),
        "raw_response_sha256": hashlib.sha256(raw).hexdigest(),
        "prompt": prompt,
        "tool_call": tool_call,
        "answer": answer,
        "samples": samples,
        "maxima": {
            key: max(int(sample[key]) for sample in samples)
            for key in ("node_cpu_millicores", "node_memory_mib", "ollama_cpu_millicores", "ollama_memory_mib")
        },
        "result": "PASS",
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"duration_seconds": record["duration_seconds"], "maxima": record["maxima"], "result": "PASS"}))


if __name__ == "__main__":
    main()
