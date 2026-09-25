# C4Bridge Alpha Test

## Current release

`v0.1.0-alpha.7`

This build specifically tests the DriverWorks compatibility path for KNX dimmers.

## Update test

Use a local file named exactly `C4Bridge.c4z`.

Right-click the existing C4Bridge instance -> **Update Driver**.

Before rebooting, check:

- Bridge Version
- Reload Counter
- Last Init Type
- Last Init Time
- Last Destroy Type
- Last Destroy Time

If hot update succeeds, expected:

```text
Bridge Version: 0.1.0-alpha.7
Last Init Type: DIT_UPDATING
```

## KNX dimmer test

Choose one light backed by `knx_dimmer.c4i`.

1. Verify On/Off still works.
2. Set brightness to **30%**.
3. Confirm physical brightness.
4. Set brightness to **70%**.
5. Confirm physical brightness.

Alpha.7 sends:

```text
RAMP_TO_LEVEL
LEVEL = 30 (or 70)
TIME = 0
```

For these KNX dimmers, C4Bridge does not require variable 1001 to confirm the requested level because the real snapshot showed the stock Control4 app also does not receive brightness-variable feedback after percentage changes.

If physical dimming still fails, collect one snapshot after one C4Bridge 30% command and one Control4-app 30% command so the two KNX gateway paths can be compared directly.
