# C4Bridge Test Plan

## Current release

`v0.2.0` — the OpenAPI release. The API changed completely, so browsers paired with an alpha build must pair again.

## 1. Install

Update the driver in Composer with a local file named exactly `C4Bridge.c4z`.

Expected in the C4Bridge properties once the new driver is loaded:

- Version: `0.2.0`
- Status: `Ready`
- API Status: `Online`
- Inventory: rooms, devices, lights and thermostats (the test system: 20 rooms, 111 lights, 22 thermostats)
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
