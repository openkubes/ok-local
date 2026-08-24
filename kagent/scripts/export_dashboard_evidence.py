#!/usr/bin/env python3
"""Export a sanitized, reviewable record of kagent Dashboard sessions."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen


SAFE_EVIDENCE_PREFIXES = (
    "Name:",
    "Namespace:",
    "Status:",
    "Image:",
    "State:",
    "Reason:",
    "Exit Code:",
    "Ready:",
    "Restart Count:",
    "Conditions:",
)


def parse_case(value: str) -> tuple[str, str, int]:
    try:
        name, remainder = value.split("=", 1)
        session_id, duration = remainder.rsplit(":", 1)
        return name, session_id, int(duration)
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError("expected NAME=SESSION_ID:DURATION_SECONDS") from error


def safe_lines(output: str) -> list[str]:
    selected: list[str] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line.startswith(SAFE_EVIDENCE_PREFIXES) or "BackOff" in line or "Failed" in line:
            selected.append(line)
    return selected


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:18083")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--case", action="append", type=parse_case, required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    summary: dict[str, object] = {"source": "kagent Dashboard", "cases": []}

    for name, session_id, duration in args.case:
        with urlopen(f"{args.base_url}/api/sessions/{session_id}", timeout=15) as response:
            raw = response.read()
        payload = json.loads(raw)
        data = payload["data"]
        events = sorted(data["events"], key=lambda item: item["created_at"])

        prompt = ""
        answer = ""
        tool_call: dict[str, object] = {}
        tool_evidence: list[str] = []
        usage: dict[str, object] = {}
        for event in events:
            event_data = json.loads(event["data"])
            content = event_data.get("Content") or {}
            for part in content.get("parts") or []:
                if content.get("role") == "user" and "text" in part:
                    prompt = part["text"]
                if content.get("role") == "model" and "text" in part:
                    answer = part["text"]
                    usage = event_data.get("UsageMetadata") or usage
                if "functionCall" in part:
                    tool_call = part["functionCall"]
                if "functionResponse" in part:
                    tool_output = part["functionResponse"].get("response", {}).get("output", "")
                    tool_evidence = safe_lines(tool_output)

        if tool_call.get("name") != "k8s_describe_resource":
            raise RuntimeError(f"{name}: missing k8s_describe_resource call")
        if not prompt or not answer or not tool_evidence:
            raise RuntimeError(f"{name}: incomplete session evidence")

        record = {
            "case": name,
            "session_id": session_id,
            "created_at": data["session"]["created_at"],
            "updated_at": data["session"]["updated_at"],
            "measured_dashboard_duration_seconds": duration,
            "raw_session_sha256": hashlib.sha256(raw).hexdigest(),
            "prompt": prompt,
            "tool_call": tool_call,
            "safe_tool_evidence": tool_evidence,
            "answer": answer,
            "usage": usage,
        }
        (output_dir / f"{name}.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        summary["cases"].append({
            "case": name,
            "session_id": session_id,
            "duration_seconds": duration,
            "tool": tool_call["name"],
            "result": "PASS",
        })

    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Exported {len(args.case)} sanitized Dashboard sessions to {output_dir}")


if __name__ == "__main__":
    main()
