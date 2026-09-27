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
- [x] DoorBird doorbells: rings, motion, access, open the gate (0.9.1)
- [x] Pairing survives driver updates: keys kept as hashes in plain persistence (0.9.1)
- [ ] Remote access: relay connection proof (0.9.1, test), then Google/Apple accounts, claim a home on the LAN with a pairing code, invitations by email
- [ ] Rediscover the project without restarting the driver

## Milestone 3 — PWA

- [x] Static Cloudflare Pages application shell
- [x] Director IP/local-hostname onboarding storage
- [x] PWA manifest + service worker/offline shell
- [x] 192px/512px install icons
- [x] Pages security headers
- [x] Cloudflare deployment documentation
- [ ] Deploy app, console and website from GitHub Actions (`deploy.yml`) — waiting for Cloudflare credentials
- [ ] Attach `directorlink.io`
- [ ] Local Network Access request flow
- [x] Pairing
- [x] API console: every endpoint from the live API description, live log (0.2.0)
- [ ] Rooms/devices dashboard
- [ ] Light UI

## Milestone 4 — more adapters

- [x] Climate / thermostat implemented in alpha.9; real-system validation pending
- [x] Blinds: position, open/close/stop through the blind proxy (0.4.0)
- [x] Cameras: snapshots through the camera proxy, near-live grid in the app (0.5.0)
- [x] KNX relays (doors and gates): pulse, open/close, state from events (0.6.0)
- [x] Room names per language (0.6.0)
- [ ] Expand unsupported-device diagnostics

## Milestone 5 — DirectorLink scenes

- [ ] Scene model
- [ ] Scene persistence
- [ ] Multi-action execution
- [ ] Failure behavior and partial execution reporting

## Milestone 6 — scheduling

- [ ] Persistent schedule store
- [ ] Fixed time
- [ ] Days of week
- [ ] Sunrise/sunset
- [ ] Solar offsets
- [ ] Run DirectorLink scenes/actions
- [ ] Recalculate after reboot/timezone/location changes
- [ ] Optional Jewish-calendar module: Shabbat and holiday times as schedule triggers (later)

## Deferred

- multiple users/roles
- remote cloud relay
- automatic C4Z update
- advanced project editing
- plugin ecosystem
