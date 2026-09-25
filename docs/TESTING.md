# C4Bridge Alpha Test

## Current test release

`v0.1.0-alpha.2`

This test validates the complete read-only path:

```text
app.c4bridge.io
    -> Chrome Local Network Access
    -> http://DIRECTOR_IP:41999
    -> C4Bridge token authentication
    -> Step 2 DeviceRegistry
```

## 1. Update the driver

Download `C4Bridge.c4z` from GitHub Release `v0.1.0-alpha.2`.

In Composer Pro use **Driver -> Add or Update Driver** / **Update Driver** to update the existing C4Bridge instance. Do not remove the instance.

## 2. Verify Composer properties

Select C4Bridge in Composer and verify:

- **Bridge Version** = `0.1.0-alpha.2`
- **Status** = `Ready (discovery complete)`
- **API Status** = `Online - read-only alpha`
- **API Port** = `41999`
- **API Token** = a UUID-like value
- **Discovery Summary** contains non-zero project counts as appropriate

If **API Status** is not online, do not continue to the browser test. Capture the C4Bridge Lua log.

## 3. Browser test

Use current desktop Chrome while connected to the same LAN as Director.

1. Open **https://app.c4bridge.io**.
2. Enter the Director LAN IPv4 address, e.g. `192.168.1.50`.
3. Paste the **API Token** from Composer.
4. Click **Connect & test**.
5. When Chrome asks whether the site may access devices on the local network, choose **Allow**.
6. Wait for the live discovery view.

Expected result:

- status changes to **Connected to C4Bridge**
- Bridge version and Director version appear
- room/device totals appear
- rooms are listed
- normalized devices are listed with their proxy type/driver metadata

## API endpoints

All data endpoints require:

```http
Authorization: Bearer <API_TOKEN>
```

Available in alpha.2:

- `GET /v1/system/info`
- `GET /v1/rooms`
- `GET /v1/devices`

Port: `41999`

Allowed browser origins:

- `https://app.c4bridge.io`
- `https://c4bridge.io`

## Failure clues

**Token rejected**
- Browser says the Director was reached but token was rejected.
- Re-copy the API Token from Composer.

**Timeout / cannot reach**
- confirm phone/PC and Director are on the same LAN
- confirm Director IP
- confirm Composer says API Status is Online
- confirm port 41999 is not blocked by LAN/firewall rules

**No Local Network Access prompt / blocked**
- use current Chrome
- check the site permission for Local Network Access
- reload the page and click Connect & test again

## Safety

Alpha.2 is read-only. It does not send commands to lights, HVAC, shades, bindings, Composer programming, or schedules.
