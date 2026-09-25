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
- [x] Set brightness now matches real Director log: `SET_BRIGHTNESS_TARGET` + `PERCENT`; real-system validation pending
- [ ] Validate on OS 3.3.x/3.4.x before broad compatibility claims

## Milestone 2 — local API/security

- [x] Implement first browser-compatible HTTP LAN transport spike on OS 3.3+
- [ ] Define final pairing flow (alpha.2 uses manual per-install token)
- [ ] Generate/store owner credential
- [x] Authenticate alpha read-only requests with Bearer token
- [ ] Implement protocol v1 methods:
  - [x] `system.info`
  - [ ] `discovery.refresh`
  - [x] `rooms.list`
  - [x] `devices.list`
  - [ ] `devices.get`
  - [ ] light control methods
- [x] Validate CORS / Local Network Access behavior on real Director

## Milestone 3 — PWA

- [x] Static Cloudflare Pages application shell
- [x] Director IP/local-hostname onboarding storage
- [x] PWA manifest + service worker/offline shell
- [x] 192px/512px install icons
- [x] Pages security headers
- [x] Cloudflare deployment documentation
- [ ] Connect GitHub repository to Cloudflare Pages
- [ ] Attach `c4bridge.io`
- [ ] Local Network Access request flow
- [ ] Pairing
- [ ] Rooms/devices dashboard
- [ ] Light UI

## Milestone 4 — more adapters

- [ ] Climate / thermostat
- [ ] Cover / blind / motorized window
- [ ] Expand unsupported-device diagnostics

## Milestone 5 — C4Bridge scenes

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
- [ ] Run C4Bridge scenes/actions
- [ ] Recalculate after reboot/timezone/location changes

## Deferred

- multiple users/roles
- remote cloud relay
- automatic C4Z update
- advanced project editing
- plugin ecosystem
