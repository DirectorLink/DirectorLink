# C4Bridge Test Plan

## Current release

`v0.5.0` — cameras. Update in Composer (no reboot); keys keep working.

## 0b. Cameras

1. **Inventory** in Composer ends with `13 cameras` (the test system: 12 Hikvision, 1 DoorBird).
2. `GET /v1/cameras` lists them without addresses or passwords.
3. The web app's Cameras grid shows a picture for each camera within a few seconds; tapping one shows it larger, refreshing about once a second.
4. A camera that is offline or rejects its login shows "No picture"; `GET /v1/logs?category=camera` says why (never with the password).

## 0a. Blinds

1. **Inventory** in Composer ends with `15 blinds` (the test system).
2. `GET /v1/blinds` lists them; `position` is a number for blinds with a KNX status address, otherwise `null` until the blind moves.
3. In the web app open, stop and close one blind, and set 50% on one with percentage control. The Control4 app shows the same movement.
4. `GET /v1/logs?category=blind_command` shows each command; `GET /v1/logs?category=blind&level=debug` (after setting the log level to Debug and reloading) lists the proxy variables.

## 0. After updating: the C4Bridge Access button

1. The project should now contain **C4Bridge** and **C4Bridge Access** (same room).
2. Within about 10 seconds, without touching Composer's Navigators, the button shows in the Control4 app under **Security** in that room, as a gray key. If it does not, run the Composer action **Show Access Button in App** and check `GET /v1/logs?category=navigator`.
3. In the web app click **Request access**: the key turns orange and Composer's **Access Request** shows the waiting browser.
4. Press the button: it turns green, the web app connects, and the button returns to gray.
5. Also check: **Cancel request** turns it gray again, and a request left alone expires after 2 minutes.

If the button does not appear, remove and re-add C4Bridge in Composer, then request access again. Driver updates load without a reboot since 0.4.0; if one does not, check `/var/log/debug/broker.log` for "Unable to parse driver".

## 1. Install

Update the driver in Composer with a local file named exactly `C4Bridge.c4z`.

Expected in the C4Bridge properties once the new driver is loaded:

- Version: `0.5.0`
- Status: `Ready`
- API Status: `Online`
- Inventory: rooms, devices, lights, thermostats, blinds and cameras (the test system: 20 rooms, 111 lights, 22 thermostats, 15 blinds, 13 cameras)
- Pairing Code: 8 digits; Pairing Status: `Ready until HH:MM`
- Log Level: `Info`

## 2. Request bodies

The driver runs the DriverWorks TCP server without a delimiter and reads bodies by `Content-Length` (confirmed on Director 3.4.3). Check it first after every update:

1. Pair (next step). If pairing hangs or times out, body handling does not work on this Director — capture the log and stop.
2. `PATCH /v1/lights/{id}` with `{"on": true}` must answer `202` within a second.

## 3. Pair and connect

1. Open `https://app.c4bridge.io` (or a local copy, see step 7), enter the controller IP and the Pairing Code, and click **Pair & connect**.
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

## 7. Testing the web app before it is deployed

The driver accepts `http://localhost` origins, so the web app can be tested from this PC:

```bash
python -m http.server 8080 --directory web
```

Then open `http://localhost:8080`.

## If something fails

Collect `GET /v1/logs?level=debug` (after setting the level to debug), the Composer properties, and the C4Bridge lines from the Director driver log.
