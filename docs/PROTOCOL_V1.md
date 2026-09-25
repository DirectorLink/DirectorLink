# C4Bridge Protocol v1

This document defines the logical API shape. Transport and authentication are intentionally not frozen until the LAN transport proof-of-concept is complete.

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

Light actions:

- `POST /v1/devices/{id}/actions/on`
- `POST /v1/devices/{id}/actions/off`
- `POST /v1/devices/{id}/actions/set_brightness?value=0..100`

These route names are C4Bridge semantics. Clients must never send raw DriverWorks/Control4 command names.

All routes require the paired/alpha credential. The current alpha uses a manually copied Bearer token; the transport shape may evolve when the final pairing/session flow is implemented.
