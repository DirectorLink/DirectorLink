# C4Bridge Alpha Test

## Current release

`v0.1.0-alpha.9`

This build validates Thermostat V2 state and HVAC commands.

## Update

Use a local file named exactly `C4Bridge.c4z`.

Expected after the new driver is actually loaded:

- Bridge Version: `0.1.0-alpha.9`
- Supported Climate: greater than zero
- API Status: `Online - pairing enabled`

Owner pairing from alpha.8 should continue working.

## HVAC panel

Hard-refresh `https://app.c4bridge.io` and connect using the already-paired browser.

Expected:

- a new HVAC panel appears;
- Thermostat V2 devices are listed;
- current temperature, target temperature, HVAC mode and fan mode are visible where supported.

## Test one AC zone first

Use one known visible AC zone.

1. Set HVAC mode to Off and confirm the real Control4 state.
2. Set mode to Cool and confirm it changes.
3. Change target temperature to 22°C and confirm.
4. Change fan from Low to Medium and back.

Do not test every zone until one known AC zone works end-to-end.

## Heat-only zone

After the AC test succeeds, open one floor-heating thermostat.

Expected:

- HVAC modes should not show Cool;
- no AC-style fan controls should be presented;
- target temperature can extend higher than normal AC zones.

## Internal mapping

```text
set_hvac_mode(cool)
  -> SET_MODE_HVAC { MODE = "Cool" }

set_fan_mode(medium)
  -> SET_MODE_FAN { MODE = "Medium" }

set_temperature(22)
  -> SET_SETPOINT_SINGLE { CELSIUS = 22 }
```

If a command fails, capture a snapshot immediately after one C4Bridge command and one Control4-app command on the same thermostat.
