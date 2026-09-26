# C4Bridge API

[`openapi.yaml`](openapi.yaml) is the contract for the LAN API that the C4Bridge driver serves on the Control4 controller. It is the single source of truth: the driver routes are checked against it in CI (`scripts/check_api.py`), the build embeds it in the driver, and every release publishes it as `openapi.json`.

A running bridge also serves its own copy at `http://<controller-ip>:41999/v1/openapi.json`, so tools such as Postman or Swagger UI can import it directly. The web app's [API console](../web/console.html) reads it to list and try every endpoint.

## Conventions

| Topic | Rule |
| --- | --- |
| Base URL | `http://<controller-ip>:41999`, LAN only. Every path starts with `/v1`. |
| Names | Logical resources — rooms, devices, lights, thermostats, blinds. No Control4 command names, proxy IDs or variable numbers. |
| Authentication | `Authorization: Bearer <api key>` on every route except health, `GET /v1/openapi.json`, access requests (`/v1/auth/requests`) and pairing. |
| Reading | `GET` on a collection returns `{ "items": [...] }`; `GET` on an item returns the object. |
| Changing | `PATCH` with the desired state, e.g. `{"on": true}`. The answer is `202 Accepted` with the last state the controller reported; read the resource again to confirm. |
| Errors | RFC 9457 Problem Details (`application/problem+json`) with a stable `code`, e.g. `INVALID_FIELD`, `NOT_FOUND`, `UNAUTHORIZED`. |
| JSON | snake_case properties, ISO 8601 UTC times, temperatures in °C, `null` for unknown values. |
| IDs | The numeric IDs of the Control4 project. Treat them as opaque. |
| Versioning | Breaking changes get a new path prefix (`/v2`). `info.version` is the bridge release. |

## Getting a key

**With the Control4 app (recommended).** Ask for access, press **C4Bridge Access** in the Control4 app within 2 minutes, then collect the key once:

```bash
curl -X POST http://192.168.1.201:41999/v1/auth/requests -H "Content-Type: application/json" -d '{"name": "My laptop"}'
# -> {"id": "<request id>", "status": "pending", ...}   now press C4Bridge Access
curl http://192.168.1.201:41999/v1/auth/requests/<request id>
# -> {"status": "approved", "api_key": {"key": "ak_...", ...}}
```

**With the pairing code (fallback).**

1. Read the 8-digit **Pairing Code** in the C4Bridge properties in Composer.
2. Exchange it for a key (the code then changes):

   ```bash
   curl -X POST http://192.168.1.201:41999/v1/auth/pair \
     -H "Content-Type: application/json" \
     -d '{"pairing_code": "12345678", "name": "My laptop"}'
   ```

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
