# Alarm drivers for DirectorLink

> **DirectorLink is an independent project, not affiliated with Control4 or Snap One.**

DirectorLink shows the home's alarm in its app (with the Composer property **Alarm Status** On), and
from 1.15.0 arms and disarms it (with **Alarm Control** On too): admins, and the members an admin
allows, type their alarm code for each command, at home or away (ADR-091). It does this through
Control4's standard security partition proxy (`security.c4i`), the way a Control4 screen does, so
**any Control4 alarm driver works without anything of its own for DirectorLink.**

This page is the **DirectorLink alarm agreement, version 1**: what an alarm driver may add so that
DirectorLink knows when arming and disarming can work, and what DirectorLink sends and promises.
[DirectorLink · PIMA FORCE](https://directorlink.io/drivers/pima-force), for PIMA FORCE panels,
follows it. A driver that follows it works the same without DirectorLink.

## What DirectorLink reads

From the partition's proxy, as every Control4 app does: its variables (1000 to 1012: armed home or
away, disarmed, alarm and its type, open zones, the delay, trouble, `IS_ACTIVE`; ADR-038).

From the protocol driver behind the partition:

- **The modes it arms in:** `<arm_states>` in the `<capabilities>` of its `driver.xml`, as for
  Control4's own screens, for example `<arm_states>Away,Home,Night</arm_states>`. DirectorLink offers
  those modes, in that order (at most 8, each at most 32 bytes), and sends the word as written. A
  driver that declares none is only disarmed from DirectorLink.
- **The agreement's variables** (optional), by name, with `C4:GetDeviceVariables`, read again at
  most every 5 seconds while the app shows the alarm:

| Variable | Type | Value |
| --- | --- | --- |
| `DIRECTORLINK_ALARM` | STRING | `1`: the agreement's version. Set at every start. A higher whole number is read as version 1; anything else is no marker. |
| `DIRECTORLINK_ALARM_CONTROL` | STRING | `1` while arming and disarming can work now; `0` while they cannot (a panel that only reports, a panel not connected). Changed as it changes. |

Without `DIRECTORLINK_ALARM`, DirectorLink takes the driver as able to arm and disarm: what a command
did shows in the partition's state. With it and `DIRECTORLINK_ALARM_CONTROL` not `1`, the app shows
no Arm or Disarm for its partitions, only a line that it cannot now, and the API answers 409
`ALARM_UNAVAILABLE` without sending anything.

## What DirectorLink sends

Only these two commands, to the partition's proxy (`C4:SendToDevice(<partition>, ...)`), which hands
them to the protocol driver as a Control4 screen's (`ReceivedFromProxy`):

| Command | Parameters |
| --- | --- |
| `PARTITION_ARM` | `ArmType` (one of the driver's `<arm_states>`, as written), `UserCode` (the code the person typed), `InterfaceID` = `DirectorLink` |
| `PARTITION_DISARM` | `UserCode`, `InterfaceID` = `DirectorLink` |

Each comes from one person's command in the app, with the code they typed for it, in a request
sealed end to end. DirectorLink never sends `ARM_CANCEL`, `EXECUTE_EMERGENCY`, `EXECUTE_FUNCTION`,
`KEY_PRESS`, `ADDITIONAL_INFO`, `SEND_CONFIRMATION` or a default user code, never Composer's
programming InterfaceID (`DirectorProgramming`), and never arms or disarms from a scene, a schedule,
a link or by itself. It never keeps or logs the code, and sends the commands with `LogCommand`
false. That only drops Director's ordinary line for them: Director, logging at its debug level,
still writes each command it passes between drivers into its own log, the code with it (a root-only
file in the controller's memory, gone within about 2 to 3 hours and at a restart). At most 6
commands a person in 5 minutes and 20 in the home in an hour.

DirectorLink does not wait for an answer: the app reads the partition's state again and tells the
person whether it changed. A driver's `ARM_FAILED` and `DISARM_FAILED` notifications go to Control4's
screens as always.

## What a driver of the agreement must do

- **Send the typed code to the panel as typed,** and let the panel check it. Never carry out a command
  with `InterfaceID` `DirectorLink` with a code of the driver's own (a stored master code, a default
  code), also when the code is empty: refuse it.
- **Never log the code**, typed or stored, at any debug level.
- **Keep `DIRECTORLINK_ALARM_CONTROL` true to what a command would do:** `1` only while an arm or
  disarm can reach the panel.
- Keep its variables' names and order across versions: dealers' projects and DirectorLink read them.

## Versions

| DirectorLink | |
| --- | --- |
| 1.2.0 to 1.14.x | Reads the partitions' state only. The agreement's variables are not read. |
| 1.15.0 and later | Arms and disarms; reads `<arm_states>` and the agreement, version 1. |

## Trying a driver

The dev server (`python scripts/dev_server.py`) has a fake alarm whose panel takes the code `1234`;
type `control off` or `control on` to switch Alarm Control. On a real controller: set Alarm Status
and Alarm Control On in DirectorLink's Composer properties, give yourself (an admin) or a member the
permission in Settings → Users (*Arms and disarms the alarm*), and arm and disarm from the alarm's card on Home. DirectorLink's
log never names the code; the history (Settings → Controller → History) lists each command.
