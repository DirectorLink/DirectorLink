# DirectorLink relay

The cloud side of remote access, on **https://api.directorlink.io**: a Cloudflare Worker (`directorlink-api`) with one Durable Object per home. The driver keeps one outgoing WebSocket here, and requests for its home travel over it, so nothing is opened on the home network. The protocol is **[`docs/RELAY.md`](../docs/RELAY.md)**; the driver's side is `driver/src/cloud/`.

Since DirectorLink 0.10.0 (protocol version 1) signed-in accounts reach their homes through it, and **everything it passes on is sealed end to end** between the app and the controller: the relay routes envelopes it cannot read (`docs/ACCOUNTS.md`, ADR-029).

## Structure

- `src/index.js` — the Worker: routes, header checks, the test token; hands each home's requests to its Durable Object
- `src/home-relay.js` — `HomeRelay`, the Durable Object (`idFromName(home_id)`): trust on first use, the driver's WebSocket (Hibernation API), messages to the driver and their replies, the status
- `src/homes.js` — homes for accounts: claiming, members, invitations, sealed requests (`e2e`) and joining, with the owner's approval when the email differs (ADR-041)
- `src/invitations.js` — tombstones for invitations whose email or creator goes, and the daily purge
- `src/member-keys.js` — which account uses which key id; the controller's `keys` list ends the membership of accounts whose keys are all revoked
- `src/backups.js` — automatic backups (1.6.0, ADR-048): the controller's sealed backup, received in chunks over its socket and kept in D1 (one a day, the last 7, 5 MB a home, 25 MB an owner's homes, 4 starts a home a day besides the nightly one); listed, downloaded and deleted by the home's admins
- `src/alerts.js` — alerts to a home's admins (ADR-047): their browsers' push subscriptions, who is an admin, the offline alarm and the controller's `alert` messages
- `src/web-push.js` — Web Push: the message encrypted for the browser (RFC 8291) and the VAPID signature (RFC 8292), with WebCrypto
- `src/stats.js` — DirectorLink in numbers (1.7.0, ADR-052): the hourly count of three totals and the public `GET /v1/stats`
- `src/http.js` — JSON and Problem Details responses, constant-time secret comparison, cookies, random tokens
- `src/accounts.js` — accounts (docs/ACCOUNTS.md): sign-in, sessions, sign-out, deleting the account, and accounts left without a sign-in
- `src/google.js` — Google's authorization-code flow with PKCE
- `src/apple.js` — Sign in with Apple: the posted answer, the ES256 client secret, and the check of Apple's notifications
- `src/apple-notifications.js` — Apple's server-to-server notifications about its accounts (ADR-041)
- `src/jwt.js` — ID token checks shared by both (signature, issuer, audience, expiry, nonce), and Apple's and Google's signing keys, cached
- `migrations/` — the D1 schema: `0001` `users`, `sessions`, `sign_ins`; `0002` `homes`, `members`, `invitations`; `0003` `identities` (Google and Apple for one account); `0004` `member_keys` (which account uses which key id); `0005` `join_requests` (invitations accepted with another email, waiting for the owner); `0006` `push_subscriptions` (alerts, 1.6.0); `0007` `backups`, `backup_chunks` (automatic backups, sealed; 1.6.0); `0010` `stats` (DirectorLink in numbers; 1.7.0)
- `wrangler.jsonc` — Worker `directorlink-api`, the `HOME_RELAY` binding (SQLite-backed class, migration `v1`), the `api.directorlink.io` custom domain
- `.dev.vars` (git-ignored) — secrets for `wrangler dev`

## How it works

1. The driver connects: `GET /relay/connect` with `Upgrade: websocket`, `X-DirectorLink-Home: <home_id>` and `Authorization: Bearer <home_secret>`. The Worker checks the headers (400) and passes the request to the home's object.
2. The object compares the secret's SHA-256 with the one stored for the home (`secret_sha256`, stored by the first connection) and answers 401 if it differs. Otherwise it closes an earlier driver socket with 4000 `replaced` (requests still waiting on it fail at once with 502), accepts the new one with the Hibernation API (`ctx.acceptWebSocket(server, ["driver"])`) and answers 101.
3. The app posts a sealed envelope to `/v1/homes/{home_id}/e2e` (or `/v1/join`, or a claim) with the account's session. `homes.js` checks that the account is a member, keeps only the envelope's own fields and hands it to the object's `/message` operation, which sends `{"type":"e2e",...}` over the socket and waits up to 15 s for the reply with the same `id`. The sealed answer goes back to the app as it came; a refusal code becomes Problem Details.
4. The driver may ask the object too (1.0.0): `invitation` registers an invitation it made in D1 (`registerHomeInvitation`, answered `invitation_result`; at most 20 waiting per home, only for a claimed home, and those missing from the controller's `pending` list are forgotten), and `invitation_cancel` forgets one it revoked or gave up waiting for. Only the socket the home's secret opened can send them.
5. The driver sends its automatic backup (1.6.0, ADR-048) as `backup_chunk` messages, each answered `backup_result` before the next goes: the object checks the sizes and the order and writes each chunk to D1 (`backups.js`; only for a claimed home). A chunk is printable ASCII only (the sealed text is JSON around base64), so its characters are its bytes: at most 65,536 a chunk and 3,000,000 a backup, well under D1's 2 MB a row. A home starts at most 4 backups a UTC day (`BACKUP_LIMIT`), and its first nightly one (`"why":"daily"`) besides, so Back up now never uses up the night's; the homes of one owner hold at most 25 MB together, and a backup that would not fit with the newest of each of the owner's other homes is refused (`ACCOUNT_BACKUPS_FULL`). Once the last chunk is in, the backups the new one replaces go: an earlier one the same day (UTC), all but the last 7, the oldest beyond 5 MB a home (the newest always stays), then the oldest beyond 25 MB across the owner's homes (each home's newest stays). The home's admins list them (`GET /v1/homes/{home_id}/backups`: id, date, size, which password's key), download one (`/backups/{id}`, its sealed text) and delete them (`DELETE /v1/homes/{home_id}/backups`). The cloud does not know roles: the controller's `keys` message names its admin keys (`admins`, 1.6.0), and the accounts that use one pass, the owner too only then; with a controller before 1.6.0, which names none, only the owner passes. `mayUseBackups` in `backups.js` is the one place that decides. An upload that never finished goes at the daily cron after an hour.
6. The home's owner can replace the home's secret (`POST /v1/homes/{home_id}/secret`, below): the object stores the new SHA-256 and closes the driver's socket (4001 `secret replaced`); the driver, which has been keeping the new secret, connects again with it. The driver itself cannot replace it: whoever holds a copy of its data could.

Between requests the object is evicted from memory while the socket stays connected. The driver's `ping` is answered `pong` by the runtime itself (`setWebSocketAutoResponse`), which does not wake the object; `getWebSocketAutoResponseTimestamp` gives the time of the last one for the status. What must outlive an eviction is kept in the socket's attachment (connection id, connect time, version, last message, the ping interval from the `hello`, when it went stale) or in storage (`secret_sha256`, `connected_at`, `disconnected_at`, `last_seen`, `version`). Requests waiting for their answer are kept in memory: while one waits, its caller keeps the object awake. So are requests waiting for a driver that has just disconnected: a driver connects again within seconds (1.5.0), and a request that arrives up to 30 s after the disconnect, or after a deploy restarted the object under the connection (no disconnect is recorded then), waits up to 8 s for its `hello` instead of failing with `HOME_OFFLINE` (docs/RELAY.md, *Keeping the connection*). A socket can also die without a close the runtime sees (1.6.0): one on which the driver has not been heard (no ping answered, no message) for 2.5 of the ping intervals its `hello` announced (`ping_s`: 10 s, so 25 s; drivers before 1.6.0 announce none and ping every 25 s, so about 62 s) is stale. Nothing is sent into it: requests wait for the driver's next connection the same way (up to 30 s after it went stale), and the status says it is not connected.

## Endpoints

| Request | Answer |
| --- | --- |
| `GET /health` | `{"status":"ok"}` |
| `GET /relay/connect` | 101 and the driver's WebSocket (RELAY.md) |
| `GET /test/homes/{home_id}/status` | `{"connected", "since", "version", "last_seen"}` in ISO times. `since` is when the driver connected or, while it is offline, when it disconnected; all `null` for a home never seen |
| `GET /test/homes/{home_id}/v1/...` | the driver's answer to that API path, query string included |

The test endpoints are version 0's: they need `Authorization: Bearer <TEST_TOKEN>`, allow only GET, and are off in production (no `TEST_TOKEN` secret, `503 TEST_TOKEN_NOT_SET`); drivers from 0.10.0 answer their relayed request 410. Errors are Problem Details (`application/problem+json` with `type`, `title`, `status`, `detail`, `code`):

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
| 503 | `HOME_OFFLINE` | no driver is connected for this home (after waiting up to 8 s for one that disconnected in the last 30 s, or after a restart) |
| 503 | `TEST_TOKEN_NOT_SET` | the `TEST_TOKEN` secret is missing |
| 504 | `HOME_TIMEOUT` | no answer within 15 s |
| 500 | `INTERNAL_ERROR` | the relay itself failed |

## Local development

```bash
cd cloud && echo 'TEST_TOKEN=local-test-token' > .dev.vars && npx --yes wrangler@4.143.0 dev --local --port 8787
```

`.dev.vars` may also set `REQUEST_TIMEOUT_MS` (default 15000), `RECONNECT_WAIT_MS` (default 8000: how long a request waits for a driver that has just disconnected or gone quiet) and `UNUSED_ACCOUNT_DAYS` (default 90: the daily clean-up's wait for accounts nobody can sign in to; the tests set 0 and run it with `wrangler dev --test-scheduled`, `GET /__scheduled`). In another terminal, a fake driver and the test endpoints:

```bash
node scripts/relay_smoke.mjs                                            # prints the home id it made up
node scripts/relay_smoke.mjs status --home <home_id> --token local-test-token
node scripts/relay_smoke.mjs get "/v1/lights?room_id=10" --home <home_id> --token local-test-token
```

`scripts/relay_smoke.mjs` speaks the protocol byte by byte over `node:net`/`node:tls` (its header lists every option). With `--url wss://api.directorlink.io` it checks the deployed relay; its client mode (`status`, `get` with `--url https://api.directorlink.io`) checks a real driver through it.

Tests: `node --test tests/cloud/*.test.mjs` (CI runs them too, `.github/workflows/validate.yml`). `frames.test.mjs` checks the smoke script's WebSocket code against a fake relay, and `jwt.test.mjs` the signing-key cache, in Node. `relay.test.mjs` (and the accounts, Apple, homes and backups tests) run the Worker end to end in `wrangler dev` on a free port, from a temporary copy of this folder with its own `.dev.vars`, so your `.dev.vars` and `.wrangler/` are left alone; its first run needs network access for `npx`.

## Alerts (1.6.0, ADR-047)

Web Push notifications to a home's admins, for two things only: the home has been offline for 10 minutes, or a schedule failed (`src/alerts.js`, `src/web-push.js`; docs/ACCOUNTS.md, *6. Alerts*). Session, CORS and origin rules as for Homes, below.

| Request | Answer |
| --- | --- |
| `GET /v1/homes/{home_id}/alerts` | members: `{"public_key"}`, the VAPID key browsers subscribe with; 503 `ALERTS_NOT_CONFIGURED` until the key pair is set, or when its two halves do not belong together |
| `POST /v1/homes/{home_id}/alerts` | `{ endpoint, keys: { p256dh, auth } }` (the browser's `PushSubscription.toJSON()`): 201 `{"alerts": true}`, this browser gets the home's alerts. 403 `ADMIN_ONLY` (the account uses none of the home's admin keys, as far as the cloud knows), 403 `NOT_A_MEMBER`, 409 `ROLES_UNKNOWN` (the controller has not listed its admin keys: DirectorLink before 1.6.0), 400 `INVALID_SUBSCRIPTION` (not a push service's https address, or not a P-256 key and a 16-byte secret) |
| `DELETE /v1/homes/{home_id}/alerts` | `{ endpoint }`: 204, it no longer does |

How it works: the controller's `keys` message lists its admin key ids (`admins`), which the home's Durable Object keeps; an account that uses one of them (`member_keys`) is an admin there. A browser's subscription (`push_subscriptions`, migration `0006`) goes with the account's membership (leaving, being removed, another account claiming the home), the account (deleted, or Apple ending its only sign-in), signing out everywhere, and a 404 or 410 from the push service; each of these tells the home's object (`homesChanged`). Only while an admin's browser is subscribed does the object set alarms: 10 minutes after the driver disconnects, and every 10 minutes while it is connected, to see that it is still heard (a socket that went quiet counts as away since the driver was last heard); while connected it also asks D1 again every hour, and stops once nobody is subscribed. One offline alert per absence; a driver back within the 10 minutes ends it. An offline alert that reached no push service (D1 failed, the service was unreachable, answered 429 or 5xx) is sent again a minute later, to the browsers it missed, 4 sends at most; a redirect is never followed. A deploy records no disconnect: the absence then counts from the first alarm that finds no driver. The controller's `{"type":"alert","kind":"schedule_failed","at"}` goes to the admins at most three times an hour. Each alert is `{kind, home, at}`, padded to 128 bytes so that every alert is the same size, encrypted for each browser (RFC 8291, aes128gcm) and signed with the VAPID key (RFC 8292, ES256); the words are the app's (`app/sw.js`). Push addresses are taken only from the push services' hosts, on HTTPS's own port.

Settings: `VAPID_PUBLIC_KEY` (a var in `wrangler.jsonc`), `VAPID_PRIVATE_KEY` (a secret: the private key as a JWK), optionally `VAPID_SUBJECT` (a var: the contact push services see; `https://directorlink.io` by default). Make the pair once, from this folder; the script writes the private key only into the pipe (it refuses a terminal) and shows the public key:

```bash
node ../scripts/vapid_key.mjs | npx wrangler@4.143.0 secret put VAPID_PRIVATE_KEY
```

Then put the public key it printed in `wrangler.jsonc` (`vars.VAPID_PUBLIC_KEY`), apply the migration and deploy. Alerts stay off while either half is missing. Browsers subscribe with the public key, so a new pair later means every device subscribes again; the app does it by itself the next time it opens, signed in.

For `wrangler dev` and the tests, `.dev.vars` may set `OFFLINE_ALERT_MINUTES` (default 10; the tests use 0.1), `ALERT_SILENCE_SECONDS` (default 60: how long a driver may go unheard on its socket before it counts as away, where the relay has no stale rule of its own), `ALERT_RETRY_SECONDS` (default 60: when an offline alert that did not get through is sent again; the tests use 1) and `PUSH_TEST_URL` (the tests' fake push service, accepted besides the real ones; never set in production).

Logs: `alerts_subscribed`, `alerts_unsubscribed`, `alerts_refused`, `alerts_stopped` (no admin's browser is subscribed any more), `alerts_change_not_told`, `alert_sent` (`kind`, `at`, `devices`, `delivered`, `gone`, the other statuses as `failed`, and how many are sent `again`), `alert_retry`, `alert_not_sent`, `alert_limited`, `alert_ignored`, `alert_failed`, `alerts_not_configured`, `alert_alarm_failed`. A push address is never logged, only its service's host name.

Cost: a home with a subscribed admin costs up to 144 alarms a day while its driver is connected (each a Durable Object request and a row written, about 4,300 of each a month), 24 D1 reads a day, and the few seconds each wake keeps the object in memory; each alert, one D1 read and one request per browser to its push service. Homes without one cost nothing more.

Tests: `web-push.test.mjs` (in Node: RFC 8291's test vector, the padding, the VAPID header, the settings check, which addresses and keys are taken, redirects, `scripts/vapid_key.mjs`), `alerts-alarm.test.mjs` (in Node, with a fake storage and a fake D1 that fails: tries again, asking D1 again, stopping) and `alerts.test.mjs` (end to end, with a fake push service, `fake-push.mjs`, that checks each push's VAPID signature and opens it with the browser's key, and can fail or redirect).

## DirectorLink in numbers (1.7.0, ADR-052)

Three totals for the website, counted once an hour (`src/stats.js`; docs/ACCOUNTS.md, *What is public*):

| Request | Answer |
| --- | --- |
| `GET /v1/stats` | `{"homes", "people", "downloads", "updated"}`: homes linked to an account, accounts someone can sign in to, downloads of `DirectorLink.c4z` over all GitHub releases, and when the oldest of the three was counted (ISO time). No cookie, no key; `Cache-Control: public, max-age=300`; CORS without credentials for `SITE_ORIGINS`. 503 `STATS_NOT_COUNTED` until all three have been counted once, 503 `STATS_UNAVAILABLE` when D1 cannot be read; 405 for anything but GET (and OPTIONS) |

The second cron trigger, `47 * * * *` (`STATS_CRON` in `src/stats.js`, which must match `wrangler.jsonc` character for character: `scheduled` tells the hourly count from the daily housekeeping by `event.cron`), counts homes and people in one D1 batch and asks GitHub's releases list (`/repos/IsraelCIL/DirectorLink/releases?per_page=100&page=N`, at most 10 pages, with a User-Agent) for the downloads. Each total is kept in `stats` (migration `0010`) with its time; a part that fails (D1, or GitHub unreachable, refusing, limited, or answering something else) leaves its total and time as they were. The website (`site/numbers.js`) shows the totals only from 25 homes.

Settings: `SITE_ORIGINS` (a var: the website's origins, `https://directorlink.io,https://www.directorlink.io`). Optional: `GITHUB_TOKEN` (a secret: GitHub allows 60 requests an hour per address without one, and Workers share addresses; a fine-grained token with no permissions is enough), `GITHUB_API_URL` (`.dev.vars` only: a fake GitHub for `wrangler dev` and the tests). Locally, with `wrangler dev --test-scheduled`: `curl "http://localhost:8787/__scheduled?cron=47+*+*+*+*"`.

Logs: `stats_counted` (`homes`, `people`, `downloads`; `null` for a total not counted this hour), `stats_not_counted` (`totals`, `error`, and GitHub's `status`, `page` and `rate_limit_remaining`), `stats_unavailable`.

Cost: 24 runs a day, each two or three requests to GitHub and two D1 writes; one D1 read of three rows per answer (browsers keep it 5 minutes).

Tests: `stats-count.test.mjs` (in Node: the sum over pages and only the package, failures keeping the totals, the answer, CORS and caching) and `stats.test.mjs` (end to end with a fake GitHub: claimed homes only, deleted accounts and accounts without a sign-in not counted, the hourly and daily triggers apart).

## Deploying (by hand for now)

```bash
cd cloud
npx wrangler@4.143.0 d1 migrations apply directorlink --remote   # new tables first (1.6.0: 0006_push_subscriptions, 0007_cloud_backups)
node ../scripts/vapid_key.mjs | npx wrangler@4.143.0 secret put VAPID_PRIVATE_KEY   # once (1.6.0, alerts): then the public key, below
npx wrangler@4.143.0 deploy                   # Worker, Durable Object migration v1, custom domain api.directorlink.io
curl https://api.directorlink.io/health
```

The migrations go before the Worker that uses them. The VAPID key pair is made once (1.6.0): the script pipes the private key into the secret and prints the public key; put that in `wrangler.jsonc` (`vars.VAPID_PUBLIC_KEY`) and commit it before `deploy`, or the deploy ships an empty key (alerts answer `503 ALERTS_NOT_CONFIGURED`) and a later deploy from the repository blanks it again. Never make a new pair once browsers subscribed: each would have to subscribe again.

`.github/workflows/deploy.yml` does not deploy this folder yet. Logs are in Workers Observability: each event is one JSON line (`home_registered`, `driver_connected`, `driver_hello`, `request_relayed`, `request_timeout`, `driver_disconnected`, `wrong_secret`, `invitation_registered`, `invitation_cancelled`, `home_secret_approved`, `home_secret_replaced`, `signed_out_everywhere`, `sessions_purged`, `join_request_created`, `join_request_decided`, `join_request_withdrawn`, `apple_notification`, `apple_notification_refused`, `backup_stored`, `backup_refused`, `backup_downloaded`, `backups_deleted`, `backup_uploads_purged`, ...). Secrets and tokens are never logged, nor Apple's id for a person or an email from a notification. `driver_disconnected` says how the socket ended (`why`, with the close code: 1006 is a connection cut without a close frame), how long it was up (`up_s`), and how long before the end the runtime last answered the driver's ping (`ping_s`) and the driver last sent a message (`message_s`); `driver_connected` says how long the home was away (`down_ms`). `driver_stale` (once per socket) says that the driver went quiet on a socket that is still open, with the interval its `hello` announced (`interval_s`) and the same `up_s`, `ping_s` and `message_s`.

## Cost

- The Durable Object class is SQLite-backed, which every plan (Free included) can use.
- A connected home is idle almost all the time. With the Hibernation API an idle object is evicted and accrues no duration charges while its WebSocket stays open, and the driver's pings (every 10 s from 1.6.0) are answered by the runtime without waking it. Cloudflare documents that these auto-responses incur no wall-clock time and are not charged.
- What is billed per home: the connection itself (one request), each relayed request, and incoming WebSocket messages, which Durable Objects bill as requests at 20:1. Even if every ping counted, a ping every 10 s is 8,640 messages, about 432 requests, per home per day. Check Cloudflare's current Durable Objects pricing before relying on these figures.

## Limits

- Trust on first use: the first secret that connects with a `home_id` owns its connection (who may use the home is decided by the claim and the device keys). The driver makes up its `home_id` (128 random bits), so only someone who learned it before the driver's first connection could take it. The home's owner can replace its secret (the app's **Replace the remote secret**, `POST /v1/homes/{home_id}/secret`); otherwise a registration cannot be reset short of deleting the object's storage, and a driver that loses its identity, or is reset (Composer: Reset Remote Identity), simply creates a new `home_id`.
- A WebSocket message may be at most 32 MiB: a binary answer larger than about 24 MiB (as `body_base64`) makes the runtime close the driver's connection (1009), and the caller gets 502.
- No rate limiting yet, except for automatic backups.
- Automatic backups: at most 5 MB a home in D1 (each at most 3 MB; a big home's is about 175 KB) and 25 MB an owner's homes together, one a day is kept, however often an admin backs up, and a home starts at most 4 a day besides its nightly one. How many homes an account may claim is not limited; each account's backups are.

## Accounts

| Request | Answer |
| --- | --- |
| `GET /auth/providers` | `{"providers": ["google", "apple"]}`: the sign-ins set up here (their settings and secrets exist). No cookie; CORS for `APP_ORIGINS`. The app asks only when someone chooses to sign in, and shows only these buttons |
| `GET /auth/google/start?return_to=<app URL>` | 302 to Google; sets the 10-minute `__Host-dl_signin` cookie. `return_to` must be on one of `APP_ORIGINS`, else the app's Settings |
| `GET /auth/google/callback` | Google comes back here; 302 to `return_to` with `?signin=ok`, `cancelled`, `expired`, `failed` or `unverified`, and on success the `__Host-dl_session` cookie |
| `GET /auth/{google\|apple}/start?…&link=1` | the same, adding that provider to the signed-in account (session cookie required; else `?signin=expired`). Outcomes `linked`, `taken` (the identity belongs to another account, or another account began with it and gets it back when it signs in), `duplicate` (the account has one from this provider) |
| `GET /auth/apple/start?return_to=<app URL>` | 302 to Apple (`response_mode=form_post`); sets the 10-minute `__Host-dl_signin_apple` cookie (`SameSite=None`: Apple's answer is a POST from its site). 503 `SIGN_IN_NOT_CONFIGURED` until the Apple settings exist |
| `POST /auth/apple/callback` | Apple's form comes here; 303 to `return_to` with the same outcomes as Google's |
| `POST /auth/apple/notifications` | Apple's server-to-server notifications (ADR-041): `{"payload": "<JWT>"}` signed with Apple's keys, issuer Apple, audience `APPLE_APP_ID` (the primary App ID). `consent-revoked`, `account-deleted` (older documents: `account-delete`, also accepted): that Apple sign-in goes, and an account left without one is signed out everywhere. After `consent-revoked` it stays as it was for the same Apple ID to come back; after `account-deleted` it keeps nothing of the person: without a home it is deleted, with one it stays for the home without name and email, outside other homes (homes, their members and keys stay). `email-disabled`, `email-enabled`: the stored address follows Apple's. 200 `{"ok": true}` (also for an Apple ID with no account, or a notice from before the person's last sign-in); 400 `INVALID_REQUEST` / `INVALID_NOTIFICATION` (the log line names the refused audience); 503 `NOTIFICATIONS_NOT_CONFIGURED` without `APPLE_APP_ID`, `PROVIDER_UNREACHABLE` when Apple's keys cannot be read |
| `GET /v1/me` | `{"id", "email", "name", "created_at", "providers", "sign_in_providers"}` (`providers`: the account's, `google`, `apple`; `sign_in_providers`: those set up here), or 401 `NOT_SIGNED_IN` |
| `DELETE /v1/me/identities/{google\|apple}` | 204: the account no longer signs in with that provider; 409 `LAST_SIGN_IN` for its only one, 409 `SIGN_IN_HELD_ELSEWHERE` (nothing changed) when another account began with the one it would keep |
| `DELETE /v1/me` | 204; the account and all its sessions are deleted |
| `POST /auth/logout` | 204; this session ends |
| `POST /auth/logout?everywhere=1` | 204; every session of the account ends, on every device |

## Homes

| Request | Answer |
| --- | --- |
| `POST /v1/homes/claim` | `{ home_id, claim_token }` from the controller (`POST /v1/remote/claim`, home network, admin key): the controller confirms the token over the relay and the account owns the home. `{"home_id", "owner": true, "transferred"}`; a claim by another account moves the home and removes its members and invitations |
| `GET /v1/homes` | the account's homes: `{"items": [{"home_id", "owner", "added_at", "connected"}]}` |
| `GET /v1/homes/{home_id}` | `{"home_id", "claimed", "owner", "member"}`, so the app can ask before taking a home over |
| `POST /v1/homes/{home_id}/e2e` | `{ envelope }` sealed by a member's device; `{ envelope }` sealed by the home. 403 `NOT_A_MEMBER`, 400 `INVALID_ENVELOPE` (also for requests over 128 KiB), 503 `HOME_OFFLINE`, 504 `HOME_TIMEOUT`, or the driver's refusal code |
| `POST /v1/homes/{home_id}/secret` | `{ secret_sha256 }` from the controller (`POST /v1/remote/secret`, home network); the owner only (403 `OWNER_ONLY`). 204: only the new secret opens the home's connection from now on, and the driver is reconnected |
| `POST /v1/homes/{home_id}/invitations` | For drivers before 1.0.0, which do not register their invitations themselves: `{ invitation_id, email, expires_at }` of an invitation the controller made; 201. The home's owner only (403 `OWNER_ONLY`). Registered once: 409 `INVITATION_EXISTS`; at most 20 waiting per account and home: 429 `INVITATION_LIMIT_REACHED` |
| `POST /v1/join` | `{ home_id, invitation_id, envelope[, ask_owner] }` sealed with the invitation's secret, by the invited email (404 `INVITATION_NOT_FOUND`); `{ home_id, envelope, member }` with the new key sealed inside; `member` says whether the account now belongs to the home. Another email (ADR-041): with `ask_owner: true`, 202 `{"status", "code", "requested_at", "decided_at", "expires_at"}` and nothing is sent to the home until the owner approves (then the same call joins); 403 `REFUSED_BY_OWNER` once refused; 429 `JOIN_REQUEST_LIMIT_REACHED` (5 open per invitation, 20 waiting per home on invitations still waiting); without `ask_owner`, 403 `EMAIL_MISMATCH`. An approved account the owner refused while the home made its key gets 403 `REFUSED_BY_OWNER` and no envelope (logged `join_key_withheld`) |
| `GET /v1/join/{home_id}/{invitation_id}` | this account's request: `{"status": "pending" \| "approved" \| "refused" \| "expired", "code", "requested_at", "decided_at", "expires_at"}`; 404 `NOT_FOUND` (none), 404 `INVITATION_NOT_FOUND` (used, revoked, gone) |
| `DELETE /v1/join/{home_id}/{invitation_id}` | 204: the request is withdrawn (not a refused one: 404) |
| `GET /v1/homes/{home_id}/join-requests` | the owner only (403 `OWNER_ONLY`): `{"items": [{"id", "user_id", "name", "email", "email_hidden", "providers", "account_created_at", "requested_at", "status", "decided_at", "code", "invitation": {"id", "email", "expires_at"}}]}`, pending and approved requests for invitations still waiting; `email` is null when Apple hides it |
| `POST /v1/homes/{home_id}/join-requests/{id}` | the owner only: `{ "decision": "approve" \| "refuse" }` → `{"id", "status", "decided_at"}`; 404 `NOT_FOUND` once the invitation was used, revoked or expired |
| `GET /v1/homes/{home_id}/members` | the owner only: `{"items": [{"user_id", "email", "name", "owner", "added_at", "key_ids"}]}`; `key_ids`: the home's API keys this account uses, as far as the cloud has seen (the key an invitation made, and each key the home accepted a sealed request with) |
| `DELETE /v1/homes/{home_id}/members/{user_id}` | 204: the owner removes someone, or anyone leaves (the owner cannot, 409) |

They all need the session (401 `NOT_SIGNED_IN`). A daily cron (`triggers` in `wrangler.jsonc`, `src/invitations.js`, `src/index.js`) removes invitations a day after their expiry, with their requests to join, and expired sessions and unfinished sign-ins; and accounts nobody can sign in to (Apple's consent-revoked took their only sign-in) that nobody signed in to for 90 days, as after Apple's account-deleted (ADR-041: deleted without a home, emptied of the person with one).

`/v1/me`, `/v1/homes…`, `/v1/join` and `/auth/logout` answer CORS with credentials only for `APP_ORIGINS`, and `DELETE`/`POST` from any other origin (or none) are refused with 403 `ORIGIN_NOT_ALLOWED`.

Settings (`wrangler.jsonc` → `vars`): `GOOGLE_CLIENT_ID` (public), `APP_ORIGINS`, `PUBLIC_URL` (the address Google and Apple send the browser back to, registered with each). Secret: `GOOGLE_CLIENT_SECRET` (`npx wrangler@4.143.0 secret put GOOGLE_CLIENT_SECRET`).

Sign in with Apple (on since 1.3.0, ADR-041) uses, from the Apple Developer account: the Services ID `io.directorlink.signin` (Sign in with Apple on, domain `api.directorlink.io`, return URL `https://api.directorlink.io/auth/apple/callback`), grouped with the primary App ID `io.directorlink.app`; the Team ID `VA4Q88T4RC`; and a key with Sign in with Apple, Key ID `Q3WXX95K83`. `APPLE_SERVICES_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID` and `APPLE_APP_ID` are in `vars`; the key is a secret (`npx wrangler@4.143.0 secret put APPLE_PRIVATE_KEY < AuthKey_Q3WXX95K83.p8`), and until it is set `/auth/providers` leaves Apple out, so the app shows no Apple button. Apple's server-to-server notification endpoint, on the primary App ID: `https://api.directorlink.io/auth/apple/notifications`. Tests: `apple.test.mjs` with a fake Apple (`fake-apple.mjs`) that checks the client secret as Apple does and signs ID tokens and notifications with a test key. Database: D1 `directorlink`, binding `DB`; schema changes go in `migrations/`:

```
npx wrangler@4.143.0 d1 migrations apply directorlink --remote
```

For `wrangler dev`, `.dev.vars` may set the Google endpoints (`GOOGLE_AUTH_URL`, `GOOGLE_TOKEN_URL`, `GOOGLE_JWKS_URL`, `GOOGLE_ISSUER`) to a fake Google, as `tests/cloud/accounts.test.mjs` does, and `APP_ORIGINS=http://localhost:8080` for a local app (whose account API is `http://localhost:8787`).

