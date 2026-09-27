# DirectorLink relay protocol (v0, proof of concept)

The relay lets the app reach a home from anywhere without opening anything on the home network:
the **driver** keeps one outgoing WebSocket (TLS, port 443) to `api.directorlink.io`, and requests
for that home travel over it. This document is the contract between `driver/src/cloud/` and
`cloud/`. Version 0 exists to prove the connection on a real controller; accounts, invitations and
the app come later (ADR-027).

## Identity of a home

When **Remote Access** is switched on the first time, the driver creates and keeps (encrypted, in
its persistent data):

- `home_id` — 32 hex characters, random. Not secret; shown shortened in Composer.
- `home_secret` — 64 hex characters, random. Never logged, never shown.

Version 0 uses *trust on first use*: the relay stores the SHA-256 of the first secret it sees for a
`home_id` and afterwards only accepts that secret. (Later, claiming a home with a pairing code while
signed in replaces this.)

## Connecting

```
GET /relay/connect HTTP/1.1
Host: api.directorlink.io
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64 of 16 random bytes>
Sec-WebSocket-Version: 13
Authorization: Bearer <home_secret>
X-DirectorLink-Home: <home_id>
X-DirectorLink-Version: <driver version>
User-Agent: DirectorLink/<driver version>
```

- `101 Switching Protocols` — connected. One driver connection per home: a new one replaces the
  previous (the relay closes the old socket with code 4000, reason `replaced`).
- `400` — missing or malformed headers; `401` — wrong secret for this `home_id`. Problem Details
  JSON (`application/problem+json`) with a `code`.

The driver reconnects after a lost connection with backoff: 5 s, 10 s, 30 s, then every 60 s.

## Messages

All frames are **text**. Apart from the keep-alive words below, each is one JSON object with a
`type`.

| Direction | Message | Meaning |
| --- | --- | --- |
| driver → relay | `ping` (plain text) | Keep-alive, every 25 s. |
| relay → driver | `pong` (plain text) | Answer to `ping`. The relay answers without waking its code (hibernation auto-response). |
| driver → relay | `{"type":"hello","home":"<home_id>","version":"0.9.0"}` | First message after connecting. |
| relay → driver | `{"type":"request","id":"<id>","method":"GET","path":"/v1/lights?room_id=10","body":null}` | Run an API request. `path` includes the query string; `body` is a JSON string or `null`. |
| driver → relay | `{"type":"response","id":"<id>","status":200,"content_type":"application/json; charset=utf-8","body":"<text>"}` | The API's answer, byte for byte. Binary answers (camera pictures) use `"body_base64"` instead of `"body"`. |

If the driver hears nothing (not even `pong`) for 60 s, it drops the connection and reconnects.
The relay answers `504` to its caller when a response takes longer than 15 s.

## What a relayed request may do (version 0)

- The relay forwards only `GET` requests.
- The driver runs every relayed request as a principal with role **viewer**, whatever the relay
  sends: reads only, no control, no keys, no log. Later versions carry the signed-in member's role.
- Relayed requests are logged by the driver like LAN requests, with `client` = `relay`.

## Test endpoints (version 0 only)

For proving the relay before accounts exist. They require `Authorization: Bearer <TEST_TOKEN>`
(a Worker secret) and are removed once accounts replace them.

- `GET /test/homes/{home_id}/status` → `{"connected": true, "since": "<ISO time>", "version": "0.9.0", "last_seen": "<ISO time>"}`
- `GET /test/homes/{home_id}/v1/...` → forwarded to the driver as a `request`; the answer carries
  the driver's status, content type and body.
- `GET /health` → `{"status":"ok"}` (no token).
