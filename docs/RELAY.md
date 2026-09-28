# DirectorLink relay protocol (version 1)

The relay lets the app reach a home from anywhere without opening anything on the home network:
the **driver** keeps one outgoing WebSocket (TLS, port 443) to `api.directorlink.io`, and requests
for that home travel over it. This document is the contract between `driver/src/cloud/` and
`cloud/`. Accounts, claiming a home, invitations and the lock are in `docs/ACCOUNTS.md` (ADR-029).

Since version 1 (DirectorLink 0.10.0) **everything the relay passes on is sealed end to end**: the
relay routes envelopes it cannot read. The plain requests of version 0 are refused by the driver.

## Identity of a home

When **Remote Access** is switched on the first time, the driver creates and keeps, in its
persistent data (ADR-028):

- `home_id` — 32 hex characters, random. Not secret; shown shortened in Composer.
- `home_secret` — 64 hex characters, random. Never logged, never shown.

The relay trusts the first secret it sees for a `home_id` (it stores the SHA-256) and afterwards
only accepts that secret. This only decides which connection carries the home's envelopes: who may
use the home is decided by the account's claim and by the device keys (`docs/ACCOUNTS.md`).

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
`type`. Every message the relay sends has an `id`; the driver's reply carries the same `id`.

| Direction | Message | Meaning |
| --- | --- | --- |
| driver → relay | `ping` (plain text) | Keep-alive, every 25 s. |
| relay → driver | `pong` (plain text) | Answer to `ping`, sent by the runtime without waking the relay's code. |
| driver → relay | `{"type":"hello","home":"<home_id>","version":"0.11.0"}` | First message after connecting. |
| driver → relay | `{"type":"keys","ids":["<key id>", …]}` | The ids of the home's API keys (ids only), after `hello` and after every change. The cloud forgets the others; an account whose keys are all gone leaves the home (never its owner). Since 0.11.0. |
| relay → driver | `{"type":"e2e","id":"…","envelope":{…}}` | A request sealed by a device (the lock, `docs/ACCOUNTS.md`). |
| driver → relay | `{"type":"e2e","id":"…","envelope":{…}}` | The sealed answer; or `{"type":"e2e","id":"…","code":"…"}` when the request is refused. |
| relay → driver | `{"type":"join","id":"…","invitation":"<id>","envelope":{…}}` | Accepting an invitation: a request sealed with the invitation's secret. |
| driver → relay | `{"type":"join_result","id":"…","ok":true,"key_id":"…","envelope":{…}}` | The new key, sealed for the invited device; or `"ok":false` with a `code`. |
| relay → driver | `{"type":"claim","id":"…","token":"<48 hex>"}` | Is this the claim token the controller gave out? |
| driver → relay | `{"type":"claim_result","id":"…","ok":true}` | Yes (the token is used up); or `"ok":false,"code":"INVALID_CLAIM"`. |
| relay → driver | `{"type":"request",…}` | Version 0. Refused: `{"type":"response","id":"…","status":410,…}` with `code` `RELAY_REQUESTS_RETIRED`; nothing reaches the API. |

Refusal codes from the driver: `UNKNOWN_KEY`, `BAD_ENVELOPE`, `BAD_MAC`, `BAD_CIPHERTEXT`, `BAD_REQUEST`, `STALE`
(outside the 2-minute window, or sealed before the driver started), `REPLAYED`, `TOO_LARGE`
(requests over 64 KiB), `LOCK_UNAVAILABLE` (the lock self-test failed at start),
`INVITATION_NOT_FOUND`, `KEY_LIMIT_REACHED`, `INTERNAL`. The cloud turns them into Problem Details
for the app (`cloud/src/homes.js`).

If the driver hears nothing (not even `pong`) for 60 s, it drops the connection and reconnects.
The relay answers `504 HOME_TIMEOUT` to its caller when a reply takes longer than 15 s.

## What a relayed request may do

- A sealed request runs as the device's own API key, with that key's role (viewer, member, doors,
  admin) and the Composer Door Control switch, exactly as on the home network.
- The driver logs it like a LAN request, with `client` = `relay` and the key id.
- Claim tokens (`POST /v1/remote/claim`) are given out only on the home network, to admin keys.

## Test endpoints

Version 0's `GET /test/homes/{home_id}/status` and `GET /test/homes/{home_id}/v1/...` exist only
while the Worker has a `TEST_TOKEN` secret; production has none, so they answer
`503 TEST_TOKEN_NOT_SET`. Drivers from 0.10.0 refuse the relayed plain request in any case.

- `GET /health` → `{"status":"ok"}` (no token).
