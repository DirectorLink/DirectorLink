# Scenes

**Status: built in DirectorLink 0.13.0.** Schedules (0.14.0, `docs/SCHEDULES.md`) run them by
time, sun and weather.

A scene is one tap that sets several things: "all lights off, the bedroom AC to 24°, the
living-room blinds closed". Scenes belong to the home and are kept on the controller
(`src/core/scenes.lua`, persistent data that survives driver updates). They are DirectorLink's own:
Composer scenes and programming are never read or changed (docs/DECISIONS.md).

## Who does what

| Role | Scenes |
| --- | --- |
| viewer | sees them |
| member | also runs them |
| doors | also runs their doors and gates |
| admin | also makes, changes, tries and deletes them |

## A scene

- `name` (1–64 characters), `icon` (`moon`, `sun`, `leave`, `movie`, `bulb`, `climate`, `blinds`,
  `home`), `show_on_home` (a Run button at the top of Home), and up to 40 `steps`, run in order.
- A step sets devices of one `type`: `lights`, `climate`, `blinds` or `relays` (doors and gates).
  - With `device_ids`, those devices (`room_id` is then only the room they were picked in).
  - Without, every device of that type in `room_id`, or in the whole home when `room_id` is null.
    This is worked out each time the scene runs, so a light added to the room later is included.
- What a step sets:
  - lights: `{"on": true|false}` or `{"brightness": 0-100}`; on/off-only lights turn on.
  - climate: any of `mode` (`off`, `heat`, `cool`, `auto`), `target_temperature`, `fan_speed`
    (`low`, `medium`, `high`, `auto`, `on`, `circulate`), and since 1.1.0 `heat_setpoint` and
    `cool_setpoint` instead of `target_temperature` (5–40, cool above heat). With `mode: off`,
    nothing else. The temperature is kept within each thermostat's range; a fan speed a unit does
    not have is left out.
  - Thermostats with heat and cool setpoints (1.1.0) take `heat_setpoint` and `cool_setpoint` as
    their setpoints, and `target_temperature` as the setpoint of the step's mode (or of the current
    mode); in auto and off a target is left out. Setpoints that come closer than the thermostat's
    deadband are left out. Single-setpoint thermostats take `heat_setpoint` in heat and
    `cool_setpoint` in cool, and leave out any other setpoint.
  - blinds: `{"position": 0-100}` (0 closed, 100 open).
  - relays: `{"action": "pulse"}` — what the door's or gate's Open button does. A scene never
    holds a relay closed: on door strikes and gate inputs that would leave the door unlocked or
    the gate's button pressed.
- At most 50 scenes. `version` goes up with every change; sent back with a change
  (`PATCH /v1/scenes/{id}`), it makes the change conditional (409 `VERSION_CONFLICT`).

## Running

`POST /v1/scenes/{id}/run` sends the commands of each step, in order, through the same adapters as
the device routes, and answers `202` with what happened to each device:

- `ran`: commands handed to the controller (a device that ran with a setting it does not have left
  out, such as a fan speed, or a setpoint the thermostat refuses, is also listed in `problems` as
  `partial`, `NOT_SUPPORTED`);
- `skipped`: left alone, with the reason in `problems` — doors and gates for a key without door
  access (`FORBIDDEN`) or with Door Control off in Composer (`DOOR_CONTROL_DISABLED`), a mode a
  unit does not have (`MODE_NOT_SUPPORTED`), a device no longer in the project (`NOT_FOUND`), a
  thermostat left with nothing to do once its refused setpoints are left out;
- `failed`: refused by the controller.

A thermostat's temperature command is checked before the thermostat gets any command: a refused
one is left out (`partial`), and the rest of the step, such as its mode, still goes to it.

Steps without `device_ids` take the devices DirectorLink supports when the scene runs. So when an
update adds a device family (1.1.0: the older Light proxy and thermostats with heat and cool
setpoints), room and whole-home steps, and the schedules that run them, include those devices
from then on.

The rest of the scene still runs when a device is skipped or fails. Doors and gates opened by a
scene are logged like any other relay command, with the key that ran it. In the app, a scene that
opens doors or gates asks for a second tap, like their Open button.

Stored scenes are checked again when the driver starts: steps that are not valid are left out
(and logged). If the stored scenes cannot be read at start, changes are refused (503) until a
restart reads them, so they are never overwritten by an empty list.

`POST /v1/scenes/try` with `steps` runs them once without saving (admins): "Try it now".

## The app

- **Scenes** tab: every scene with a Run button (members and above); admins tap a name to change
  it, make a **New scene**, or start from an idea (All off, Good night, Good morning, Leaving home,
  Cool the house) that opens the editor filled in.
- The editor: the name and an icon; **What happens** (the actions, which can be moved and
  removed); **Add an action** — where (a room or the whole home), what (lights, AC, blinds, doors
  and gates, with how many there are) and what to do; **Choose** picks single devices ("only the
  reading lamp of the six"); **Copy the house as it is now** makes the actions from the current
  state of every light, AC and blind (doors and gates are never copied); **Show on Home**; **Try it
  now**; **Save scene**.
- Auto for thermostats with heat and cool setpoints (1.1.0) offers a Heat and a Cool stepper, kept
  at least the largest deadband of the chosen thermostats apart; copying the house keeps both
  setpoints of such a thermostat in auto.
- **Home** shows the scenes marked Show on Home, with one-tap Run, above the favorites.
- Saving leaves out devices and rooms that are no longer in the project, and says so.
