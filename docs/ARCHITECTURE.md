# C4Bridge Architecture

## Product boundary

C4Bridge is a homeowner-facing local management layer for Control4 Director OS 3.3.0+.

C4Bridge assumes `C4Bridge.c4z` is already installed. Installation method is out of scope.

## V1 architecture

```text
Cloudflare Pages PWA
        |
        | HTTPS: static app only
        v
Browser
        |
        | Local Network Access permission
        | authenticated LAN API
        v
C4Bridge.c4z
        |
        | DriverWorks
        v
Control4 Director
        |
        v
Existing project devices
```

Cloudflare does not relay Control4 commands. The browser talks directly to C4Bridge on the LAN.

## Core rules

1. Minimum supported Director version: 3.3.0.
2. Director is the only Control4 runtime dependency.
3. Do not import Composer programming, schedules, or scenes.
4. C4Bridge owns its own scenes, schedules, and automations.
5. Unknown device types are visible but marked unsupported.
6. Public API uses normalized actions, never raw Control4 command names.
7. OS/version differences stay behind the Control4 compatibility layer.
8. V1 is LAN-only and supports one owner.
9. No automatic C4Z self-update in V1.

## First milestone

Discovery only:

- Director compatibility check
- project metadata
- rooms
- proxy devices
- protocol/proxy relationships
- normalized registry
- adapter classification

Light control comes only after discovery is verified on a real Director.
