# Local ejabberd stack verification

This directory verifies the local compose stack:

- `ejabberd-local-stack`
- `ejabberd-local-postgres`
- `ejabberd-local-redis`

The verifier uses only the Python standard library plus Docker CLI. No XMPP dependency is required.

## Start local stack

```bash
cd /Users/xujian/workspace/ejabberd-orbstack-builder
cp local/.env.local.example local/.env.local

docker compose --env-file local/.env.local -f docker-compose.local.yml up -d
```

## Run verification

```bash
python3 scripts/verify_local_stack.py
```

Defaults:

```text
container: ejabberd-local-stack
domain: xmpp.narsk.dpdns.org
XMPP: 127.0.0.1:16222
mock HTTP callback server: 0.0.0.0:18088
```

## What it checks

1. Container is running and healthy.
2. Two SQL-backed users can be registered by `ejabberdctl`.
3. Both users can authenticate over raw XMPP SASL PLAIN.
4. Normal online chat is delivered.
5. `mod_message_filter` calls the HTTP verifier.
6. `mod_message_filter` rewrite path works.
7. `mod_message_filter` reject path returns an XMPP error stanza instead of crashing c2s.
8. `mod_offline_push` calls the HTTP push gateway for an offline message.

Successful output ends with:

```json
{
  "domain": "xmpp.narsk.dpdns.org",
  "filter_requests": 4,
  "push_requests": 1,
  "verified": [
    "online_chat",
    "message_filter_pass",
    "message_filter_rewrite",
    "message_filter_reject",
    "offline_push"
  ]
}
```

## Important implementation notes

The official ProcessOne image declares:

```text
VOLUME /opt/ejabberd
```

Docker may preserve an anonymous volume across image rebuilds. That can hide freshly baked module sources in a new image.

For deterministic tests, the verifier copies the current checked-out module sources into the running container before `ejabberdctl module_install`.

The verifier also patches module config to point both custom modules at its local mock HTTP server:

```text
mod_message_filter -> http://host.docker.internal:18088/verify
mod_offline_push   -> http://host.docker.internal:18088/notify
```

## Bugs caught by the verifier

- `jiffy:encode/decode` was not available in the official ejabberd image. Fixed by using `misc:json_encode/json_decode`.
- `#stanza_error.text` must be a list of `#text{}` records, not a single record.
- `user_send_packet` is a fold hook. Returning `{stop, drop}` crashes c2s. Fixed by returning a message stanza of type `error`.
- `offline_message_hook` in ejabberd 26 calls the custom hook with one Acc argument. Fixed `mod_offline_push` to export and implement `push_offline_message/1`.
