# C4Bridge Web PWA

This directory is the Cloudflare Pages frontend for C4Bridge. It is framework-free HTML, CSS and JavaScript and needs no build step.

## Pages

- `index.html` + `app.js` — dashboard: pair a browser, then read and control lights and thermostats
- `console.html` + `console.js` — API console: loads the API description from the controller, lists every endpoint, sends requests, and follows the bridge log
- `api-client.js` — shared client for the LAN API (API port, API key storage, `fetch` with `targetAddressSpace: "local"`)
- `sw.js` — offline mode (see below); it never intercepts controller/LAN requests

## Offline mode

The service worker saves the app on the device, so it still opens when the internet is down and keeps controlling the house over the LAN:

- every same-origin `GET` goes to the network first and falls back to the saved copy when the network fails or takes longer than 3 seconds; each successful load refreshes the saved copy, so it never goes stale
- pages are saved under every path that serves them — Cloudflare redirects `/index.html` → `/` and `/console.html` → `/console` — and stored without the redirect, because browsers refuse redirected responses for page loads
- controller requests are cross-origin and are never intercepted or cached
- the dashboard's **Offline copy** row shows whether the app is saved

`tests/web/sw.test.mjs` checks this against a fake network that serves the app the way Cloudflare does. Tests live outside `web/` because Cloudflare publishes everything in this folder.

## Cloudflare

The site is a Cloudflare Workers static-assets project (`c4bridge`) built from this folder by Workers Builds:

| Setting | Value |
| --- | --- |
| Root directory | `web` |
| Configuration | [`wrangler.jsonc`](wrangler.jsonc) — assets from `.`, Cloudflare's default HTML and 404 handling |
| Production (`main`) | `npx wrangler deploy` |
| Pull-request branches | `npx wrangler preview` (needs the `previews` block) |

`_headers` sets the security headers; `.assetsignore` keeps `wrangler.jsonc` from being published. No environment variables are required. Every merge to `main` deploys, so web changes must go out together with the driver version they need.

## Local development

The driver accepts `http://localhost` origins, so the app can be tested against a real controller before it is deployed:

```bash
python -m http.server 8080 --directory web
```

Then open `http://localhost:8080`. Without a controller, run `python scripts/dev_server.py` as well and use `localhost` as the controller address (see `docs/BUILD.md`).

## Local Network Access

The production site is served over HTTPS and talks to the controller over plain HTTP on the LAN. Chromium browsers gate these requests behind Local Network Access permission; requests to private IP literals or `.local` hostnames, annotated with `targetAddressSpace: "local"`, are allowed after the user grants it.
