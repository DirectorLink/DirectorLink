# C4Bridge Web PWA

This directory is the Cloudflare Pages frontend for C4Bridge. It is framework-free HTML, CSS and JavaScript and needs no build step.

## Structure

- `index.html` — app shell: tab bar, the screen container and `theme-boot.js`
- `theme-boot.js` — blocking script in `<head>`: applies the saved palette, theme and text direction before the first paint (the CSP forbids inline scripts)
- `app.js` — entry module: hash router, renderer, dialogs, start-up
- `js/` — ES modules, no build step:
  - `state.js` (shared state + redraw scheduling), `session.js` (access request, pairing code, reconnect, 10 s refresh, 401 handling, room rename, key revocation), `controls.js` (optimistic device commands, confirmation by re-reading, door/gate pulse with confirm step), `camera-feed.js` (snapshots as blobs, visible tiles only, paused while hidden)
  - `model.js` (room names per language, grouping, "on" counts), `favorites.js` (per controller, in `localStorage`), `components.js` (device rows and tiles), `dom.js`, `icons.js` (inline stroke SVG), `theme.js`, `i18n.js`, `pwa.js` (service worker, install prompt)
  - `views/` — `home.js`, `room.js`, `cameras.js`, `climate.js`, `settings.js`, `connect.js` (first-time setup), `common.js` (header, connection chip, shared states)
- `i18n/en.js`, `i18n/he.js` — interface text
- `styles.css` — the app's styles; `console.css` — the API console's
- `console.html` + `console.js` — API console: loads the API description from the controller, lists every endpoint, sends requests, and follows the bridge log (linked from Settings)
- `api-client.js` — shared client for the LAN API (API port, API key storage, `fetch` with Local Network Access annotations)
- `sw.js` — offline mode (see below); it never intercepts controller/LAN requests

## Screens

Hash routes, so Back and reload work: `#/` Home, `#/room/<id>`, `#/cameras`, `#/climate`, `#/settings`.

- **Home** — connection chip, summary chips ("2 lights on", "1 AC on", "1 blind open"; tapping one filters the rooms), Favorites (Edit mode to add, remove and reorder), room cards. Without a key it shows the connect screen: controller address → **Request access** (press **C4Bridge Access** in the Control4 app within 2 minutes) or **Use a pairing code instead**.
- **Room** — All off (lights and AC), then Lights, Climate, Blinds, Doors & gates (drivers with `/v1/relays`), Cameras and the room's other, uncontrollable devices. Empty sections are hidden; the star on each device adds it to Favorites.
- **Cameras** — one large picture and a grid; thumbnails refresh about every 3 s, the full view about every second.
- **Climate** — all thermostats grouped by room.
- **Settings** — appearance, language, room names per language (`PATCH /v1/rooms/{id}`), controller (address, status, versions, request new access, forget key), app (offline copy, install, API console), about.

API key roles (drivers from v0.7.0): on connect the app reads `GET /v1/api-keys/current` (404 on older drivers → treated as admin) and shows only what the key may do — `viewer` sees state without controls, `member` controls lights, climate and blinds, `doors` also opens doors and gates (after a confirming second tap), `admin` also renames rooms. A 403 `FORBIDDEN` reverts the change, shows "Your access level (…) can't do this" and adopts the role it reports; `DOOR_CONTROL_DISABLED` explains how to turn Door Control on in Composer. Forget key and Request new access revoke the key with `DELETE /v1/api-keys/current` (older drivers: the key list).

Controls change the screen at once, send the command, then re-read the device until the controller confirms it; a failed command reverts and shows a short error on the device. Device state refreshes every 10 s while the page is visible.

## Palettes and themes

Five palettes — graphite (default), ocean, forest, plum, midnight — each with a light and a dark variant, as CSS custom properties on `:root[data-palette=…][data-theme=…]` in `styles.css` (tokens `--bg`, `--card`, `--nav`, `--ink`, `--muted`, `--line`, `--onBg`/`--onText`, `--coolBg`/`--coolText`, `--primary`/`--primaryText`, `--okBg`/`--okText`/`--okDot`). The theme is Light, Dark or Auto (follows `prefers-color-scheme`); `data-theme` always holds the resolved value. The choice is stored in `localStorage` (`c4bridge.palette`, `c4bridge.theme`) and `meta[name=theme-color]` follows the page background. Adding a palette: a light and a dark token block and a swatch rule in `styles.css`, its name in `PALETTES` (`js/theme.js`) and `theme-boot.js`, and a label under `palettes` in each language file.

Fonts are Sora (headings) and IBM Plex Sans / IBM Plex Sans Hebrew (text) from Google Fonts, with system fallbacks — the offline copy renders without them.

## Languages

Every string on screen goes through `t(key, params)` from `js/i18n.js`, with plural forms chosen by `Intl.PluralRules` (`{ one: …, two: …, other: … }`). Language is Auto (browser languages), English or עברית, stored as `c4bridge.lang`. Hebrew sets `<html lang="he" dir="rtl">`; the layout uses logical CSS properties, so it mirrors, and directional icons flip. Names from Control4 are rendered with `dir="auto"`. Rooms show `room.names[lang]` when set in Settings → Rooms, else the Control4 name.

To add a language:

1. Copy `i18n/en.js` to `i18n/<code>.js` and translate the values (missing keys fall back to English).
2. Add one line to `LANGUAGES` in `js/i18n.js`: `{ code: "<code>", label: "<name in that language>", dir: "ltr" | "rtl" }`.

Optionally list the file in `ASSETS` in `sw.js` so it is saved for offline use at install; otherwise it is saved the first time it is used. For a right-to-left language, also add it to the direction check in `theme-boot.js` to avoid a flash of the left-to-right layout.

## Offline mode

The service worker saves the app on the device, so it still opens when the internet is down and keeps controlling the house over the LAN:

- every same-origin `GET` goes to the network first and falls back to the saved copy when the network fails or takes longer than 3 seconds; each successful load refreshes the saved copy, so it never goes stale
- pages are saved under every path that serves them — Cloudflare redirects `/index.html` → `/` and `/console.html` → `/console` — and stored without the redirect, because browsers refuse redirected responses for page loads
- controller requests are cross-origin and are never intercepted or cached
- Settings → App → **Offline copy** shows whether the app is saved

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

The production site is served over HTTPS and talks to the controller over plain HTTP on the LAN. Chromium browsers gate these requests behind Local Network Access permission; requests to private IP literals or `.local` hostnames, annotated with `targetAddressSpace: "local"`, are allowed after the user grants it. A controller on this computer (`localhost`, the dev server) is annotated `"loopback"` instead, because Chromium blocks a request whose annotation does not match the address.

The CSP in `_headers` allows Google Fonts (`fonts.googleapis.com`, `fonts.gstatic.com`) and `blob:` images (camera pictures are fetched with the API key and shown as blobs).
