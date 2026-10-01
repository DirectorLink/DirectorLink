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

**Since changed (ADR-035):** releases up to 1.0.0 were published mutable: their files could still be replaced after publishing. From 1.1.0 on they are immutable, with the repository's immutable-releases setting on: once a release is published, its tag and files cannot change. The app's update notice offers only immutable releases.


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

## ADR-043 — DirectorLink's settings in the app: three changeable, the rest set in Composer only

**Context:** Every DirectorLink setting is a Composer property, and Composer is a dealer's tool many owners cannot use. Pausing schedules for a holiday away, turning the Jewish calendar on or off, or raising the log level for a bug report should not need an installer. Others must not move away from the installer: Door Control and Relay Hold decide whether the app opens doors and gates or holds them open, Alarm Status whether the alarm is watched, Remote Access whether the home is on the internet, and New Pairing Code, Revoke All API Keys and Reset Remote Identity are what an installer uses when a key or the home's identity cannot be trusted.

**Decision (1.4.0):**
- Admins change **Schedules**, **Jewish Calendar** and **Log Level** in the app (Settings → Controller → DirectorLink settings; `PATCH /v1/settings`, and `PATCH /v1/logs/settings` for the log level), and run **Refresh Project** (`POST /v1/project/refresh`). The app shows the other four properties with their value and "Set in Composer", the read-only properties (Status, Version, API Status, Pairing Status, API Keys, Remote Status, Schedule Status, Last Automation, Calendar Status, Inventory; never the pairing code) as Composer shows them, and what **Print Schedules and Scenes** prints (`GET /v1/settings/printout`, the same lines). `GET /v1/settings` lists each setting with its value, choices, whether the app may change it and where it is set. Members and viewers get `403 FORBIDDEN`; drivers before 1.4.0 answer `404` and the app shows no section. While a change is on its way the controls say they are busy (`aria-disabled`) but keep the keyboard's focus. This amends ADR-037: the Jewish Calendar switch is no longer the installer's alone.
- **One path.** A change in the app sets the property as Composer would (`Properties` and `C4:UpdateProperty`, so Composer shows the new value), then runs the code a change in Composer runs (`propertyChanged` in `src/main.lua`, which `OnPropertyChanged` calls). DirectorLink keeps no copy of its own: Director keeps the properties across restarts and updates. `OnPropertyChanged` acts only on DirectorLink's settings (`Settings.LIST`): the read-only properties, the pairing code among them, are DirectorLink's own, and Director may report each update of them back. For each setting DirectorLink remembers the value it applied last (from the app or from Composer); `OnPropertyChanged` with that value, which is Director reporting back what DirectorLink set, at once or later, once or more, changes nothing, and nothing loops. Any other value is a change in Composer, which wins as usual. A setting already at its value is left alone.
- **When applying fails.** If what a setting does fails (pausing the schedules, working the calendar out again), the property keeps the new value and the answer is `500 SETTING_NOT_APPLIED`, naming it, with the error in the log. The property is what DirectorLink reads (the scheduler asks it every minute) and what Composer shows, so it is the truth to report; putting the old value back would run the same code again for it, which can fail the same way, and Composer and the app would no longer agree on what was asked.
- **Set in Composer only.** `src/core/settings.lua` marks each setting and action for the app or not. `PATCH /v1/settings` refuses Door Control, Relay Hold, Alarm Status and Remote Access for every key, admins included (`403 SET_IN_COMPOSER`), before anything changes; no route runs New Pairing Code, Revoke All API Keys or Reset Remote Identity. `scripts/check_package.py` fails the build if the marks change, if anything in the package writes one of those four properties (in either kind of quotes, or as `Alarm.PROPERTY`), if the refusal goes, or if the API reaches one of those actions, turns remote access on or off (`Relay.start`, `Relay.stop`, the relay module) or watches the alarm (`onPropertyChanged`). There is no Composer switch to turn the app's settings off: the three it changes are the owner's to change, and the installer still sees and overrides them.
- **Who.** Every change, made in the app or in Composer, and every Refresh Project, is logged in the category `settings` whatever the Log Level (`Log.always`): the property, its value, `from` (`app` or `composer`) and, from the app, the key's id and name. Nothing else was added to Composer: no existing property fits it, and like every entry it also goes to Director's log (`C4:DebugLog`); the property itself shows the value. The pairing code never reaches the log: every entry is cleared of the current code, as Composer shows it and as typed, in any field and in the message (`Log.hide`).
- Schedule Status and the printout say "Paused", not "Paused in Composer", since an admin may have paused them. Turning the Jewish calendar off and pausing schedules ask in the app first, saying what stops (and that a time due in the last 5 minutes of a pause runs when the schedules are on again). Members and viewers are told that an admin turns paused schedules back on, not where.

**Why:** The owner decides how the family's automation runs; the installer decides what can open the house and what reaches the internet. One code path, and the property as the only place the value lives, keep Composer showing the truth and a later change there winning, without a second implementation to drift. A check in the build, because loosening the line between the two would be a one-word change. Logged whatever the level, because the log is how the owner finds out which key paused the schedules; and the pairing code kept out of it, because the log goes to every admin and to Director's log, and the code pairs an admin key.

**Consequence:** An admin key can pause every schedule or turn the Shabbat schedules off: the log says which key did it. The Log Level the app sets is Composer's, so an installer may find it changed. The statuses are English, as Composer shows them. Not yet seen on a real controller: whether Director reports the driver's own `C4:UpdateProperty` back to `OnPropertyChanged` (both ways are handled). If Director reported back, late, a value DirectorLink set before the last one, it would be taken for a change in Composer.

## ADR-042 — Backups: everything, locked with a password in the browser, restored all or nothing

**Context:** Updating the driver keeps its data, but removing it from the project (by accident), replacing the controller or rebuilding the project loses everything DirectorLink keeps: Control4 deletes a removed driver's persisted data. Keys, profiles, scenes, schedules and the remote identity then have to be made again by hand, every device paired again and the family invited again.

**Decision (1.4.0):**
- `GET /v1/backup` gives one document with every store the driver keeps, each as it is stored with its version (docs/BACKUP.md): the keys as their hashes and lock keys (never a key), profiles, room names and the room order, scenes, schedules without what they ran, the calendar's settings and the remote identity (home id, secret, waiting replacements), but only one the relay has accepted (`linked`: it is a home in the account service), and none is made for a backup; how the Composer properties are set; the names of the rooms and devices the sections refer to; and which controller made it (`controller_id`, a hash of its MAC address, `C4:GetUniqueMAC`). Not in it: pending invitations, the schedules' runtime, the replay guard, the random pool, the weather and the counters. For admins, and only in sealed requests (at home and through the account; `403 SEALED_REQUEST_REQUIRED` otherwise, as `GET /v1/alarm`), because the lock keys and the home secret let whoever has them act as the home's devices and as the home.
- The app locks the document in the browser before it is saved: PBKDF2-SHA-256 with 600,000 iterations and a random 16-byte salt makes an AES-256-GCM key; a random 12-byte IV; the file's header (the file's version, salt, iterations, IV, home, date, driver version) is the additional data, so a changed header or byte does not open, and only version 1, inside the header and out, is opened. The password is typed twice, at least 10 characters, with a strength hint that rates common words, one word with digits or symbols, sequences, keyboard rows and repeats as weak, and the app says that without it the file cannot be opened. The password never leaves the browser and is never written into the page's HTML; the opened document goes only to this controller, in sealed requests. A file over 4 MB is not read. The panel shows only with a DirectorLink that has backups (the one that answers DirectorLink settings, ADR-043); a `404` says to update DirectorLink.
- A restore comes back in parts (`POST /v1/restore/parts`, 48 KiB each, 2 MiB and 100 parts in all; one upload at a time per key and three in all, a fourth replacing the one used longest ago; dropped by a timer 10 minutes after its last use, so a checked backup does not stay in the controller's memory), because a sealed request at home is at most 64 KiB and the account's relay takes 128 KiB of ciphertext: raising either would let anyone on the network make the controller hold more, and change the cloud. `POST /v1/restore` checks it (`dry_run`, the default) and restores it only with `"dry_run": false`, the same upload the admin saw checked. It refuses a document that is not a backup, lacks a section or has one of the wrong shape (`422 BACKUP_INVALID`), or that a newer DirectorLink or a newer store version wrote (`409 BACKUP_TOO_NEW`); older ones are read as an update reads their stores. It refuses while a store could not be read when DirectorLink started (`503 UNAVAILABLE`): writing it could lose what it holds, which comes back at the next start, and a restore that failed could not put it back. It then writes every store, or none: each store's values are taken before, and when one write fails, the stores written so far, and that one, get them back (`500 RESTORE_FAILED`). Names (scenes, profiles, keys, rooms) are cut to what the API takes, 64 characters and 10 languages a room, and preferences the API would refuse are left out.
- **Keys.** The backup's keys come back only onto a controller where no key but the restoring admin's is paired, and that one is not in the backup (it was paired after the backup was made): the driver was removed and added again, or the controller replaced. Every device with its key then keeps working without pairing again; the preview lists them by name and role. Otherwise every key stays exactly as it is now, and the preview says "Keys: kept as they are now": a key revoked, or an admin made a member, since the backup was made never comes back. In the reinstall case the admin may say which of the backup's keys this device had ("This device is …", `replaces_key`; none by default): the restoring key then takes that key's profile and role, and that key is not restored, so the owner's old key is not left as an admin key on no device; a choice that would leave no admin is refused (`409 LAST_ADMIN`). The restoring key otherwise stays exactly as it is now (its role, hash, lock key and expiry), and is added with its current profile when the backup does not have that one; a backup key with the same id and another hash stays out (reported as `conflict`). A backup's key record is checked as the driver makes keys: an id of 8 hex digits, a role (none is not admin), a hash of its algorithm's length, a lock key of 64 hex digits or none, and a hash no other key has; the rest is left out and counted (`left_out`, shown). Keys whose expiry has passed, or that have more than 30 days and an hour left (ADR-040: made while a clock ran ahead), stay out, in the preview's counts too. The limit of 20 keys may be passed by the restoring key (`over_limit`): new keys wait until some are removed. Nobody is locked out mid-restore, and there is always an admin.
- **Rooms and devices.** Scene steps, favorites, hidden rooms, room names and the room order are matched to the project: the same id with the same name, still a room or a device of the kind its use needs (a lights step, a light); else the one other room, or device of that kind in the same room, with the backup's name (the ids were swapped, or it was made again); else the same id with another name (`renamed`). What opens doors and gates (relays, doorbells, and a relays step for a whole room) is never moved: it is kept only on the same id with the same name, and otherwise left out and listed with what that id is now (`now`). The rest is left out and listed with where it was used (`unmatched`), never dropped without a word. A step whose room matches nothing is left out rather than kept without it, which would act on every room.
- **Schedules** start as if saved at the restore: nothing due before runs or is caught up, and a weather rule waits until the weather has turned. What they ran belongs to the controller that ran them, and restoring it (days old) could run a Shabbat scene a second time or not at all.
- **Invitations** are not in a backup, and a restore revokes the pending ones and any claim token: an invitation revoked after the backup was made must not come back, and those made since were for the keys and the home there were. They last a week at most; the admin invites again.
- **Another home's backup.** The preview says whether the backup looks like another home's (`origin`): by the home id when both the backup and this controller have one the relay accepted, else by the controller it was made on; and besides when the home's name differs or most of what it refers to is not in this project. Then the app warns first, naming that home and why, Replace everything asks a confirmation that names it, and its remote identity stays out (`kept`) unless the admin ticks **Move remote access to this controller** (`move_remote`, off by default), which says the other controller must be off or reset first.
- **The remote identity.** The backup holds none: the one in use stays (`none`). The same home id: the identity in use stays, with its secrets, which may be newer than the backup's (`same`). Otherwise, and for another home's only when asked (`restore`): the backup's identity is used, its home id and secret checked as the relay takes them (32 lower-case hex digits, 64 hex digits) and its waiting replacements cut to the three the relay tries, none dated after now; the one in use until then is kept as `previous`. Two seconds after the answer (sent on the connection there is, which may be the one the restore came through) the relay connection is made again with the backup's identity. When the relay accepts it, `previous` goes: the home in the account comes back with its members, whose keys the backup has, and the controller announces the key ids to it; the home it used until then goes offline in the account. When the relay refuses it (401 after the waiting replacements: its secret was replaced after the backup was made; or 400, an identity it does not take), the identity from before comes back, the controller connects with that, and the log and Remote Status say so. With Remote Access off, the same happens when it is turned on. A controller with no identity yet takes the backup's without a `previous`. When the identity moves here from a backup made on another controller (or one that cannot be told), the preview warns that the controller the backup was made on must have Remote Access off, or no DirectorLink: two controllers with one identity push each other off the relay (`old_controller`). The app points a device linked to the other home at the backup's.
- **Composer properties** are never restored, only listed with how they are now: a file must never switch a safety setting on (Door Control, Relay Hold, Alarm Status, Remote Access). Three of them, Schedules, Jewish Calendar and Log Level, are set again in the app (ADR-043).

**Why:** Everything, because the owner wants the home back as it was, without pairing or inviting anyone again. The lock keys and the home secret must be in it for that, so the file is only ever encrypted and the document only ever sealed. The password in the browser, because the controller must not keep what opens the file, and AES-GCM with an authenticated header, because a changed file must not open rather than open changed. Parts rather than larger requests, because the limits protect the controller and the cloud. The backup's keys only in the reinstall case, because a controller that kept its keys knows better than an older file who may still come in. "This device is …", because the restoring device always pairs anew after a reinstall, and its owner's old key would otherwise be left as an admin key nobody holds. Doors never moved, because a gate's scene pulsing the main door every morning is worse than a scene step missing and listed. The backup's identity rather than the one in use, because the restored keys are the backup home's members'; keeping the current one would leave the family with keys for a home the controller no longer answers as. Only an identity the relay accepted, and another home's only when asked, because one the relay never saw, or another family's, would replace this home in the account and cut everyone off. The fallback, because a secret replaced since would otherwise leave the home unreachable until someone resets it in Composer.

**Consequence:** A backup file and its password together are as good as the home's keys: kept apart, and the file away from the controller. After a reinstall, pair one device and restore at once, before anyone else pairs or is invited: once another key is paired, the backup's keys are not restored. Devices paired after the backup was made pair again, and people who joined after it leave the home in the account (their keys are not in the backup). A device that opened the app while the controller's data was gone forgot its key (the controller told it the key was unknown) and pairs again: restore before the family opens the app. Someone who holds an old backup and its password holds the keys it had until they are revoked (Revoke All API Keys, Reset Remote Identity). If the relay refuses the backup's identity, the family's devices, whose keys are restored, are members of the backup's home, which the controller no longer answers as: they reach it only at home until they are invited again. A backup made before the relay ever accepted the home's identity brings no remote access back: the owner links the home again. Before a restore that moves the identity, the controller the backup was made on must be off, have Remote Access off, or have DirectorLink removed. A backup made by a newer DirectorLink needs that DirectorLink. Through the account the backup goes as one relay message, so a very large home downloads it at home. One key may pass the key limit. Not yet seen on a real controller: `C4:GetUniqueMAC`; without it, backups name no controller, and the home id and the other signs decide.

## ADR-041 — Sign in with Apple is on; the owner approves invitations accepted with another email; Apple's account notifications

**Context:** Sign in with Apple was built in 0.10.0 and hidden until Apple's keys existed; the owner has now set up the Services ID `io.directorlink.signin`, the key (Key ID `Q3WXX95K83`, Team ID `VA4Q88T4RC`) and the primary App ID `io.directorlink.app`. People who sign in with Apple often hide their email (Hide My Email), so an invitation sent to their Gmail never matched and was refused (`EMAIL_MISMATCH`); ADR-027 had planned owner approval for that. Apple also tells apps, server to server, when someone stops using Sign in with Apple for them, deletes their Apple Account, or turns Hide My Email forwarding off or on.

**Decision (1.3.0):**
- **Apple on, only when it works.** The public ids are Worker vars; the `.p8` key is the secret `APPLE_PRIVATE_KEY`, and Apple sign-in counts as set up only with it. The app shows a provider's button only when the account service says it is set up (`GET /auth/providers`, and `sign_in_providers` in `/v1/me`), so a missing secret never shows a button that fails. A device that never signed in still contacts nothing until someone taps **Sign in** (or opens an invitation link, which needs a sign-in anyway); then it asks which sign-ins exist, shows their buttons and remembers the answer. Apple's button follows Apple's Human Interface Guidelines: black, or white on the dark theme; the Apple logo and *Sign in with Apple* (*Continue with Apple* to add it to an account, one of Apple's titles) in one color and the system font; at least as large as Google's and next to it.
- **Another email: the owner approves.** When the signed-in account's emails do not match the invitation's, the app sends the join with `ask_owner`. The cloud then sends nothing to the home: it records a request (D1 `join_requests`, migration `0005`) with a random 6-digit code and answers `202`. The home's owner, and only the owner, sees it in **People and devices** and approves or refuses it (`GET`/`POST /v1/homes/{home_id}/join-requests`). The invited person's page shows the code and asks every 5 seconds (`GET /v1/join/{home_id}/{invitation_id}`); once approved it seals a new join request with the invitation's secret and the cloud relays it as any other join. A refusal is final for that account and invitation; the invitation's expiry, use or revocation ends its requests; an open request can be withdrawn. At most 5 open requests (waiting or approved) per invitation and 20 waiting per home on invitations that can still be accepted, one per account and invitation: a refused request, or one on an invitation that expired, does not keep the invited person from asking. Apps before 1.3.0, which do not ask, still get `EMAIL_MISMATCH`.
- **Owner only.** The cloud knows who owns a home but not the members' roles: those are the controller's keys. Admins could approve only if the controller vouched for them over its connection (a driver change, and the home online), and nothing short of that stops a viewer's account. The owner is also the only one who sees the home's accounts. An admin who is not the owner can make an invitation for the right address instead.
- **What the owner sees, so as not to approve a stranger:** the name the account gave, which nobody checks (anyone can type any name at Apple or Google); its email, or *hidden by Apple*; how it signs in; how old the account is; when it asked; the invitation — its email and expiry from the cloud, its role and the device that made it from the controller, which also says when the invitation is no longer waiting there (Approve is then off); and the code. Whoever got hold of the link could ask too, under any name. The code is the check: the owner approves only when the person they invited reads out the same code, in person or on a call they trust, and the app asks for that in the confirmation.
- **The join's security stays as it was (docs/ACCOUNTS.md).** Asking needs only the ids, so the invitation's secret stays after `#` and on the device; after the approval the controller still opens the envelope with it and uses the invitation up, so an approved account without the secret gets `BAD_MAC` and nothing else. The new key still travels only sealed, and the cloud keeps no envelope (the controller accepts a sealed request only within 2 minutes, which is why the approved join is sealed anew). The invitation stays bound to its email and works once. Membership and the new key id (`member_keys`) are written as for any join, only while the invitation is still pending and the approval still stands, and the join's answer goes through the home's Durable Object after the key work queued before it, in the controller's order. An account the owner refuses while the home is already making its key gets `REFUSED_BY_OWNER` and never the sealed answer (logged `join_key_withheld`); the key made at home is of no use to anyone, and the owner can remove it in People and devices. Revoking the invitation at home, or the admin key that made it, still refuses the join.
- **Apple's notifications**, at `POST /auth/apple/notifications` (entered in Apple's portal on the primary App ID): the body's `payload` is a JWT checked as an ID token is (Apple's signing keys, RS256, issuer `https://appleid.apple.com`), for the audience Apple uses for these, the primary App ID `io.directorlink.app` (`APPLE_APP_ID`); an ID token, whose audience is the Services ID, is refused. `events` is read as Apple writes it, a JSON string (an object too); its time in seconds (milliseconds too). *consent-revoked* and *account-deleted* (Apple's current name; older documents say *account-delete*, also accepted) remove that Apple sign-in, and an account left without any sign-in loses every session. A notice never removes a home, its members or its keys. *email-disabled* and *email-enabled* only update the stored address when Apple gives one: forwarding itself is not stored, and DirectorLink sends no email. A notice dated before the person last signed in with that Apple ID changes nothing, whichever it is (a late or replayed one: that sign-in gave the address Apple has now), each is safe to receive twice, the body is read up to 16 KiB, and Apple's keys are cached for an hour and fetched again early, for an unknown key id, at most once a minute: tokens that arrive during a fetch share it, and a fetch that fails (an error answer, no keys) keeps the keys the Worker had and still counts as the minute's, so posts to this open endpoint cannot make the Worker ask Apple again and again, nor empty its keys. Each notice is one JSON log line with our account id, never Apple's id for the person or an address; a refused one names the audience it had, a public app id, since whether Apple addresses notices for sign-ins through the Services ID to the App ID can only be seen once it is live.
- **An account whose only sign-in was Apple** is signed out everywhere. After *consent-revoked* it stays as it was, homes, members and invitations included (the family keeps its access), and signing in with the same Apple ID gets the same account back (Apple keeps the same id for the person with DirectorLink's team, and the account still records the Apple ID it began with); that Apple ID cannot be added to another account meanwhile (`taken`), or the account would be out of reach for good. After *account-deleted* nobody can sign in to it again, so it keeps nothing of the person: one that owns no home is deleted, as **Delete account** does (its memberships, its requests, the invitations only it could accept); one that owns a home stays so the home and its family keep working, without the person's name and email, outside other homes and without requests to join them. The owner then takes the home over by claiming it again at home with an admin key, from a new account, which as for any change of owner (ADR-027) removes the old members and invitations, who are then invited again. An account left without a sign-in by *consent-revoked* goes the same way once nobody has signed in to it for 90 days (the daily clean-up): the person who comes back after that starts afresh. An owner who also added Google keeps signing in with it.

**Why:** Hide My Email is common, and refusing it left Apple users no way in but workarounds in Apple's settings. The owner already decides who is in the home; a code compared through another channel is what tells the person invited from someone else holding the link, which the name and the hidden email cannot. Apple asks apps to follow these notifications; deleting a home because of one would cut off a whole family, but keeping the name and email of someone who deleted their Apple Account, for good, serves nobody.

**Consequence:** An invited person with another address can join once the owner approves. The approval is only as good as the owner's check of the code, and, like the email check before it, it is enforced by the account service, not by the controller. The invited page must stay open, or be opened again from the link, to finish. The notification endpoint does nothing until it is entered in Apple's portal; until then an Apple ID that stopped using DirectorLink only stops being able to sign in (Apple refuses it). The Worker reads Apple's signing keys for each new key id, cached. Migration `0005` must be applied before the Worker that uses it is deployed.

## ADR-040 — The API console's own key lasts a day

**Context:** The API console does not seal (ADR-032): it sends its key with `Authorization: Bearer` in every request, in the clear on the home network. It pairs for itself an admin key named "DirectorLink Console", which until 1.3.0 worked until someone revoked it, so a key picked up once on the Wi-Fi stayed good for good.

**Decision (1.3.0):** Keys can expire. `POST /v1/auth/pair` takes an optional `expires_in` (whole seconds, 60 to 2592000, 30 days); the key stops working that long after it is made. Once that time has passed, the key is refused with `401 KEY_EXPIRED` and removed at once (the next request is plainly `UNAUTHORIZED`), with its invitations, as a revoked key is; a key that is not presented goes within a minute (the scheduler's tick looks at the keys, which also updates Composer's count and the cloud's list) and before anything that uses the keys (listing, counting, a sealed request, a join, a change of a key, the driver's start), so an expired admin is never counted as another admin, and its invitations never let anyone join. The key views (`GET /v1/api-keys`, `/v1/api-keys/current`, a new key) show `expires_at`, null for never. The console always asks for 86400 seconds for its own key, binds it into the pairing exchange (ADR-039), shows the time left on its Connection screen and warns there that its key travels unprotected; at the end it asks the controller, and `KEY_EXPIRED` sends it back to pairing with "Your console key expired. Get a new pairing code in Composer (DirectorLink → Actions → New Pairing Code)." The console keeps the key's `expires_at` next to it, so a key refused after that time (the controller removed it already, when the app looked at the keys) gets the same message; the clocks may be 5 minutes apart. A key that lasts longer than a browser timer can wait (24.8 days) is asked about every 6 hours. Once, at the first start of 1.3.0 (the key store's version 4), the keys named "DirectorLink Console" from before get `expires_at` a day after that start. Keys made in the console's Keys tab for scripts do not expire, and nothing new is shown there; the app's People and devices shows "expires in …" for keys that do.

**Why:** A day is long enough to work with the console and short enough that a key read on the network is soon of no use; the console is for debugging (its banner says so), not for everyday use. The console's key only: scripts and integrations run unattended, and the app seals.

**Consequence:** Whoever uses the console pairs again each day, with a new code from Composer. The expiry follows the controller's clock; a console on a computer whose clock is ahead asks early and is told the key still works, then asks again a minute later. The controller's clock decides how long a key lasts: a clock put forward ends every key that expires (they pair again), and one put back would make a key last that much longer, so a key with more than 30 days and an hour left (more than any key gets) was made while the clock ran ahead and is over too; a correction of less than an hour changes nothing. The one-time change goes by the name only, so a key someone named "DirectorLink Console" in the Keys tab before 1.3.0 expires too. Going back to 1.2.x drops `expires_at` at the next save, and the console's key then lasts until revoked again.

## ADR-039 — Pairing never sends the code (CPace)

**Context:** Pairing sent the 8-digit code in the clear, over plain HTTP on the home network. The key exchange of 1.0.0 (ADR-032) kept a listener from reading the new key, but someone who could change traffic could read the code, pair with the controller himself and pose as the controller to the app. Local HTTPS is not possible without certificates the app could check; comparing a number on both sides (the fallback plan) asks the person to read digits in Composer twice.

**Decision (1.3.0):** The app and the API console pair with CPace (draft-irtf-cfrg-cpace-21, cipher suite CPACE-X25519-SHA512), the pairing code as the password, in two requests to `POST /v1/auth/pair` (docs/ACCOUNTS.md; api/openapi.yaml). The controller is the initiator A: it answers the app's nonce with its own and its share; the app answers with its share and a tag. `sid` is the two nonces (the draft's recommendation for a session id from both sides); `CI = lv_cat("DirectorLink pair v2", name, expires_in)` binds what the first request asked for; ADa and ADb are empty; the transcript is initiator-responder. Key confirmation is the draft's section 10.4, HMAC-SHA512 with `SHA-512("CPaceMac" || sid || ISK)`: the controller makes the key only after the app's tag is right, and the app opens the key (sealed as before, with `HMAC-SHA256(ISK, "DirectorLink pair v2")`) only after the controller's tag is. A wrong tag is a wrong code, and each attempt counts as one from its first request until it succeeds, within the existing limits (5 per device a minute, 20 per code, 15 minutes, once); a device whose started attempts reached its 5 gets no plain-code guess either until the minute is over. Low-order shares are refused (libsodium's list and the draft's zero check). The driver does SHA-512, HMAC-SHA512 and Elligator 2 (RFC 9380) in plain Lua 5.1 (`src/core/sha512.lua`, `x25519.lua`): CPace hashes bytes (zeros included), and whether Director's `C4:Hash` offers SHA-512 over such data on every controller cannot be checked without one; the app and the console share `app/js/cpace.js` (copied byte for byte, with `js/lock.js`), with WebCrypto's X25519 (deriveBits with the generator or a share as the "public key"; a BigInt ladder where it is missing) and BigInt for Elligator 2. With a controller that refuses the field `cpace` (DirectorLink before 1.3.0), or one whose lock failed its self-test (it answers `503 LOCK_UNAVAILABLE`, so that the two can be told apart), nothing about the code has been sent: the app and the console warn that it would travel unprotected and say why — DirectorLink should be updated in Composer, or, for the lock, there is nothing to update and the installer should look at DirectorLink's log — and only **Pair anyway** sends it, the old way. The warning belongs to the controller it was about: another address, typed or found, clears it, and Pair anyway pairs only that controller. Scripts keep sending the code and getting the key in the answer.

**Why:** CPace is balanced (both sides know the code), small, has test vectors, and fits a code that lasts 15 minutes and works once: a listener learns nothing, and someone in the middle gets one online guess per exchange, which the controller counts. Pair anyway rather than refusing: a home whose driver is not updated yet can still be paired, knowingly; so can a controller whose lock failed, where refusing would leave no way to pair at all (no update fixes it), and the risk is that of 1.2.x. Pure Lua: 70 ms for the controller's half on this PC against 54 ms for the 1.0.0 exchange, about 0.35–0.7 s on a CORE-1, split over the two requests.

**Consequence:** Checked against the draft's X25519 vectors (generator, shares, K, ISK, the low-order points), RFC 9380's curve25519 map (15 vectors), FIPS 180-4 and RFC 4231, in Lua and in JavaScript (Node and Edge), and Lua against JavaScript on random inputs (`tests/vectors/cpace.json`); `scripts/check_contract.py` pairs with a third implementation in Python. Someone in the middle can still stop pairing or use up a code's attempts, and can take the code when Pair anyway is chosen. The Lua code is not constant time; it runs a few times per pairing, on the home network. An app older than 1.3.0 still pairs with a 1.3.0 driver the old way (the driver keeps it).

## ADR-038 — The alarm's status: read-only, off by default, never for viewers

**Context:** bkwagner's pull request #15 read the security partition proxy (`security.c4i`) on a live Director: its variables 1000–1012 give each partition's state (e.g. `DISARMED_READY`), armed home or away and the type of arming, alarm and its type, the number of open zones, the entry or exit delay and the trouble text; a partition the panel does not use says `IS_ACTIVE = 0`. Arming and disarming (`PARTITION_ARM` / `PARTITION_DISARM`) take the user's alarm code. Whether a home is armed tells whoever learns it when the home is empty.

**Decision (1.2.0):** A Composer property **Alarm Status**, next to Door Control and Relay Hold, ships `Off`. While it is Off, DirectorLink does not watch the partitions, `GET /v1/alarm` answers `200` with `{"enabled": false, "partitions": []}` (as `GET /v1/remote` answers `enabled: false` while Remote Access is off), the app shows nothing, and the partitions stay unsupported devices, as before 1.2.0. Set to On (read at every request; the partitions are watched, or let go, at once, without a restart), members and admins, never viewers (`403 FORBIDDEN`), read each partition the panel uses: its state, whether it is armed and how, alarm and its type, open zones, the delay and trouble; on Home and in Settings → Controller in the app. The partitions go only into sealed answers, at home (`POST /v1/sealed`, the app's way) and through the account: a request with `Authorization: Bearer` gets `403 SEALED_REQUEST_REQUIRED`. The answer is padded with spaces to the size it would have with every partition at its longest, so that its size, sealed, depends only on the partitions there are (their names and rooms) and never on their state; for that the panel's words are cut to 32 bytes (the state and the types of arming and alarm) and 100 (trouble), control characters become spaces, and counts stop at 99999. Their state is never logged, at any level. Read-only everywhere: no route, scene step, schedule or Composer action sends anything to a partition, and `scripts/check_package.py` fails the build if the adapter asks Director for anything but reading and watching variables (or loads a module, or prints), if any packaged Lua names a partition command, if a route under `/v1/alarm` is not a `GET`, or if a scene step type reaches the alarm. `GET /v1/system` says whether it is on (`features.alarm_status`), so the app knows whether to show it. In `/v1/devices` a partition stays a device of type `other`, and the API's inventory does not count it as supported; Composer's Inventory adds "N alarm partitions" while it is On.

**Why:** Off by default and never for viewers, because the state says whether the home is empty. Sealed only, because a plain answer would cross the home network in the clear. Padded, because AES only rounds to 16 bytes: an exit or entry delay made the sealed answer longer, and so could an arming for some names, and the home network and the relay see an envelope's size, every 10 seconds while the app is open. Read-only, because arming and disarming take the user's code, which must not travel with an API key: that needs a stronger design of its own (who may arm, where the code is entered and kept, how a disarm through the account is confirmed).

**Consequence:** Scripts and the API console, which do not seal, cannot read the alarm. Each answer carries about 1 KB of padding per partition. A panel text longer than its cap arrives cut. Arming and disarming stay with the alarm's own keypad and app. The IDs and values were read on the contributor's Director; no DirectorLink build has run against a real alarm yet (the owner's home has none), so the first real partition may show a state or type the app words only as the panel writes it.

## ADR-037 — Shabbat and holiday times, worked out on the controller behind a Composer switch

**Context:** Families who keep Shabbat want the home to follow it: the lights and the hot plate before candle lighting, the boiler not on Shabbat morning, the blinds after havdalah. Composer's scheduler knows no Jewish calendar, and setting the times by hand each week is what such a family cannot do on Shabbat itself. The times depend on the home's location, on the community's custom (how long before sunset candles are lit, how long after it Shabbat ends) and on whether Yom Tov is kept one day (Israel) or two (abroad). DirectorLink already works out sunrise and sunset on the controller (ADR-030).

**Decision (1.2.0):**
- A Composer property **Jewish Calendar** ships Off. While it is Off the driver works nothing out, the app shows none of it, `GET /v1/calendar` answers `enabled: false` with nulls (as `GET /v1/remote` does while Remote Access is off) and setting anything that uses the calendar is `409 JEWISH_CALENDAR_OFF`; `GET /v1/system` says whether it is on (`features.jewish_calendar`). A read-only **Calendar Status** shows what it works out, and Schedule Status, Last Automation and the printout show the Shabbat schedules (ADR-031). The installer keeps the switch (since ADR-043, admins also switch it in the app); the family's custom (candle lighting 20 minutes before sunset and havdalah 42 after by default, and Israel or abroad, automatic from the location, else the project's country or time zone) is theirs: admins set it in the app, and it is kept on the controller (`PATCH /v1/calendar/settings`, with a `version`).
- Everything is worked out in plain Lua on the controller from the project's latitude and longitude, and nothing goes to the network (`scripts/check_package.py` refuses a calendar file that could): the Hebrew calendar (Dershowitz and Reingold), the holidays, the weekly reading (Orach Chaim 428:4 as pyluach formulates it), sunsets by NOAA's solar calculator and Hebcal's roundings (docs/CALENDAR.md). `sun.lua` moved from the Almanac method to NOAA for every schedule: it gives Hebcal's times to the minute 99.8% of the time, against 78%.
- Shabbat and Yom Tov that follow each other are one holy period. A schedule trigger `{"type": "shabbat", "event": "candle_lighting"|"havdalah", "offset"}` (up to six hours either way) runs once when a period begins or ends; `during_shabbat` (`run`, `skip`, `only`) keeps a time, sun or weather schedule away from holy time, from candle lighting to havdalah, or to it. Holy moments are points in time, never minutes of the day, so offsets cross midnight and a clock change moves nothing.
- While the calendar is off or has no location, no moment counts as holy: Shabbat schedules and `only` are kept but do not run, and `skip` runs as usual. Counting `only` as "run as usual" would run Shabbat-only automation every weekday.
- A Shabbat schedule runs once a period, whatever is changed or restarted (it remembers the period's first day and the event). In the first minute after a start, Shabbat schedules and `only` schedules missed in the last 6 hours run late, oldest first, each once, marked `late`; the owner confirmed the 6 hours. Everything else keeps its 5 minutes. What was due while the schedules were paused, or while the calendar was off or had no location, is never caught up, not even by a later restart: the driver keeps, with what the schedules ran, the moment they could run again (`catch_up_after`). Nor is anything caught up when what they ran could not be read at the start, which could run a Shabbat schedule twice.
- The engine is loaded only when the calendar is on, and a failure in it leaves the calendar without times (Calendar Status says so) while every other schedule runs.

**Why:** Off by default, because most homes do not want it, and the switch belongs to the installer as the door switches do (since ADR-043 an admin may switch it too: it opens no door); the minutes and Israel or abroad are the family's custom, which they change in the app like their schedules, and Composer is poor for numbers. On the controller, because the schedules that use the times run there, without the internet, and the location stays at home. The catch-up, because a family keeping Shabbat cannot make up by hand for automation a reboot missed.

**Consequence:**
- A home that never turns it on runs as before, except that sunrise and sunset schedules may move by up to a minute, two in the far north (NOAA).
- The times are as good as the project's location; the app and the docs ask families to check them against their community's calendar. DirectorLink works out times; what to automate on Shabbat, and whether a late run is wanted, is the family's decision.
- Where the sun does not set (above about 66°, around midsummer and midwinter) there are no times: a period that lacks its candle lighting or its havdalah runs no Shabbat trigger, neither at its begin nor at its end (a begin without an end would keep the home in Shabbat mode for weeks), and they wait for the next period that has both; the condition counts its civil days, from 00:00 to 24:00, and from candle lighting or to havdalah when that one happens.
- The automatic Israel uses a box around Israel that also takes in parts of Jordan, Lebanon and Sinai; admins there set abroad.
- After a restart during Shabbat a scene may run up to 6 hours late, logged and labelled.
- Going back to 1.1.x loses Shabbat-trigger schedules at the next save (1.1.x refuses them when it loads) and forgets `during_shabbat`, so `skip` schedules run on Shabbat and `only` schedules run on every day they are set for (an `only` schedule at 08:00 every day runs every morning); the next save in 1.1.x drops `during_shabbat` for good. Switch the `only` schedules off before going back, and set skip and only again after returning to 1.2.x; the settings survive. A 1.1.x app still open shows a Shabbat trigger as a rain rule, and saving it in its editor would make it a heat rule; that lasts until the app reloads, and only with the property On.
- The reference data the tests compare with comes from Hebcal.com (CC BY 4.0, credited in NOTICE); nothing is asked of Hebcal at run time.

## ADR-036 — Door relays are pulse-only by default

**Context:** A door or gate on a KNX Contact/Relay device opens while its relay's contact is closed. The app and scenes only pulse relays (close, then open again after 500 ms, as Control4's Relay Door and Gate Controllers do), but `PATCH /v1/relays/{id}` with `{"state": "closed"}` (0.6.0) holds the contact closed, and so the door open, until someone sends `open`. Any key with door access (`doors` or `admin`, with Door Control on) could send it, at home and through the account, and the API console offered it as its example body.

**Decision (1.1.1):** A new Composer property, **Relay Hold**, next to Door Control, is `Not allowed` by default. Until an installer sets it to `Allowed`, `{"state": "closed"}` answers `409 HOLD_NOT_ALLOWED` and nothing is sent to the device. `{"state": "open"}` (releasing the contact, the safe state) and `POST /v1/relays/{id}/pulse` work as before, and the key's role and Door Control are still checked first (`403`). Like Door Control, the property is read at every request, so a change in Composer applies at once, to requests at home, sealed and through the account alike, and is logged. Scenes stay pulse-only whatever it says. The API description's example body is now `open`, so the console no longer offers the hold. `scripts/check_package.py` fails the build when the check in `relays.lua` is gone or either door switch no longer ships off.

**Consequence:** A script or integration that held relays closed gets `409` after the update until Relay Hold is Allowed. The switch is for the whole driver, not per relay: allowing it for a relay that is not a door lets every door relay be held too. The app, scenes and schedules do not change. A key with door access can still open a door, a pulse at a time, but no longer leave it open.

## ADR-035 — Driver updates: a guided notice first, one-tap install only after a test on a real controller

**Context:** Updating DirectorLink means Composer: download `DirectorLink.c4z` from the release, keep exactly that name, and run Update Driver on the device (ADR-010, ADR-014). Admins learned about a release only by watching GitHub. No documented DriverWorks API installs a `.c4z`. The only known method — the unlock key of `C4:FileSetDir`, writing the package into `C4Z_ROOT` and `UpdateProjectC4i` on `127.0.0.1:5020`, used by some open-source drivers — is undocumented and unproven on OS 3.4.3.

**Decision (1.1.0):** The app shows admins that a newer release is out, with What's new, a download of that release's `DirectorLink.c4z` and the Composer steps. The admin's device asks GitHub's releases API (`releases/latest`) at most every 12 hours; other roles never ask, and a driver whose version is not MAJOR.MINOR.PATCH is never compared. Only the version, the date and links into the project's releases are used, never the text of the release notes. Only immutable releases are offered (GitHub's immutable releases, on for the repository from 1.1.0): once published, their tag and files cannot be replaced. Later, and only after a test with a throwaway driver on the owner's CORE-1 succeeds: installing from the app, for admins only, behind a Composer property **App Updates** (default Not allowed), with packages signed in GitHub and checked by the driver, and only to newer versions. Going back stays in Composer. The minimum OS stays 3.3.0 (ADR-001), so the signature is checked in plain Lua.

**Consequence:** Nothing new runs on the controller. GitHub sees admins' IP addresses about twice a day; the privacy page says so. An admin whose app asked just before a release was published hears of it up to 12 hours later. When GitHub gives no usable answer (a rate limit, no connection), a newer release the app already knows of is still offered, but *Up to date* is said only within 3 days of GitHub's last answer; after that Settings says that the check did not work, and when it last did. A release that is not immutable is never offered; it can still say that the driver is up to date (1.0.0, the latest release when the 1.1.0 app went live, was published mutable). With the repository's immutable-releases setting forgotten, admins get no notice of a newer release rather than one for files that could still change.

## ADR-034 — The driver checks the relay's certificate against roots it carries

**Context:** Up to 1.0.0 the driver opened the relay connection with `NetPortOptions` `SSL` and no `VERIFY_MODE`, and Control4's documentation says Director then checks nothing. Everything through the relay is sealed end to end (ADR-029), but the handshake carries the home secret, so anyone in the network path could pose as the relay, take the secret and keep the home offline.

**Decision (1.1.0):** The connection asks for `VERIFY_MODE = "peer"`, with `CACERTFILE` set to `certs/directorlink-roots.pem` inside the package: the root certificates of the authorities Cloudflare issues the relay's certificate from (Let's Encrypt, Google Trust Services, SSL.com), taken by name from certifi, with each SHA-256 in the file's header. `scripts/check_package.py` checks the options, and that the certificates OpenSSL would load from the file are exactly these roots, each once with its pinned SHA-256, with no key or other block; `scripts/build.py` packages only this file of `driver/certs/`, and `scripts/check_repo.py` allows this one `.pem` and checks its staged content the same way. Control4 does not document how Director reports a certificate that fails the check, so the driver ends any relay connection attempt that has not opened within 30 s and retries with its usual backoff.

**Consequence:** If Cloudflare moves the relay to an authority that is not in the file, or a root expires (2035–2046), remote access stops until a driver update, so the file is rebuilt from a current CA list first (docs/RELAY.md). Control4 does not document whether Director also checks the host name with `peer`; if not, a certificate one of these authorities issued for another name would pass too. Reaching `Connected` shows neither that nor the check itself, so docs/TESTING.md 0p tests the check once with a package that trusts only a root the relay's chain does not end at (`scripts/build.py --roots-only`), which must never connect.

## ADR-033 — Contributed device families and dual setpoints

**Context:** bkwagner's pull requests #14, #19 and #16 added three device families that DirectorLink listed as unsupported, found on a real installation and read on a live Director: the legacy Light proxy, heat-only Thermostat V2 floor heating whose single setpoint is unused, and the Control4 thermostat proxy with separate heat and cool setpoints. They were rebuilt on 1.0.0 (docs/PROJECT_SPEC.md, *Adapters added in 1.1.0*).

**Decision (1.1.0):**
- **Legacy Light proxy** (`light.c4i`): its own adapter, so the Light V2 path validated on real hardware does not change. State from `1000` and `1001` as on Light V2; `ON`, `OFF` and `SET_LEVEL {LEVEL}` with no ramp time, to the proxy; no KNX exception without a trace from a real device.
- **Heat-setpoint rule:** a Thermostat V2 zone follows its heat setpoint only while it is heat-only, its single setpoint reads 0 in both scales and the heat setpoint does not, checked again on every change. On that path it goes down to 5 °C and takes `SET_SETPOINT_HEAT` in the project's scale. Zones with Cool or Auto never take it.
- **Thermostat proxy scale:** the project's scale is required, never guessed. Setpoints are read and compared in its units (whole °F, tenths of °C) and commands go out in it only, whole degrees in °F; the API stays in °C.
- **Public shape:** every thermostat has `setpoints` (`single` or `dual`), `heat_setpoint`, `cool_setpoint` and `setpoint_deadband` (null on single-setpoint ones). On a dual thermostat `target_temperature` is the setpoint of the current mode (null in auto and off), PATCH and scene steps take `heat_setpoint` and `cool_setpoint`, and a `target_temperature` sets the setpoint of the request's mode, else the current one.
- **Push rule:** one setpoint moves the other when needed to keep the deadband; two sent together must already be that far apart. They are sent in the order that never breaks the deadband in between, judged against the setpoints last sent until the thermostat reports them (at most 10 s), so a request that comes before the report is planned from what the thermostat was just told.
- **Safety, as ADR-017:** a device is controllable only when its state variables exist and its listeners register, and every command of a request is checked by its adapter (`Manager.prepare`) before any is sent, so a refused setpoint does not leave the mode changed.
- Fan speeds: the API lists only its own values, which gain `on` and `circulate`.

**Why:** One rule for PATCH, older clients and scene steps. A 1.0.0 client, or an existing "cool 24" scene, sends only `target_temperature`, and that works in heat and cool; sending both setpoints stays strict.

**Consequence:** The API only gains fields, so 1.0.0 clients keep working; in auto they see no target. Room and whole-home scene steps include the new devices. The IDs, values and command lists were read on a live Director; no DirectorLink command has run on these devices yet. The rebuilt adapters are covered by tests against the fake Director and have not yet run on real hardware (docs/TESTING.md 0p).

**Extended in 1.2.0:** fans (#18) were rebuilt the same way. The Fan proxy (`fan.c4i`) has its own adapter: state from `IS_ON` and `CURRENT_SPEED`, found by name, else by the ids read (1000, 1001); `ON`, `OFF` and `SET_SPEED {SPEED}` with 1–4, to the proxy, and nothing sent for anything else; controllable only when both variables exist and their listeners register. `/v1/fans` shows `on`, `speed` and `speeds`, off is `{"on": false}` rather than speed 0, and fans join room and whole-home scene steps. Every fan is taken to have four speeds: the proxy allows 0 to N (`discrete_levels` in its setup), which DirectorLink does not read yet, so a fan with three shows its top speed as Medium High and is sent 4 for High, and one with five or more shows the speeds above 4 only as on. Read on the contributor's Director; no DirectorLink command has run on a real fan yet. A 1.1.x app still open (or cached) after the update does not know fan steps: it shows one as an action of a door (*Open (short press)*), and saving the scene in its editor, or trying it with **Try it now**, drops the fan steps that name devices (*devices no longer in the project*); room and whole-home fan steps are kept. That lasts until the app reloads, as for the Shabbat trigger (ADR-037).

## ADR-032 — The app's key stays off the home network; security review fixes

**Context:** A public review of the code (issue #43) pointed out that an admin key picked up on the home Wi-Fi (plain HTTP) was enough to claim the home to another account and to use it from anywhere; that pairing codes could be guessed through the relay and one person's wrong guesses locked pairing for everyone; that `localhost` was an allowed origin and the `Host` header was not checked (DNS rebinding); that every secret came from `C4:UUID("RANDOM")` alone; that viewers saw the home's exact location; that any member could register invitation ids with the cloud; and that a copy of the controller's data (home secret and lock keys) was enough to pose as the controller.

**Decision (1.0.0):** The app seals its requests on the home network with the lock of ADR-029 (`GET`/`POST /v1/sealed`) and pairs with an X25519 key exchange whose lock also covers the pairing code and both public keys, so its key is not sent in the clear; `Authorization: Bearer` stays for scripts and the console. Pairing is refused as a sealed or relayed request; five wrong codes lock pairing per client address for 60 s and twenty close the code. The driver accepts only DirectorLink's two sites as origins (no `localhost`, also not in development builds: only the local test bridge, `driver/tests/dev_bridge.lua`, also allows `http://localhost:<port>` and `http://127.0.0.1:<port>`) and only IP addresses and local names as `Host` (`421 MISDIRECTED_REQUEST`). Every secret comes from `src/core/random.lua`, a SHA-256 pool stirred with `C4:UUID`, clocks, `/dev/urandom` when readable and each request; only a hash of it is saved across restarts. Once a controller sealed for a device, the app never sends it the key in the clear again (unsigned refusals cannot make it fall back), and `GET /v1/sealed` no longer gives out the home id (envelopes at home name the home `lan`); a sealed request cannot carry another. The location is shown to admins only, rounded to two decimals. The controller registers its own invitations over the relay socket, and the cloud's member endpoint is kept for the home's owner (drivers before 1.0.0). The home's owner replaces the home secret from the app on the home network: the controller makes it and gives only its hash, the account service accepts it only from the owner, and the relay then accepts only it (the controller cannot replace it alone, or a copy of its data could lock it out). The Composer action **Reset Remote Identity** makes a new home id as a last resort. Accounts can sign out everywhere and expired sessions are purged daily. CI actions are pinned to commits, wrangler to an exact version, and `scripts/check_repo.py` refuses local configuration and secret files.

**Consequence:** Someone who only listens on the home network learns nothing that opens the home. Someone who can change traffic during pairing still could (the code travels with the request); local HTTPS or a code compared on both sides would close that, later. (ADR-039 closes it in 1.3.0: pairing never sends the code; ADR-040: the console's key lasts a day.) Old browsers, old drivers and scripts keep working unsealed. A copy of the controller's data still allows acting as its devices and as the home until **Revoke All API Keys** and the owner's **Replace the remote secret** are used (docs/ACCOUNTS.md, *What the lock does not protect*). A device with no sealed request yet (a key paired before 1.0.0) can still be made to send its key once by someone who changes traffic. The API console does not seal. Envelope sizes remain visible to the cloud.

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
