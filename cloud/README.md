# DirectorLink relay

The cloud side of remote access, on **https://api.directorlink.io**: a Cloudflare Worker (`directorlink-api`) with one Durable Object per home. The driver keeps one outgoing WebSocket here, and requests for its home travel over it, so nothing is opened on the home network. The protocol is **[`docs/RELAY.md`](../docs/RELAY.md)**; the driver's side is `driver/src/cloud/`.

**Version 0 is a proof of concept.** It proves the connection on a real controller: a home is trusted on first use, and the only callers are the test endpoints, behind one shared token. Accounts, invitations and the app come later (ADR-027).

## Structure

- `src/index.js` — the Worker: routes, header checks, the test token; hands each home's requests to its Durable Object
- `src/home-relay.js` — `HomeRelay`, the Durable Object (`idFromName(home_id)`): trust on first use, the driver's WebSocket (Hibernation API), relayed requests, the status
- `src/http.js` — JSON and Problem Details responses, constant-time secret comparison, cookies, random tokens
- `src/accounts.js` — accounts (docs/ACCOUNTS.md): sign-in, sessions, sign-out, deleting the account
- `src/google.js` — Google's authorization-code flow with PKCE, and the ID token checks
- `migrations/` — the D1 schema (`users`, `sessions`, `sign_ins`)
- `wrangler.jsonc` — Worker `directorlink-api`, the `HOME_RELAY` binding (SQLite-backed class, migration `v1`), the `api.directorlink.io` custom domain
- `.dev.vars` (git-ignored) — secrets for `wrangler dev`

## How it works

1. The driver connects: `GET /relay/connect` with `Upgrade: websocket`, `X-DirectorLink-Home: <home_id>` and `Authorization: Bearer <home_secret>`. The Worker checks the headers (400) and passes the request to the home's object.
2. The object compares the secret's SHA-256 with the one stored for the home (`secret_sha256`, stored by the first connection) and answers 401 if it differs. Otherwise it closes an earlier driver socket with 4000 `replaced`, accepts the new one with the Hibernation API (`ctx.acceptWebSocket(server, ["driver"])`) and answers 101.
3. A caller asks `GET /test/homes/{home_id}/v1/...`. The object sends `{"type":"request",...}` over the socket and waits up to 15 s for the `response` with the same `id`, which becomes the HTTP answer: the driver's status, content type and body (`body_base64` decoded), with `cache-control: no-store`.

Between requests the object is evicted from memory while the socket stays connected. The driver's `ping` is answered `pong` by the runtime itself (`setWebSocketAutoResponse`), which does not wake the object; `getWebSocketAutoResponseTimestamp` gives the time of the last one for the status. What must outlive an eviction is kept in the socket's attachment (connection id, connect time, version, last message) or in storage (`secret_sha256`, `connected_at`, `disconnected_at`, `last_seen`, `version`). Requests waiting for their answer are kept in memory: while one waits, its caller keeps the object awake.

## Endpoints

| Request | Answer |
| --- | --- |
| `GET /health` | `{"status":"ok"}` |
| `GET /relay/connect` | 101 and the driver's WebSocket (RELAY.md) |
| `GET /test/homes/{home_id}/status` | `{"connected", "since", "version", "last_seen"}` in ISO times. `since` is when the driver connected or, while it is offline, when it disconnected; all `null` for a home never seen |
| `GET /test/homes/{home_id}/v1/...` | the driver's answer to that API path, query string included |

The test endpoints need `Authorization: Bearer <TEST_TOKEN>` and allow only GET. Errors are Problem Details (`application/problem+json` with `type`, `title`, `status`, `detail`, `code`):

| Status | `code` | When |
| --- | --- | --- |
| 400 | `WEBSOCKET_REQUIRED` | `/relay/connect` without `Upgrade: websocket` |
| 400 | `INVALID_HOME_ID` | `X-DirectorLink-Home` or `{home_id}` is not 32 lowercase hex characters |
| 400 | `INVALID_HOME_SECRET` | `Authorization` is not `Bearer <64 hex characters>` |
| 401 | `WRONG_HOME_SECRET` | another secret is registered for this `home_id` |
| 401 | `UNAUTHORIZED` | a test endpoint without the right token |
| 404 | `NOT_FOUND` | any other path |
| 405 | `METHOD_NOT_ALLOWED` | anything but GET (`Allow: GET`) |
| 502 | `HOME_DISCONNECTED` | the driver's connection closed while the request waited |
| 502 | `INVALID_RESPONSE` | the driver's `response` was malformed (status, body or base64) |
| 503 | `HOME_OFFLINE` | no driver is connected for this home |
| 503 | `TEST_TOKEN_NOT_SET` | the `TEST_TOKEN` secret is missing |
| 504 | `HOME_TIMEOUT` | no answer within 15 s |
| 500 | `INTERNAL_ERROR` | the relay itself failed |

## Local development

```bash
cd cloud && echo 'TEST_TOKEN=local-test-token' > .dev.vars && npx --yes wrangler@4 dev --local --port 8787
```

`.dev.vars` may also set `REQUEST_TIMEOUT_MS` (default 15000). In another terminal, a fake driver and the test endpoints:

```bash
node scripts/relay_smoke.mjs                                            # prints the home id it made up
node scripts/relay_smoke.mjs status --home <home_id> --token local-test-token
node scripts/relay_smoke.mjs get "/v1/lights?room_id=10" --home <home_id> --token local-test-token
```

`scripts/relay_smoke.mjs` speaks the protocol byte by byte over `node:net`/`node:tls` (its header lists every option). With `--url wss://api.directorlink.io` it checks the deployed relay; its client mode (`status`, `get` with `--url https://api.directorlink.io`) checks a real driver through it.

Tests: `node --test tests/cloud/*.test.mjs`. `frames.test.mjs` checks the smoke script's WebSocket code against a fake relay. `relay.test.mjs` runs the relay end to end in `wrangler dev` on a free port, from a temporary copy of this folder with its own `.dev.vars`, so your `.dev.vars` and `.wrangler/` are left alone; its first run needs network access for `npx`.

## Deploying (by hand for now)

```bash
cd cloud
npx wrangler@4 deploy                   # Worker, Durable Object migration v1, custom domain api.directorlink.io
npx wrangler@4 secret put TEST_TOKEN    # a long random value: node -e "console.log(crypto.randomBytes(32).toString('hex'))"
curl https://api.directorlink.io/health
```

`.github/workflows/deploy.yml` does not deploy this folder yet. Logs are in Workers Observability: each event is one JSON line (`home_registered`, `driver_connected`, `driver_hello`, `request_relayed`, `request_timeout`, `driver_disconnected`, `wrong_secret`, ...). Secrets and tokens are never logged.

## Cost

- The Durable Object class is SQLite-backed, which every plan (Free included) can use.
- A connected home is idle almost all the time. With the Hibernation API an idle object is evicted and accrues no duration charges while its WebSocket stays open, and the 25 s pings are answered by the runtime without waking it.
- What is billed per home: the connection itself (one request), each relayed request, and incoming WebSocket messages, which Durable Objects bill as requests at 20:1. Even if every ping counted, that is 3,456 messages, about 173 requests, per home per day. Check Cloudflare's current Durable Objects pricing before relying on these figures.

## Limits of version 0

- Trust on first use: the first secret that connects with a `home_id` owns it. The driver makes up its `home_id` (128 random bits), so only someone who learned it before the driver's first connection could take it. A registration cannot be reset short of deleting the object's storage; a driver that loses its identity simply creates a new `home_id`.
- One shared `TEST_TOKEN` for every home; the test endpoints go away when accounts arrive.
- A WebSocket message may be at most 32 MiB: a binary answer larger than about 24 MiB (as `body_base64`) makes the runtime close the driver's connection (1009), and the caller gets 502.
- No rate limiting yet.

## Accounts

| Request | Answer |
| --- | --- |
| `GET /auth/google/start?return_to=<app URL>` | 302 to Google; sets the 10-minute `__Host-dl_signin` cookie. `return_to` must be on one of `APP_ORIGINS`, else the app's Settings |
| `GET /auth/google/callback` | Google comes back here; 302 to `return_to` with `?signin=ok`, `cancelled`, `expired`, `failed` or `unverified`, and on success the `__Host-dl_session` cookie |
| `GET /v1/me` | `{"id", "email", "name", "created_at"}`, or 401 `NOT_SIGNED_IN` |
| `DELETE /v1/me` | 204; the account and all its sessions are deleted |
| `POST /auth/logout` | 204; this session ends |

`/v1/me` and `/auth/logout` answer CORS with credentials only for `APP_ORIGINS`, and `DELETE`/`POST` from any other origin (or none) are refused with 403 `ORIGIN_NOT_ALLOWED`.

Settings (`wrangler.jsonc` → `vars`): `GOOGLE_CLIENT_ID` (public), `APP_ORIGINS`, `PUBLIC_URL` (the address Google redirects back to, registered with the client). Secret: `GOOGLE_CLIENT_SECRET` (`npx wrangler@4 secret put GOOGLE_CLIENT_SECRET`). Database: D1 `directorlink`, binding `DB`; schema changes go in `migrations/`:

```
npx wrangler@4 d1 migrations apply directorlink --remote
```

For `wrangler dev`, `.dev.vars` may set the Google endpoints (`GOOGLE_AUTH_URL`, `GOOGLE_TOKEN_URL`, `GOOGLE_JWKS_URL`, `GOOGLE_ISSUER`) to a fake Google, as `tests/cloud/accounts.test.mjs` does, and `APP_ORIGINS=http://localhost:8080` for a local app (whose account API is `http://localhost:8787`).

