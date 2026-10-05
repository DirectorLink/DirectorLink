# Camera drivers for DirectorLink

> **DirectorLink is an independent project, not affiliated with Control4 or Snap One.**

DirectorLink shows every camera of a Control4 project in its app, through Control4's camera proxy.
A camera driver can give DirectorLink more: its detections as alerts on the family's phones ("Person
at Garden at 21:14"), and, for a doorbell, its rings, with Home's banner and the ring alert. This
page is the **DirectorLink camera agreement, version 1**: what a Control4 camera driver does so that
DirectorLink 1.10.0 and later takes it without any code of its own for that driver. The free
[DirectorLink Drivers](https://directorlink.io/drivers) follow it; any driver may.

The agreement is a few variables and two events, all by name. A driver that follows it works the
same without DirectorLink: nothing here depends on DirectorLink being in the project.

## The agreement, version 1

| What | The driver | DirectorLink |
| --- | --- | --- |
| **Marker** | A string variable `DIRECTORLINK_CAMERA`, value `1` (the agreement's version) | Knows the camera's driver follows the agreement |
| **Kind** | A string variable `DIRECTORLINK_CAMERA_KIND`, value `camera` or `doorbell` | A `doorbell` is listed with the doorbells too |
| **An alert** | Sets the string variable `LAST_ALERT` to the label (below), then fires the event named exactly `Alert` | Sends the camera alert |
| **A ring** (a doorbell) | Sets the string variable `LAST_RING` to the time, ISO 8601 in UTC (`2026-10-05T18:14:03Z`), then fires the event named exactly `Ring` | A ring: Home's banner, the ring alert |
| **Pictures and live video** | Through its camera proxy, as every Control4 camera driver | Reads the address, the login and the snapshot path from the proxy |

1. **One camera a driver.** The driver has one camera proxy (`camera`). DirectorLink does not watch
   a driver with several camera proxies (an NVR's channels): give each camera its own driver, as the
   DirectorLink · Hikvision Camera driver does.
2. **The marker and the kind** are ordinary driver variables (`C4:AddVariable`), read by their names.
   Add them as early as you can (in `OnDriverInit`). A driver that knows its kind only later (once
   it reaches the camera and learns its model) may add the marker or change the kind then:
   DirectorLink looks again every few minutes. Set the kind before the first ring.
3. **The events** `Alert` and `Ring` are declared in the driver's `driver.xml` (`<events>`), with these
   names exactly. Their ids are yours: DirectorLink finds them by name in `driver.xml`, as Director
   gives it, so do not add them at run time with `C4:AddEvent`. A doorbell has both, a camera only
   `Alert`.
4. **Set the variable first, then fire the event.** DirectorLink reads `LAST_ALERT` or `LAST_RING` when
   the event comes.
5. **Pictures** come through Control4's camera proxy, as for every camera: DirectorLink asks the
   proxy for the camera's address, ports, login and snapshot path (`GET_PROPERTIES`,
   `GET_SNAPSHOT_QUERY_STRING`), and fetches pictures 320, 640, 1280 or 1920 pixels wide, several
   cameras at once and one camera at most two at a time. Answer small sizes with a small picture
   (a camera's sub stream) where the camera has one.

### Example

`driver.xml`:

```xml
<proxies>
    <proxy proxybindingid="5001" name="Camera" primary="True">camera</proxy>
</proxies>
<events>
    <event><id>1</id><name>Alert</name><description>When NAME raises an alert</description></event>
    <event><id>2</id><name>Ring</name><description>When someone rings at NAME</description></event>
</events>
```

`driver.lua`:

```lua
function OnDriverInit()
    C4:AddVariable("DIRECTORLINK_CAMERA", "1", "STRING", true, false)
    C4:AddVariable("DIRECTORLINK_CAMERA_KIND", "doorbell", "STRING", true, false) -- or "camera"
    C4:AddVariable("LAST_ALERT", "", "STRING", true, false)
    C4:AddVariable("LAST_RING", "", "STRING", true, false)
end

-- A detection the driver's own settings say is worth an alert: once per alert.
local function RaiseAlert(label) -- "Person", "Vehicle", "Package", ...
    C4:SetVariable("LAST_ALERT", label)
    C4:FireEvent("Alert")
end

-- Someone pressed the doorbell's button.
local function Ring()
    C4:SetVariable("LAST_RING", os.date("!%Y-%m-%dT%H:%M:%SZ"))
    C4:FireEvent("Ring")
end
```

### The labels

`LAST_ALERT` is one of these labels. Case, spaces, `_` and `-` do not matter (`License Plate`,
`license_plate`). The app says each in English and Hebrew; any other label is said as "Alert".

| Label | The app says |
| --- | --- |
| `Person` | Person |
| `Vehicle` | Vehicle |
| `Animal` | Animal |
| `Package` | Package |
| `Face` | Face |
| `License Plate` | License plate |
| `Line Crossing` | Line crossed |
| `Intrusion` | Intrusion |
| `Motion` | Motion |
| `Region Entrance`, `Region Exiting` | Someone entering, Someone leaving |
| `Tamper`, `Scene Change` | Tampering, View changed |
| `Object Left`, `Object Removed` | Object left behind, Object removed |
| `Alarm Input`, `PIR` | Alarm input, Motion (PIR) |

## How DirectorLink uses it

- **Recognizing the driver.** When it reads the project, DirectorLink reads the variables of each
  camera proxy's driver by name. A marker that comes later, or a kind that changes, is seen within a
  few minutes (DirectorLink looks at five cameras a minute); a driver updated in Composer (a new
  `<version>`) is read again within minutes, its events too. Refresh Project reads everything again
  at once.
- **Alerts.** "Person at Garden at 21:14", on the phones and computers that switched on camera alerts
  (off until chosen) and whose user may see that camera's pictures. At most one alert a camera a
  minute, and 30 camera alerts an hour in the home, so that rings always get through. The driver
  decides what is worth an alert (its own settings, schedules and snooze): DirectorLink passes on its
  `Alert`, not every detection.
- **Doorbells.** A `doorbell` is listed with the doorbells as well as with the cameras, under the
  camera's own id, with its own picture: Home shows "Someone is at the door" with its live picture
  for two minutes after a ring, its room shows when it rang last and its last 20 rings, and everyone
  who sees the doorbell gets the ring alert (members too, in their rooms; the picture only for those
  who see cameras). At most one ring alert a doorbell in 30 seconds. The ring's time is `LAST_RING`
  when it is within two minutes of the controller's clock, else the moment the event came; after
  DirectorLink restarts, its last ring is `LAST_RING`. A doorbell camera opens nothing: a gate or door
  at the doorbell is its own Control4 device (a relay).
- **Privacy.** Names, rooms and what a camera saw stay on the controller: an alert is sealed on the
  controller for each phone, and DirectorLink's servers only pass it on (see
  [`ACCOUNTS.md`](ACCOUNTS.md)). Pictures go from the camera to the controller and, sealed, to the app.

## What a driver must not do

- **Alert on every motion.** Fire `Alert` once per alert, not again while it lasts, and only for what
  the user asked for: the home's alerts are limited, and a busy camera crowds out the others.
- **Fire `Ring` for anything but a press** of a doorbell's button, or from a driver whose kind is
  `camera`.
- **Put names, addresses or other personal data in `LAST_ALERT`.** It is a label from the list.
- **Write `LAST_RING` in local time** or without its zone: UTC, ending in `Z`.
- **Rename or renumber `Alert` and `Ring` without a new driver version.** DirectorLink reads the
  events again when Composer updates the driver to a new `<version>`.
- **Use the `DIRECTORLINK_` variables for anything else**, or set the marker on a driver with more
  than one camera.
- **Depend on DirectorLink.** The driver works on its own; DirectorLink only reads what it shows to
  every Control4 driver.

## Versions

| DirectorLink | Camera drivers |
| --- | --- |
| 1.10.0 and later | The agreement, version 1. A driver that says a later version is read as version 1 (a later version only adds). |
| 1.8.0 to 1.9.x | Only the DirectorLink · Hikvision Camera driver, by its file name (`DirectorLink-Hikvision-Camera.c4z`), its event 1 and `LAST_ALERT`. Other cameras: pictures only; a doorbell camera is a camera. |

DirectorLink 1.10.0 still knows the DirectorLink · Hikvision Camera driver by its file name while it
does not set the marker; once it does, by the marker only, never twice.

## Trying a driver

- In Composer, the driver's **Variables** show the marker, the kind, `LAST_ALERT` and `LAST_RING`.
- With DirectorLink's **Log Level** at Debug, its log says for each camera of the agreement which
  `Alert` and `Ring` it found (`a camera of DirectorLink's camera agreement`), and warns when Director
  names neither (`whose Alert event Director does not name`).
- Without a controller: `python scripts/dev_server.py --agreement-cameras` runs DirectorLink against
  a fake Director with two made-up drivers of the agreement, a camera (driver 157) and a doorbell
  (driver 158); type `alert 157 Animal` or `ring 158`.

The decision and its details are ADR-065 in [`DECISIONS.md`](DECISIONS.md).
