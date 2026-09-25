# C4Bridge Alpha Test

## Current test release

`v0.1.0-alpha.3`

This test validates the first full device-control path:

```text
app.c4bridge.io
    -> Local Network Access
    -> C4Bridge authenticated LAN API
    -> normalized Light V2 adapter
    -> C4:SendToDevice(proxy ID, SET_BRIGHTNESS_TARGET)
    -> real light
    -> Light V2 variable feedback
    -> C4Bridge registry
    -> browser state
```

## 1. Update C4Bridge

Download `C4Bridge.c4z` from GitHub Release `v0.1.0-alpha.3`.

Use Composer Pro to update the existing C4Bridge driver. Do not remove the existing C4Bridge project instance.

## 2. Verify Composer

Expected:

- **Bridge Version:** `0.1.0-alpha.3`
- **Status:** `Ready (light adapter initialized)`
- **Supported Lights:** greater than 0 on a project with Light V2 devices
- **API Status:** `Online - light control alpha`
- **API Port:** `41999`

The API token should remain the same after a normal driver update.

## 3. Connect the PWA

1. Open **https://app.c4bridge.io** in current Chrome.
2. Enter the Director LAN IP.
3. Enter the API token from Composer.
4. Click **Connect & test**.
5. Allow Local Network Access if asked.

The discovery view should now include a **Lights** panel.

## 4. State validation before control

Choose one nearby light.

Confirm:

- light name/room is correct;
- displayed On/Off state matches reality;
- if dimmable, displayed brightness is plausible.

If state is wrong, stop and report the light name, proxy ID, displayed state, and real state before sending a command.

## 5. Control one test light

Use one known light only:

- press **Off**;
- confirm only that light turns off;
- press **On**;
- confirm only that light turns on;
- for a dimmer, set a clearly visible brightness such as 30% or 70%.

Then press **Refresh states** and verify the browser matches the physical result.

## 6. External state feedback

Change the same light from an existing Control4 interface or physical wall control, then press **Refresh states** in C4Bridge.

Expected: the new state is returned from the Light V2 proxy variables.

## Safety boundary

Alpha.3 only exposes normalized actions for devices successfully initialized by the Light V2 adapter. Unsupported/unknown devices remain non-controllable.
