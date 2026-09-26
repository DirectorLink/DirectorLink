# C4Bridge Architecture

## Product boundary

C4Bridge is a homeowner-facing local management layer for Control4 Director OS 3.3.0+.

C4Bridge assumes `C4Bridge.c4z` is already installed. Installation method is out of scope.

## Runtime

```text
Cloudflare Pages PWA (web/)
        |
        | HTTPS: static app only
        v
Browser / any API client (curl, Home Assistant, scripts)
        |
        | LAN HTTP + API key, described by api/openapi.yaml
        v
C4Bridge.c4z inside Director
        |
        | DriverWorks
        v
Existing Control4 project devices
```

Cloudflare does not relay Control4 commands. Clients talk directly to C4Bridge on the LAN.

## Repository

```text
api/        openapi.yaml — the API contract (single source of truth)
driver/     the DriverWorks driver
  src/api/        HTTP server, router, handlers, views (API ↔ internal model)
  src/auth/       API keys, pairing
  src/adapters/   Control4 proxy adapters (Light V2, Thermostat V2, Blind, Camera)
  src/control4/   discovery and normalization
  src/core/       json, log, registry, version
  tests/          driver tests against a fake Director
web/        static PWA: dashboard and API console (deployed by Cloudflare from this folder)
scripts/    build and validation
docs/       specification, decisions, research, releases
```

## Driver layers

```text
request bytes → api/http.lua (parse) → api/server.lua (CORS, auth, routing, errors, access log)
             → api/handlers/*.lua → api/views.lua (public JSON)
             → adapters/*.lua (Control4 commands) → Director
```

Control4 specifics — proxy drivers, command names, variable IDs — live only in `adapters/` and `control4/`. `api/views.lua` is the one place internal records become public JSON.

## Core rules

1. Minimum supported Director version: 3.3.0.
2. Director is the only Control4 runtime dependency.
3. Do not import Composer programming, schedules, or scenes.
4. C4Bridge owns its own scenes, schedules, and automations.
5. Unknown device types are visible but marked unsupported.
6. The public API uses logical names, never raw Control4 command names.
7. OS/version differences stay behind the Control4 compatibility layer.
8. V1 is LAN-only and needs an API key for everything except health, the API description and pairing.
9. No automatic C4Z self-update in V1.
10. `api/openapi.yaml` and the driver routes must always match (enforced in CI).
