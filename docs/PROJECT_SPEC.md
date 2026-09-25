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

- One owner account only
- First-use pairing flow
- Authenticated API even on LAN
- No default/shared password
- Credentials must not depend on Control4 cloud credentials
- Exact request-signing/session design will be frozen when the LAN transport is implemented

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

A plugin architecture may be added later for niche functionality. A Hebrew/Jewish calendar module was discussed but is **explicitly excluded from C4Bridge core and V1**; if ever implemented, it should be optional.

## Distribution and versioning

- Official `C4Bridge.c4z` binaries are distributed through **GitHub Releases**
- The repository `VERSION` file contains the semantic release version
- Alpha/beta versions are GitHub prereleases
- Release assets include `C4Bridge.c4z` and `SHA256SUMS.txt`
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
- normalized `set_brightness` → `SET_BRIGHTNESS_TARGET` with `PERCENT = 0..100`
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

The PWA does not yet make Director requests. The service worker explicitly ignores all cross-origin requests so future LAN traffic is never cached or proxied by the web shell.



### Read-only LAN API spike — alpha.2

For the first browser-to-Director validation, C4Bridge exposes a minimal HTTP server on TCP port `41999`.

Security/transport rules for this alpha:

- HTTP is LAN-only; the public app remains HTTPS.
- Chrome Local Network Access permission gates the public-to-local browser request.
- Every data endpoint requires a per-install Bearer token.
- Token is generated with `C4:UUID("RANDOM")`.
- Token is persisted encrypted on Director.
- Browser CORS is restricted to official C4Bridge origins.
- The API is read-only.
- The token is manually copied from Composer only for this alpha test.

Routes:

- `GET /v1/system/info`
- `GET /v1/rooms`
- `GET /v1/devices`

This is an integration spike, not the final pairing UX. Successful real-Director testing will inform the final owner pairing/session design.
