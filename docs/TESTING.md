# DirectorLink Test Plan

## Current release

`v1.1.0` — older Control4 lights, floor heating set through its heat setpoint, and Control4 thermostats with heat and cool setpoints (thanks to bkwagner, #14, #19, #16, ADR-033); the relay's certificate is checked (ADR-034); shades, Composer changes without a restart and the room order (0r); admins see new versions in the app (0q, ADR-035). Update DirectorLink in Composer (no reboot).

## 0r. Room order, Composer changes and shades (1.1.0)

Room order (broken since 1.0.0):

1. In the app at home, Settings → Rooms: move a room up, then down. The order changes, stays after reloading the app, and no *Remote requests are GET, POST, PATCH or DELETE* message appears. The same away from home (a phone on mobile data, with remote access).

Composer changes, with **Log Level** Debug:

2. After the update, `GET /v1/logs?category=discovery` shows *watching the project for Composer changes* with the events. If it shows *Director does not announce Composer changes to DirectorLink* instead, steps 3–4 need the action Refresh Project.
3. In Composer, move a shade (or a light) to another room. About 5 seconds later the log shows *project event* lines and then *project rediscovered* with `moved` 1; the app shows the device in its new room at its next refresh. Keep the *project event* lines: what Director sends with `OnItemMoved` is not documented. Rename a device, add one and remove one: `renamed`, `added` and `removed`, and **Inventory** follows.
4. Actions → **Refresh Project**: *project rediscovered* with `reason` *Composer action*. Composer's **Refresh Navigators** does the same (`OnPIP`); pressed again within two minutes, it is read once more at the end of the two minutes. Status stays `Ready` throughout, and the adapters' per-device lines of a refresh (*initialized thermostat* and the like) are at debug level; *initialized N controllable proxies* stays at info.
5. After a refresh, a door relay's last state and a doorbell's last ring are as before; a scene with a removed device runs the others and reports the removed one as skipped.

Shades (KNX blinds on the blind proxy), with **Log Level** Debug and the driver reloaded:

6. `GET /v1/logs?category=blind&level=debug`: *proxy setup* for every shade, with the raw `GET_SETUP` answer (`<blind_setup>…`), and *proxy variables* with their values (`1002=Stopped:…`, `1004=Level:…`, `1005=Target Level:…`, `1007=Movement:…`, `1008=Opening:…`, `1009=Closing:…`). Keep both: the values of Stopped, Opening and Closing had not been seen before. Movement is the kind of movement (such as *Up to Down*), not whether the shade moves: at rest every shade has `"moving": false` in `GET /v1/blinds`, and the app reads the blinds every 10 seconds, not every 2.
7. `GET /v1/blinds`: a shade with a Percent Set Address has `"capabilities": {"position": true, …}`, one without has `"position": false` (as its setup's `level_discrete_control`). In the app the second has no slider, and a shade with `"stop": false` has no Stop.
8. Set a shade with a percent address to 50%: the line under its name reads *Opening… to 50%* (or *Closing… to 50%*) and the slider stays at 50 until the shade stops, then shows the position it reports (the actuator's own report comes about a second after the stop; the app reads a few seconds more for it). While it moves, `GET /v1/blinds/{id}` has `"moving": true`, `direction` and `target_position`, and the log has *movement changed* lines with the raw values of Stopped, Opening and Closing. Move the slider again while it moves: it stays where it was put. Open fully and press Stop halfway: the app shows it stopped at once (not *Opening…*), then where it stopped.
9. On a shade without position control, `PATCH {"position": 50}` answers `409 POSITION_NOT_SUPPORTED` and nothing moves; Open and Close work. A shade whose level is unknown (`-155` or `-255` in the log) shows *Position unknown*.
10. Move a shade from a keypad or the Control4 app: the DirectorLink app shows the movement within about 10 seconds.

## 0q. Update notice (1.1.0)

While the controller still runs a DirectorLink older than the latest release on GitHub (1.0.0, once 1.1.0 is published), before updating it. The app asks GitHub at most every 12 hours: if it asked just before the release was published, remove `directorlink.update` from the site's local storage (developer tools → Application) and reload.

1. With an admin key, Settings → Controller shows **Updates**: *DirectorLink 1.1.0 is available* with the release date, **Download DirectorLink.c4z** (the file of that release), **What's new** (the release page, in a new tab) and the steps in Composer.
2. Home shows *DirectorLink 1.1.0 is available. How to update*; the link opens Settings at the steps. ✕ hides the notice, also after a reload; Settings still shows the update.
3. With a member key (another browser), neither Home nor Settings mention updates, and developer tools → Network shows no request to `api.github.com`. On the admin's browser a reload does not ask again within 12 hours.
4. Update the driver with the downloaded file as the steps say, with the app left open on Settings: within a minute, without a reload, Settings → Controller shows version 1.1.0 and *Up to date*, Home shows no notice, and Network shows no new request to `api.github.com`.
5. In developer tools → Application → Local storage, lower `answeredAt` in `directorlink.update` by 300000000 (milliseconds, about 3½ days) and reload: **Updates** says *Could not check for updates (last checked …)* with that day. Remove `directorlink.update` and reload: *Up to date* again.

## 0p. Legacy lights and more thermostats (1.1.0)

On the test system, which has none of the new devices, this is a regression check:

1. Before updating, `GET /v1/thermostats`: note any floor-heating zone whose `target_temperature` is `-18`.
2. After updating, **Inventory** still shows 111 lights and 22 thermostats. More would mean the project has older lights or Control4 thermostats that now join room and whole-home scenes.
3. All 22 thermostats show `"setpoints": "single"`, with `heat_setpoint`, `cool_setpoint` and `setpoint_deadband` `null`, and the same targets, modes and ranges as before. A zone noted in step 1 now shows its real target, 5 °C minimum.
4. Section 4 passes unchanged: an AC zone Off → Cool, 22 °C, fan Low → Medium, and a floor-heating zone without Cool or fan.
5. `GET /v1/logs?category=climate`: each zone's *initialized thermostat* line has the fields of 1.0.0 and no `setpoint_source`, except a zone noted in step 1, whose line adds `setpoint_source` `heat` and the values 1149, 1150 and 1133 read.
6. With **Remote Access** on, **Remote Status** reaches `Connected` again after the update, and the app works away from home. This shows that the relay's certificate passes, not that Director checks it (1.0.0 connected with no check at all); step 7 shows that. If it keeps showing `Reconnecting in N s (connection lost)` or `Reconnecting in N s (no connection within 30 s)` instead, the check may have failed: save `GET /v1/logs?category=relay` and the DirectorLink lines of the Director driver log, and go back to 1.0.0.

The certificate check, once on the test system: a package that trusts only a root the relay's chain does not end at must never connect.

7. Build the test package from the release's commit: `python scripts/build.py --roots-only "ISRG Root X1"` writes `dist/DirectorLink-wrong-roots.c4z`, whose `certs/directorlink-roots.pem` holds only ISRG Root X1 (today's chain is WE1 → GTS Root R4; if a browser shows the certificate of `api.directorlink.io` issued by Let's Encrypt instead, build with `--roots-only "GTS Root R4"`). Copy it to an empty folder as `DirectorLink.c4z` and update DirectorLink with it in Composer (**Driver → Add or Update Driver**). With Remote Access on, Remote Status must never reach `Connected`: watch it for 3 minutes, and again after a reboot of the controller (an update in place might keep the connection's earlier settings). Note which it shows, `connection lost` or `no connection within 30 s`, and save `GET /v1/logs?category=relay` and the lines about the relay connection in `/var/log/debug/director.log` and `/var/log/debug/driver_log.log`: they should show the TLS failure (note its exact words, which Control4 does not document). If it connects, Director did not check the certificate against the package's CA file: stop, and report it.
8. Update DirectorLink again with the release's own `DirectorLink.c4z`: Remote Status reaches `Connected` again and the app works away from home. Record steps 7 and 8 in docs/VALIDATION.md. Whether Director also checks the name on the certificate is not tested here (release notes, *Known issues*).

On a Director with these devices (the contributor, @bkwagner, read them on a live Director; ask before running these steps on someone's installation). Set **Log Level** to Debug in Composer **before** updating: the start-up lines below are written only when the driver loads, and setting Debug later does not bring them back. Right after the update, before using the app, save `GET /v1/logs?level=debug` (it keeps the last 500 entries, and at Debug every request adds one) or the DirectorLink lines of the Director driver log:

9. **Older lights (`light.c4i`):** a dimmer on, off and 40%, and a switch on and off, each confirmed in the app without *waiting for the device to confirm*. `GET /v1/logs?category=light_command` shows `ON`, `OFF` and `SET_LEVEL` with `LEVEL` 40. Keep the `light_state` start-up lines (variable names, protocol drivers).
10. **Floor heating on its heat setpoint:** the zone shows its real target and − goes down to 5°. Set 21°: the device's heat setpoint changes, the log shows `SET_SETPOINT_HEAT` with `FAHRENHEIT` 70 (in a °F project) and `setpoint_source` `heat`. Keep the start-up values of 1100, 1104, 1105, 1120, 1132, 1133, 1149 and 1150.
11. **Each thermostat with heat and cool setpoints:** `GET` shows `"setpoints": "dual"`, both setpoints, the deadband, the modes and fan speeds. In Heat the stepper moves the heat setpoint, in Cool the cool setpoint, in Auto both are shown and Home shows the range (such as *Auto 20°–24°*); raising heat into the deadband moves cool, and the device ends with both values. The mode chips Off, Heat, Cool and Auto work, and a scene *Auto 20°–24°* runs. Set the fan to **On** and, where listed, **Circulate**: each is confirmed in the app, and the log shows `SET_MODE_FAN` with the thermostat's own spelling. Run a scene with a *Cool 24°* action on them (a mode and one target temperature, as scenes made before 1.1.0 have and as the editor makes for Cool): the thermostat goes to Cool with its cool setpoint at 24° (75 °F in a °F project), and the run reports no problem. Keep the Debug list of 1100–1150, and note whether the thermostat moves the other setpoint by itself.
12. Save `GET /v1/lights`, `GET /v1/thermostats` and a scene run's result, and validate them against `api/openapi.yaml`.

`v1.0.0` — the app's key stays off the home network (sealed requests, pairing with a key exchange) and the security review's fixes (issue #43, ADR-032). Update DirectorLink in Composer (no reboot).

## 0o. Security (1.0.0)

1. An app already paired keeps working at home after the update, without pairing again. In the browser's developer tools (Network), requests to the controller are `POST /v1/sealed` and carry no `Authorization` header; the answers are envelopes.
2. **New Pairing Code** in Composer, pair a second computer: the pairing answer holds `exchange` and `sealed`, not `key`. The new device works.
3. Type a wrong code five times from one computer: that computer is locked for a minute (*Too many wrong codes …*); another computer can still pair meanwhile.
4. `curl -H "Host: example.com" http://<controller-ip>:41999/v1/health` answers `421`; with the IP address as the host it answers `200`. A page served from `http://localhost` cannot reach the controller (a CORS error).
5. With a viewer key, `GET /v1/system` has `latitude` and `longitude` `null`; with an admin key they are rounded to two decimals.
6. With remote access: invite someone by email; the invitation is created (the controller registered it; `GET /v1/logs?category=remote` shows no *invitation not registered*) and they can join with it. With the controller's internet unplugged (Remote Status not connected), inviting fails within about 10 seconds and no invitation is left behind.
7. As the home's owner, at home: Settings → Account → **Replace the remote secret**: *Done*; Remote Status shows a reconnect within a minute (the Lua log says *home secret replaced*); the app away from home (a phone on mobile data) still works. From an admin who is not the owner: *Only the home's owner can replace its secret*.
8. Settings → Account → **Sign out everywhere** on one device: *Signed out on every device*; the other signed-in devices need to sign in again for remote use; at home they keep working.
9. (Only on a test project.) Actions → **Reset Remote Identity**: Remote Status connects with a new home id; the home must be linked again from Settings → Account.

`v0.15.0` — DirectorLink's automation is visible to the installer in Composer. Update DirectorLink in Composer (no reboot).

## 0n. Schedules and scenes in Composer

1. The DirectorLink device's properties now include **Schedules** (`On`), **Schedule Status** (e.g. `2 on · next tomorrow 06:45 Good morning`) and **Last Automation**.
2. Run a scene from the app: Last Automation shows its name, *run from* the device's name, and how many devices.
3. When a schedule runs, Last Automation says which schedule (or, for a weather rule, the reading, e.g. *heat rule, 31C outside*).
4. Actions → **Print Schedules and Scenes**: the Lua output lists every schedule and scene with its steps.
5. Set **Schedules** to `Paused`: Schedule Status says *Paused in Composer*, the app's Schedules page says the installer paused them, and a schedule due now does not run. Set it back to `On`.

`v0.14.0` — schedules: scenes run by themselves at a time, at sunrise or sunset, or when it gets hot, windy or rainy (weather from Open-Meteo). Update DirectorLink in Composer (no reboot).

## 0m. Schedules and the weather

1. Scenes → **Schedules**: the weather card shows the temperature, wind and today's forecast, sunrise and sunset. (If it asks for the location, set latitude and longitude in Composer's project properties.)
2. **New schedule** → a scene → At a time, two minutes from now → today's day → Save: the row says *Next: today …*; at that minute the scene runs, and the row says *Ran today …*. `GET /v1/logs?category=schedules` shows it.
3. Switch a schedule off from the list: it no longer runs.
4. Sun: sunset, 30 min before, every day: *Next* shows today's or tomorrow's time.
5. Weather → Heat, a threshold 1° below the temperature now → Save: within 15 minutes it runs once, and not again until it has cooled 2° below.
6. Only if → *It isn’t raining* on a time schedule, with *Skip* for no weather data; unplug the controller's internet: at its time it does not run and says *no weather data*.
7. A scene with a gate, run by a schedule: the gate is skipped (never opened by a schedule).
8. Deleting a scene that a schedule runs is refused, with a message.
9. Update the driver again in Composer: the schedules are still there and nothing runs twice.

`v0.13.0` — scenes: one tap sets lights, AC, blinds and gates; made in the app by admins, run by everyone with member access. Update DirectorLink in Composer (no reboot).

## 0l. Scenes

1. As an admin: **Scenes** tab → **Good night** under *Start from an idea*: the editor opens with all lights off and all blinds closed.
2. **Add an action** → Living room → Lights → **Choose** → only one lamp → Dim to 15% → **Add to scene**. Add the bedroom AC: Cool, 24°.
3. Turn on **Show on Home**, **Try it now** (the house changes, nothing is saved), then **Save scene**.
4. On Home, tap the scene: it says *Done*, and the lights, AC and blinds follow. On a phone with a member key, the same; with a view-only key the scene is listed but has no Run.
5. Add the gate (Doors & gates: *Open (short press)*) and run it from a member key: *doors and gates were skipped*. From an admin key with Door Control on, Run asks for a second tap, then the gate opens exactly like its Open button (the relay closes and releases).
6. Set the house by hand, open the scene → **Copy the house as it is now** → Save: running it later puts the house back like that.
7. Update the driver again in Composer: the scenes are still there.

`v0.12.0` — profiles: your language, theme, favorites and hidden rooms follow you to all your devices; one room order for the home. Update DirectorLink in Composer (no reboot).

## 0k. Profiles and rooms

1. On the PC (paired before the update): the app keeps its language, theme and favorites; `GET /v1/profile` now shows them.
2. Settings → Rooms: untick a room: it disappears from Home and Climate on this device, and on your other devices of the same person within a minute; other people still see it.
3. As an admin, move a room up with the arrow: the new order shows on every device.
4. **Add my other device** and accept it on the iPhone: the iPhone opens in your language and theme, with your favorites and hidden rooms.
5. People and devices: two devices of one person paired separately show as two persons; set one's Person to the other, then Rename the person: both now share the same preferences.

`v0.11.1` — air conditioning: the full 16–32 °C range, and − / + right after a fan or mode change send the temperature chosen. On an AC that is off at 32 °C, change the fan and tap − at once: the target becomes 31 °C, with no error.

`v0.11.0` — People and devices: who has access, from the app; revoking a device's key also ends its account's membership. Update DirectorLink in Composer (no reboot).

## 0j. People and devices

1. On the computer at home (admin key): Settings → Controller → **People and devices**. Devices lists every key, with *This device* for the computer (no Revoke, role fixed) and when each was last used; People lists your account as *Owner* with your devices, and anyone who joined with theirs; Invitations lists the ones waiting.
2. Change the role of the iPhone's key to *Member*: the iPhone can still switch lights, and Door Control gates are refused. Set it back to *Admin*.
3. **Add my other device** makes an invitation that appears under Invitations; **Revoke** it: its link answers "used, revoked or has expired".
4. Invite a second Google account, accept it on another device, then **Remove** that person: their device shows "Your home does not know this device’s key" (or the account message), and they are gone from People.
5. Revoke a device's key in the API console instead: within seconds that account also disappears from People (the controller told the cloud), unless it has another device.

`v0.10.0` — remote access with your account, locked end to end, on iPhone too. Update DirectorLink in Composer (no reboot) and set Remote Access to On.

## 0i. Remote access with an account

1. After the update, DirectorLink's log (`GET /v1/logs?category=remote`) shows `lock self-test passed`, and `GET /v1/remote` answers `enabled: true`, `connected: true`, `lock: true` and the home id.
2. On a computer at home (already paired): Settings → Account → **Sign in with Google**, then **Link this home to my account**. The card says the home is linked.
3. **Add my other device**: a QR code and a link appear, valid for 10 minutes. Scan the code with the iPhone camera and open it; the address bar shows only `#/join`. Sign in with the same Google account and **Accept invitation**.
4. The iPhone opens Home with **Connected · via account**; lights, climate and blinds work, and a light switched on the iPhone switches in the Control4 app.
5. On the computer, switch Wi-Fi off and use a phone hotspot: within a few seconds the chip says **Connected · via account**; back on the home Wi-Fi it returns to **Connected** within a minute.
6. **Invite someone** with another Google account's email and the `viewer` role; open the link in a private window signed in as that account: it can read but not switch lights (403 FORBIDDEN in the log). Opened with a third account, the link answers "for another email address".
7. In the log, remote requests appear with `client` = `relay` and the device's key id; the cloud's own logs show only home ids, key ids, sizes and codes.

## 0h. Staying paired through updates

1. After updating to 0.9.2, pair the app once more if it asks (**New Pairing Code**): 0.9.1 and older could not read their saved keys back after a reload.
2. Update DirectorLink again with the same file: the app stays connected without pairing, **API Keys** keeps its count, **Pairing Code** stays `-`, and `GET /v1/logs?category=auth` shows `keys loaded` with `"stored_as":"json"`.
3. Room names set in the app are still there after the update.
4. With **Remote Access** on, **Remote Status** shows the same home id before and after the update.

## 0g. DoorBird

1. **Inventory** ends with `1 doorbells`; `GET /v1/doorbells` lists the DoorBird with its camera (`/v1/cameras/{id}/snapshot` shows the gate).
2. Ring the DoorBird: within 10 s `last_ring_at` is set, `events[0].type` is `doorbell`, and the app shows the banner with the camera.
3. Walk past it: `last_motion_at` updates (`motion` events).
4. With Door Control enabled and a `doors` or `admin` key, **Open gate** in the app (or `POST /v1/doorbells/{id}/open`) opens the entrance gate like the DoorBird button in the Control4 app; `last_opened_at` follows.
5. With a `member` key, opening answers `403 FORBIDDEN`; with Door Control off, `403 DOOR_CONTROL_DISABLED`.

## 0f. Remote access (test)

1. **Remote Access** is `Off` and **Remote Status** `Off` after the update.
2. Set **Remote Access** to `On`: **Remote Status** shows `Connecting...`, then `Connected since HH:MM - home xxxxxxxx`.
3. From outside the home network, the relay's test endpoint returns the lights; `GET /v1/logs?category=relay` shows the connection, and each relayed request is logged with client `relay`.
4. Switch it `Off`: the status returns to `Off` and nothing reconnects.

## 0e. DirectorLink and pairing

1. The project contains one **DirectorLink** device and no button proxy. Its properties are, in order: Status, Version, API Status (`Online - port 41999`), Pairing Code, Pairing Status, API Keys, Door Control, Log Level, Inventory.
2. A new DirectorLink shows a code at once (`1234 5678`, **Pairing Status** `Ready until HH:MM - works once`). Pair https://app.directorlink.io with it: the app gets an admin key, **Pairing Code** turns to `-` and **Pairing Status** to `Used at HH:MM`.
3. Run **New Pairing Code**: a new code appears; after 15 minutes unused it turns to `-` / `Expired`.
4. Pair https://console.directorlink.io with a new code; its Keys tab lists both keys.
5. `POST /v1/auth/requests` answers 404.

## 0d. Roles and Door Control

1. The new **Door Control** property is `Disabled`: opening a door from the API answers `403 DOOR_CONTROL_DISABLED`. Set it to `Enabled` and it works again.
2. `GET /v1/api-keys/current` with an existing key shows `"role": "admin"`.
3. Create a `member` key in the console (Keys → Create) and use it in a second browser: it can switch lights but not open doors (`403 FORBIDDEN`) or list keys.
4. `PATCH /v1/api-keys/{id}` `{"role": "doors"}` from the admin browser lets it open doors.

## 0c. Relays and room names

1. **Inventory** ends with `3 relays` (the test system's two doors and gate).
2. `GET /v1/relays` lists them; `state` is `null` until a relay changes. Open one door from the Control4 app: its state turns `closed` and back to `open`.
3. `POST /v1/relays/{id}/pulse` opens that door exactly like its button in the Control4 app. `GET /v1/logs?category=relay_command` shows who sent it.
4. `PATCH /v1/rooms/{id}` with `{"names": {"en": "Living room"}}`, then `GET /v1/rooms/{id}` shows the name; it survives a driver update.

## 0b. Cameras

1. **Inventory** in Composer ends with `13 cameras` (the test system: 12 Hikvision, 1 DoorBird).
2. `GET /v1/cameras` lists them without addresses or passwords.
3. The app's Cameras grid shows a picture for each camera within a few seconds; tapping one shows it larger, refreshing about once a second.
4. A camera that is offline or rejects its login shows "No picture"; `GET /v1/logs?category=camera` says why (never with the password).

## 0a. Blinds

1. **Inventory** in Composer ends with `15 blinds` (the test system).
2. `GET /v1/blinds` lists them; `position` is a number for blinds with a KNX status address, otherwise `null` until the blind moves.
3. In the app open, stop and close one blind, and set 50% on one with percentage control. The Control4 app shows the same movement.
4. `GET /v1/logs?category=blind_command` shows each command; `GET /v1/logs?category=blind&level=debug` (after setting the log level to Debug and reloading) lists the proxy variables.

## 1. Install

Update the driver in Composer with a local file named exactly `DirectorLink.c4z` (delete an older one from the download folder before downloading, or the browser names the new one `DirectorLink (1).c4z`). Coming from C4Bridge (0.7 and older), remove C4Bridge from the project first and add DirectorLink as a new driver — see the 0.8.0 release notes.

Expected in the DirectorLink properties once the new driver is loaded:

- Status: `Ready`
- Version: `1.1.0`
- API Status: `Online - port 41999`
- Pairing Code: `1234 5678` (new driver) or `-`; Pairing Status: `Ready until HH:MM - works once`, or how to get a code
- API Keys: how many keys exist
- Door Control: `Disabled`; Log Level: `Info`
- Remote Access and Remote Status: `Off` (new driver)
- Schedules: `On`; Schedule Status: `None` (new driver); Last Automation: empty
- Inventory: rooms, devices, lights, thermostats, blinds, cameras, relays and doorbells (the test system: 20 rooms, 111 lights, 22 thermostats, 15 blinds, 13 cameras, 3 relays)

## 2. Request bodies

The driver runs the DriverWorks TCP server without a delimiter and reads bodies by `Content-Length` (confirmed on Director 3.4.3). Check it first after every update:

1. Pair (next step). If pairing hangs or times out, body handling does not work on this Director — capture the log and stop.
2. `PATCH /v1/lights/{id}` with `{"on": true}` must answer `202` within a second.

## 3. Pair and connect

1. Open `https://app.directorlink.io`, enter the controller IP and the Pairing Code, and click **Connect**.
2. Expect rooms, devices, lights and thermostats to load. After pairing the Pairing Code in Composer shows `-`, Pairing Status `Used at HH:MM - …`, and **API Keys** goes up by one.

## 4. Lights and thermostats

Repeat the alpha checks through the new API:

- a KNX switch: on and off, confirmed by the controller
- a dimmable light: set 40%, confirmed (KNX dimmers report "level not reported")
- where the project has them, a legacy (`light.c4i`) switch and dimmer: on/off and 40%, confirmed
- one AC zone: mode Off → Cool, target 22 °C, fan Low → Medium
- one floor-heating zone: no Cool mode and no fan controls offered
- a floor-heating zone shows its real target and a change is confirmed

## 5. API console

Open https://console.directorlink.io (or the app's Settings → App → API console) and check:

- the API tab lists every endpoint, grouped by tag
- `GET /v1/system` returns controller, location and inventory
- `GET /v1/devices?type=light&room_id=<id>` filters
- an invalid `PATCH` (for example `{"brightness": 150}`) returns `400` with `code: INVALID_FIELD`
- the Logs tab follows new `api` entries every 2 seconds as requests are made

## 6. API keys and logs

- `POST /v1/api-keys` with `{"name": "Test"}` returns a key once; `GET /v1/api-keys` lists it without the secret
- `DELETE /v1/api-keys/{id}` makes that key return `401`
- `PATCH /v1/logs/settings` with `{"level": "debug"}` changes the Composer **Log Level** to Debug; set it back to `info` afterwards
- Composer action **Revoke All API Keys** makes every browser need a new pairing

## 7. Testing the app before it is deployed

The driver answers browsers only from app.directorlink.io and console.directorlink.io (since 1.0.0,
not `localhost`): a copy of the app served from this PC talks only to the fake controller of the dev
server, which allows local origins.

```bash
python scripts/dev_server.py                  # fake controller on http://localhost:41999
python -m http.server 8080 --directory app    # app on http://localhost:8080
```

Then open `http://localhost:8080`, with `localhost` as the controller address and the code the dev
server prints (`docs/BUILD.md`). Changes are tried against the real controller once they are
deployed (a merge to `main`).

## If something fails

Collect `GET /v1/logs?level=debug` (after setting the level to debug), the Composer properties, and the DirectorLink lines from the Director driver log.
