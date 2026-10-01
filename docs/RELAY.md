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
- `home_secret` — 64 hex characters, random. Never logged, never shown. It leaves the controller
  only in a backup (1.4.0, ADR-042): `GET /v1/backup` gives it, with the waiting replacements, to
  admin keys in sealed requests only, and the app saves it encrypted with a password; only an
  identity the relay has accepted goes into one.

The relay trusts the first secret it sees for a `home_id` (it stores the SHA-256) and afterwards
only accepts that secret. This only decides which connection carries the home's envelopes: who may
use the home is decided by the account's claim and by the device keys (`docs/ACCOUNTS.md`).

**Replacing the secret** (1.0.0), for instance after a copy of the controller's data went missing,
needs the home's owner, since whoever holds that copy can connect as the home:

1. The owner's app, on the home network, asks the controller for a new secret
   (`POST /v1/remote/secret`, admin key, refused through the relay). The driver makes a new one for
   every request (never one made earlier, which a copy of its data taken meanwhile would hold),
   keeps the newest three for a day next to the one in use, and answers only its SHA-256 (the
   secrets themselves go only into a backup).
2. The app gives the SHA-256 to the account service (`POST /v1/homes/{home_id}/secret`, the owner's
   session only). From then on the relay accepts only the new secret, and it closes the driver's
   socket (4001 `secret replaced`).
3. The driver reconnects with the secret in use, is refused (401), and tries the waiting ones once
   each, newest first. The one that connects is the home secret from then on, and the others go.
   If all are refused, the driver waits as for any refusal (300 s) and starts again with the secret
   in use.

The account service trusts the owner's session for this: someone who stole it could approve a
secret of their own and cut the controller off from the relay (they still could not read or change
anything, and a stolen owner session could already delete the home). The owner then signs out
everywhere and replaces the secret again at home, or the installer runs Reset Remote Identity.

The Composer action **Reset Remote Identity** is the last resort, for when the owner cannot do this
(someone else took the home over): the driver makes a new `home_id` and secret, revokes its pending
invitations and claim token, and connects as a new home, which the owner links again.

**A restore from a backup** (ADR-042, docs/BACKUP.md) may bring the backup's identity to this
controller: the one it replaces is kept until the relay accepts the backup's, and comes back if the
relay refuses it (401, or 400 for an identity it does not take). Another home's identity moves only
when the admin asks. The relay lets one connection carry a home: a second controller with the same
identity replaces the first (4000 `replaced`), and the two push each other off every few seconds,
so the controller the backup was made on must be off, or have Remote Access off, first.

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

The driver reconnects after a lost connection with backoff: 5 s, 10 s, 30 s, then every 60 s. An
attempt that has not opened within 30 s (no TLS connection, or no answer to the upgrade) counts as
lost too.

The driver asks Director to check the relay's certificate (`VERIFY_MODE = "peer"` in
`driver/src/cloud/websocket.lua`). Without it, Director checks nothing, and anyone in the network
path could pose as the relay and catch the home secret. The chain must end at one of the root
certificates in the driver package, `certs/directorlink-roots.pem`. These are the authorities
Cloudflare issues the relay's certificate from, and Cloudflare may switch between them at any renewal:
- Let's Encrypt: ISRG Root X1 and X2.
- Google Trust Services: GTS Root R1, R3 and R4. Today's chain is WE1 → GTS Root R4.
- SSL.com: the TLS RSA and ECC roots of 2022, and the older RSA and ECC roots.

This check is new in 1.1.0 (ADR-034). Control4 does not document two things, which a controller
has to show: whether Director also checks that the certificate names `api.directorlink.io`, and
how it reports a certificate that does not verify. `Connected` alone shows neither: 1.0.0 connected
with no check at all. docs/TESTING.md 0p has the negative test for the check itself: a test package
(`scripts/build.py --roots-only`) that trusts only a root the relay's chain does not end at must
never connect. The name is not tested; if Director does not check it, a certificate that one of
these authorities issued for another name passes too. Either way the driver retries with the
backoff:
- If Director reports the connection offline, Remote Status shows
  `Reconnecting in N s (connection lost)`.
- If Director reports nothing, the 30 s limit ends the attempt. Remote Status shows
  `Reconnecting in N s (no connection within 30 s)`, and the relay log says *no TLS connection to
  the relay within 30 s; the certificate check may have failed*.

The file lists each root's SHA-256. Rebuild it from a current CA list (such as certifi) before a
root expires or when Cloudflare adds an authority. `scripts/build.py` packages only this file of
`driver/certs/` (any other file there stops the build), with LF line endings.
`scripts/check_package.py` reads it as OpenSSL does (every `BEGIN` block, trailing whitespace and
CRLF included) and checks that the certificates in it are exactly these roots, each once, with its
pinned SHA-256, and nothing else: no key and no other block. `scripts/check_repo.py` checks the
staged file the same way.

## Messages

All frames are **text**. Apart from the keep-alive words below, each is one JSON object with a
`type`. Every message the relay sends has an `id`; the driver's reply carries the same `id`. The
same holds the other way for what the driver asks the relay (`invitation`).

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
| driver → relay | `{"type":"invitation","id":"…","invitation_id":"<8 hex>","email":"…","expires_at":"<ISO time>","pending":["<8 hex>", …]}` | Registers an invitation the controller made for an admin (`POST /v1/invitations` with `email`), binding it to that email. `pending`: the ids of every invitation still waiting on the controller (this one included); the relay forgets the others it registered for the home. Since 1.0.0. |
| relay → driver | `{"type":"invitation_result","id":"…","ok":true}` | Registered; or `"ok":false` with `INVALID_REQUEST`, `INVITATION_EXISTS` (an id is bound to its email once), `INVITATION_LIMIT_REACHED` (20 waiting), `NOT_CLAIMED` (no account has claimed the home) or `INTERNAL`: the driver revokes the invitation and answers the admin `502` with that code. With no answer within 10 s, or while not connected, it revokes it and answers `503 REMOTE_OFFLINE`. |
| driver → relay | `{"type":"invitation_cancel","invitation_id":"<8 hex>"}` | The driver revoked the invitation, or gave up waiting for `invitation_result`: the relay forgets it if it took it. No answer. Since 1.0.0. |
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
  admin) and the Composer Door Control and Relay Hold switches, exactly as on the home network.
- The driver logs it like a LAN request, with `client` = `relay` and the key id.
- Claim tokens (`POST /v1/remote/claim`) are given out only on the home network, to admin keys,
  and pairing (`POST /v1/auth/pair`) works only there too (`PAIRING_ONLY_ON_HOME_NETWORK`).
- Only the controller registers invitations for its home; the account service's own endpoint for
  it is kept for the home's owner, for drivers before 1.0.0 (`OWNER_ONLY` for other members).

## Test endpoints

Version 0's `GET /test/homes/{home_id}/status` and `GET /test/homes/{home_id}/v1/...` exist only
while the Worker has a `TEST_TOKEN` secret; production has none, so they answer
`503 TEST_TOKEN_NOT_SET`. Drivers from 0.10.0 refuse the relayed plain request in any case.

- `GET /health` → `{"status":"ok"}` (no token).
