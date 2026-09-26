# C4Bridge Web PWA

This directory is the Cloudflare Pages frontend for C4Bridge. It is framework-free HTML, CSS and JavaScript and needs no build step.

## Pages

- `index.html` + `app.js` — dashboard: pair a browser, then read and control lights and thermostats
- `console.html` + `console.js` — API console: loads the API description from the controller, lists every endpoint, sends requests, and follows the bridge log
- `api-client.js` — shared client for the LAN API (API port, API key storage, `fetch` with `targetAddressSpace: "local"`)
- `sw.js` — offline shell; it never intercepts controller/LAN requests

## Cloudflare Pages settings

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | None |
| Root directory | `web` |
| Build command | `exit 0` |
| Build output directory | `.` |

No environment variables are required. Every merge to `main` deploys, so web changes must go out together with the driver version they need.

## Local development

The driver accepts `http://localhost` origins, so the app can be tested against a real controller before it is deployed:

```bash
python -m http.server 8080 --directory web
```

Then open `http://localhost:8080`. Without a controller, run `python scripts/dev_server.py` as well and use `localhost` as the controller address (see `docs/BUILD.md`).

## Local Network Access

The production site is served over HTTPS and talks to the controller over plain HTTP on the LAN. Chromium browsers gate these requests behind Local Network Access permission; requests to private IP literals or `.local` hostnames, annotated with `targetAddressSpace: "local"`, are allowed after the user grants it.
