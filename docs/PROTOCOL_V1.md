# C4Bridge Protocol v1

This document defines the logical API shape. The LAN transport remains an HTTP alpha, while the V1 one-owner pairing model is now defined.

## Envelope

Request:

```json
{
  "v": 1,
  "id": "request-id",
  "method": "devices.list",
  "params": {}
}
```

Success:

```json
{
  "v": 1,
  "id": "request-id",
  "ok": true,
  "result": {}
}
```

Error:

```json
{
  "v": 1,
  "id": "request-id",
  "ok": false,
  "error": {
    "code": "DEVICE_NOT_FOUND",
    "message": "Device does not exist"
  }
}
```

## Reserved namespaces

- `system.*`
- `auth.*`
- `discovery.*`
- `rooms.*`
- `devices.*`
- `scenes.*`
- `schedules.*`
- `events.*`

## Initial discovery methods

- `system.info`
- `discovery.refresh`
- `rooms.list`
- `devices.list`
- `devices.get`

## Normalized device contract

```json
{
  "id": 41,
  "name": "Living Room Light",
  "room_id": 25,
  "kind": "light",
  "supported": true,
  "proxy": {},
  "protocol": {},
  "capabilities": {},
  "state": {},
  "actions": []
}
```

Raw Control4 command names are not part of the public C4Bridge API.


## Alpha HTTP transport

The current browser transport maps normalized C4Bridge semantics onto a small authenticated HTTP interface.

Read:

- `GET /v1/system/info`
- `GET /v1/rooms`
- `GET /v1/devices`
- `GET /v1/lights`
- `GET /v1/diagnostics` (authenticated alpha diagnostics; recent lifecycle/command/state trace)

Pairing:

- `POST /v1/pair`
- no Bearer credential is required for this one route
- the browser sends the current 8-digit code in `X-C4Bridge-Pairing-Code`
- a successful exchange returns the long owner Bearer credential
- pairing codes expire after 15 minutes, rotate after success, and are rate-limited

Light actions:

- `POST /v1/devices/{id}/actions/on`
- `POST /v1/devices/{id}/actions/off`
- `POST /v1/devices/{id}/actions/set_brightness?value=0..100`

These route names are C4Bridge semantics. Clients must never send raw DriverWorks/Control4 command names.

Every route except `POST /v1/pair` requires the paired owner Bearer credential. The owner credential is generated with `C4:UUID("RANDOM")`, persisted encrypted on Director, and stored only in the paired browser. Composer shows only the short rotating pairing code; the long credential is not displayed.
