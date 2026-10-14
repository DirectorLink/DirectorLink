# DirectorLink Architecture

## Product boundary

DirectorLink is a homeowner-facing local management layer for Control4 Director OS 3.3.0+.

DirectorLink assumes `DirectorLink.c4z` is already installed. Installation method is out of scope.

## Scope and limits

- Control4 Director OS **3.3.0+**
- `DirectorLink.c4z` is assumed to already be installed in the Control4 project
- Installation method is outside the scope of this project
- A standard REST API on the local LAN, described by OpenAPI 3.1, protected by API keys
- An app (PWA) hosted on Cloudflare; the browser connects directly to DirectorLink over the LAN, and seals every request with its own lock key, so its API key does not cross the network
- LAN-first, with no port forwarding; remote access with a Google or Apple account through `api.directorlink.io`, locked end to end so that DirectorLink's servers cannot read it (off by default; [`ACCOUNTS.md`](ACCOUNTS.md))
- One owner and invited family members, with a separate named API key per browser, app or script; each user is an admin or a member, with the rooms, devices and scenes an admin chose (1.8.0), and every key of theirs has their permissions; the devices of one Google or Apple account become one user when an admin confirms it (1.9.0)
- Device adapters: lights (Light V2 and the older Light proxy), HVAC/climate (Thermostat V2, including floor heating set through its heat setpoint, and Control4 thermostats with heat and cool setpoints), fans (the Control4 fan proxy: on, off and four speeds), blinds, cameras (snapshots, several at once; alerts and doorbell rings from camera drivers of DirectorLink's camera agreement, [`CAMERA_DRIVERS.md`](CAMERA_DRIVERS.md), and from the DirectorLink · Hikvision Camera driver), KNX relays and Control4's Relay Door, Gate and Garage Door Controllers (doors and gates, opened with a pulse or the controller's own Open; open or closed when the controller has a contact), DoorBird doorbells, Samsung refrigerators (through the Samsung Refrigerator (DirectorLink) driver: temperatures, the door, Power Cool, Power Freeze, Sabbath Mode and the ice maker), the alarm's status (security partitions: read-only, off by default), and Sonos speakers on the home network (off by default; DirectorLink talks to them itself, [`SONOS.md`](SONOS.md))
- Room names in several languages
- Unknown devices are exposed as unsupported
- DirectorLink owns its own scenes, schedules, and automations
- No import of Composer programming, scenes, or schedules
- Schedules by time and weekday, at sunrise or sunset with offsets, and by the weather (heat, wind and rain from Open-Meteo), with "only if" weather conditions; with the Jewish calendar on, also at candle lighting and havdalah, or never or only on Shabbat and holidays (worked out on the controller)
- Director location/timezone used for solar scheduling
- A private link per scene for the phone's own automations (iPhone Shortcuts, Android apps, an NFC tag), through the account; never for scenes that open doors or gates, and every run in History ([`SCENES.md`](SCENES.md))
- No automatic `.c4z` self-update: updates go through Composer (ADR-035)

## Runtime

```text
Cloudflare Workers static sites: app/ (app.directorlink.io),
console/ (console.directorlink.io), site/ (directorlink.io)
        |
        | HTTPS: static files only
        v
Browser / any API client (curl, Home Assistant, scripts)
        |                                     |
        | at home: LAN HTTP,                  | away (the app): HTTPS,
        | sealed (app) or API key (scripts),  | sealed end to end
        | described by api/openapi.yaml       v
        |                          api.directorlink.io (cloud/): accounts and the relay
        |                                     |
        |                                     | the driver's one outgoing WebSocket
        v                                     | (docs/RELAY.md)
DirectorLink.c4z inside Director  <-----------+
        |
        | DriverWorks
        v
Existing Control4 project devices
```

At home, clients talk to DirectorLink directly: the app with sealed requests, scripts with an API key. Away, the app's requests go through api.directorlink.io (`cloud/`), sealed end to end, so the relay cannot read them (docs/ACCOUNTS.md, docs/RELAY.md). Remote access is optional and off by default. With Direct HTTPS (1.12.0, ADR-082, off by default) the controller also serves the API over HTTPS on port 28443 under the home's own name (`<20 random letters and digits>.dlhome.cc`, whose public DNS record is its LAN address), so that iPhones and iPads, which cannot reach plain HTTP from the app's page, talk to it directly at home too; its certificate comes from Let's Encrypt through the relay (`src/api/direct_https.lua`, `cloud/src/https.js`).

## Repository

```text
api/        openapi.yaml — the API contract (single source of truth)
driver/     the DriverWorks driver
  src/api/        HTTP server, router, handlers, views (API ↔ internal model)
  src/auth/       API keys, roles, pairing, profiles, invitations; who may do what (access.lua),
                  users and their devices, and which keys share an account (users.lua,
                  accounts.lua; ADR-061)
  src/adapters/   Control4 proxy adapters (Light V2, Light V1 (legacy Light proxy), Thermostat V2, Control4
                  thermostat proxy, Fan, Blind, Camera, KNX Contact/Relay, Relay Door, Gate and Garage Door
                  Controllers (ADR-069), DoorBird, security
                  partitions: read-only, ADR-038; Samsung refrigerators through their DirectorLink
                  driver's variables, ADR-049)
  src/cloud/      remote access: WebSocket client, relay connection (docs/RELAY.md), the end-to-end
                  lock (lock.lua) and sealed requests, claims and joins (remote.lua); automatic
                  backups to the account, sealed to the backup password's key (auto_backup.lua,
                  backup_seal.lua; ADR-048); alerts sealed to each device's key (alerts.lua; ADR-050)
  src/control4/   discovery and normalization; Director's project events (Composer changes, read
                  again without a restart) and device events; drivers updated in Composer (their
                  devices set up again, ADR-059); camera snapshots; DirectorLink's camera agreement
                  (camera_drivers.lua: a camera driver's marker, alerts and rings, ADR-065); what a
                  light's driver declares, dimmer or switch (light_capabilities.lua, ADR-077);
                  DirectorLink's notification agreement (notify_targets.lua: the screens that show
                  its alerts, found by their marker, and the one command they get, ADR-086)
  src/core/       json, log, store, registry, version; random (secrets) and x25519 (pairing);
                  scenes, scene links (a private link per scene for the phone's automations,
                  ADR-051), ask-to-open links (a door's link that asks its person, ADR-058), schedules, scheduler, sun, weather, installer view; room names and layout;
                  backup (backup and restore, ADR-042; docs/BACKUP.md);
                  activity (the history admins read, ADR-046; docs/HISTORY.md);
                  favorites of devices removed in Composer (ADR-059; docs/PREFERENCES.md);
                  the Jewish calendar (jewish_calendar, the service, and its pure engine: hebrew_date,
                  holidays, parasha, holy_times; docs/CALENDAR.md);
                  the alerts on the home's screens, with their pictures, and their words in the
                  owner's language (notify, notify_words; ADR-086; docs/NOTIFY_DRIVERS.md)
  tests/          driver tests against a fake Director
app/        the app (PWA), deployed to app.directorlink.io
console/    API console, debugging and logs, deployed to console.directorlink.io
site/       landing page, deployed to directorlink.io
cloud/      accounts and the relay (Cloudflare Worker), api.directorlink.io
tests/      app and cloud tests, shared test vectors
scripts/    build and validation
docs/       specification, decisions, research, releases
```

## Driver layers

```text
request bytes → api/http.lua (parse) → api/server.lua (Host check, CORS, auth, routing, errors, access log)
             → api/handlers/*.lua → api/views.lua (public JSON)
sealed request (POST /v1/sealed, or an envelope from the relay)
             → api/handlers/sealed.lua → cloud/remote.lua (open, check, run as the key) → the same handlers
             → adapters/*.lua (Control4 commands) → Director
```

Control4 specifics — proxy drivers, command names, variable IDs — live only in `adapters/` and `control4/`. `api/views.lua` is the one place internal records become public JSON.

## Core rules

1. Minimum supported Director version: 3.3.0.
2. Director is the only Control4 runtime dependency.
3. Do not import Composer programming, schedules, or scenes.
4. DirectorLink owns its own scenes, schedules, and automations.
5. Unknown device types are visible but marked unsupported.
6. The public API uses logical names, never raw Control4 command names.
7. OS/version differences stay behind the Control4 compatibility layer.
8. The API needs an API key (or a request sealed with a key's lock key, `/v1/sealed`) for everything except health, the API description and pairing. Remote access is optional, off by default, and sealed end to end.
9. No automatic C4Z self-update in V1.
10. `api/openapi.yaml` and the driver routes must always match (enforced in CI).
