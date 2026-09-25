# C4Bridge Alpha Test

## Current test release

`v0.1.0-alpha.5`

On/Off is already validated on the real Control4 system. This test is specifically for dimmer brightness.

## Update

Update the existing C4Bridge driver in Composer. Do not remove/re-add the C4Bridge instance.

Expected:

- Bridge Version: `0.1.0-alpha.5`
- Status: `Ready (light adapter initialized)`
- API Status: `Online - light control alpha`

## Dimmer test

Choose one visible dimmable light.

1. Confirm On/Off still works.
2. Set brightness to **30%**.
3. Confirm the physical light changes.
4. Wait for the PWA to confirm Director-reported state.
5. Set brightness to **70%**.
6. Confirm again.

Expected command:

```text
SET_BRIGHTNESS_TARGET
LIGHT_BRIGHTNESS_TARGET = 30 (or 70)
RATE = 0
```

If dimming still fails, report the light name, proxy ID, current displayed brightness, requested brightness, and the exact PWA confirmation/error text.
