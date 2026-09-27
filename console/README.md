# DirectorLink Console

The API console, debugging and log viewer for DirectorLink, on **https://console.directorlink.io**. Plain HTML, CSS and ES modules — no build step, no service worker (it is not a PWA). Like the app, it talks to the driver directly over the LAN at `http://<controller>:41999`; nothing goes through Cloudflare.

## Structure

- `index.html` — header (DL mark, connection chip, controller address), tabs, and the static markup of every tab
- `console.js` — entry module: hash router (`#/api`, `#/logs`, `#/system`, `#/keys`, `#/connect`; the last tab is remembered as `directorlink.console.tab`), header, start-up
- `js/session.js` — address, API key, role; every request (`send`/`call`/`image`); 401 → the key is cleared and the connection screen opens; network errors and timeouts explain Local Network Access and port 41999
- `js/connection.js` — connection screen
- `js/explorer.js`, `js/logs.js`, `js/system.js`, `js/keys.js` — the tabs; `js/dom.js` — helpers
- `api-client.js` — **an exact copy of `app/api-client.js`**; `scripts/check_sites.py` fails if they differ. After changing the app's client: `cp app/api-client.js console/`
- `console.css` — the app's graphite palette, Sora + IBM Plex, light and dark from `prefers-color-scheme`
- `icons/icon.svg` — the DL mark (`python scripts/make_icons.py brand`)
- `_headers` — security headers and CSP; `.assetsignore` — keeps `wrangler.jsonc`, `.assetsignore` and this README from being published; `wrangler.jsonc` — Worker `directorlink-console` on the `console.directorlink.io` custom domain

## Connection

The controller address and the API key are stored in this origin's `localStorage` (`directorlink.directorHost`, `directorlink.apiKey`), separate from the app's. Three ways to get a key:

1. **Request admin access** — `POST /v1/auth/requests` with `{"name": "DirectorLink Console", "role": "admin"}`, then `GET /v1/auth/requests/{id}` every 2 s until it is approved (the key is stored) or gone (404: expired or cancelled). Press **DirectorLink Access** in the Control4 app within 2 minutes; Composer shows "Waiting: DirectorLink Console as admin". **Cancel** sends `DELETE /v1/auth/requests/{id}`.
2. **Pairing code** — the 8-digit code from the DirectorLink properties in Composer, `POST /v1/auth/pair`. Always an admin key.
3. **Paste a key.**

After connecting the console reads `GET /v1/api-keys/current` (its role; 404 on drivers before roles → admin), `GET /v1/system` and `GET /v1/openapi.json`. **Forget key** revokes the key with `DELETE /v1/api-keys/current`, then removes it from the browser.

## Tabs

- **API** — every operation of the running bridge's API description, grouped by tag, with its role (`x-directorlink-role`; roles are ordered viewer < member < doors < admin, and operations this key cannot use are marked). Path and query parameters, a JSON body prefilled with the spec's example, **Send** (status, duration, pretty body; camera snapshots are shown as pictures) and **Copy as curl**, which uses `$DIRECTORLINK_KEY` instead of the key. Deep links: `#/api/<operationId>`.
- **Logs** (admin) — follows `GET /v1/logs?after=<last_seq>&limit=200` every 2 s while the tab is open; pause/resume, level and category filters (applied by the bridge; chips for the categories seen), text search in the loaded entries, click an entry for its `data`, **Clear view**, **Download** (JSON lines). The recording level is `GET`/`PATCH /v1/logs/settings`; `debug` is verbose. At most 2000 entries are kept.
- **System** — `GET /v1/system`, this console's key, the API description's version against the bridge's (a warning when they differ), a connection test (5 × `GET /v1/health`: min/avg/max and failures) and **Copy diagnostics**, a plain-text report for support that never contains the API key or a pairing code.
- **Keys** (admin) — `GET /v1/api-keys`; change a role (`PATCH /v1/api-keys/{id}`; the last admin key cannot be demoted: `409 LAST_ADMIN`), rename, revoke (revoking the console's own key logs it out), and create a key (`POST /v1/api-keys`) whose secret is shown once.

A key below admin sees an explanation on Logs and Keys instead of errors.

## Local development

```bash
python scripts/dev_server.py                                      # fake controller on localhost:41999
python -m http.server 8081 --bind 127.0.0.1 --directory console   # console on http://127.0.0.1:8081
```

Use `localhost` as the controller address and the pairing code the dev server prints (type `press` + Enter in the dev server to approve an access request). The driver accepts `http://localhost` and `http://127.0.0.1` origins. The app's Settings → API console opens this local copy when the app itself runs on localhost.

## Deploying

`.github/workflows/deploy.yml` runs `wrangler deploy` in this folder on pushes to `main`. `python scripts/check_sites.py` validates it.
