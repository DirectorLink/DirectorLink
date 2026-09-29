# Architecture Decision Record

This file records decisions that should not be silently changed.

## ADR-001 — Director OS baseline

**Decision:** Minimum supported version is **3.3.0**.

**Why:** OS 3.3 provides a cleaner modern DriverWorks baseline while keeping compatibility with the older OS 3 family that DirectorLink targets.

## ADR-002 — Installation is out of scope

**Decision:** DirectorLink assumes `DirectorLink.c4z` is installed. The project does not care how the user obtained permission/access to install it.

**Consequence:** No jailbreak dependency and no dealer-specific runtime dependency.

## ADR-003 — Director is the runtime dependency

**Decision:** DirectorLink talks to Director from inside a DriverWorks driver.

**Rejected:** Building the core around Composer Pro or the external `/api/v1` Director REST interface.

## ADR-004 — Cloudflare frontend, local control

**Decision:** Host the PWA on Cloudflare Pages, but have the browser connect directly to DirectorLink on the LAN.

**Consequence:** Browser Local Network Access permission and correct CORS/private-network handling are part of onboarding.

**Superseded in part by ADR-026 (0.8.0):** the sites are Cloudflare Workers static assets, deployed by `deploy.yml`.

## ADR-005 — LAN only in V1

**Decision:** No DirectorLink-hosted remote-control relay in V1.

**Superseded by ADR-029 (0.10.0):** optional remote access through api.directorlink.io, sealed end to end.

## ADR-006 — One owner

**Decision:** One paired owner identity/account in V1. Multi-user/roles are deferred.

**Superseded by ADR-025, ADR-027 and ADR-029:** keys have roles, the owner pairs and everyone else is invited.

## ADR-007 — Adapter-based devices

**Decision:** Normalize devices and add explicit proxy-family adapters. Unknown devices remain unsupported rather than receiving guessed commands.

## ADR-008 — DirectorLink owns automation

**Decision:** Scenes, schedules, and automations are DirectorLink-native. Do not import Composer programming/schedules/scenes.

## ADR-009 — Internal scheduler

**Decision:** Do not depend on the Composer Scheduler Agent as the primary automation engine. DirectorLink will persist schedules and execute actions itself using Director timers/time/location APIs.

## ADR-010 — No automatic C4Z update in V1

**Decision:** Updates are manual through Composer initially.

**Extended by ADR-035 (1.1.0):** admins see in the app when a newer release is out, with its download and the Composer steps; installing stays in Composer.

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

**Decision:** DirectorLink uses Apache License 2.0.


## ADR-014 — GitHub Releases are the binary distribution channel

**Decision:** Do not commit built `DirectorLink.c4z` binaries to `main`. Publish official binaries as versioned GitHub Release assets.

**Why:** Users can clearly upgrade/downgrade, release binaries stay tied to immutable tags, and source history remains clean.

**Release contents:** `DirectorLink.c4z`, `SHA256SUMS.txt`, and release notes.

**Version source:** root `VERSION` file using semantic versioning. Versions with a prerelease suffix such as `-alpha.1` are published as prereleases.

**Since changed (ADR-022):** releases also carry `openapi.json`, and `VERSION` is plain `MAJOR.MINOR.PATCH`, without prerelease suffixes.


## ADR-015 — Start the PWA without a frontend framework

**Decision:** The first DirectorLink PWA is plain HTML, CSS, and JavaScript hosted directly from the repository `app/` directory.

**Why:** The current UI is small, this removes Node/framework dependencies from deployment, and it lets us prove the harder browser-to-LAN transport before committing to a larger frontend stack.

**Cloudflare configuration:** root `web`, build command `exit 0`, output directory `.`. (Superseded by ADR-026: `app/`, `console/` and `site/` are deployed by `deploy.yml`.)

**Revisit:** A framework/build tool may be introduced later if the device dashboard, state management, routing, or component complexity justifies it.


## ADR-016 — Read-only HTTP transport spike on port 41999

**Decision:** Validate browser-to-Director communication with a minimal HTTP/1.1 server implemented on DriverWorks `C4:CreateServer`, listening on fixed TCP port `41999`.

**Why fixed port:** A public browser cannot discover Director's random ephemeral DriverWorks socket port. A known port gives the PWA a deterministic local endpoint without LAN scanning.

**Security:** Read-only routes require a random per-install Bearer token persisted encrypted on Director. CORS is restricted to official DirectorLink origins.

**Status:** Alpha integration decision. Re-evaluate port configurability and final pairing/authentication after testing on real systems.

**Superseded by ADR-019 in 0.2.0.** The fixed port 41999 stays; the read-only alpha routes were replaced by the OpenAPI contract.


## ADR-017 — Control lights through the Light V2 proxy

**Decision:** DirectorLink controls lighting entities by their Light V2 **proxy IDs**, not by sending commands directly to backing protocol drivers.

**State contract:**
- variable 1000 = Light State
- variable 1001 = Light Brightness Percent when the device is dimmable
- variable 1006 = Default On Preset Brightness when available

**Control contract:** On/Off use `SET_BRIGHTNESS_TARGET` with static preset IDs 1/2 and are validated on a real Director. Explicit brightness is adapter-selected: `knx_dimmer.c4i` uses DriverWorks-documented `RAMP_TO_LEVEL` (`LEVEL`, `TIME = 0`); other Light V2 dimmers currently use `SET_BRIGHTNESS_TARGET` with `PERCENT`.

**Why:** The proxy is Control4's abstraction boundary. It lets DirectorLink support Control4, Zigbee, Z-Wave and third-party lighting drivers through one documented interface instead of learning each protocol driver's private command set.

**Safety:** A device is not marked controllable unless its Light V2 state variable exists and DirectorLink can register the required state listener.

**Extended by ADR-033 (1.1.0):** the legacy Light proxy (`light.c4i`) is controlled the same way, through its proxy, with its own commands.


## ADR-018 — One-owner local pairing

**Decision:** V1 uses a short local pairing code to provision one long-lived owner Bearer credential to a browser.

**Owner credential:**
- generated randomly with `C4:UUID("RANDOM")`
- persisted encrypted on Director
- never displayed in Composer after alpha.8
- stored locally by each paired browser

**Pairing code:**
- 8 numeric digits
- visible in the DirectorLink Composer properties
- valid for 15 minutes
- rotated after every successful pairing
- five failed attempts per minute trigger a 60-second lock
- never persisted by the PWA

**Transport:** `POST /v1/pair` is the only unauthenticated application route. The code is sent in the `X-DirectorLink-Pairing-Code` header, not in a URL.

**Why:** Homeowners should not copy long API secrets from Composer. Pairing keeps the long credential private while preserving the local-first, no-cloud-relay architecture.

**Superseded by ADR-021 in 0.2.0.** Pairing now issues named API keys instead of one shared owner credential, and the code moved from a header to the JSON body of `POST /v1/auth/pair`.


## ADR-019 — OpenAPI-first REST API with logical names

**Decision:** `api/openapi.yaml` (OpenAPI 3.1) is the contract for the LAN API. Resources use logical names — `rooms`, `devices`, `lights`, `thermostats`, `logs`, `api-keys` — and state changes are `PATCH` requests with the desired state (`{"on": true}`), answered with `202 Accepted`. Errors use RFC 9457 Problem Details with a stable `code`.

**Why:** A standard description lets any client (the app, Postman, Home Assistant, scripts) use the API without knowing Control4. Control4 command names, proxy IDs and variable numbers stay inside the adapters.

**Consequences:**
- `scripts/check_api.py` fails CI when the spec and `driver/src/api/routes.lua` differ in any method, path or public flag.
- The build embeds the spec so the driver serves it at `/v1/openapi.json`; releases publish it as `openapi.json`.
- The driver uses its own JSON encoder/decoder (`src/core/json.lua`) for deterministic output (explicit `[]` and `null`) and so the API layer can be tested in plain Lua.
- The HTTP server runs without a delimiter and assembles requests itself, so request bodies (`Content-Length`) are supported.

## ADR-020 — One repository for API, driver and app

**Decision:** The API contract, driver and app stay in this repository (`api/`, `driver/`, `app/`), with the app deployed by Cloudflare from `app/`.

**Why:** While the API is changing, most changes touch the spec, driver and app together; one pull request keeps them consistent and CI checks them together. The Jewish-calendar module (later) and the automation engine ship inside the `.c4z` anyway.

**Revisit:** Split a part into its own repository when it gets an independent lifecycle or other consumers (most likely a reusable calendar library, then the app).

## ADR-021 — API keys

**Decision:** Every route except health, the API description and pairing requires `Authorization: Bearer <api key>`. Keys are named, stored on Director (at most 20; encrypted up to 0.8.0, only hashes since 0.9.2 — ADR-028), listed without secrets, and revocable through the API or all at once with the Composer action **Revoke All API Keys**.

**First key (0.2.0):** exchange the 8-digit Composer pairing code at `POST /v1/auth/pair` (15-minute code, rotated after use, 5 failures per minute lock pairing for 60 seconds).

**0.3.0–0.7.0 (replaced by ADR-027):** the first key came from approval in the Control4 app: the driver adds a **DirectorLink Access** experience button (a `uibutton` proxy on binding 5001); a client calls `POST /v1/auth/requests`, the homeowner presses the button within 2 minutes, and the client collects its key once with the secret request id. One request waits at a time, 5 per 10 minutes. The Composer pairing code stays as a fallback.

**Why keys and not an open LAN API:** the API can operate door, gate and garage relays through KNX; without a key anything on the home network could.

## ADR-024 — DirectorLink is a protocol driver with a button proxy, not a combo driver

**Superseded by ADR-027 (0.8.0):** with the button gone, DirectorLink is a combo driver again.

**Decision (0.3.0):** `driver.xml` declares no `<combo>`; the DirectorLink protocol device runs the Lua code and owns one `uibutton` proxy on binding 5001 (**DirectorLink Access**).

**Why:** Real-system testing showed that for a combo driver the Director creates only the combined device and never the extra button proxy. Every working button driver on the test system (door and garage relays, DoorBird, experience buttons) is a protocol device (item type 6) with a `uibutton` child proxy (type 7).

**Consequence:** Moving from the 0.2.x combo layout needs a one-time remove and re-add in Composer. `check_package.py` fails if `<combo>` comes back. Discovery skips the bridge's own proxies.

## ADR-022 — Versions are MAJOR.MINOR.PATCH with one source

**Decision:** `VERSION` holds a plain `MAJOR.MINOR.PATCH` version with no pre-release suffix and is the only version to edit. The build stamps it into `version.lua`, the API description and `driver.xml`, where Control4's integer version is derived as `MAJOR*10000 + MINOR*100 + PATCH`.

**Why:** One place to change, and the Control4 driver version always increases with the release version. `0.x` releases already signal that the project is in development.

## ADR-023 — Driver log served by the API

**Decision:** The driver keeps its last 500 log entries in memory and serves them at `GET /v1/logs` (filters by level, category and sequence number); the level is set with `PATCH /v1/logs/settings` or the Composer **Log Level** property. Entries also go to the Director driver log.

**Scope:** DirectorLink's own log only. Director's system logs are outside the driver sandbox and contain other drivers' data, so they are not exposed over the LAN. Fields such as keys, tokens and pairing codes are redacted before logging.

## ADR-025 — API keys have roles; doors need a Composer switch

**Context:** One kind of key could do everything, including opening doors and creating more keys. Remote access (next) and family members need less than that.

**Decision (0.7.0):** Four ordered roles — `viewer`, `member`, `doors`, `admin` — each allowed everything the ones before it are. Every non-public route in `routes.lua` names the least role it needs, and the OpenAPI operation states the same as `x-directorlink-role`; `check_api.py` fails the build when they differ or when a restricted operation does not document 403. Keys from before roles existed become `admin`; the Composer pairing code issues `admin`; access requests default to `admin` for a home's first key and `member` afterwards, and Composer shows the requested role before the homeowner presses the button. The last admin key cannot be demoted. Opening doors additionally needs the Composer property **Door Control** = Enabled (default Disabled).

**Consequence:** Remote users will map onto the same roles. The app should read `GET /v1/api-keys/current` and hide what the key may not do.

## ADR-026 — The project is DirectorLink, on directorlink.io

**Context:** "C4Bridge" leaned on the Control4 name and the project needed an international brand before it has outside users and accounts. The API console had grown into a developer tool of its own inside the app.

**Decision (0.8.0):** The project, driver and API are named **DirectorLink** (slogan: *Direct to Director. End-to-end integration. Open source.*), on `directorlink.io`. The driver package is `DirectorLink.c4z` and its button **DirectorLink Access**. The repository holds three static sites, each its own Cloudflare Worker with a custom domain: `app/` (formerly `web/`) on `app.directorlink.io`, `console/` (API console, debugging, logs, key management) on `console.directorlink.io`, and `site/` (landing page) on `directorlink.io`. GitHub Actions deploys them (`deploy.yml`) instead of dashboard-configured builds, so the deployment is part of the repository. Past release notes and the validation log keep the old name as written.

**Consequence:** Control4 sees DirectorLink as a different driver: moving from C4Bridge means removing it and adding DirectorLink, so API keys, room names and the Door Control setting start fresh. The driver's CORS allowlist is the two new sites plus localhost (localhost removed in 1.0.0, ADR-032); the old `app.c4bridge.io` no longer reaches a DirectorLink controller.

## ADR-027 — Owners pair once with an on-demand code; everyone else is invited

**Context:** 0.3.0–0.7.0 approved each new browser with a button in the Control4 app. That needed a child proxy (so DirectorLink could not be a single device), a workaround to make the button visible, and an approval for every phone. With accounts and remote access coming, only the owner should ever need to prove control of the project.

**Decision (0.8.0):** The button and access requests are removed; DirectorLink is again a single self-contained device (combo driver with its own proxy). The first key comes from a pairing code created on demand with the Composer action **New Pairing Code** (automatically while the driver has no keys): shown as `1234 5678`, valid 15 minutes, works once, rate-limited (5 wrong codes → 60 s lock), and always `admin` — Composer access already means full control. Further keys are created by an admin. With remote access (planned): the owner signs in with Google or Apple and claims the home on the LAN with a pairing code; family members join by an invitation tied to the invited email (single use, 7 days; the owner approves when the accepting account's email differs); roles are the same as for API keys. Home-network use without an account stays possible.

**Consequence:** Installers read the code for homeowners without Composer. Replaces the approval flow of ADR-021 and the protocol-driver-with-button layout of ADR-024. The Composer properties are reduced to what an installer needs; the load history moves to `GET /v1/system` and the console.

## ADR-028 — Stored data is written as `json:` plus JSON; keys are kept as hashes

**Context:** Up to 0.9.1, DirectorLink lost its API keys and its remote-access identity whenever the driver reloaded, and room names were read by the same kind of code. On the test controller (OS 3.4.3) the values were saved — they are in Director's `state.db` — but `C4:PersistGetValue` returned a stored JSON string decoded into a Lua table, and DirectorLink accepted only a string, so it started empty. Values that are not JSON (the load and pairing counters) came back as written, which hid the problem. The keys that 0.8.0 kept encrypted were lost on update too; whether they also came back decoded or could not be decrypted (Director logs "has no driverKey" at every load of the driver) was not established.

**Decision (0.9.2):** `src/core/store.lua` writes every stored value as `json:` followed by JSON, which Director returns unchanged, and accepts tables Director has already decoded, so data written by 0.9.1 and older is read and then rewritten. Keys are kept in plain persistence as SHA-256 hashes (SHA-1 on a controller without SHA-256; each key records its algorithm). A presented key is hashed and compared in constant time; the key itself exists only in the response that creates it. Keys in the encrypted store of 0.8.0 and 0.9.0 are moved when Director can read that store, which is then emptied. The remote-access identity is kept in plain persistence as well: its secret has to be sent to the relay, so it cannot be kept as a hash.

**Consequence:** Keys, room names and the home identity survive driver updates and restarts, and each load logs how the keys came back (`keys loaded`, `stored_as`). Whoever can read the driver's stored data (root on the controller, possibly a project backup) finds only hashes of long random keys, which cannot be turned back into keys. The home secret is readable there; that is acceptable while remote access is a read-only test, and is revisited when claiming a home with a pairing code replaces trust on first use. The fake Director in the driver tests decodes stored JSON the same way. (Since ADR-029 each key's lock key is stored too; ADR-032 lets the owner replace the home secret and says what such a copy allows.)

## ADR-035 — Driver updates: a guided notice first, one-tap install only after a test on a real controller

**Context:** Updating DirectorLink means Composer: download `DirectorLink.c4z` from the release, keep exactly that name, and run Update Driver on the device (ADR-010, ADR-014). Admins learned about a release only by watching GitHub. No documented DriverWorks API installs a `.c4z`. The only known method — the unlock key of `C4:FileSetDir`, writing the package into `C4Z_ROOT` and `UpdateProjectC4i` on `127.0.0.1:5020`, used by some open-source drivers — is undocumented and unproven on OS 3.4.3.

**Decision (1.1.0):** The app shows admins that a newer release is out, with What's new, a download of that release's `DirectorLink.c4z` and the Composer steps. The admin's device asks GitHub's releases API (`releases/latest`) at most every 12 hours; other roles never ask, and a driver whose version is not MAJOR.MINOR.PATCH is never compared. Only the version, the date and links into the project's releases are used, never the text of the release notes. Later, and only after a test with a throwaway driver on the owner's CORE-1 succeeds: installing from the app, for admins only, behind a Composer property **App Updates** (default Not allowed), with packages signed in GitHub and checked by the driver, and only to newer versions. Going back stays in Composer. The minimum OS stays 3.3.0 (ADR-001), so the signature is checked in plain Lua.

**Consequence:** Nothing new runs on the controller. GitHub sees admins' IP addresses about twice a day; the privacy page says so. An admin whose app asked just before a release was published hears of it up to 12 hours later.

## ADR-034 — The driver checks the relay's certificate against roots it carries

**Context:** Up to 1.0.0 the driver opened the relay connection with `NetPortOptions` `SSL` and no `VERIFY_MODE`, and Control4's documentation says Director then checks nothing. Everything through the relay is sealed end to end (ADR-029), but the handshake carries the home secret, so anyone in the network path could pose as the relay, take the secret and keep the home offline.

**Decision (1.1.0):** The connection asks for `VERIFY_MODE = "peer"`, with `CACERTFILE` set to `certs/directorlink-roots.pem` inside the package: the root certificates of the authorities Cloudflare issues the relay's certificate from (Let's Encrypt, Google Trust Services, SSL.com), taken by name from certifi, with each SHA-256 in the file's header. `scripts/check_package.py` checks the options and that the file holds exactly these roots, each with its pinned SHA-256, and no key; `scripts/check_repo.py` allows this one `.pem`. Control4 does not document how Director reports a certificate that fails the check, so the driver ends any relay connection attempt that has not opened within 30 s and retries with its usual backoff.

**Consequence:** If Cloudflare moves the relay to an authority that is not in the file, or a root expires (2035–2046), remote access stops until a driver update, so the file is rebuilt from a current CA list first (docs/RELAY.md). Control4 does not document whether Director also checks the host name with `peer`; if not, a certificate one of these authorities issued for another name would pass too.

## ADR-033 — Contributed device families and dual setpoints

**Context:** bkwagner's pull requests #14, #19 and #16 added three device families that DirectorLink listed as unsupported, found in his house and read from his Director: the legacy Light proxy, heat-only Thermostat V2 floor heating whose single setpoint is unused, and the Control4 thermostat proxy with separate heat and cool setpoints. They were rebuilt on 1.0.0 (docs/PROJECT_SPEC.md, *Adapters added in 1.1.0*).

**Decision (1.1.0):**
- **Legacy Light proxy** (`light.c4i`): its own adapter, so the Light V2 path validated on real hardware does not change. State from `1000` and `1001` as on Light V2; `ON`, `OFF` and `SET_LEVEL {LEVEL}` with no ramp time, to the proxy; no KNX exception without a trace from a real device.
- **Heat-setpoint rule:** a Thermostat V2 zone follows its heat setpoint only while it is heat-only, its single setpoint reads 0 in both scales and the heat setpoint does not, checked again on every change. On that path it goes down to 5 °C and takes `SET_SETPOINT_HEAT` in the project's scale. Zones with Cool or Auto never take it.
- **Thermostat proxy scale:** the project's scale is required, never guessed. Setpoints are read and compared in its units (whole °F, tenths of °C) and commands go out in it only, whole degrees in °F; the API stays in °C.
- **Public shape:** every thermostat has `setpoints` (`single` or `dual`), `heat_setpoint`, `cool_setpoint` and `setpoint_deadband` (null on single-setpoint ones). On a dual thermostat `target_temperature` is the setpoint of the current mode (null in auto and off), PATCH and scene steps take `heat_setpoint` and `cool_setpoint`, and a `target_temperature` sets the setpoint of the request's mode, else the current one.
- **Push rule:** one setpoint moves the other when needed to keep the deadband; two sent together must already be that far apart. They are sent in the order that never breaks the deadband in between.
- **Safety, as ADR-017:** a device is controllable only when its state variables exist and its listeners register, and every command of a request is checked by its adapter (`Manager.prepare`) before any is sent, so a refused setpoint does not leave the mode changed.
- Fan speeds: the API lists only its own values, which gain `on` and `circulate`.

**Why:** One rule for PATCH, older clients and scene steps. A 1.0.0 client, or an existing "cool 24" scene, sends only `target_temperature`, and that works in heat and cool; sending both setpoints stays strict.

**Consequence:** The API only gains fields, so 1.0.0 clients keep working; in auto they see no target. Room and whole-home scene steps include the new devices. The IDs and commands come from the contributor's Director; the rebuilt commands are covered by tests against the fake Director and are yet to be re-run on real hardware (docs/TESTING.md 0p).

## ADR-032 — The app's key stays off the home network; security review fixes

**Context:** A public review of the code (issue #43) pointed out that an admin key picked up on the home Wi-Fi (plain HTTP) was enough to claim the home to another account and to use it from anywhere; that pairing codes could be guessed through the relay and one person's wrong guesses locked pairing for everyone; that `localhost` was an allowed origin and the `Host` header was not checked (DNS rebinding); that every secret came from `C4:UUID("RANDOM")` alone; that viewers saw the home's exact location; that any member could register invitation ids with the cloud; and that a copy of the controller's data (home secret and lock keys) was enough to pose as the controller.

**Decision (1.0.0):** The app seals its requests on the home network with the lock of ADR-029 (`GET`/`POST /v1/sealed`) and pairs with an X25519 key exchange whose lock also covers the pairing code and both public keys, so its key is not sent in the clear; `Authorization: Bearer` stays for scripts and the console. Pairing is refused as a sealed or relayed request; five wrong codes lock pairing per client address for 60 s and twenty close the code. The driver accepts only DirectorLink's two sites as origins (no `localhost`, also not in development builds: only the local test bridge, `driver/tests/dev_bridge.lua`, also allows `http://localhost:<port>` and `http://127.0.0.1:<port>`) and only IP addresses and local names as `Host` (`421 MISDIRECTED_REQUEST`). Every secret comes from `src/core/random.lua`, a SHA-256 pool stirred with `C4:UUID`, clocks, `/dev/urandom` when readable and each request; only a hash of it is saved across restarts. Once a controller sealed for a device, the app never sends it the key in the clear again (unsigned refusals cannot make it fall back), and `GET /v1/sealed` no longer gives out the home id (envelopes at home name the home `lan`); a sealed request cannot carry another. The location is shown to admins only, rounded to two decimals. The controller registers its own invitations over the relay socket, and the cloud's member endpoint is kept for the home's owner (drivers before 1.0.0). The home's owner replaces the home secret from the app on the home network: the controller makes it and gives only its hash, the account service accepts it only from the owner, and the relay then accepts only it (the controller cannot replace it alone, or a copy of its data could lock it out). The Composer action **Reset Remote Identity** makes a new home id as a last resort. Accounts can sign out everywhere and expired sessions are purged daily. CI actions are pinned to commits, wrangler to an exact version, and `scripts/check_repo.py` refuses local configuration and secret files.

**Consequence:** Someone who only listens on the home network learns nothing that opens the home. Someone who can change traffic during pairing still could (the code travels with the request); local HTTPS or a code compared on both sides would close that, later. Old browsers, old drivers and scripts keep working unsealed. A copy of the controller's data still allows acting as its devices and as the home until **Revoke All API Keys** and the owner's **Replace the remote secret** are used (docs/ACCOUNTS.md, *What the lock does not protect*). A device with no sealed request yet (a key paired before 1.0.0) can still be made to send its key once by someone who changes traffic. The API console does not seal. Envelope sizes remain visible to the cloud.

## ADR-031 — DirectorLink's automation is visible and pausable in Composer

**Context:** Dealers' main objection to homeowner-made automation is that it is invisible: "the AC shuts off at 11:30 and nobody knows why" sends the next technician hunting through Composer programming that is not there.

**Decision (0.15.0):** The DirectorLink device shows its automation in Composer: a **Schedules** property (On / Paused) that pauses every DirectorLink schedule, **Schedule Status** (what is on and what runs next), **Last Automation** (the last scene run, when, why — schedule, weather reading or the device that ran it — and the result), and the action **Print Schedules and Scenes**, which lists everything in the Lua output. This extends the rule of 0.8.0 that Composer shows what an installer needs.

**Consequence:** An installer can find, understand and stop DirectorLink's automation from Composer without the app. DirectorLink still does not read or change Composer programming, so conflicts between the two are found, not prevented.

## ADR-030 — Schedules run on the controller; the weather comes from Open-Meteo

**Context:** Schedules must run without an app open and without the cloud, and the owner chose weather rules for heat, rain and wind, without local sensors for now.

**Decision (0.14.0):** The driver keeps and runs the schedules itself, once a minute, in the controller's local time; sunrise and sunset are computed on the controller. The weather is Open-Meteo's (free, no key, CC BY 4.0), asked by the controller directly every 15 minutes while an enabled schedule needs it (or for an hour after the app shows it), with the project's location rounded to two decimals. Weather rules have hysteresis (2°, 10 km/h, a dry hour) and run at most once a day by default. Scheduled scenes run with a member's rights: doors and gates are never opened by a schedule.

**Consequence:** No DirectorLink server is involved in schedules or the weather; the privacy page says what Open-Meteo sees. A controller without internet still runs time and sun schedules; weather rules then wait, and "only if" follows the schedule's choice (run or skip).

## ADR-029 — Accounts, with remote access locked end to end

**Context:** Remote access has to work for people other than the developer, on iPhones too (which cannot use the home-network connection), without the cloud being able to read what homes do. The owner asked for the end-to-end lock to be part of the design from the start, and for Google sign-in first.

**Decision (2026-09-27):** `docs/ACCOUNTS.md` as proposed, with Google as the only sign-in until the whole flow works end to end; Apple follows. Each device's lock key is derived from its API key; remote requests and answers are sealed with AES-256-CBC and HMAC-SHA256 (2-minute window, one-time ids); the owner claims the home once on the home network; everyone else joins by an invitation whose secret stays after `#` in the link; the cloud stores only accounts, sessions, homes, members and pending invitations. Sign-in is Google's authorization-code flow with PKCE, run by the Worker, so no Google script runs in the app's pages.

**Consequence:** A device that never signs in never contacts the account service. The cloud Worker gains a D1 database (`directorlink`) and the `GOOGLE_CLIENT_SECRET` secret; `directorlink.io/privacy` states what is stored.
