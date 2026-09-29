# DirectorLink API

[`openapi.yaml`](openapi.yaml) is the contract for the LAN API that the DirectorLink driver serves on the Control4 controller. It is the single source of truth: the driver routes are checked against it in CI (`scripts/check_api.py`), the build embeds it in the driver, and every release publishes it as `openapi.json`.

A running bridge also serves its own copy at `http://<controller-ip>:41999/v1/openapi.json`, so tools such as Postman or Swagger UI can import it directly. The [API console](https://console.directorlink.io) ([`../console/`](../console/)) reads it to list and try every endpoint.

## Conventions

| Topic | Rule |
| --- | --- |
| Base URL | `http://<controller-ip>:41999` on the home network. Every path starts with `/v1`. The `Host` must be the controller's IP address or a local name (e.g. `director.local`), otherwise `421 MISDIRECTED_REQUEST`; browsers may call it only from app.directorlink.io and console.directorlink.io. |
| Names | Logical resources — rooms, devices, lights, thermostats, fans, blinds, cameras, relays, doorbells, the alarm, scenes, schedules, the weather, profiles, invitations. No Control4 command names, proxy IDs or variable numbers. |
| Authentication | `Authorization: Bearer <api key>` on every route except health, `GET /v1/openapi.json`, pairing (`POST /v1/auth/pair`) and `/v1/sealed`, which carries requests sealed with a key's lock key instead (the app's way, so its key does not cross the network; `docs/ACCOUNTS.md`). |
| Roles | Every key has a role: `viewer` (read, but not the alarm), `member` (also lights, climate, fans, blinds, running scenes, the alarm's status), `doors` (also doors and gates), `admin` (also keys, rooms, scenes, schedules, invitations, profiles, remote access, log). Each operation states the least role it needs as `x-directorlink-role`; otherwise `403 FORBIDDEN`. `GET /v1/api-keys/current` tells a client its own role. Opening doors also needs **Door Control** = Enabled in Composer. |
| Reading | `GET` on a collection returns `{ "items": [...] }`; `GET` on an item returns the object. |
| Changing | `PATCH` with the desired state, e.g. `{"on": true}`. For a device the answer is `202 Accepted` with the last state the controller reported; read the resource again to confirm. Scenes, schedules, rooms, profiles and keys answer `200` with the stored result. |
| Errors | RFC 9457 Problem Details (`application/problem+json`) with a stable `code`, e.g. `INVALID_FIELD`, `NOT_FOUND`, `UNAUTHORIZED`. |
| JSON | snake_case properties, ISO 8601 UTC times, temperatures in °C, `null` for unknown values. |
| IDs | The numeric IDs of the Control4 project. Treat them as opaque. |
| Versioning | Breaking changes get a new path prefix (`/v2`). `info.version` is the bridge release. |

## Getting a key

The first key comes from a **pairing code**: in Composer, run **New Pairing Code** on DirectorLink (a new DirectorLink shows one right away). The code is shown as `1234 5678`, is valid for 15 minutes and works once; the key it gives is `admin`.

1. Exchange the code for a key:

   ```bash
   curl -X POST http://<controller-ip>:41999/v1/auth/pair \
     -H "Content-Type: application/json" \
     -d '{"pairing_code": "1234 5678", "name": "My laptop"}'
   ```

2. Keep the returned `key` — it is shown only once. Without an active code the answer is `403 PAIRING_NOT_ACTIVE`. Five wrong codes within a minute lock pairing for that device (IP address) for 60 s (`429`, `Retry-After`); twenty wrong codes in all close the code. Pairing works only on the home network. With `"exchange": {"public_key": …}` (X25519, base64) the answer is sealed instead, as the app does (`docs/ACCOUNTS.md`).

3. Use the returned `key`, and create more keys for other clients under `/v1/api-keys`:

   ```bash
   curl http://<controller-ip>:41999/v1/lights -H "Authorization: Bearer ak_..."
   curl -X PATCH http://<controller-ip>:41999/v1/lights/259 \
     -H "Authorization: Bearer ak_..." -H "Content-Type: application/json" \
     -d '{"brightness": 40}'
   ```

The controller keeps only a hash of each key, so keys survive driver updates and cannot be read back from it. It also keeps each key's lock key, for sealed requests: if a copy of the controller's data is lost, use **Revoke All API Keys** in Composer (which also removes every key if one is lost) and the owner's **Replace the remote secret** in the app (`docs/ACCOUNTS.md`).

## Thermostats

Most thermostats have one `target_temperature` (`"setpoints": "single"`). Thermostats with separate heat and cool setpoints (`"setpoints": "dual"`, the Control4 thermostat) also report both, and the smallest gap they keep between them:

```json
{
  "id": 31,
  "name": "Study",
  "mode": "auto",
  "target_temperature": null,
  "target_temperature_min": 5,
  "target_temperature_max": 35,
  "setpoints": "dual",
  "heat_setpoint": 20,
  "cool_setpoint": 24.4,
  "setpoint_deadband": 1.7
}
```

(Other fields left out.) Set both in auto:

```bash
curl -X PATCH http://<controller-ip>:41999/v1/thermostats/31 \
  -H "Authorization: Bearer ak_..." -H "Content-Type: application/json" \
  -d '{"mode": "auto", "heat_setpoint": 20, "cool_setpoint": 24}'
```

- Sending one setpoint moves the other when needed to keep `setpoint_deadband`. Two setpoints sent together must already be that far apart, or the answer is `400 INVALID_FIELD`. When `setpoint_deadband` is `null`, cool must still be above heat.
- `target_temperature` sets the setpoint of the mode (the one in the same request, else the current one). In auto and off it is refused with `409 NOT_SUPPORTED`.
- Temperatures stay in °C, whatever scale the Control4 project uses. `heat_setpoint`, `cool_setpoint` and `setpoint_deadband` are `null` on single-setpoint thermostats. A dual thermostat reports `null` for a setpoint none of its modes uses, such as the heat setpoint of one with only Off and Cool.

## Fans

Since 1.2.0 fans on the Control4 fan proxy are resources too. A fan is on or off, and runs at a
speed from 1 (low) to 4 (high); `speed` is `null` while it is off:

```json
{
  "id": 41,
  "name": "Ceiling Fan",
  "on": true,
  "speed": 2,
  "speeds": [1, 2, 3, 4]
}
```

(`room` left out.) `speeds` lists the speeds `PATCH` takes.

```bash
curl -X PATCH http://<controller-ip>:41999/v1/fans/41 \
  -H "Authorization: Bearer ak_..." -H "Content-Type: application/json" \
  -d '{"speed": 3}'
```

- `{"speed": 3}` sets the speed and turns the fan on if it is off. `{"on": true}` turns it on at the
  speed the fan chooses (its preset speed, or the last one); `{"on": false}` turns it off. There is
  no speed 0: `{"speed": 0}`, like any other value outside `speeds`, is `400 INVALID_FIELD`, and
  `"on": false` with a speed is `400 INVALID_REQUEST`. Nothing is sent when a request is refused.
- Viewers read fans; members and above change them. In scenes a `fans` step sets
  `{"on": true|false}` or `{"speed": 1-4}` on the fans it names, or on all of them in a room or the
  whole home.

## Blinds

Since 1.1.0 a blind says what it can do, and whether it is moving:

```json
{
  "id": 52,
  "name": "Terrace Shade",
  "position": 40,
  "position_reported": true,
  "capabilities": { "position": true, "stop": true },
  "moving": true,
  "direction": "opening",
  "target_position": 80
}
```

- `capabilities.position` is false for a blind that only opens and closes fully: `PATCH` then takes only `{"position": 0}` and `{"position": 100}`, and anything else is `409 POSITION_NOT_SUPPORTED`. With `capabilities.stop` false, `POST /v1/blinds/{id}/stop` is `409 STOP_NOT_SUPPORTED`. Both are true where the controller does not say.
- A move takes seconds to a minute, and `position` may keep the value the blind left until it stops: while `moving` is true, show `target_position`, and read the blind again every few seconds. `moving` is `null` when the controller does not report movement.
- `position` and `target_position` are `null` when unknown.

## Relays

Doors and gates open with `POST /v1/relays/{id}/pulse` (the relay closes, then opens again after 500 ms), as in the app and scenes. `PATCH` with `{"state": "open"}` releases a relay. `{"state": "closed"}` would hold it closed, and its door or gate open: since 1.1.1 it is `409 HOLD_NOT_ALLOWED` and nothing is sent, unless an installer sets **Relay Hold** to Allowed in Composer.

## Shabbat and holidays (arriving in 1.2.0)

DirectorLink 1.2.0 works out Shabbat and holiday times on the controller from the project's location; nothing is sent to the network. It stays off until an installer sets **Jewish Calendar** to On in Composer. Until then `GET /v1/calendar` answers `{"enabled": false, "status": "off", ...}` with nulls, `GET /v1/system` has `"features": {"jewish_calendar": false}`, and setting anything that uses the calendar is `409 JEWISH_CALENDAR_OFF`.

- `GET /v1/calendar` (any key): the settings, today's Hebrew date and holidays (`today`), this week's Shabbat and reading (`week`), and the holy period now (`current`) and next (`next`), from candle lighting (`starts_at`) to havdalah (`ends_at`), in UTC. Shabbat and holidays that follow each other are one period.
- `PATCH /v1/calendar/settings` (admin): `{"candle_lighting_minutes": 30, "havdalah_minutes": 50, "version": 1}` (0–90 minutes before sunset and 20–90 after; 20 and 42 by default), or `{"holidays": "abroad"}` (`auto`, `israel` or `abroad`).
- Schedules: the trigger `{"type": "shabbat", "event": "candle_lighting", "offset": -30}` (or `havdalah`; −360 to 360 minutes) runs once when a period begins or ends; `"during_shabbat": "skip"` or `"only"` keeps a time, sun or weather schedule away from Shabbat and holidays, or to them. `calendar_status` (`ok`, `off`, `no_location`) says whether such a schedule can run.

Example answers: [`tests/vectors/calendar/api-examples.json`](../tests/vectors/calendar/api-examples.json).

## Alarm

`GET /v1/alarm` (since 1.2.0) says whether each partition of the home's alarm is armed. It is read-only: nothing in the API arms or disarms, which takes the user's alarm code (ADR-038).

- Off by default. Until an installer sets **Alarm Status** to On in Composer, the answer is `{"enabled": false, "partitions": []}`, and DirectorLink does not watch the alarm. `GET /v1/system` says which in `features.alarm_status`.
- For `member`, `doors` and `admin` keys; viewers get `403 FORBIDDEN`.
- Only in sealed requests: on the home network through `POST /v1/sealed`, as the app sends every request, and through remote access. With `Authorization: Bearer` the answer is `403 SEALED_REQUEST_REQUIRED`, so whether the home is armed never crosses a network in the clear. Scripts and the API console, which do not seal, cannot read it.

```json
{
  "enabled": true,
  "partitions": [
    {
      "id": 81,
      "name": "Garage",
      "state": "entry_delay",
      "armed": true,
      "armed_mode": "away",
      "armed_type": "Away",
      "alarm": false,
      "alarm_type": null,
      "open_zones": 1,
      "delay": { "type": "entry", "remaining": 12, "total": 30 },
      "trouble": null
    }
  ]
}
```

(`room` left out.) `state` is the panel's word in lower case: `disarmed_ready`, `disarmed_not_ready`, `armed`, `exit_delay`, `entry_delay`, `alarm`, `confirmation_required`, `offline`, or another a panel reports. `armed_type` and `alarm_type` are the panel's own words (e.g. `Stay`, `Fire`), `null` unless armed or in alarm. `delay` is `null` unless an entry or exit delay is counting down, in seconds as the panel last reported. Partitions the alarm does not use are left out. In `/v1/devices` a partition stays a device of type `other`.

## Debugging

`GET /v1/logs` returns the bridge's last 500 log entries (API requests, device commands, state changes, errors). Poll it with `after=<last_seq>` to follow new entries, and switch to `debug` with `PATCH /v1/logs/settings` while investigating. Secrets are never logged.
