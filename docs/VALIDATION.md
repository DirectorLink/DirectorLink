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
