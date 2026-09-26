# Real-System Validation

## 2026-09-25 — v0.1.0-alpha.2

The first end-to-end browser-to-Director test succeeded on a real Control4 installation.

### Environment

- C4Bridge: `0.1.0-alpha.2`
- Director: `3.4.3.727848-res`
- System type: `XDT_CORE1`
- Production PWA: `https://app.c4bridge.io`
- LAN API: HTTP on TCP `41999`
- Browser transport: Chrome Local Network Access
- Authentication: per-install Bearer token

### Discovery result

- Rooms: **20**
- Normalized devices: **195**
- Protocol drivers: **181**
- Recognized proxy families: **148**
- Unsupported entities: **47**

### Confirmed working

```text
app.c4bridge.io
    -> browser Local Network Access
    -> Director LAN IP:41999
    -> C4Bridge HTTP server
    -> Bearer-token authentication
    -> Step 2 DeviceRegistry
    -> live rooms/devices rendered in browser
```

This validates the core V1 network architecture:

1. Cloudflare hosts static UI only.
2. Control/project data travels directly browser <-> Director on LAN.
3. No C4Bridge cloud relay is required.
4. A DriverWorks TCP server can provide a browser-compatible HTTP endpoint.
5. CORS and Local Network Access work from the production C4Bridge origin.
6. The Step 2 normalized registry is usable by the web frontend.

### Next milestone

Implement and validate the first controllable adapter: **Light V2**.

Required:
- read current power/brightness state
- subscribe to light variable/state changes
- normalized `on`
- normalized `off`
- normalized `set_brightness`
- expose only light actions through the C4Bridge API
- keep unsupported/raw devices non-controllable


## 2026-09-25 — alpha.4 Light V2 control

Real-system Light V2 On/Off control succeeded on the same Director test system.

### Confirmed

- PWA -> C4Bridge authenticated LAN API works
- normalized `on` action works
- normalized `off` action works
- Light V2 proxy routing works
- corrected `SET_BRIGHTNESS_TARGET` preset mapping works
- state returned to the PWA is usable for confirmation

### Still to validate for the light milestone

- dimmer brightness percentage control
- state changes initiated outside C4Bridge (wall keypad / Navigator / Composer)
- driver update/reload behavior without rebooting Director


## 2026-09-25 — Snapshot diagnosis — dimmer and updates

A Director snapshot captured the failed alpha.5 dimmer attempt and the native working path.

### Dimmer

Working native commands to the tested Light V2 proxy used:

```text
SET_BRIGHTNESS_TARGET
PERCENT = <level>
```

C4Bridge alpha.5 used a different parameter shape. Alpha.6 changes the adapter to match the captured native command exactly.

### Driver update

The snapshot showed both `C4Bridge.c4z` and `C4Bridge (1).c4z` installed. After reboot the project instance loaded the suffixed filename.

Alpha.6 update validation must use a local file named exactly `C4Bridge.c4z` and inspect the new lifecycle diagnostics before rebooting.


## 2026-09-25 — alpha.6 KNX dimmer trace

The real Director snapshot confirms:

- alpha.6 is loaded as C4Bridge device 572;
- C4Bridge receives slider requests from the PWA;
- C4Bridge dispatches `SET_BRIGHTNESS_TARGET PERCENT=<value>` to KNX-backed Light V2 proxies;
- Director sends a payload to the KNX Tunneling Gateway immediately after each C4Bridge command;
- the stock Control4 app uses the same command/parameter names but its broker serializes `PERCENT` as XML `type="number"`, while DriverWorks serializes C4Bridge's value as `type="INT"`;
- the physical dimmer works from the stock app but not from the alpha.6 DriverWorks path;
- KNX Light V2 variable 1001 does not provide reliable post-dim level feedback.

Alpha.7 changes only KNX-backed dimmer brightness to the documented DriverWorks `RAMP_TO_LEVEL` path and marks brightness feedback unavailable for those devices.


## 2026-09-25 — alpha.8 owner pairing

Real-system owner pairing succeeded. A short Composer Pairing Code successfully provisioned the browser owner credential, and the paired browser reconnects without manually copying the long API token.


## 2026-09-25 — HVAC command capture

A real Director snapshot captured the stock Control4 UI controlling a Thermostat V2 proxy with `SET_MODE_HVAC {MODE}`, `SET_MODE_FAN {MODE}`, and `SET_SETPOINT_SINGLE {CELSIUS}`. These exact command shapes are the basis of alpha.9.


## 2026-09-26 — v0.2.0 OpenAPI API

Installed as a Composer driver update on the same test system (Director `3.4.3.727848-res`, `XDT_CORE1`).

### Confirmed

- The DriverWorks TCP server works without a delimiter: the driver assembles requests itself and reads JSON bodies by `Content-Length` (pairing and `PATCH` requests).
- Pairing with the Composer code issues a named API key; the paired web app loads system, rooms, devices, lights and thermostats.
- Lights on/off through `PATCH /v1/lights/{id}` (three KNX switches) and an AC zone mode and setpoint change through `PATCH /v1/thermostats/{id}`, confirmed on the real devices.
- Browser preflights (CORS and Private Network Access) from a web app served on localhost.
- The Composer **Log Level** property changes the recorded level immediately.
- 83 real responses — every room, every thermostat, lights, devices, logs, API keys and error responses — validated against `api/openapi.yaml` with zero schema errors.

### Project as seen through the API

- 20 rooms, all on a floor; 195 devices: 111 lights, 22 thermostats, 15 covers (recognized, not controllable yet), 47 other.
- Lights: 2 dimmable KNX dimmers (level not reported), the rest on/off.
- Thermostats: 14 AC zones (off/heat/cool, fan low/medium/high) and 8 floor-heating zones (off/heat, no fan).

### Performance

Inside the driver most requests take 3–35 ms. Seen from a LAN client, the full device list takes about 60 ms and 500 log entries about 85 ms.


## 2026-09-26 — v0.3.0 C4Bridge Access button

Same test system (Director `3.4.3.727848-res`, `XDT_CORE1`), captured live from the Director logs.

### Driver structure

- As a combo driver (first 0.3.0 build) the Director created only the combined device; the button proxy never appeared. Every working button driver on the system (door/garage relays, DoorBird, experience buttons) is a protocol device (item type 6) with a `uibutton` child proxy (type 7).
- Without `<combo>`, `AddDevice` created **C4Bridge** (protocol device) and **C4Bridge Access** (`uibutton` proxy, binding 5001) in the same room.

### Button visibility

- Control4 adds new buttons hidden. Composer's Navigators view shows one by sending the room `SET_SECURITY_DEVICE_ORDER` with `DEVICE_DATA_XML` — the visible Security entries (hidden 0) followed by the hidden ones (hidden 1). `GET_SECURITY_DEVICES` returns the visible list; with `hidden = 1` it returns the hidden list. Special entries are listed unsigned (4294966301) and written signed (-995).
- The driver now does this itself 5 seconds after being added: confirmed — `SET_SECURITY_DEVICE_ORDER` on the room, "C4Bridge Access is now visible in the Control4 app (Security)", and the button appeared in the Control4 app without opening Composer.

### Approval

- Access requested from the web app → the button pressed in the Control4 app → API key issued, within 4 seconds; a press with nothing waiting is ignored.

### Driver updates (issue #8)

- Composer's connection sync copies a new `.c4z` into the Director's driver store (`/opt/control4/var/drivers/c4z`), but no reload command reaches the Director and the running instance keeps its old code until a reboot. Adding a device (`AddDevice`) or booting loads the new code immediately (`Attempting to load file` → `loadC4Z: Extracting` → `Lua driver loaded successfully`). A right-click **Update Driver** has not been captured yet.

## 2026-09-26 — v0.4.0 blinds and driver updates

### Driver updates (issue #8) — fixed

- Cause: the broker (Director's driver upload service) reads `driver.xml` as `<xml>` + contents + `</xml>` with expat. The `<?xml ...?>` declaration C4Bridge had since its first commit is not allowed mid-document, so every upload logged `Unable to parse driver C4Bridge.c4z` in `/var/log/debug/broker.log` (the only one of 375 drivers) and the Director never reloaded it.
- Without the declaration, updating in Composer reloaded the running driver in place: `[DriverUpdateAgent] Driver updated: C4Bridge.c4z`, C4Bridge logged `driver destroyed` / `driver init` with `DIT_UPDATING` and version 0.4.0 within a second — no reboot, no remove and re-add. `check_package.py` now parses `driver.xml` the same way.

### Blinds

- 15 blind proxies (`blind.c4i` over `knx_blind.c4z`) discovered; the proxy's `Level` variable was found on all of them.
- From the web app: open (`SET_LEVEL_TARGET` 100), stop (`STOP`) and close (`SET_LEVEL_TARGET` 0) on blinds 312, 314, 316, 320 and 322 — the blinds moved as commanded.

## 2026-09-26 — v0.5.0 cameras

- Updated from 0.4.0 in Composer: reloaded in place (`DIT_UPDATING`), no reboot. 13 camera proxies (`camera.c4i`: 12 Hikvision IPC, 1 DoorBird) discovered.
- `GET_PROPERTIES` and `GET_SNAPSHOT_QUERY_STRING` on the camera proxy (via `C4:SendUIRequest`), `C4:url()` with digest login (`C4:Hash` MD5) work on Director 3.4.3: the homeowner confirmed the web app's Cameras grid shows pictures.
- Camera 99 (192.168.1.89) timed out (`Error 28: Timeout was reached`) — reported as `CAMERA_UNREACHABLE`; the other cameras kept working.
