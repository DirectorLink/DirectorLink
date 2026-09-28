# Scenes

**Status: built in DirectorLink 0.13.0.** Schedules (0.14.0) will run these scenes by time and
by weather.

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
    (`low`, `medium`, `high`, `auto`). With `mode: off`, nothing else. The temperature is kept
    within each thermostat's range; a fan speed a unit does not have is left out.
  - blinds: `{"position": 0-100}` (0 closed, 100 open).
  - relays: `{"state": "open"|"closed"}`.
- At most 50 scenes. `version` goes up with every change; sent back with a change
  (`PATCH /v1/scenes/{id}`), it makes the change conditional (409 `VERSION_CONFLICT`).

## Running

`POST /v1/scenes/{id}/run` sends the commands of each step, in order, through the same adapters as
the device routes, and answers `202` with what happened to each device:

- `ran`: commands handed to the controller;
- `skipped`: left alone, with the reason in `problems` — doors and gates for a key without door
  access (`FORBIDDEN`) or with Door Control off in Composer (`DOOR_CONTROL_DISABLED`), a mode a
  unit does not have (`MODE_NOT_SUPPORTED`), a device no longer in the project (`NOT_FOUND`);
- `failed`: refused by the controller.

The rest of the scene still runs when a device is skipped or fails. Doors and gates opened by a
scene are logged like any other relay command, with the key that ran it.

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
- **Home** shows the scenes marked Show on Home, with one-tap Run, above the favorites.
