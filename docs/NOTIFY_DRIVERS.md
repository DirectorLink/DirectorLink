# Screen drivers for DirectorLink

> **DirectorLink is an independent project, not affiliated with Control4 or Snap One.**

DirectorLink raises alerts on the controller: a doorbell rang, a camera saw someone or heard a smoke
alarm, a door or gate was opened, the refrigerator's door was left open, a schedule had a problem.
Phones and computers get them through the family's DirectorLink accounts. A driver for a TV, or any
other screen, can show them too, as pop-ups. This page is the **DirectorLink notification agreement,
version 1**: what a Control4 driver does so that DirectorLink 1.13.0 and later tells it every alert
of the kinds it shows, without any code of its own for that driver. The **DirectorLink · LG TV
Notifications** driver for LG webOS TVs ([DirectorLink Drivers](https://directorlink.io/drivers)) is
built on it; any driver may follow it.

The agreement is two variables and one command, all by name. A driver that follows it works the same
without DirectorLink: nothing here depends on DirectorLink being in the project.

## The agreement, version 1

| What | The driver | DirectorLink |
| --- | --- | --- |
| **Marker** | A string variable `DIRECTORLINK_NOTIFY`, value `1` (the agreement's version), set at every start | Knows the driver is a screen |
| **Kinds** | A string variable `DIRECTORLINK_NOTIFY_KINDS`: the kinds it shows, comma separated, of `doorbell`, `camera`, `door`, `alarm` and `other`; set again whenever its Composer properties change | Tells it only those kinds |
| **A notification** | Takes the command `DIRECTORLINK_NOTIFY` (in `ExecuteCommand`) | Sends it once for each alert of those kinds: `C4:SendToDevice(<the driver's device id>, "DIRECTORLINK_NOTIFY", params)` |

1. **The marker and the kinds** are ordinary driver variables (`C4:AddVariable`), read by their names.
   Set them at every start, as early as you can (`OnDriverInit`). Kinds are read without case or
   spaces around; a name the agreement does not know is left out. No `DIRECTORLINK_NOTIFY_KINDS` at
   all means every kind; an empty one means none (the screen is listed, and told nothing).
2. **The command** comes to the driver that set the marker (its own device id, the one whose
   variables these are), never to a proxy. Answer it at once: DirectorLink never waits for it, and a
   driver that blocks holds up nothing of DirectorLink's but itself.
3. **One driver, one screen.** A driver for several TVs sets the marker on each TV's own driver.

### The command's parameters

Every value is a string.

| Parameter | Value |
| --- | --- |
| `VERSION` | `1` |
| `ID` | Unique to the alert (16 hex digits). Every screen gets the same `ID` for the same alert. Ignore an `ID` you got in the last 10 minutes. |
| `KIND` | `doorbell`, `camera`, `door`, `alarm` or `other` (below). |
| `TITLE` | Short: `Someone is at the door`, `Camera alert`, `DirectorLink`. |
| `MESSAGE` | The sentence: `Entrance rang at 21:14.` |
| `PICTURE` | Only for a doorbell and a camera's alert: an address on the controller that gives a JPEG for 60 seconds, `http://<the controller's address>:41999/v1/notify-pictures/<32 hex digits>.jpg`. Missing when there is no picture. |

`TITLE` and `MESSAGE` are final: show them as they are. They are in the language of the home's owner
(as the owner chose it in DirectorLink's app, Settings → Appearance and language: English, Hebrew,
Spanish or Italian; English while it is Auto), in the same words as on the family's phones. A time
in them is the controller's, 24-hour. Hebrew text begins with U+200F (RIGHT-TO-LEFT MARK), so that a
screen that takes the direction from the first letter lays it out right to left even when it starts
with a name in Latin letters.

### The kinds

| `KIND` | DirectorLink's alert | `TITLE` | `MESSAGE`, in English | `PICTURE` |
| --- | --- | --- | --- | --- |
| `doorbell` | A doorbell rang: a DoorBird, or a doorbell camera of the [camera agreement](CAMERA_DRIVERS.md) | Someone is at the door | Entrance rang at 21:14. | The doorbell's camera |
| `camera` | A camera's alert, by its label | Camera alert | Person at Porch at 21:14. | The camera |
| `alarm` | A smoke or CO alarm a camera heard | Camera alert | Smoke alarm at Garden at 21:14. | The camera |
| `door` | A door or gate opened (by a user, a scene, or in Control4), a relay held open, a refrigerator's door left open | DirectorLink | Main Gate was opened by Dana (iPhone) at 21:14. | None |
| `other` | A schedule had a problem | DirectorLink | Your home – the schedule for Morning blinds had a problem at 21:14. Open the app to see what happened. | None |

A camera's labels are the camera agreement's (Person, Vehicle, License plate, Smoke alarm, …); one
DirectorLink does not know is "Alert". The home's alarm system: DirectorLink only shows its status
(Alarm Status in Composer) and raises no alert for it, so it is no `alarm` here. Kinds may get more
alerts in later DirectorLink versions; a new kind would be a new version of the agreement.

### The picture

- **No key, no login.** The address's 128 random bits are its key. Only the screen's driver gets it,
  inside the controller.
- **For 60 seconds, three times.** Then, and for any other address, `404`. Fetch it as soon as the
  notification comes (or hand the address to the TV at once). Each screen gets an address of its own.
- **The camera's picture at that moment**, 640 pixels wide where the camera gives a small picture,
  fetched on the controller as DirectorLink's app gets it.
- **Plain HTTP on the home network**, at the controller's LAN address, port 41999: a TV could not
  check DirectorLink's certificate either way. Do not log the address, keep it, or pass it anywhere
  but the screen.

### Example

`driver.lua`:

```lua
local KINDS = { "doorbell", "camera", "door", "alarm", "other" }

-- The kinds the installer chose (the driver's own properties, e.g. "Show Doorbell" = Yes).
local function ShownKinds()
    local shown = {}
    for _, kind in ipairs(KINDS) do
        if Properties["Show " .. kind] == "Yes" then
            shown[#shown + 1] = kind
        end
    end
    return table.concat(shown, ",")
end

function OnDriverInit()
    C4:AddVariable("DIRECTORLINK_NOTIFY", "1", "STRING", true, false)
    C4:AddVariable("DIRECTORLINK_NOTIFY_KINDS", ShownKinds(), "STRING", true, false)
end

function OnPropertyChanged(name)
    if name:find("^Show ") then
        C4:SetVariable("DIRECTORLINK_NOTIFY_KINDS", ShownKinds())
    end
end

local seen = {} -- ID -> when, for 10 minutes

function ExecuteCommand(command, params)
    if command ~= "DIRECTORLINK_NOTIFY" or type(params) ~= "table" then
        return
    end
    local now = os.time()
    for id, at in pairs(seen) do
        if now - at > 600 then
            seen[id] = nil
        end
    end
    if params.ID == nil or seen[params.ID] then
        return
    end
    seen[params.ID] = now
    -- Show params.TITLE and params.MESSAGE (and params.PICTURE) later, never here: answer at once.
    C4:SetTimer(10, function()
        ShowPopUp(params.KIND, params.TITLE, params.MESSAGE, params.PICTURE)
    end)
end
```

## How DirectorLink uses it

- **Finding the screens.** Each time DirectorLink reads the project (when it starts, Refresh Project,
  Composer's changes), it reads the variables of every driver of the project by name, once each.
  It watches a screen's `DIRECTORLINK_NOTIFY` and `DIRECTORLINK_NOTIFY_KINDS`: new kinds count at once,
  and a marker that is no longer `1` stops the notifications at once, until it says `1` again. A
  marker set after DirectorLink read the project is found within minutes (it looks at ten drivers a
  minute); a screen whose marker is gone two looks in a row is forgotten.
- **Telling them.** Every alert, on the controller, the moment it happens: whether or not a phone
  switched alerts on, whatever the phones' own limits, and while the internet is down. At most one
  notification of a kind a screen in 5 seconds, but a doorbell's and an alarm's always. A screen that
  fails (its driver throws) stops nothing: not the other screens, not the phones' alerts.
- **Settings → Alerts → On TVs** in DirectorLink's app lists the screens for the home's admins: each
  one's name, room and the kinds it shows, and the language. The installer sets them up in Composer,
  in each screen's own driver; DirectorLink has no setting for them.
- **The log** has a line for each notification (`notification sent to a screen`, the screen's
  `driver_id` and the `kind`), never its words or its picture's address. The history has none: it would
  be every alert again.
- **Privacy.** All of it stays in the home: the cloud learns nothing of the screens or what they show.
  A screen shows the home's alerts to whoever is in front of it, whatever a user may see on a phone
  (doors opened and schedules are the admins' there): choose its kinds with that in mind.

## What a driver must not do

- **Block in `ExecuteCommand`**: no network calls or waits there. Answer at once, show later.
- **Show an `ID` twice** within 10 minutes.
- **Change `TITLE` or `MESSAGE`**: they are final, in the owner's language.
- **Keep, log or pass on `PICTURE`** beyond showing the picture.
- **Rename the variables or the command**, or use the `DIRECTORLINK_` variables for anything else.
- **Depend on DirectorLink.** The driver works on its own; DirectorLink only reads what it shows to
  every Control4 driver and sends it one command.

## Versions

| DirectorLink | Screen drivers |
| --- | --- |
| 1.13.0 and later | The agreement, version 1. A driver that says a later version (`2`, …) is read as version 1 (a later version only adds). |
| Before 1.13.0 | Nothing: a screen's driver gets no notification. |

## Trying a driver

- In Composer, the driver's **Variables** show `DIRECTORLINK_NOTIFY` and `DIRECTORLINK_NOTIFY_KINDS`.
- DirectorLink's log (in Composer, at the shipped **Log Level**, Info) says at each project read
  `a screen of DirectorLink's notification agreement` with its `driver_id` and `kinds`, and
  `screens of DirectorLink's notification agreement` with how many; then `notification sent to a
  screen` for each one (`notification not sent to a screen` with why: `too soon`, or the error the
  driver threw). Refresh Project reads the screens again at once.
- Without a controller: `python scripts/dev_server.py --agreement-cameras --notify-targets` runs
  DirectorLink against a fake Director with two made-up screens, 301 "Living Room TV" (every kind) and
  302 "Kitchen TV" (doorbell and alarm). Type `ring 158` (a doorbell camera rings) or
  `alert 157 Person` (a camera's alert): the console prints what each screen got, and the picture's
  address works in a browser for 60 seconds. `var 301 1003 doorbell` changes what the Living Room TV
  shows, as its properties would.

The decision and its details are ADR-086 in [`DECISIONS.md`](DECISIONS.md).
