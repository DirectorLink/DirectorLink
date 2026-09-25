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


## ADR-017 — Control lights through the Light V2 proxy

**Decision:** C4Bridge controls lighting entities by their Light V2 **proxy IDs**, not by sending commands directly to backing protocol drivers.

**State contract:**
- variable 1000 = Light State
- variable 1001 = Light Brightness Percent when the device is dimmable
- variable 1006 = Default On Preset Brightness when available

**Control contract:** normalized C4Bridge actions are translated to the Light V2 `SET_BRIGHTNESS_TARGET` command using `LIGHT_BRIGHTNESS_TARGET`.

**Why:** The proxy is Control4's abstraction boundary. It lets C4Bridge support Control4, Zigbee, Z-Wave and third-party lighting drivers through one documented interface instead of learning each protocol driver's private command set.

**Safety:** A device is not marked controllable unless its Light V2 state variable exists and C4Bridge can register the required state listener.
