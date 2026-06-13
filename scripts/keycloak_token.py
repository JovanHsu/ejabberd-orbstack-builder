#!/usr/bin/env python3
"""Fetch a Keycloak access token for verifier use.

Reads password from stdin or KEYCLOAK_TEST_PASSWORD. Prints only JSON metadata by
 default, never the token. Use --print-token only when piping directly into a
 local verifier.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
import urllib.parse
import urllib.request


def post_token(base_url: str, realm: str, client_id: str, username: str, password: str) -> dict:
    url = f"{base_url.rstrip('/')}/realms/{realm}/protocol/openid-connect/token"
    data = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": client_id,
        "username": username,
        "password": password,
    }).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"content-type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())


def jwt_payload(token: str) -> dict:
    import base64
    parts = token.split(".")
    if len(parts) != 3:
        return {}
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode()).decode())


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default=os.getenv("KEYCLOAK_BASE_URL", "https://kc.pyramidtip.com"))
    p.add_argument("--realm", default=os.getenv("KEYCLOAK_REALM", "cadoo"))
    p.add_argument("--client-id", default=os.getenv("KEYCLOAK_CLIENT_ID", "cadoo-backend"))
    p.add_argument("--username", default=os.getenv("KEYCLOAK_TEST_USERNAME"))
    p.add_argument("--password-stdin", action="store_true")
    p.add_argument("--print-token", action="store_true")
    args = p.parse_args()
    if not args.username:
        raise SystemExit("missing --username or KEYCLOAK_TEST_USERNAME")
    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = os.getenv("KEYCLOAK_TEST_PASSWORD") or getpass.getpass("Keycloak password: ")
    token = post_token(args.base_url, args.realm, args.client_id, args.username, password)["access_token"]
    claims = jwt_payload(token)
    if args.print_token:
        print(token)
    else:
        safe = {
            "issuer": claims.get("iss"),
            "preferred_username": claims.get("preferred_username"),
            "sub_present": bool(claims.get("sub")),
            "exp": claims.get("exp"),
            "aud": claims.get("aud"),
        }
        print(json.dumps(safe, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
