# DirectorLink app (PWA)

The DirectorLink app on **https://app.directorlink.io**. It is framework-free HTML, CSS and JavaScript and needs no build step. The API console is its own site (`../console/`, https://console.directorlink.io).

## Structure

- `index.html` — app shell: tab bar, the screen container and `theme-boot.js`
- `theme-boot.js` — blocking script in `<head>`: applies the saved palette, theme and text direction before the first paint (the CSP forbids inline scripts)
- `app.js` — entry module: hash router, renderer, dialogs, start-up
- `js/` — ES modules, no build step:
  - `state.js` (shared state + redraw scheduling), `session.js` (pairing code, reconnect, 10 s refresh, 401 handling, room rename, key revocation), `controls.js` (optimistic device commands, confirmation by re-reading, door/gate pulse with confirm step), `camera-feed.js` (snapshots as blobs, visible tiles only, paused while hidden; live pictures about every second), `doorbells.js` (noticing rings, Dismiss, notifications), `rings.js` (when a ring is recent, relative times; no browser dependencies, unit-tested)
  - `model.js` (room names per language, grouping, "on" counts), `favorites.js` (per controller, in `localStorage`), `components.js` (device rows and tiles), `dom.js`, `icons.js` (inline stroke SVG), `theme.js`, `i18n.js`, `pwa.js` (service worker, install prompt)
  - `views/` — `home.js`, `room.js`, `cameras.js`, `climate.js`, `settings.js`, `connect.js` (first-time setup), `common.js` (header, connection chip, shared states)
- `i18n/en.js`, `i18n/he.js` — interface text
- `styles.css` — the app's styles
- `api-client.js` — shared client for the LAN API (API port, API key storage, pairing code format, `fetch` with Local Network Access annotations); `console/api-client.js` is an exact copy (`scripts/check_sites.py` compares them)
- `_redirects` — sends the old `/console.html` and `/console` to https://console.directorlink.io (301); Cloudflare reads it, it is not published
- `sw.js` — offline mode (see below); it never intercepts controller/LAN requests

## Screens

Hash routes, so Back and reload work: `#/` Home, `#/room/<id>`, `#/cameras`, `#/climate`, `#/settings`.

- **Home** — a doorbell banner while someone rings (see Doorbells), connection chip, summary chips ("2 lights on", "1 AC on", "1 blind open"; tapping one filters the rooms), Favorites (Edit mode to add, remove and reorder), room cards. Without a key it shows the connect screen: controller address and **pairing code** (see below).
- **Room** — All off (lights and AC), then Lights, Climate, Blinds, Doorbells (drivers with `/v1/doorbells`), Doors & gates (drivers with `/v1/relays`), Cameras (without the doorbell's own camera, shown with the doorbell) and the room's other, uncontrollable devices. Empty sections are hidden; the star on each device adds it to Favorites.
- **Cameras** — one large picture and a grid; thumbnails refresh about every 3 s, the full view about every second.
- **Climate** — all thermostats grouped by room.
- **Settings** — appearance, language, room names per language (`PATCH /v1/rooms/{id}`), controller (address, status, versions, pair again, forget key), app (offline copy, install, API console — opens https://console.directorlink.io, or `http://127.0.0.1:8081` when the app runs on localhost; doorbell notifications), about. The controller's project counts include doorbells.

## Pairing

The pairing code is the only way to get a device's first key. In Composer: DirectorLink → Actions → **New Pairing Code** (one is also made when the driver is added or has no keys); Composer shows it as `1234 5678`. A code lasts 15 minutes and works once. The field brings up the number pad (`inputmode="numeric"`, `autocomplete="one-time-code"`) and formats the code as it is typed or pasted, with or without the space or a dash. `POST /v1/auth/pair` with `{"pairing_code", "name"}` returns an admin key; the name is the browser and system, e.g. "Chrome on Windows". Every problem it can answer has its own message in each language: `INVALID_FIELD` (not 8 digits), `PAIRING_CODE_INVALID` (with the tries left), `PAIRING_NOT_ACTIVE` (no code — run New Pairing Code), `PAIRING_RATE_LIMITED` (5 wrong codes lock pairing for 60 s), `KEY_LIMIT_REACHED`, `PAIRING_UNAVAILABLE`. More keys, with other roles, are created by an admin in the API console (Keys).

API key roles (drivers from v0.7.0): on connect the app reads `GET /v1/api-keys/current` (404 on older drivers → treated as admin) and shows only what the key may do — `viewer` sees state without controls, `member` controls lights, climate and blinds, `doors` also opens doors and gates (after a confirming second tap), `admin` also renames rooms. A 403 `FORBIDDEN` reverts the change, shows "Your access level (…) can't do this" and adopts the role it reports; `DOOR_CONTROL_DISABLED` explains how to turn Door Control on in Composer. Forget key and Pair again revoke the key with `DELETE /v1/api-keys/current` (older drivers: the key list); a 401 on any request forgets the key and asks for a new pairing code.

## Doorbells

DoorBird doorstations come from `GET /v1/doorbells`, polled with the other devices every 10 s (an older driver answers 404: no doorbells; other failures keep the last list).

- **Ringing** — a ring is recent for 2 minutes: when its `last_ring_at` is within 2 minutes of this browser's clock (a controller clock up to 2 minutes ahead is believed), or when this page saw `last_ring_at` change within the last 2 minutes, whatever the clocks say. While it is recent, Home starts with a banner — "Someone is at the door — <name>", the doorbell's camera refreshed about every second, **Open gate** and **Dismiss** — and the other screens show one line that leads to it. Dismiss remembers that `last_ring_at` (per controller, in `localStorage`); the next ring shows the banner again.
- **Open gate** — doors and admin keys, on doorbells with `can_open`: a second tap within 5 s sends `POST /v1/doorbells/{id}/open` (Opening… → Sent). `403 DOOR_CONTROL_DISABLED` explains the Composer switch.
- **Room** — the picture (tap for the full view), "Last ring: 3 minutes ago · Motion: …", "Not responding" after a communication failure, the last five events with relative times (`Intl.RelativeTimeFormat`), and Open gate.
- **Favorites** — a starred doorbell shows its last ring and opens its room; it is highlighted while ringing.
- **Notifications** — Settings → App → **Turn on doorbell notifications** is the only place that asks for the permission. A ring then notifies (through the service worker when there is one) while the app is open but not in front; in the background only `/v1/doorbells` is polled. There is no push yet, so a closed app cannot notify. Clicking the notification brings the app to Home.

Controls change the screen at once, send the command, then re-read the device until the controller confirms it; a failed command reverts and shows a short error on the device. Device state refreshes every 10 s while the page is visible.

## Palettes and themes

Five palettes — graphite (default), ocean, forest, plum, midnight — each with a light and a dark variant, as CSS custom properties on `:root[data-palette=…][data-theme=…]` in `styles.css` (tokens `--bg`, `--card`, `--nav`, `--ink`, `--muted`, `--line`, `--onBg`/`--onText`, `--coolBg`/`--coolText`, `--primary`/`--primaryText`, `--okBg`/`--okText`/`--okDot`). The theme is Light, Dark or Auto (follows `prefers-color-scheme`); `data-theme` always holds the resolved value. The choice is stored in `localStorage` (`directorlink.palette`, `directorlink.theme`) and `meta[name=theme-color]` follows the page background. Adding a palette: a light and a dark token block and a swatch rule in `styles.css`, its name in `PALETTES` (`js/theme.js`) and `theme-boot.js`, and a label under `palettes` in each language file.

Fonts are Sora (headings) and IBM Plex Sans / IBM Plex Sans Hebrew (text) from Google Fonts, with system fallbacks — the offline copy renders without them.

## Languages

Every string on screen goes through `t(key, params)` from `js/i18n.js`, with plural forms chosen by `Intl.PluralRules` (`{ one: …, two: …, other: … }`). Language is Auto (browser languages), English or עברית, stored as `directorlink.lang`. Hebrew sets `<html lang="he" dir="rtl">`; the layout uses logical CSS properties, so it mirrors, and directional icons flip. Names from Control4 are rendered with `dir="auto"`. Rooms show `room.names[lang]` when set in Settings → Rooms, else the Control4 name.

To add a language:

1. Copy `i18n/en.js` to `i18n/<code>.js` and translate the values (missing keys fall back to English).
2. Add one line to `LANGUAGES` in `js/i18n.js`: `{ code: "<code>", label: "<name in that language>", dir: "ltr" | "rtl" }`.

Optionally list the file in `ASSETS` in `sw.js` so it is saved for offline use at install; otherwise it is saved the first time it is used. For a right-to-left language, also add it to the direction check in `theme-boot.js` to avoid a flash of the left-to-right layout.

## Offline mode

The service worker saves the app on the device, so it still opens when the internet is down and keeps controlling the house over the LAN:

- every same-origin `GET` goes to the network first and falls back to the saved copy when the network fails or takes longer than 3 seconds; each successful load refreshes the saved copy, so it never goes stale
- pages are saved under every path that serves them — Cloudflare redirects `/index.html` → `/` — and stored without the redirect, because browsers refuse redirected responses for page loads; redirects to other sites (the old console addresses) are left to the browser and never saved
- controller requests are cross-origin and are never intercepted or cached
- Settings → App → **Offline copy** shows whether the app is saved

`tests/app/sw.test.mjs` checks this against a fake network that serves the app the way Cloudflare does. Tests live outside `app/` because Cloudflare publishes everything in this folder.

## Cloudflare

The app is the Cloudflare Workers static-assets project `directorlink-app` on the `app.directorlink.io` custom domain ([`wrangler.jsonc`](wrangler.jsonc): assets from `.`, Cloudflare's default HTML and 404 handling). `.github/workflows/deploy.yml` runs `wrangler deploy` from this folder on pushes to `main`; pull requests get preview versions (the `previews` block).

`_headers` sets the security headers, `_redirects` the old console addresses; `.assetsignore` keeps `wrangler.jsonc`, `.assetsignore` and this README from being published. No environment variables are required. Every merge to `main` deploys, so web changes must go out together with the driver version they need.

## Local development

The driver accepts `http://localhost` origins, so the app can be tested against a real controller before it is deployed:

```bash
python -m http.server 8080 --directory app
```

Then open `http://localhost:8080`. Without a controller, run `python scripts/dev_server.py` as well, use `localhost` as the controller address and the pairing code it prints (see `docs/BUILD.md`).

## Local Network Access

The production site is served over HTTPS and talks to the controller over plain HTTP on the LAN. Chromium browsers gate these requests behind Local Network Access permission; requests to private IP literals or `.local` hostnames, annotated with `targetAddressSpace: "local"`, are allowed after the user grants it. A controller on this computer (`localhost`, the dev server) is annotated `"loopback"` instead, because Chromium blocks a request whose annotation does not match the address.

**iPhone and iPad cannot use the LAN connection.** Every browser on iOS and iPadOS uses WebKit, which blocks these HTTP requests from an HTTPS page as mixed content and has no Local Network Access permission to allow them; the request never leaves the device (the controller logs nothing) and the app shows "Could not reach DirectorLink". Pairing therefore has to happen on a computer or an Android phone. iPhones and iPads will connect through remote access (`docs/ACCOUNTS.md`).

The CSP in `_headers` allows Google Fonts (`fonts.googleapis.com`, `fonts.gstatic.com`) and `blob:` images (camera pictures are fetched with the API key and shown as blobs).
