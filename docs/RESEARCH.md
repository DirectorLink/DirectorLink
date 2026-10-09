# Technical Research Notes

These notes capture external findings that informed the architecture.

## DriverWorks discovery

Control4 documents `C4:GetDevices(tFilter, locationFilter)` from OS 2.10. Passing an empty filter table returns all devices. Returned data varies by driver type and explicitly represents combo, proxy/protocol, and multi-proxy relationships.

Reference:
https://control4.github.io/docs-driverworks-api/#getdevices

Control4 documents `C4:GetProjectHierarchy()` from OS 2.10 as a table representing the location hierarchy.

Reference:
https://control4.github.io/docs-driverworks-api/#getprojecthierarchy

## Initialization

Project-wide discovery APIs should not be used during `OnDriverInit`. DirectorLink performs project discovery during `OnDriverLateInit`.

Reference:
https://control4.github.io/docs-driverworks-api/#safe-usage-of-ondriverinit-and-ondriverlateinit

## Composer changes (1.1.0)

A driver learns about Composer's changes only through Director's system events: `C4:RegisterSystemEvent(C4SystemEvents[name], 0)` for every device, and a global `OnSystemEvent(data)` whose `data` is XML with the event's name first. DirectorLink watches `OnItemAdded`, `OnItemRemoved`, `OnItemNameChanged`, `OnItemMoved`, `OnPIP` (Composer → Refresh Navigators), `OnDriverAdded` and `OnProjectLoaded`, and reads the project again once they stop (`src/control4/project_events.lua`). The documentation deprecates `OnProjectChanged` (OS 2.10) and names the item events for add, remove and rename; the names and ids come from Snap One's drivers-common-public `handlers.lua`. No public source shows the parameters of `OnItemMoved`: DirectorLink treats every event only as a sign of change and logs the payload at debug level, and a payload whose name it does not recognise counts too (Director sends a driver only the events it registered). `OnPIP` is not only Refresh Navigators: the documentation has it fire "when bindings, device names, or device media has changed", so alone it starts a read at most every two minutes. None of this has run on a real controller yet.

References:
snap-one/docs-driverworks-api, `source/includes/7_event/` (RegisterSystemEvent, OnSystemEvent, Registering for System Events)
https://raw.githubusercontent.com/snap-one/drivers-common-public/master/global/handlers.lua

## Blind proxy (1.1.0)

On Director 3.4.3 with KNX blinds (the "KNX Blinds (2.9+)" driver behind `blind.c4i`) the proxy's variables are 1000 Open, 1001 Fully Closed, 1002 Stopped, 1003 Fully Open, 1004 Level, 1005 Target Level, 1006 Type, 1007 Movement, 1008 Opening and 1009 Closing. Level is set when a move starts (the proxy's estimate), when it ends (the driver's timer) and whenever the actuator reports; values outside 0–100 are unknown (-155 when the actuator reports 255, -255 after a restart). Control4's own UI reads the proxy's setup with a UI request (Director logs `UIRequest returned: <blind_setup><has_level>True</has_level><level_discrete_control>True</level_discrete_control><can_stop>True</can_stop>...<movement>1</movement>...<levels minimum="0" maximum="100" resolution="1" unknown="-1"><level name="Closed" ... level="0" .../><level name="Open" ... level="100" .../>...`); `level_discrete_control` is False on shades that only open and close fully, whose KNX driver sends up for any target above 0. DirectorLink sends `GET_SETUP` with `C4:SendUIRequest` (the return value is not documented) and logs the answer once per shade at debug level.

What the proxy does during a move, on the same controller: it sends the UI `<moving><level>100</level><level_target>0</level_target><ramp_rate>25000</ramp_rate></moving>` when the move starts, `<stopped><level>0</level><level_target>0</level_target></stopped>` once the configured travel time is over, and the KNX actuator's real position comes about a second later as a change of Level. Snap One's proxy documentation (Blind: Variables) makes Stopped, Opening and Closing the motion variables (Stopped is false while the hardware moves, on drivers that report it) and Target Level where the blind is to stop, "used to know if a driver is currently going up or down". Movement is "a string representation of the enumeration for the movement": Open/Close, Up to Down, Down to Up, Out to In, Left to Right or Right to Left (`SET_MOVEMENT`; the setup's `<movement>`), the kind of movement and never whether the shade moves. Seen on that controller with DirectorLink 1.1.0 (2026-09-29): Stopped, Opening and Closing read `1`/`0`; Movement reads `Up-Down`, `Left-Right` or `Right-Left` (the setup lists `Open-Close,Up-Down,Down-Up,Out-In,Left-Right,Right-Left`); a move reads Stopped 0, then Target Level (the new target), then Opening or Closing 1; at its end Level becomes Target Level, then Stopped 1, and after a Stop the proxy's stopped state arrives 0.1–0.2 s after the command's answer. DirectorLink still reads true and false as 1/0, true/false or True/False and logs every change. The documentation also lets a driver count its levels from 0 to another open level (`level_open` defaults to 1; a shade that can stop uses 0, 1 and 2): DirectorLink takes the range from the setup's Closed and Open levels (else `level_closed`/`level_open`, else the minimum and maximum of `<levels>`) and shows it as 0–100.

Reference:
https://snap-one.github.io/docs-driverworks-proxyprotocol/ (Blind Proxy: commands, notifications, capabilities, events and variables)

## Project metadata

OS 3.0+ exposes project properties including latitude, longitude, country, city and related settings through `C4:GetProjectProperty()`; timezone is exposed through `C4:GetTimeZone()`.

Reference:
https://control4.github.io/docs-driverworks-api/

## External Director REST API

Other community projects use Director's local `/api/v1` HTTP interface. DirectorLink does **not** use it as the core architecture.

Reason:
DirectorLink already executes inside Director and can use DriverWorks directly. This avoids making the core dependent on external Director REST authentication/JWT behavior.

Projects reviewed for research only:
- https://github.com/New-Forest-Technology-Services/Control4-MCP
- https://github.com/lawtancool/pyControl4

No DirectorLink runtime dependency should be added on either project.

## Packaging

Control4 documents `.c4z` as a ZIP-based driver package containing `driver.xml`, Lua code and optional supporting directories.

Reference:
https://control4.github.io/docs-driverworks-fundamentals/

## Composer installation

Control4's documented manual-driver flow is:
**Driver → Add or Update Driver**, then locate the driver through System Design/Search and add it to the project.

Reference:
https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm


## Cloudflare Pages

Cloudflare Pages supports GitHub-connected projects and preview deployments. For a framework-free static site, DirectorLink uses:

- root directory: `web`
- build command: `exit 0`
- output directory: `.`
- production branch: `main`

(Historical: since 0.8.0 the app, console and landing page are Cloudflare Workers static-asset sites deployed by `.github/workflows/deploy.yml`; ADR-026.)

References:
- https://developers.cloudflare.com/pages/get-started/git-integration/
- https://developers.cloudflare.com/pages/configuration/build-configuration/

## Browser Local Network Access

DirectorLink's public HTTPS PWA must connect to a private/local Director address. Chromium's Local Network Access model gates these requests behind browser permission. Private IP literals and `.local` hostnames are recognized as local-network targets; fetch also supports the `targetAddressSpace` hint in Chromium.

WebSocket local-network restrictions are also covered by the Local Network Access model in current Chromium releases.

References:
- https://developer.chrome.com/blog/local-network-access
- https://developer.chrome.com/blog/chrome-147-beta


## Browser-to-Director HTTP transport

DriverWorks `C4:CreateServer(port, delimiter, useUDP)` is available from OS 2.10 and can accept multiple TCP clients. DirectorLink alpha.2 uses it as a small HTTP/1.1 server with header delimiter `\r\n\r\n`.

DirectorLink minimum OS remains 3.3.0, so it can also generate a random UUID4 token with `C4:UUID("RANDOM")` and persist that token encrypted using `C4:PersistSetValue(..., true)`. (Superseded: keys are stored as hashes since 0.9.2, ADR-028, and every secret comes from the driver's own random pool since 1.0.0, `src/core/random.lua`, ADR-032, because how Director makes its UUIDs is not documented.)

**Finding (0.9.1, OS 3.4.3):** `C4:PersistGetValue` returns a stored string that is JSON decoded, as a Lua table; strings that are not JSON come back as written. Other drivers' typed values are stored the same way (`{":boolean:":true}` in `state.db`). The values themselves survive driver updates in `state.db` (`item_state`, one row per name and device). DirectorLink therefore stores `json:` plus JSON and accepts decoded tables (`src/core/store.lua`, ADR-028).

Reference:
- https://control4.github.io/docs-driverworks-api/

Chrome 142+ gates public-site requests to local/private addresses behind Local Network Access permission. Current Chrome can exempt known local destinations (private IP literals, `.local`, or fetch requests annotated with `targetAddressSpace: "local"`) from mixed-content blocking after the permission decision.

Reference:
- https://developer.chrome.com/blog/local-network-access
- https://developer.chrome.com/release-notes/142


## Light V2 state and control

Control4's Light V2 proxy defines:

- Light State variable ID `1000`
- Light Brightness Percent variable ID `1001` for dimmers
- Default On Preset Brightness variable ID `1006`
- `SET_BRIGHTNESS_TARGET` as the current brightness control command
- `LIGHT_BRIGHTNESS_TARGET_PRESET_ID` can be used for static On/Off preset targets and is validated on the real test system
- Control4's official sample Light V2 protocol driver handles `SET_BRIGHTNESS_TARGET` by reading `tParams.LIGHT_BRIGHTNESS_TARGET` and `tParams.RATE`
- `RATE = 0` is used by DirectorLink for an immediate explicit brightness change
- `C4:SendToDevice(proxyId, command, params)` for sending a command to another project device
- `C4:RegisterVariableListener(deviceId, variableId)` plus `OnWatchedVariableChanged` for live state updates

Control4 recommends the Brightness Target API for Light V2 on OS 3.3.0 and newer.

References:
- https://control4.github.io/docs-driverworks-proxyprotocol/
- https://control4.github.io/docs-driverworks-api/
- https://github.com/snap-one/docs-driverworks/tree/master/driver_development_training/sample_light_driver

### KNX switches and dimmers — 2026-10-09 (1.10.2, ADR-077)

Read on the owner's controller (CORE-1, OS 4.2.1), read-only, for interoperability:

- 107 lights are on `knx_switch.c4i` and 2 on `knx_dimmer.c4i`, all behind `light_v2.c4i` proxies.
  The switches' proxies have variable `1001` too, at 0 or 100, which 1.10.1 took for a dimmer.
- What each driver declares in its driver.xml `<capabilities>`: the switch `<dimmer>False</dimmer>`,
  `<set_level>False</set_level>`, `<ramp_level>False</ramp_level>`, `<on_off>True</on_off>`; the
  dimmer `<dimmer>True</dimmer>`, `<set_level>True</set_level>`, `<ramp_level>True</ramp_level>`,
  `<supports_target>True</supports_target>`, `<requires_target_preset_ids>True</requires_target_preset_ids>`.
- The KNX dimmer's driver handles the proxy command `SET_BRIGHTNESS_TARGET` with the level in
  `LIGHT_BRIGHTNESS_TARGET` (0–100), an optional ramp `RATE` (ms; 0 sets the level at once) and an
  optional `LIGHT_BRIGHTNESS_TARGET_PRESET_ID` (its On and Off presets mean 100 and 0). It reads no
  `PERCENT`: what alpha.6 to 1.10.1 sent moved nothing, and `RAMP_TO_LEVEL` (alpha.7 on) did not
  either (#11).
- Snap One's proxy documentation (*Light V2*, `SET_BRIGHTNESS_TARGET`) gives a driver with
  `supports_target` exactly `LIGHT_BRIGHTNESS_TARGET` (FLOAT, within the driver's min and max) and
  `RATE` (milliseconds, within its min and max rate); a driver without it gets `LEVEL` and `TIME`.
  `dimmer` and `set_level` default to false and may change while a driver runs (dynamic capabilities).
- `C4:GetDeviceData(id, "capabilities")` gives what is inside a driver's `<capabilities>`
  (DriverWorks API, `GetDeviceData`, from OS 2.10: a tag of the first two levels of `<devicedata>`).


## Light (legacy) proxy

Older Control4 dimmers and switches (LDZ-101/102, LDZ-5S1) use the legacy Light proxy
`light.c4i`. bkwagner read its variables and commands on a live Director over Director REST
(`GET /api/v1/items/{id}/variables` and `/commands`, #14); in that installation 25 of 38 lights
used it:

- Light State `1000` and the level `1001`, as on Light V2; switches have no `1001`
- the commands `ON`, `OFF` and `SET_LEVEL` with `LEVEL`, instead of `SET_BRIGHTNESS_TARGET`

Not seen yet: a DirectorLink `SET_LEVEL` moving one of these lights (`LEVEL` goes out as XML
`INT`, the form Control4 documents for `RAMP_TO_LEVEL`), and whether `1000` can read `100`
rather than `1`.


## Fan proxy

Fan speed controllers sit behind the Fan proxy `fan.c4i`. bkwagner read it on a live Director
(#18): `1000` IS_ON, `1001` CURRENT_SPEED (0–4) and `1003` PRESET_SPEED, and a `SET_SPEED`
command listing 0–4 (Off, Low, Medium, Medium High, High). Snap One's proxy documentation
(docs-driverworks-proxyprotocol, *Fan Proxy*) adds:

- `ON` turns the fan on at its preset speed, or at its last one (the protocol driver chooses);
  `OFF`; `SET_SPEED {SPEED}` from 0 (off) to the highest speed; also `TOGGLE`, `CYCLE_SPEED_UP` /
  `_DOWN`, `DESIGNATE_PRESET {PRESET}` and, where `can_reverse`, `SET_DIRECTION`.
- The UI request `GET_SETUP` answers `<fan_setup>` with `speeds_count`, `speed_names` (by default
  for 4: Low, Medium Low, Medium High, High — other names than the contributor's fan listed),
  `can_reverse`, `can_set_preset` and `preset_speed`.
- `CURRENT_SPEED` is reported 0 when the fan turns off.

Not seen yet: a DirectorLink command moving a real fan, what `GET_SETUP` answers on one, and fans
with fewer than four speeds. DirectorLink 1.2.0 takes speeds 1–4, as read, and logs the variables
and the setup at Debug.


## Thermostat setpoint variables 1100–1150

Thermostat V2 and the Control4 thermostat proxy (`control4_thermostat_proxy.c4i`) share these
ids. The names were read by bkwagner on a live Director: five proxy thermostats (#16), and a real
heat-only floor-heating Thermostat V2 in a °F project (#19).

| Id | Name | Notes |
| --- | --- | --- |
| 1100 | SCALE | the project's scale, `FAHRENHEIT` or `CELSIUS` |
| 1104 | HVAC_MODE | |
| 1105 | FAN_MODE | can read `Undefined` |
| 1107 | HVAC_STATE | |
| 1112 | IS_CONNECTED | |
| 1120 | HVAC_MODES_LIST | comma-separated |
| 1121 | FAN_MODES_LIST | comma-separated |
| 1130 / 1131 | TEMPERATURE_F / TEMPERATURE_C | |
| 1132 / 1133 | HEAT_SETPOINT_F / HEAT_SETPOINT_C | the floor-heating zone's real target |
| 1134 / 1135 | COOL_SETPOINT_F / COOL_SETPOINT_C | |
| 1146 / 1147 | DEADBAND_F / DEADBAND_C | the smallest gap between heat and cool |
| 1149 / 1150 | the single setpoint, °F / °C | 0 in both on that floor-heating zone |

On that zone only `SET_SETPOINT_HEAT {FAHRENHEIT}` was listed, no `SET_SETPOINT_SINGLE`. The proxy
thermostats list `SET_SETPOINT_HEAT` and `SET_SETPOINT_COOL` with `FAHRENHEIT` or `CELSIUS`. Open:
whether they take `CELSIUS` in a °F project, fractional `FAHRENHEIT`, what they do themselves
when the deadband is broken, and the real spellings in their mode lists.


## Snapshot findings — 2026-09-25

A real Director snapshot resolved both active alpha issues.

### Dimmer command

For the tested Light V2 proxy, the working native path in Director logs used:

```text
SET_BRIGHTNESS_TARGET
PERCENT = <0..100>
```

DirectorLink alpha.5 was sending a different parameter shape and the light did not change. Alpha.6 therefore uses the exact `PERCENT` parameter observed in the working Director path.

### Driver update/reload

The Director filesystem contained both:

```text
DirectorLink.c4z
DirectorLink (1).c4z
```

and after reboot the project instance loaded `DirectorLink (1).c4z`.

This indicates repeated browser downloads with Windows filename suffixes can create a second Control4 driver filename instead of replacing the canonical package. The update test procedure now requires selecting a file named exactly `DirectorLink.c4z`.

Alpha.6 also adds lifecycle diagnostics so the next update test can distinguish `DIT_UPDATING` from `DIT_STARTUP`.


## Alpha.6 KNX dimmer snapshot

The alpha.6 snapshot proved DirectorLink itself reached the tested KNX dimmer path correctly. For example, DirectorLink sent `SET_BRIGHTNESS_TARGET` with `PERCENT=48` to proxy 459 and Director immediately sent a payload to the KNX Tunneling Gateway.

The same snapshot showed an observable serialization difference:

- DirectorLink via `C4:SendToDevice`: `PERCENT` serialized as XML `type="INT"`
- Control4 app via Director broker REST: `PERCENT` serialized as XML `type="number"`

The physical KNX dimmer responds to the Control4 app path but not the DirectorLink DriverWorks path.

Control4's DriverWorks API documentation explicitly demonstrates driver-to-light dimming using:

```lua
C4:SendToDevice(lightId, "RAMP_TO_LEVEL", {
    LEVEL = 60,
    TIME = 3000,
})
```

Alpha.7 therefore uses `RAMP_TO_LEVEL` for Light V2 proxies backed by `knx_dimmer.c4i`.

The snapshot also showed no Light V2 variable 1001 update after normal percentage changes from the stock Control4 app. Variable 1001 did update on a full dynamic On. Therefore KNX brightness feedback is treated as unavailable rather than falsely timing out.

Reference:
- https://control4.github.io/docs-driverworks-api/#sendtodevice
