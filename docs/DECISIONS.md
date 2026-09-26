# Architecture Decision Record

This file records decisions that should not be silently changed.

## ADR-001 — Director OS baseline

**Decision:** Minimum supported version is **3.3.0**.

**Why:** OS 3.3 provides a cleaner modern DriverWorks baseline while keeping compatibility with the older OS 3 family that C4Bridge targets.

## ADR-002 — Installation is out of scope

**Decision:** C4Bridge assumes `C4Bridge.c4z` is installed. The project does not care how the user obtained permission/access to install it.

**Consequence:** No jailbreak dependency and no dealer-specific runtime dependency.

## ADR-003 — Director is the runtime dependency

**Decision:** C4Bridge talks to Director from inside a DriverWorks driver.

**Rejected:** Building the core around Composer Pro or the external `/api/v1` Director REST interface.

## ADR-004 — Cloudflare frontend, local control

**Decision:** Host the PWA on Cloudflare Pages, but have the browser connect directly to C4Bridge on the LAN.

**Consequence:** Browser Local Network Access permission and correct CORS/private-network handling are part of onboarding.

## ADR-005 — LAN only in V1

**Decision:** No C4Bridge-hosted remote-control relay in V1.

## ADR-006 — One owner

**Decision:** One paired owner identity/account in V1. Multi-user/roles are deferred.

## ADR-007 — Adapter-based devices

**Decision:** Normalize devices and add explicit proxy-family adapters. Unknown devices remain unsupported rather than receiving guessed commands.

## ADR-008 — C4Bridge owns automation

**Decision:** Scenes, schedules, and automations are C4Bridge-native. Do not import Composer programming/schedules/scenes.

## ADR-009 — Internal scheduler

**Decision:** Do not depend on the Composer Scheduler Agent as the primary automation engine. C4Bridge will persist schedules and execute actions itself using Director timers/time/location APIs.

## ADR-010 — No automatic C4Z update in V1

**Decision:** Updates are manual through Composer initially.

## ADR-011 — Discovery source

**Decision:** Prefer structured DriverWorks tables:
- `C4:GetDevices({})`
- `C4:GetProjectHierarchy()`

rather than parsing the entire project XML when structured APIs already provide the required data.

**Reason:** Less fragile and easier to normalize across versions.

## ADR-012 — User-facing entity identity

**Decision:** Proxy entities are the primary homeowner-facing devices. Backing protocol drivers are retained as relationship metadata and not shown as duplicate controllable entities.

Standalone/combo drivers without proxy relationships may appear as unsupported entities.

## ADR-013 — Apache-2.0

**Decision:** C4Bridge uses Apache License 2.0.


## ADR-014 — GitHub Releases are the binary distribution channel

**Decision:** Do not commit built `C4Bridge.c4z` binaries to `main`. Publish official binaries as versioned GitHub Release assets.

**Why:** Users can clearly upgrade/downgrade, release binaries stay tied to immutable tags, and source history remains clean.

**Release contents:** `C4Bridge.c4z`, `SHA256SUMS.txt`, and release notes.

**Version source:** root `VERSION` file using semantic versioning. Versions with a prerelease suffix such as `-alpha.1` are published as prereleases.


## ADR-015 — Start the PWA without a frontend framework

**Decision:** The first C4Bridge PWA is plain HTML, CSS, and JavaScript hosted directly from the repository `web/` directory.

**Why:** The current UI is small, this removes Node/framework dependencies from deployment, and it lets us prove the harder browser-to-LAN transport before committing to a larger frontend stack.

**Cloudflare configuration:** root `web`, build command `exit 0`, output directory `.`.

**Revisit:** A framework/build tool may be introduced later if the device dashboard, state management, routing, or component complexity justifies it.


## ADR-016 — Read-only HTTP transport spike on port 41999

**Decision:** Validate browser-to-Director communication with a minimal HTTP/1.1 server implemented on DriverWorks `C4:CreateServer`, listening on fixed TCP port `41999`.

**Why fixed port:** A public browser cannot discover Director's random ephemeral DriverWorks socket port. A known port gives the PWA a deterministic local endpoint without LAN scanning.

**Security:** Read-only routes require a random per-install Bearer token persisted encrypted on Director. CORS is restricted to official C4Bridge origins.

**Status:** Alpha integration decision. Re-evaluate port configurability and final pairing/authentication after testing on real systems.

**Superseded by ADR-019 in 0.2.0.** The fixed port 41999 stays; the read-only alpha routes were replaced by the OpenAPI contract.


## ADR-017 — Control lights through the Light V2 proxy

**Decision:** C4Bridge controls lighting entities by their Light V2 **proxy IDs**, not by sending commands directly to backing protocol drivers.

**State contract:**
- variable 1000 = Light State
- variable 1001 = Light Brightness Percent when the device is dimmable
- variable 1006 = Default On Preset Brightness when available

**Control contract:** On/Off use `SET_BRIGHTNESS_TARGET` with static preset IDs 1/2 and are validated on a real Director. Explicit brightness is adapter-selected: `knx_dimmer.c4i` uses DriverWorks-documented `RAMP_TO_LEVEL` (`LEVEL`, `TIME = 0`); other Light V2 dimmers currently use `SET_BRIGHTNESS_TARGET` with `PERCENT`.

**Why:** The proxy is Control4's abstraction boundary. It lets C4Bridge support Control4, Zigbee, Z-Wave and third-party lighting drivers through one documented interface instead of learning each protocol driver's private command set.

**Safety:** A device is not marked controllable unless its Light V2 state variable exists and C4Bridge can register the required state listener.


## ADR-018 — One-owner local pairing

**Decision:** V1 uses a short local pairing code to provision one long-lived owner Bearer credential to a browser.

**Owner credential:**
- generated randomly with `C4:UUID("RANDOM")`
- persisted encrypted on Director
- never displayed in Composer after alpha.8
- stored locally by each paired browser

**Pairing code:**
- 8 numeric digits
- visible in the C4Bridge Composer properties
- valid for 15 minutes
- rotated after every successful pairing
- five failed attempts per minute trigger a 60-second lock
- never persisted by the PWA

**Transport:** `POST /v1/pair` is the only unauthenticated application route. The code is sent in the `X-C4Bridge-Pairing-Code` header, not in a URL.

**Why:** Homeowners should not copy long API secrets from Composer. Pairing keeps the long credential private while preserving the local-first, no-cloud-relay architecture.

**Superseded by ADR-021 in 0.2.0.** Pairing now issues named API keys instead of one shared owner credential, and the code moved from a header to the JSON body of `POST /v1/auth/pair`.


## ADR-019 — OpenAPI-first REST API with logical names

**Decision:** `api/openapi.yaml` (OpenAPI 3.1) is the contract for the LAN API. Resources use logical names — `rooms`, `devices`, `lights`, `thermostats`, `logs`, `api-keys` — and state changes are `PATCH` requests with the desired state (`{"on": true}`), answered with `202 Accepted`. Errors use RFC 9457 Problem Details with a stable `code`.

**Why:** A standard description lets any client (the web app, Postman, Home Assistant, scripts) use the API without knowing Control4. Control4 command names, proxy IDs and variable numbers stay inside the adapters.

**Consequences:**
- `scripts/check_api.py` fails CI when the spec and `driver/src/api/routes.lua` differ in any method, path or public flag.
- The build embeds the spec so the driver serves it at `/v1/openapi.json`; releases publish it as `openapi.json`.
- The driver uses its own JSON encoder/decoder (`src/core/json.lua`) for deterministic output (explicit `[]` and `null`) and so the API layer can be tested in plain Lua.
- The HTTP server runs without a delimiter and assembles requests itself, so request bodies (`Content-Length`) are supported.

## ADR-020 — One repository for API, driver and web app

**Decision:** The API contract, driver and web app stay in this repository (`api/`, `driver/`, `web/`), with the web app deployed by Cloudflare from `web/`.

**Why:** While the API is changing, most changes touch the spec, driver and web app together; one pull request keeps them consistent and CI checks them together. The Jewish-calendar module (later) and the automation engine ship inside the `.c4z` anyway.

**Revisit:** Split a part into its own repository when it gets an independent lifecycle or other consumers (most likely a reusable calendar library, then the web app).

## ADR-021 — API keys

**Decision:** Every route except health, the API description and pairing requires `Authorization: Bearer <api key>`. Keys are named, stored encrypted on Director (at most 20), listed without secrets, and revocable through the API or all at once with the Composer action **Revoke All API Keys**.

**First key (0.2.0):** exchange the 8-digit Composer pairing code at `POST /v1/auth/pair` (15-minute code, rotated after use, 5 failures per minute lock pairing for 60 seconds).

**Since 0.3.0:** the first key comes from approval in the Control4 app: the driver adds a **C4Bridge Access** experience button (a `uibutton` proxy on binding 5001); a client calls `POST /v1/auth/requests`, the homeowner presses the button within 2 minutes, and the client collects its key once with the secret request id. One request waits at a time, 5 per 10 minutes. The Composer pairing code stays as a fallback.

**Why keys and not an open LAN API:** the API can operate door, gate and garage relays through KNX; without a key anything on the home network could.

## ADR-024 — C4Bridge is a protocol driver with a button proxy, not a combo driver

**Decision (0.3.0):** `driver.xml` declares no `<combo>`; the C4Bridge protocol device runs the Lua code and owns one `uibutton` proxy on binding 5001 (**C4Bridge Access**).

**Why:** Real-system testing showed that for a combo driver the Director creates only the combined device and never the extra button proxy. Every working button driver on the test system (door and garage relays, DoorBird, experience buttons) is a protocol device (item type 6) with a `uibutton` child proxy (type 7).

**Consequence:** Moving from the 0.2.x combo layout needs a one-time remove and re-add in Composer. `check_package.py` fails if `<combo>` comes back. Discovery skips the bridge's own proxies.

## ADR-022 — Versions are MAJOR.MINOR.PATCH with one source

**Decision:** `VERSION` holds a plain `MAJOR.MINOR.PATCH` version with no pre-release suffix and is the only version to edit. The build stamps it into `version.lua`, the API description and `driver.xml`, where Control4's integer version is derived as `MAJOR*10000 + MINOR*100 + PATCH`.

**Why:** One place to change, and the Control4 driver version always increases with the release version. `0.x` releases already signal that the project is in development.

## ADR-023 — Driver log served by the API

**Decision:** The driver keeps its last 500 log entries in memory and serves them at `GET /v1/logs` (filters by level, category and sequence number); the level is set with `PATCH /v1/logs/settings` or the Composer **Log Level** property. Entries also go to the Director driver log.

**Scope:** C4Bridge's own log only. Director's system logs are outside the driver sandbox and contain other drivers' data, so they are not exposed over the LAN. Fields such as keys, tokens and pairing codes are redacted before logging.

## ADR-025 — API keys have roles; doors need a Composer switch

**Context:** One kind of key could do everything, including opening doors and creating more keys. Remote access (next) and family members need less than that.

**Decision (0.7.0):** Four ordered roles — `viewer`, `member`, `doors`, `admin` — each allowed everything the ones before it are. Every non-public route in `routes.lua` names the least role it needs, and the OpenAPI operation states the same as `x-c4bridge-role`; `check_api.py` fails the build when they differ or when a restricted operation does not document 403. Keys from before roles existed become `admin`; the Composer pairing code issues `admin`; access requests default to `admin` for a home's first key and `member` afterwards, and Composer shows the requested role before the homeowner presses the button. The last admin key cannot be demoted. Opening doors additionally needs the Composer property **Door Control** = Enabled (default Disabled).

**Consequence:** Remote users will map onto the same roles. The web app should read `GET /v1/api-keys/current` and hide what the key may not do.
