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
