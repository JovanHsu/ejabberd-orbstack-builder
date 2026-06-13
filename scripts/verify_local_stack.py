#!/usr/bin/env python3
"""End-to-end verifier for the local ejabberd compose stack.

Checks:
1. ejabberd container is healthy and uses the expected vhost.
2. Two SQL-backed users can authenticate over raw XMPP/SASL PLAIN.
3. Online chat delivery works.
4. mod_message_filter calls the configured HTTP verifier.
5. mod_message_filter rewrite and reject paths work.
6. mod_offline_push calls the configured HTTP push gateway for offline messages.

No third-party Python dependencies. Uses docker CLI + raw XMPP over TCP.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import html
import http.server
import json
import os
import queue
import random
import socket
import socketserver
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class MockState:
    verify_requests: list[dict[str, Any]] = field(default_factory=list)
    notify_requests: list[dict[str, Any]] = field(default_factory=list)
    events: "queue.Queue[tuple[str, dict[str, Any]]]" = field(default_factory=queue.Queue)


class MockHandler(http.server.BaseHTTPRequestHandler):
    server: "MockServer"  # type: ignore[assignment]

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            payload = {"_raw": raw.decode("utf-8", "replace")}

        if self.path == "/verify":
            self.server.state.verify_requests.append(payload)
            self.server.state.events.put(("verify", payload))
            body = str(payload.get("body", ""))
            if "BLOCK_ME" in body:
                self._json({"pass": False, "code": "CONTENT_VIOLATION", "message": "blocked by verifier"})
            elif "REWRITE_ME" in body:
                self._json({"pass": True, "message": "rewritten by verifier"})
            else:
                self._json({"pass": True})
            return

        if self.path == "/notify":
            self.server.state.notify_requests.append(payload)
            self.server.state.events.put(("notify", payload))
            self._json({"success": True})
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args: Any) -> None:
        # Keep verifier output clean.
        return

    def _json(self, data: dict[str, Any]) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class MockServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, addr: tuple[str, int], state: MockState):
        super().__init__(addr, MockHandler)
        self.state = state


class XmppClient:
    def __init__(self, host: str, port: int, domain: str, username: str, password: str, resource: str):
        self.host = host
        self.port = port
        self.domain = domain
        self.username = username
        self.password = password
        self.resource = resource
        self.sock: socket.socket | None = None
        self.buffer = b""

    @property
    def jid(self) -> str:
        return f"{self.username}@{self.domain}/{self.resource}"

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=10)
        self.sock.settimeout(0.4)
        self._open_stream()
        self._read_until(b"</stream:features>", timeout=10)
        token = base64.b64encode(f"\0{self.username}\0{self.password}".encode()).decode()
        self._send(f"<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>{token}</auth>")
        data = self._read_until_any([b"</success>", b"/>"] , timeout=10)
        if b"<success" not in data:
            raise RuntimeError(f"SASL auth failed for {self.username}: {data!r}")
        self._open_stream()
        self._read_until(b"</stream:features>", timeout=10)
        self._send(
            "<iq type='set' id='bind1'>"
            "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
            f"<resource>{xml_escape(self.resource)}</resource>"
            "</bind></iq>"
        )
        data = self._read_until(b"</iq>", timeout=10)
        if b"type='result'" not in data and b'type="result"' not in data:
            raise RuntimeError(f"resource bind failed for {self.username}: {data!r}")
        self._send("<presence/>")
        time.sleep(0.2)

    def close(self) -> None:
        if self.sock:
            with contextlib.suppress(Exception):
                self._send("</stream:stream>")
            with contextlib.suppress(Exception):
                self.sock.close()
            self.sock = None

    def send_chat(self, to_jid: str, body: str, msg_id: str) -> None:
        self._send(
            f"<message to='{xml_escape(to_jid)}' type='chat' id='{xml_escape(msg_id)}'>"
            f"<body>{xml_escape(body)}</body>"
            "</message>"
        )

    def wait_for_text(self, needle: str, timeout: float = 5.0) -> str:
        data = self._read_until(needle.encode("utf-8"), timeout=timeout)
        return data.decode("utf-8", "replace")

    def read_for(self, seconds: float) -> str:
        end = time.time() + seconds
        chunks = [self.buffer]
        self.buffer = b""
        while time.time() < end:
            try:
                chunk = self._recv_once()
                if chunk:
                    chunks.append(chunk)
                else:
                    time.sleep(0.05)
            except TimeoutError:
                pass
        return b"".join(chunks).decode("utf-8", "replace")

    def _open_stream(self) -> None:
        self._send(
            f"<stream:stream to='{xml_escape(self.domain)}' "
            "xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' "
            "version='1.0'>"
        )

    def _send(self, text: str) -> None:
        assert self.sock is not None
        self.sock.sendall(text.encode("utf-8"))

    def _recv_once(self) -> bytes:
        assert self.sock is not None
        try:
            return self.sock.recv(65536)
        except socket.timeout as exc:
            raise TimeoutError from exc

    def _read_until(self, marker: bytes, timeout: float) -> bytes:
        return self._read_until_any([marker], timeout)

    def _read_until_any(self, markers: list[bytes], timeout: float) -> bytes:
        end = time.time() + timeout
        data = self.buffer
        self.buffer = b""
        while not any(marker in data for marker in markers):
            if time.time() > end:
                self.buffer = data
                raise TimeoutError(f"timed out waiting for {markers!r}; got {data[-1000:]!r}")
            try:
                chunk = self._recv_once()
                if not chunk:
                    raise RuntimeError("socket closed")
                data += chunk
            except TimeoutError:
                pass
        positions = [(data.index(marker) + len(marker), marker) for marker in markers if marker in data]
        idx, _ = min(positions, key=lambda item: item[0])
        out, self.buffer = data[:idx], data[idx:]
        return out


def xml_escape(value: str) -> str:
    return html.escape(value, quote=True)


def run(cmd: list[str], *, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess[str]:
    print("$ " + " ".join(cmd))
    return subprocess.run(cmd, text=True, capture_output=capture, check=check)


def docker_exec(container: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["docker", "exec", container, *args], check=check)


def wait_container_healthy(container: str, timeout: int = 90) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        cp = run(["docker", "inspect", container, "--format", "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}"])
        state = cp.stdout.strip()
        print(f"container state: {state}")
        if state.startswith("running") and "healthy" in state:
            return
        if state.startswith(("exited", "dead")):
            logs = run(["docker", "logs", "--tail", "120", container], check=False).stdout
            raise RuntimeError(f"{container} exited:\n{logs}")
        time.sleep(3)
    raise TimeoutError(f"container {container} did not become healthy")


def patch_module_config(container: str, mock_port: int) -> None:
    repo_root = Path(__file__).resolve().parents[1]
    verify_url = f"http://host.docker.internal:{mock_port}/verify"
    notify_url = f"http://host.docker.internal:{mock_port}/notify"

    wait_container_healthy(container)

    # Stop old loaded code first. Otherwise ejabberd may keep the already-loaded
    # BEAM in the Erlang code server even after recompiling the source.
    docker_exec(container, "ejabberdctl", "module_uninstall", "mod_message_filter", check=False)
    docker_exec(container, "ejabberdctl", "module_uninstall", "mod_offline_push", check=False)

    # The official image declares VOLUME /opt/ejabberd. Docker may preserve an
    # older anonymous volume across image rebuilds, hiding fresh module source
    # files baked into the image. Copy the checked-out sources into the running
    # container before module_install so the verifier tests the current tree.
    run([
        "docker", "cp",
        str(repo_root / "sae/modules/sources/mod_message_filter/src/mod_message_filter.erl"),
        f"{container}:/tmp/mod_message_filter.erl",
    ])
    run([
        "docker", "cp",
        str(repo_root / "sae/modules/sources/mod_offline_push/src/mod_offline_push.erl"),
        f"{container}:/tmp/mod_offline_push.erl",
    ])

    script = f"""
set -eu
mkdir -p \
  /opt/ejabberd/.ejabberd-modules/sources/mod_message_filter/src \
  /opt/ejabberd/.ejabberd-modules/sources/mod_message_filter/conf \
  /opt/ejabberd/.ejabberd-modules/sources/mod_offline_push/src \
  /opt/ejabberd/.ejabberd-modules/sources/mod_offline_push/conf
cp /tmp/mod_message_filter.erl /opt/ejabberd/.ejabberd-modules/sources/mod_message_filter/src/mod_message_filter.erl
cp /tmp/mod_offline_push.erl /opt/ejabberd/.ejabberd-modules/sources/mod_offline_push/src/mod_offline_push.erl
rm -rf /opt/ejabberd/.ejabberd-modules/mod_message_filter /opt/ejabberd/.ejabberd-modules/mod_offline_push
cat > /opt/ejabberd/.ejabberd-modules/sources/mod_message_filter/conf/mod_message_filter.yml <<'YAML'
modules:
  mod_message_filter:
    api_url: "{verify_url}"
    api_timeout: 5000
    api_key: ""
    filter_groupchat: false
    filter_types:
      - chat
      - normal
YAML
cat > /opt/ejabberd/.ejabberd-modules/sources/mod_offline_push/conf/mod_offline_push.yml <<'YAML'
modules:
  mod_offline_push:
    push_url: "{notify_url}"
    push_timeout: 5000
    push_api_key: ""
    push_enabled: true
    push_types:
      - chat
      - groupchat
    push_retry: 0
    push_async: false
YAML
"""
    docker_exec(container, "sh", "-lc", script)
    docker_exec(container, "ejabberdctl", "module_install", "mod_message_filter")
    docker_exec(container, "ejabberdctl", "module_install", "mod_offline_push")
    run(["docker", "restart", container])
    wait_container_healthy(container)


def register_users(container: str, domain: str, users: dict[str, str]) -> None:
    for user in users:
        docker_exec(container, "ejabberdctl", "unregister", user, domain, check=False)
    for user, password in users.items():
        docker_exec(container, "ejabberdctl", "register", user, domain, password)


def wait_event(state: MockState, kind: str, predicate, timeout: float = 8.0) -> dict[str, Any]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        remaining = max(0.05, deadline - time.time())
        try:
            got_kind, payload = state.events.get(timeout=remaining)
        except queue.Empty:
            break
        if got_kind == kind and predicate(payload):
            return payload
    raise TimeoutError(f"did not receive {kind} event matching predicate")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify local ejabberd communication and custom modules")
    parser.add_argument("--container", default="ejabberd-local-stack")
    parser.add_argument("--domain", default="xmpp.narsk.dpdns.org")
    parser.add_argument("--xmpp-host", default="127.0.0.1")
    parser.add_argument("--xmpp-port", type=int, default=16222)
    parser.add_argument("--mock-port", type=int, default=18088)
    parser.add_argument("--skip-restart", action="store_true", help="Do not restart ejabberd after patching module config")
    args = parser.parse_args()

    state = MockState()
    server = MockServer(("0.0.0.0", args.mock_port), state)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"mock verifier/push server listening on host port {args.mock_port}")

    try:
        patch_module_config(args.container, args.mock_port)
        wait_container_healthy(args.container)

        suffix = random.randint(1000, 9999)
        users = {
            f"alice_verify_{suffix}": "alice-pass-123",
            f"bob_verify_{suffix}": "bob-pass-123",
        }
        register_users(args.container, args.domain, users)
        alice_user, bob_user = list(users.keys())
        alice_jid = f"{alice_user}@{args.domain}"
        bob_jid = f"{bob_user}@{args.domain}"

        alice = XmppClient(args.xmpp_host, args.xmpp_port, args.domain, alice_user, users[alice_user], "alice")
        bob = XmppClient(args.xmpp_host, args.xmpp_port, args.domain, bob_user, users[bob_user], "bob")
        try:
            bob.connect()
            alice.connect()

            print("CASE 1: normal online chat delivery + filter API call")
            alice.send_chat(bob_jid, "hello normal verifier", "m-normal")
            incoming = bob.wait_for_text("hello normal verifier", timeout=8)
            assert "m-normal" in incoming, incoming
            wait_event(state, "verify", lambda p: p.get("body") == "hello normal verifier")
            print("OK normal delivery")

            print("CASE 2: filter rewrite path")
            alice.send_chat(bob_jid, "please REWRITE_ME now", "m-rewrite")
            incoming = bob.wait_for_text("rewritten by verifier", timeout=8)
            assert "please REWRITE_ME now" not in incoming, incoming
            wait_event(state, "verify", lambda p: p.get("body") == "please REWRITE_ME now")
            print("OK rewrite delivery")

            print("CASE 3: filter reject path")
            alice.send_chat(bob_jid, "please BLOCK_ME now", "m-block")
            wait_event(state, "verify", lambda p: p.get("body") == "please BLOCK_ME now")
            alice_error = alice.wait_for_text("policy-violation", timeout=8)
            assert "blocked by verifier" in alice_error or "policy-violation" in alice_error, alice_error
            with contextlib.suppress(Exception):
                bob.close()
            bob = XmppClient(args.xmpp_host, args.xmpp_port, args.domain, bob_user, users[bob_user], "bob-offline")
            bob.connect()
            bob_noise = bob.read_for(1.5)
            assert "please BLOCK_ME now" not in bob_noise, bob_noise
            print("OK reject converted to error stanza")

            print("CASE 4: offline push path")
            bob.close()
            time.sleep(0.5)
            alice.send_chat(bob_jid, "offline ping verifier", "m-offline")
            wait_event(state, "verify", lambda p: p.get("body") == "offline ping verifier")
            push = wait_event(
                state,
                "notify",
                lambda p: p.get("body") == "offline ping verifier" and str(p.get("to", "")).startswith(bob_jid),
                timeout=10,
            )
            assert push.get("type") == "offline_message", push
            print("OK offline push callback")
        finally:
            with contextlib.suppress(Exception):
                alice.close()
            with contextlib.suppress(Exception):
                bob.close()

        print("\nVERIFICATION PASSED")
        print(json.dumps({
            "domain": args.domain,
            "filter_requests": len(state.verify_requests),
            "push_requests": len(state.notify_requests),
            "verified": ["online_chat", "message_filter_pass", "message_filter_rewrite", "message_filter_reject", "offline_push"],
        }, ensure_ascii=False, indent=2))
        return 0
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"VERIFICATION FAILED: {exc}", file=sys.stderr)
        raise
