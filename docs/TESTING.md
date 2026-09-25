# C4Bridge Alpha Test

## Current release

`v0.1.0-alpha.6`

This build tests two things:

1. the log-verified dimmer command;
2. whether using the canonical package filename fixes live driver updates.

## A. Prepare the file correctly

Before opening Composer, make sure the downloaded file is named exactly:

```text
C4Bridge.c4z
```

If Windows downloaded `C4Bridge (1).c4z`, rename or remove the older copy first.

## B. Update without rebooting

1. In System Design, right-click the existing **C4Bridge** instance.
2. Choose **Update Driver**.
3. Select the correctly named `C4Bridge.c4z`.
4. Wait 10–15 seconds.
5. Re-select C4Bridge.

Record:

- Bridge Version
- Reload Counter
- Last Init Type
- Last Init Time
- Last Destroy Type
- Last Destroy Time

Expected hot-update result:

```text
Bridge Version: 0.1.0-alpha.6
Last Init Type: DIT_UPDATING
```

If the version does not change, do not wait two minutes. Capture the lifecycle fields, then reboot and compare them again.

## C. Dimmer test

Choose one visible dimmable light.

1. Confirm On/Off still works.
2. Set brightness to **30%**.
3. Confirm the physical level changes.
4. Wait for the PWA state confirmation.
5. Set brightness to **70%**.
6. Confirm again.

Alpha.6 sends:

```text
SET_BRIGHTNESS_TARGET
PERCENT = 30
```

or the requested value.

## D. Diagnostics

The authenticated API now exposes:

```text
GET /v1/diagnostics
```

Recent entries include:

- lifecycle init/destroy events;
- exact light command and parameters;
- watched state/brightness variable changes.

This allows targeted debugging without another full controller snapshot.
