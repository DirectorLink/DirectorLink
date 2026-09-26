# C4Bridge Project Specification

This file is the durable source of truth for the C4Bridge project. It exists so development can continue without relying on any previous chat or private context.

## Product goal

C4Bridge is an open-source, local-first management platform for **Control4 homeowners**.

It is intended for homeowners who want straightforward day-to-day device control and automation without having to use the full Composer Pro interface for routine changes.

C4Bridge is **not** a clone of Composer Pro and is not intended to replace advanced project engineering.

## Core product boundary

C4Bridge begins from one assumption:

> `C4Bridge.c4z` is already installed in the Control4 project.

How it was installed is outside the project scope. A homeowner may ask an integrator to install it, install it themselves if they have appropriate access, or use another installation workflow.

After installation, C4Bridge depends on **Director**, not Composer.

## Supported platform

- Minimum Director OS: **3.3.0**
- Target: **3.3.x and newer**, including later 3.x and 4.x/X4 where compatibility is confirmed
- Public C4Bridge API must remain stable across Director versions
- Director-version differences belong in the internal compatibility layer

## V1 architecture

```text
Cloudflare Pages PWA
        |
        | static HTML / JS / CSS
        v
Browser
        |
        | Local Network Access permission
        | authenticated direct LAN connection
        v
C4Bridge.c4z
        |
        | Control4 DriverWorks APIs
        v
Control4 Director
        |
        v
Existing Control4 project/devices
```

Cloudflare is **not** a relay. Control commands and project data are not intended to pass through C4Bridge cloud infrastructure in V1.

## V1 connectivity

- LAN only
- No remote-control cloud service
- No Internet-exposed C4Bridge port
- No port forwarding recommendation
- Remote users can use their own VPN/Tailscale/WireGuard outside the scope of C4Bridge
- Browser frontend is hosted on Cloudflare Pages and should become an installable/cacheable PWA

## V1 authentication

- One owner; every client (browser, phone, Home Assistant, script) gets its own named API key
- Authenticated API even on LAN: `Authorization: Bearer <api key>` on every route except health, the API description and pairing
- No default/shared password; credentials do not depend on Control4 cloud credentials
- Keys are random, stored encrypted on Director, listed without secrets and revocable (through the API, or all at once with a Composer action)
- First key (0.2.0): exchange the 8-digit Composer pairing code — valid 15 minutes, rotated after use, rate-limited
- Since 0.3.0: approve new clients with the **C4Bridge Access** button in the Control4 app, so Composer is no longer needed after installation (the pairing code remains a fallback)

## V1 device scope

Initial device families:

1. Lights
2. HVAC / thermostat / climate
3. Shades / blinds / motorized covers/windows

Policy for everything else:

- Discover it
- Show it
- Mark it as **unsupported**
- Add adapters one device/proxy family at a time

Do not send guessed raw commands to unknown devices.

## Control4 abstraction

The public API must never require a client to know Control4 command names.

Example:

```text
C4Bridge API:
set_brightness(70)

Internal adapter:
Control4 proxy-specific command
```

The normalized entity model should preserve:

- proxy ID
- proxy driver filename
- room
- protocol driver relationship
- protocol driver ID/name/filename
- normalized kind
- supported/unsupported status
- capabilities/state when adapters implement them

## Project ownership

C4Bridge owns its own:

- scenes/routines
- schedules
- automations

C4Bridge does **not** import or depend on:

- Composer programming
- Composer schedules
- Composer scenes
- Composer agents as the primary automation engine

## V1 scheduler scope

Later V1 scheduler work will support:

- fixed clock time
- day-of-week rules
- sunrise
- sunset
- positive/negative sunrise/sunset offsets
- persistent schedules that survive Director restart
- C4Bridge scenes as schedule actions

The scheduler will run inside C4Bridge/Director so a PC, browser, or phone does not need to remain online.

## Solar data

Use project location/time-zone data exposed by Director. Solar calculations should run locally so ordinary schedules do not require Internet access.

## Not in V1

- adding/removing arbitrary Control4 drivers
- editing bindings
- Composer-style programming editor
- importing Composer programming
- Control4 project upgrades
- C4Bridge cloud remote-access relay
- automatic `.c4z` self-update
- generic execution of raw commands against unknown devices

## Optional/deferred extensions

A plugin architecture may be added later for niche functionality. A Jewish-calendar module — Shabbat and holiday times as schedule triggers — is planned for later as an optional module inside the driver; it is not part of the first scheduler release.

## Distribution and versioning

- Official `C4Bridge.c4z` binaries are distributed through **GitHub Releases**
- The repository `VERSION` file holds the `MAJOR.MINOR.PATCH` release version (no suffixes) and is the only version to edit
- Release assets include `C4Bridge.c4z`, `openapi.json` and `SHA256SUMS.txt`
- Users may install a newer or older release manually through Composer Pro
- Downgrade safety is release-specific once persistent data formats exist
- No automatic in-driver update is part of V1

## Licensing

Apache License 2.0.

## Current implementation milestone

### Step 1 — bootstrap/package

Complete:

- repository initialized
- Apache-2.0
- DriverWorks `.c4z` source structure
- minimum OS metadata
- runtime OS version gate
- architecture and protocol documentation

### Step 2 — project discovery

Implemented:

- Director/project metadata
- project hierarchy
- all devices via `C4:GetDevices({})`
- hierarchy normalization
- room fallback from device records
- proxy/protocol relationship preservation
- known proxy classification
- normalized in-memory registry
- Composer-visible discovery status

### Step 3 — Light V2 adapter

Implemented in `v0.1.0-alpha.7`, with On/Off validated and KNX DriverWorks dimmer validation pending:

- Light V2 proxy detection
- state variable `1000`
- brightness variable `1001` when present
- variable subscriptions/live registry updates
- normalized `on` → Light V2 preset ID 1
- normalized `off` → Light V2 preset ID 2
- normalized `set_brightness` → adapter-selected compatibility path; KNX dimmers use `RAMP_TO_LEVEL` with `LEVEL` + `TIME = 0`, other Light V2 dimmers use `SET_BRIGHTNESS_TARGET` + `PERCENT`
- dedicated `GET /v1/lights` endpoint
- PWA Light controls

C4Bridge sends control only to the Light V2 proxy ID. It does not address backing protocol drivers directly.


### PWA shell — implemented ahead of transport

The initial Cloudflare Pages PWA shell is implemented under `web/`:

- framework-free HTML/CSS/JavaScript
- installable web manifest
- offline application shell via service worker
- Director IP/local-hostname storage
- browser readiness diagnostics
- security headers
- raster/SVG application icons

The PWA talks to the driver's LAN API directly. The service worker ignores all cross-origin requests so LAN traffic is never cached or proxied by the web shell. An API console page (`web/console.html`) lists every endpoint from the live API description and follows the bridge log.



### LAN API — 0.2.0

The LAN API is described by `api/openapi.yaml` (OpenAPI 3.1) and served on TCP port `41999`:

- HTTP on the LAN only; the public app remains HTTPS
- Chrome Local Network Access permission gates the public-to-local browser request
- API keys (Bearer) on every route except health, the API description and pairing
- CORS restricted to official C4Bridge origins, plus localhost for development
- logical resources: system, rooms, devices, lights, thermostats, logs, API keys
- `PATCH` with the desired state, answered with `202 Accepted`; RFC 9457 errors

See `api/README.md` for conventions and examples. The alpha routes (`/v1/system/info`, `/v1/climate`, `/v1/devices/{id}/actions/...`, `/v1/diagnostics`, header-based `/v1/pair`) were removed in 0.2.0.


### Thermostat V2 — alpha.9

The first climate adapter is implemented against the real Director command shapes captured from the stock Control4 UI.

State currently normalized from Thermostat V2 includes:
- current temperature in Celsius
- single target setpoint
- HVAC mode
- HVAC state
- fan mode where applicable
- connection state
- allowed HVAC mode list

Normalized actions:
- `set_hvac_mode`
- `set_fan_mode`
- `set_temperature`

Internal commands used on the real test system:
- `SET_MODE_HVAC { MODE = ... }`
- `SET_MODE_FAN { MODE = ... }`
- `SET_SETPOINT_SINGLE { CELSIUS = ... }`

C4Bridge exposes only actions supported by the normalized device capabilities. Heat-only zones do not receive cooling controls.

Since 0.2.0 these are exposed through `PATCH /v1/thermostats/{id}` as `mode`, `fan_speed` and `target_temperature`; the command names above stay internal to the adapter.
