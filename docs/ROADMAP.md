# Development Roadmap

## Milestone 0 — foundation

- [x] Repository
- [x] Apache-2.0
- [x] Product/architecture spec
- [x] DriverWorks package skeleton
- [x] OS 3.3.0+ gate
- [x] Discovery/normalization registry
- [x] Composer-visible discovery diagnostics

## Milestone 1 — first controllable device

- [x] Validate current discovery build on a real Director
- [ ] Capture representative `GetDevices({})` shapes from the test system
- [x] Implement Light V2 adapter
- [x] Read light state
- [x] Subscribe to state changes
- [x] ON/OFF implemented and validated on a real Director in alpha.4
- [ ] KNX percentage dimming deferred to issue #11; On/Off remains validated
- [ ] Validate on OS 3.3.x/3.4.x before broad compatibility claims

## Milestone 2 — local API/security

- [x] Implement first browser-compatible HTTP LAN transport spike on OS 3.3+
- [x] Define and implement one-owner pairing flow (alpha.8)
- [x] Validate CORS / Local Network Access behavior on real Director
- [x] OpenAPI 3.1 contract with logical resources, checked against the driver in CI (0.2.0)
- [x] Named API keys: create, list, revoke; Composer "Revoke All API Keys" (0.2.0)
- [x] Request bodies, `PATCH` state changes, RFC 9457 errors (0.2.0)
- [x] Driver log API with levels and filters (0.2.0)
- [x] Driver tests against a fake Director (0.2.0)
- [x] Validate 0.2.0 request-body handling on a real Director
- [x] Approve new clients from the Control4 app instead of the Composer pairing code (0.3.0)
- [x] Key roles (viewer, member, doors, admin) and the Composer Door Control switch (0.7.0)
- [x] Renamed to DirectorLink; app, console and website on directorlink.io (0.8.0)
- [x] Pair once with an on-demand code (New Pairing Code, 15 minutes, one use); the Access button and access requests are gone (0.8.0)
- [x] DoorBird doorbells: rings, motion, access, open the gate (0.9.2)
- [x] Keys, room names and the remote identity survive driver updates and restarts; keys stored only as hashes (0.9.2)
- [x] Remote access: relay connection proof (0.9.2, test)
- [x] Remote access with Google accounts, end-to-end encryption, claiming a home on the LAN, invitations, iPhone and iPad (0.10.0; `docs/ACCOUNTS.md`)
- [x] People and devices: keys, invitations and the home's accounts in the app; cloud membership follows the device keys (0.11.0)
- [x] Profiles: each person's language, theme, favorites and hidden rooms on the controller, shared by their devices; the home's room order (0.12.0; `docs/PREFERENCES.md`)
- [x] DirectorLink scenes: made in the app, run with one tap, shown on Home (0.13.0; `docs/SCENES.md`)
- [x] Schedules by time, sunrise/sunset and weather (Open-Meteo: heat, rain, wind), run by the controller (0.14.0; `docs/SCHEDULES.md`)
- [x] Automation visible to the installer in Composer: pause switch, schedule status, last automation, printout (0.15.0)
- [x] Security review fixes (issue #43, ADR-032): the app seals its requests at home too and pairs with a key exchange; pairing only at home, locked per device; origin and Host checks; location for admins only; secrets from a random pool; invitations registered by the controller; the owner replaces the home secret; Reset Remote Identity; sign out everywhere (1.0.0)
- [x] The driver checks the relay's certificate against the roots it carries (1.1.0, ADR-034)
- [ ] The API console seals its requests like the app
- [ ] Local HTTPS, or a code compared on both sides, against someone who changes traffic during pairing
- [ ] Sign in with Apple (built, off until its keys are set up); owner approval of email mismatches
- [x] Rediscover the project without restarting the driver: Director's project events and the action Refresh Project (1.1.0); real-system validation pending

## Milestone 3 — PWA

- [x] Static Cloudflare Pages application shell
- [x] Director IP/local-hostname onboarding storage
- [x] PWA manifest + service worker/offline shell
- [x] 192px/512px install icons
- [x] Pages security headers
- [x] Cloudflare deployment documentation
- [x] Deploy app, console and website from GitHub Actions (`deploy.yml`)
- [x] Attach `directorlink.io`
- [x] Local Network Access request flow
- [x] Pairing
- [x] API console: every endpoint from the live API description, live log (0.2.0)
- [x] Rooms/devices dashboard (Home and room screens)
- [x] Light UI

## Milestone 4 — more adapters

- [x] Climate / thermostat implemented in alpha.9; real-system validation pending
- [x] Blinds: position, open/close/stop through the blind proxy (0.4.0)
- [x] Shades: a slider and Stop only where the shade can use them, and its movement shown while it moves (1.1.0; in 1.1.1, fixes for Stop, Forget key, a move after a while away and a shade left not stopped after a restart); real-system validation pending
- [x] Cameras: snapshots through the camera proxy, near-live grid in the app (0.5.0)
- [x] KNX relays (doors and gates): pulse, open/close, state from events (0.6.0); held closed only with Relay Hold allowed in Composer (1.1.1, ADR-036)
- [x] Room names per language (0.6.0)
- [ ] Expand unsupported-device diagnostics
- [x] Light V1 (#14), heat-only setpoint (#19), dual-setpoint thermostats (#16) (1.1.0, thanks to bkwagner; ADR-033)
- [x] Alarm status (#15): security partitions, read-only, off by default (Composer **Alarm Status**), for members and admins in sealed answers only (1.2.0, thanks to bkwagner; ADR-038); real-system validation pending
- [ ] Proposed in a pull request from bkwagner, not merged yet: fans (#18)
- [ ] Arming and disarming the alarm: only with a design for the user's alarm code (ADR-038)

## Milestone 5 — DirectorLink scenes

- [x] Scene model (0.13.0)
- [x] Scene persistence (0.13.0)
- [x] Multi-action execution (0.13.0)
- [x] Failure behavior and partial execution reporting (0.13.0)

## Milestone 6 — scheduling

- [x] Persistent schedule store (0.14.0)
- [x] Fixed time (0.14.0)
- [x] Days of week (0.14.0)
- [x] Sunrise/sunset (0.14.0, worked out on the controller)
- [x] Solar offsets (0.14.0)
- [x] Run DirectorLink scenes (0.14.0)
- [x] Weather triggers and conditions from Open-Meteo: heat, wind, rain (0.14.0)
- [x] Recalculate after reboot/timezone/location changes (0.14.0: worked out each minute)
- [ ] Optional Jewish-calendar module: Shabbat and holiday times as schedule triggers (later)

## Driver updates (ADR-035)

- [x] Step 1, a guided update: admins see a newer release in the app, with what's new, the download of its `DirectorLink.c4z` and the Composer steps (1.1.0)
- [ ] Test on the owner's CORE-1 with a throwaway driver whether a driver can install a `.c4z` on OS 3.4.3
- [ ] If it can: one-tap install from the app, admins only, behind the Composer property **App Updates** (default Not allowed), only to newer versions; going back stays in Composer
- [ ] Releases signed in GitHub, the signature checked by the driver in plain Lua (minimum OS stays 3.3.0)

## Deferred

- automatic C4Z update
- advanced project editing
- plugin ecosystem
