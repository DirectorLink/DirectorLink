# C4Bridge Alpha Test

## Current test release

`v0.1.0-alpha.4`

Alpha.4 fixes the Light V2 target-parameter bug discovered during the first alpha.3 real-light test.

## 1. Update the existing driver

Download `C4Bridge.c4z` from GitHub Release `v0.1.0-alpha.4`.

Update the existing C4Bridge driver in Composer Pro. Do not remove/re-add the C4Bridge project instance.

## 2. Verify Composer properties

Expected:

- **Bridge Version:** `0.1.0-alpha.4`
- **Status:** `Ready (light adapter initialized)`
- **Supported Lights:** non-zero
- **API Status:** `Online - light control alpha`
- **API Port:** `41999`

## 3. Test one visible light

1. Open **https://app.c4bridge.io**.
2. Connect to Director.
3. Pick one light whose physical state you can see.
4. Confirm the web state matches the real state.
5. Press **On** or **Off**.
6. Wait for C4Bridge's confirmation message.

Success now means Director's Light V2 state actually changed—not merely that the HTTP request was accepted.

For a dimmer, test `30%` or `70%` after On/Off works.

## Expected command mapping

```text
On:
SET_BRIGHTNESS_TARGET
LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1

Off:
SET_BRIGHTNESS_TARGET
LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2

Brightness:
SET_BRIGHTNESS_TARGET
LIGHT_BRIGHTNESS_TARGET_PERCENT = 0..100
RATE = 0
```

## If it still does not work

Report:

- light name
- light proxy ID
- whether it is a switch or dimmer
- displayed C4Bridge state before the command
- exact confirmation/error message after the command

Then we will inspect that specific proxy/device relationship rather than changing the generic adapter blindly.
