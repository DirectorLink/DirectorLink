# DirectorLink Test Plan

## Current release

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

1. **Inventory** ends with `3 relays` (דלת מטבח, דלת ראשית, שער חניה).
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

Update the driver in Composer with a local file named exactly `DirectorLink.c4z`. Coming from C4Bridge (0.7 and older), remove C4Bridge from the project first and add DirectorLink as a new driver — see the 0.8.0 release notes.

Expected in the DirectorLink properties once the new driver is loaded:

- Status: `Ready`
- Version: `0.11.1`
- API Status: `Online - port 41999`
- Pairing Code: `1234 5678` (new driver) or `-`; Pairing Status: `Ready until HH:MM - works once`, or how to get a code
- Door Control: `Disabled`; Log Level: `Info`
- Inventory: rooms, devices, lights, thermostats, blinds, cameras, relays and doorbells (the test system: 20 rooms, 111 lights, 22 thermostats, 15 blinds, 13 cameras, 3 relays)

## 2. Request bodies

The driver runs the DriverWorks TCP server without a delimiter and reads bodies by `Content-Length` (confirmed on Director 3.4.3). Check it first after every update:

1. Pair (next step). If pairing hangs or times out, body handling does not work on this Director — capture the log and stop.
2. `PATCH /v1/lights/{id}` with `{"on": true}` must answer `202` within a second.

## 3. Pair and connect

1. Open `https://app.directorlink.io` (or a local copy, see step 7), enter the controller IP and the Pairing Code, and click **Pair & connect**.
2. Expect rooms, devices, lights and thermostats to load. The Pairing Code in Composer changes after pairing and **API Keys** shows `1`.

## 4. Lights and thermostats

Repeat the alpha checks through the new API:

- a KNX switch: on and off, confirmed by the controller
- a dimmable light: set 40%, confirmed (KNX dimmers report "level not reported")
- one AC zone: mode Off → Cool, target 22 °C, fan Low → Medium
- one floor-heating zone: no Cool mode and no fan controls offered

## 5. API console

Open **API console** from the dashboard, click **Load API** and check:

- every endpoint is listed, grouped by tag
- `GET /v1/system` returns controller, location and inventory
- `GET /v1/devices?type=light&room_id=<id>` filters
- an invalid `PATCH` (for example `{"brightness": 150}`) returns `400` with `code: INVALID_FIELD`
- **Follow** in the log panel shows new `api` entries as requests are made

## 6. API keys and logs

- `POST /v1/api-keys` with `{"name": "Test"}` returns a key once; `GET /v1/api-keys` lists it without the secret
- `DELETE /v1/api-keys/{id}` makes that key return `401`
- `PATCH /v1/logs/settings` with `{"level": "debug"}` changes the Composer **Log Level** to Debug; set it back to `info` afterwards
- Composer action **Revoke All API Keys** makes every browser need a new pairing

## 7. Testing the app before it is deployed

The driver accepts `http://localhost` origins, so the app can be tested from this PC:

```bash
python -m http.server 8080 --directory app
```

Then open `http://localhost:8080`.

## If something fails

Collect `GET /v1/logs?level=debug` (after setting the level to debug), the Composer properties, and the DirectorLink lines from the Director driver log.
