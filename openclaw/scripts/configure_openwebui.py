#!/usr/bin/env python3
"""Configure the pinned local Open WebUI as an authenticated OpenClaw consumer."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys


EMAIL = "ok156-e2e@localhost.local"
OPENCLAW_URL = "http://openclaw.openclaw.svc.cluster.local:18789/v1"

REMOTE = r'''
import asyncio
import json
import sys
import urllib.request

from open_webui.models.auths import Auths
from open_webui.models.users import Users
from open_webui.utils.auth import get_password_hash

data = json.load(sys.stdin)
email = data["email"]
password = data["password"]

async def ensure_user():
    user = await Users.get_user_by_email(email)
    hashed = get_password_hash(password)
    if user:
        if not await Auths.update_user_password_by_id(user.id, hashed):
            raise RuntimeError("could not rotate Open WebUI E2E password")
        if not await Users.update_user_role_by_id(user.id, "admin"):
            raise RuntimeError("could not set Open WebUI E2E role")
    else:
        user = await Auths.insert_new_auth(
            email=email,
            password=hashed,
            name="OK-156 E2E Operator",
            role="admin",
        )
        if not user:
            raise RuntimeError("could not create Open WebUI E2E operator")

async def delete_user():
    user = await Users.get_user_by_email(email)
    if user and not await Auths.delete_auth_by_id(user.id):
        raise RuntimeError("could not remove Open WebUI E2E operator")

def request(path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    encoded = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:8080" + path,
        data=encoded,
        headers=headers,
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read())

if data["action"] == "configure":
    asyncio.run(ensure_user())
    session = request("/api/v1/auths/signin", {"email": email, "password": password})
    token = session["token"]
    previous = request("/openai/config", token=token)
    desired = {
        "ENABLE_OPENAI_API": True,
        "OPENAI_API_BASE_URLS": [data["openclaw_url"]],
        "OPENAI_API_KEYS": [data["gateway_token"]],
        "OPENAI_API_CONFIGS": {},
    }
    updated = request("/openai/config/update", desired, token)
    if updated["OPENAI_API_BASE_URLS"] != [data["openclaw_url"]]:
        raise RuntimeError("Open WebUI did not retain the OpenClaw endpoint")
    print(json.dumps({"status": "configured", "backup": previous if data["capture_backup"] else None}))
elif data["action"] == "restore":
    asyncio.run(ensure_user())
    session = request("/api/v1/auths/signin", {"email": email, "password": password})
    token = session["token"]
    restored = request("/openai/config/update", data["backup"], token)
    if restored["OPENAI_API_BASE_URLS"] != data["backup"]["OPENAI_API_BASE_URLS"]:
        raise RuntimeError("Open WebUI configuration restore did not stick")
    asyncio.run(delete_user())
    print(json.dumps({"status": "restored"}))
else:
    raise RuntimeError("unsupported action")
'''


def remote(kubeconfig: str, payload: dict) -> dict:
    command = [
        "kubectl", "--kubeconfig", kubeconfig, "-n", "open-webui", "exec", "-i",
        "statefulset/open-webui", "-c", "open-webui", "--", "env",
        "WEBUI_SECRET_KEY=ok156-cli-import-only", "python", "-c", REMOTE,
    ]
    result = subprocess.run(
        command,
        input=json.dumps(payload),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout)


def read_secret(path: pathlib.Path) -> str:
    value = path.read_text().strip()
    if not value:
        raise RuntimeError(f"empty local secret file: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--gateway-token-file")
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--backup-file", required=True)
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    password_file = pathlib.Path(args.password_file)
    backup_file = pathlib.Path(args.backup_file)
    try:
        if args.restore:
            if not backup_file.exists():
                raise RuntimeError("Open WebUI backup is missing; refusing a destructive guessed restore")
            payload = {
                "action": "restore",
                "email": EMAIL,
                "password": read_secret(password_file),
                "backup": json.loads(backup_file.read_text()),
            }
            remote(args.kubeconfig, payload)
            backup_file.unlink()
            print("PASS Open WebUI configuration restored and E2E operator removed")
            return 0
        if not args.gateway_token_file:
            raise RuntimeError("--gateway-token-file is required when configuring")
        payload = {
            "action": "configure",
            "email": EMAIL,
            "password": read_secret(password_file),
            "gateway_token": read_secret(pathlib.Path(args.gateway_token_file)),
            "openclaw_url": OPENCLAW_URL,
            "capture_backup": not backup_file.exists(),
        }
        result = remote(args.kubeconfig, payload)
        if result.get("backup") is not None:
            backup_file.write_text(json.dumps(result["backup"], indent=2) + "\n")
            os.chmod(backup_file, 0o600)
        print("PASS Open WebUI authenticated OpenClaw connection configured")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
