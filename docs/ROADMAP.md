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

- [ ] Validate current discovery build on a real Director
- [ ] Capture representative `GetDevices({})` shapes from the test system
- [ ] Implement Light V2 adapter
- [ ] Read light state
- [ ] Subscribe to state changes
- [ ] ON/OFF
- [ ] Set brightness
- [ ] Validate on OS 3.3.x/3.4.x before broad compatibility claims

## Milestone 2 — local API/security

- [ ] Choose and prove browser-compatible LAN transport on OS 3.3+
- [ ] Define pairing flow
- [ ] Generate/store owner credential
- [ ] Authenticate every request
- [ ] Implement protocol v1 methods:
  - [ ] `system.info`
  - [ ] `discovery.refresh`
  - [ ] `rooms.list`
  - [ ] `devices.list`
  - [ ] `devices.get`
  - [ ] light control methods
- [ ] CORS / Local Network Access behavior

## Milestone 3 — PWA

- [ ] Cloudflare Pages app
- [ ] Director IP onboarding
- [ ] Local Network Access permission flow
- [ ] Pairing
- [ ] Rooms/devices dashboard
- [ ] Light UI
- [ ] PWA install/offline shell

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
