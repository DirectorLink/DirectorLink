# DirectorLink API

[`openapi.yaml`](openapi.yaml) is the contract for the LAN API that the DirectorLink driver serves on the Control4 controller. It is the single source of truth: the driver routes are checked against it in CI (`scripts/check_api.py`), the build embeds it in the driver, and every release publishes it as `openapi.json`.

A running bridge also serves its own copy at `http://<controller-ip>:41999/v1/openapi.json`, so tools such as Postman or Swagger UI can import it directly. The app's [API console](../app/console.html) reads it to list and try every endpoint.

## Conventions

| Topic | Rule |
| --- | --- |
| Base URL | `http://<controller-ip>:41999`, LAN only. Every path starts with `/v1`. |
| Names | Logical resources — rooms, devices, lights, thermostats, blinds, cameras, relays, doorbells. No Control4 command names, proxy IDs or variable numbers. |
| Authentication | `Authorization: Bearer <api key>` on every route except health, `GET /v1/openapi.json` and pairing (`POST /v1/auth/pair`). |
| Roles | Every key has a role: `viewer` (read), `member` (also lights, climate, blinds), `doors` (also doors and gates), `admin` (also keys, room names, log). Each operation states the least role it needs as `x-directorlink-role`; otherwise `403 FORBIDDEN`. `GET /v1/api-keys/current` tells a client its own role. Opening doors also needs **Door Control** = Enabled in Composer. |
| Reading | `GET` on a collection returns `{ "items": [...] }`; `GET` on an item returns the object. |
| Changing | `PATCH` with the desired state, e.g. `{"on": true}`. The answer is `202 Accepted` with the last state the controller reported; read the resource again to confirm. |
| Errors | RFC 9457 Problem Details (`application/problem+json`) with a stable `code`, e.g. `INVALID_FIELD`, `NOT_FOUND`, `UNAUTHORIZED`. |
| JSON | snake_case properties, ISO 8601 UTC times, temperatures in °C, `null` for unknown values. |
| IDs | The numeric IDs of the Control4 project. Treat them as opaque. |
| Versioning | Breaking changes get a new path prefix (`/v2`). `info.version` is the bridge release. |

## Getting a key

The first key comes from a **pairing code**: in Composer, run **New Pairing Code** on DirectorLink (a new DirectorLink shows one right away). The code is shown as `1234 5678`, is valid for 15 minutes and works once; the key it gives is `admin`.

1. Exchange the code for a key:

   ```bash
   curl -X POST http://192.168.1.201:41999/v1/auth/pair \
     -H "Content-Type: application/json" \
     -d '{"pairing_code": "1234 5678", "name": "My laptop"}'
   ```

2. Keep the returned `key` — it is shown only once. Without an active code the answer is `403 PAIRING_NOT_ACTIVE`; five wrong codes lock pairing for a minute.

3. Use the returned `key`, and create more keys for other clients under `/v1/api-keys`:

   ```bash
   curl http://192.168.1.201:41999/v1/lights -H "Authorization: Bearer ak_..."
   curl -X PATCH http://192.168.1.201:41999/v1/lights/259 \
     -H "Authorization: Bearer ak_..." -H "Content-Type: application/json" \
     -d '{"brightness": 40}'
   ```

Keys are stored encrypted on the controller. The Composer action **Revoke All API Keys** removes every key if one is lost.

## Debugging

`GET /v1/logs` returns the bridge's last 500 log entries (API requests, device commands, state changes, errors). Poll it with `after=<last_seq>` to follow new entries, and switch to `debug` with `PATCH /v1/logs/settings` while investigating. Secrets are never logged.
