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

Project-wide discovery APIs should not be used during `OnDriverInit`. C4Bridge performs project discovery during `OnDriverLateInit`.

Reference:
https://control4.github.io/docs-driverworks-api/#safe-usage-of-ondriverinit-and-ondriverlateinit

## Project metadata

OS 3.0+ exposes project properties including latitude, longitude, country, city and related settings through `C4:GetProjectProperty()`; timezone is exposed through `C4:GetTimeZone()`.

Reference:
https://control4.github.io/docs-driverworks-api/

## External Director REST API

Other community projects use Director's local `/api/v1` HTTP interface. C4Bridge does **not** use it as the core architecture.

Reason:
C4Bridge already executes inside Director and can use DriverWorks directly. This avoids making the core dependent on external Director REST authentication/JWT behavior.

Projects reviewed for research only:
- https://github.com/New-Forest-Technology-Services/Control4-MCP
- https://github.com/lawtancool/pyControl4

No C4Bridge runtime dependency should be added on either project.

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

Cloudflare Pages supports GitHub-connected projects and preview deployments. For a framework-free static site, C4Bridge uses:

- root directory: `web`
- build command: `exit 0`
- output directory: `.`
- production branch: `main`

References:
- https://developers.cloudflare.com/pages/get-started/git-integration/
- https://developers.cloudflare.com/pages/configuration/build-configuration/

## Browser Local Network Access

C4Bridge's public HTTPS PWA must connect to a private/local Director address. Chromium's Local Network Access model gates these requests behind browser permission. Private IP literals and `.local` hostnames are recognized as local-network targets; fetch also supports the `targetAddressSpace` hint in Chromium.

WebSocket local-network restrictions are also covered by the Local Network Access model in current Chromium releases.

References:
- https://developer.chrome.com/blog/local-network-access
- https://developer.chrome.com/blog/chrome-147-beta


## Browser-to-Director HTTP transport

DriverWorks `C4:CreateServer(port, delimiter, useUDP)` is available from OS 2.10 and can accept multiple TCP clients. C4Bridge alpha.2 uses it as a small HTTP/1.1 server with header delimiter `\r\n\r\n`.

C4Bridge minimum OS remains 3.3.0, so it can also generate a random UUID4 token with `C4:UUID("RANDOM")` and persist that token encrypted using `C4:PersistSetValue(..., true)`.

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
- `RATE = 0` is used by C4Bridge for an immediate explicit brightness change
- `C4:SendToDevice(proxyId, command, params)` for sending a command to another project device
- `C4:RegisterVariableListener(deviceId, variableId)` plus `OnWatchedVariableChanged` for live state updates

Control4 recommends the Brightness Target API for Light V2 on OS 3.3.0 and newer.

References:
- https://control4.github.io/docs-driverworks-proxyprotocol/
- https://control4.github.io/docs-driverworks-api/
- https://github.com/snap-one/docs-driverworks/tree/master/driver_development_training/sample_light_driver


## Snapshot findings — 2026-09-25

A real Director snapshot resolved both active alpha issues.

### Dimmer command

For the tested Light V2 proxy, the working native path in Director logs used:

```text
SET_BRIGHTNESS_TARGET
PERCENT = <0..100>
```

C4Bridge alpha.5 was sending a different parameter shape and the light did not change. Alpha.6 therefore uses the exact `PERCENT` parameter observed in the working Director path.

### Driver update/reload

The Director filesystem contained both:

```text
C4Bridge.c4z
C4Bridge (1).c4z
```

and after reboot the project instance loaded `C4Bridge (1).c4z`.

This indicates repeated browser downloads with Windows filename suffixes can create a second Control4 driver filename instead of replacing the canonical package. The update test procedure now requires selecting a file named exactly `C4Bridge.c4z`.

Alpha.6 also adds lifecycle diagnostics so the next update test can distinguish `DIT_UPDATING` from `DIT_STARTUP`.
