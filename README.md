# DirectorLink

**Direct to Director. End-to-end integration. Open source.**

DirectorLink is an open-source, local-first management layer for Control4 homeowners.

The goal is to provide simple device control, scenes, schedules, and everyday automation without requiring homeowners to use Composer Pro for routine changes.

## V1 scope

- Control4 Director OS **3.3.0+**
- `DirectorLink.c4z` is assumed to already be installed in the Control4 project
- Installation method is outside the scope of this project
- A standard REST API on the local LAN, described by OpenAPI 3.1, protected by API keys
- An app (PWA) hosted on Cloudflare; the browser connects directly to DirectorLink over the LAN, and seals every request with its own lock key, so its API key does not cross the network
- LAN-first, with no port forwarding; remote access with a Google account through `api.directorlink.io`, locked end to end so that DirectorLink's servers cannot read it (off by default; `docs/ACCOUNTS.md`)
- One owner and invited family members, with a separate named API key and role (viewer, member, doors, admin) per browser, app or script
- Device adapters: lights (Light V2 and the older Light proxy), HVAC/climate (Thermostat V2, including floor heating set through its heat setpoint, and Control4 thermostats with heat and cool setpoints), blinds, cameras (snapshots), KNX relays (doors and gates), DoorBird doorbells
- Room names in several languages
- Unknown devices are exposed as unsupported
- DirectorLink owns its own scenes, schedules, and automations
- No import of Composer programming, scenes, or schedules
- Schedules by time and weekday, at sunrise or sunset with offsets, and by the weather (heat, wind and rain from Open-Meteo), with "only if" weather conditions
- Director location/timezone used for solar scheduling
- No automatic `.c4z` self-update in V1

## Installation

DirectorLink itself does not depend on Composer Pro during normal operation. Composer is only one way to install the `DirectorLink.c4z` driver into a Control4 project.

### 1. Download DirectorLink

Download DirectorLink from **[GitHub Releases](https://github.com/IsraelCIL/DirectorLink/releases)**.

Each release keeps its own `DirectorLink.c4z`, `openapi.json`, release notes, and SHA-256 checksums so users can upgrade or downgrade to a specific version.

### 2. Install Composer Pro

If you need Composer Pro for the initial driver installation, this project currently provides the following Control4-hosted installer link:

**Composer Pro 2026.3.18.506**

https://update2.control4.com/release/2026.3.18.506-res+Composer/win/ComposerPro-2026.3.18.506-res.exe

DirectorLink does not depend on this specific Composer version after the driver has been installed.

### 3. Add the driver to Composer

1. Open Composer Pro and connect to your Director.
2. In the top menu, choose **Driver → Add or Update Driver**.
3. Select `DirectorLink.c4z`.
4. Go to **System Design**.
5. Select any room in the project tree. DirectorLink only needs one instance in the project; the room is not functionally important.
6. Open the **Search** tab in the Items pane.
7. Make sure **Local** drivers are included and search for **DirectorLink**.
8. Double-click or drag **DirectorLink** into the selected room.
9. Select the DirectorLink device and check its Properties.

A successful install shows:

- **Status:** `Ready`
- **Version:** the installed DirectorLink release
- **API Status:** `Online - port 41999`
- **Pairing Code:** 8 digits shown as `1234 5678`, with **Pairing Status** `Ready until HH:MM - works once`
- **API Keys:** how many keys exist
- **Door Control:** `Disabled` until you allow opening doors and gates from the app
- **Remote Access** and **Remote Status**: reaching the home from anywhere with an account
- **Schedules** (`On`, or `Paused` to stop every DirectorLink schedule), **Schedule Status** (what is on and what runs next) and **Last Automation** (the last scene DirectorLink ran, when and why); the action **Print Schedules and Scenes** lists them all in the Lua output
- **Log Level** and **Inventory** (rooms and devices found)

Actions: **New Pairing Code**, **Revoke All API Keys**, **Print Schedules and Scenes**, and **Reset Remote Identity** (a last resort: the controller becomes a new home for DirectorLink's servers, and the owner links it again). If a copy of the project's data got into the wrong hands, run Revoke All API Keys, and have the home's owner use **Replace the remote secret** in the app (Settings → Account, at home).

If the status shows an error, open `GET /v1/logs` (see below) or capture the DirectorLink Lua log and open a GitHub issue.

### 4. Pair the owner's device

Open **https://app.directorlink.io**, enter the controller IP and the **Pairing Code** from the DirectorLink properties. The device gets an admin key.

> **Pair from a computer or an Android phone, not from an iPhone or iPad.** On iPhone and iPad every browser (Safari, Chrome, Edge, …) uses Apple's WebKit, which blocks a secure page such as app.directorlink.io from reaching the controller's plain `http://` address on the home network, and offers no permission to allow it. Pairing cannot work there. iPhones and iPads join through the account instead: on a paired computer at home, sign in and use Settings → Account → **Link this home**, then **Add my other device**, and scan the QR code with the iPhone.

A code is valid for 15 minutes and works once, and only on the home network. Five wrong codes lock pairing for that device for a minute; twenty close the code. The app pairs with a key exchange, so its new key is never readable on the network. A new DirectorLink shows one right away; later, run the Composer action **New Pairing Code** on DirectorLink (an installer can read it out for the homeowner). Other devices and family members do not pair: an admin invites them (Settings → Account → **Invite someone**, with remote access) or creates their keys (API console → Keys).

### Updating DirectorLink

Automatic self-update is intentionally **not** part of V1.

Update the installed driver manually through Composer Pro using the `DirectorLink.c4z` asset from the desired GitHub Release.

**Important:** before updating, make sure the local file is named exactly `DirectorLink.c4z`. Do not select `DirectorLink (1).c4z`, `DirectorLink (2).c4z`, etc. A real Director snapshot showed those suffixed filenames can be installed as separate driver files instead of replacing the canonical package.

To downgrade, download `DirectorLink.c4z` from an older release and install that version through Composer Pro. Release notes say when a downgrade is not safe.

Do not remove and re-add the project instance unless a release specifically requires it.

## API

The LAN API is a standard REST API described by **[`api/openapi.yaml`](api/openapi.yaml)** (OpenAPI 3.1) — see **[`api/README.md`](api/README.md)** for conventions and examples.

```bash
curl http://<controller-ip>:41999/v1/lights -H "Authorization: Bearer <api key>"
curl -X PATCH http://<controller-ip>:41999/v1/lights/259 \
  -H "Authorization: Bearer <api key>" -H "Content-Type: application/json" \
  -d '{"brightness": 40}'
```

Resources: system, rooms, devices, lights, thermostats, blinds, cameras, relays (doors and gates), doorbells, scenes, schedules and the weather, profiles, logs, API keys, invitations and remote access. The running bridge serves its own description at `/v1/openapi.json`, so Postman, Swagger UI or Home Assistant can import it, and the app's **API console** lists and tries every endpoint.

A script's key travels in the clear on the home network (plain HTTP); give each script its own key with the least role it needs. The app does not send its key: it seals each request (`POST /v1/sealed`, [`docs/ACCOUNTS.md`](docs/ACCOUNTS.md)). Requests must name the controller by its IP address or a local name such as `director.local`.

## Design principle

DirectorLink depends on **Director**, not Composer.

```text
DirectorLink app (PWA, hosted on Cloudflare)
        |
        | Local Network Access permission
        v
Browser / any API client
        |
        | LAN: sealed requests (app) or API key (scripts)
        | away: through api.directorlink.io, sealed end to end
        v
DirectorLink.c4z
        |
        v
Control4 Director
        |
        v
Existing Control4 devices
```

## Repository

```text
api/       OpenAPI contract
driver/    DriverWorks driver (Lua 5.1) and its tests
app/       the app (PWA)                       → https://app.directorlink.io
console/   API console, debugging and logs      → https://console.directorlink.io
site/      landing page                         → https://directorlink.io
cloud/     accounts and the relay (Worker)      → https://api.directorlink.io
tests/     app and cloud tests, shared vectors
scripts/   build and validation
docs/      specification, decisions, research, releases
```

See **[`docs/BUILD.md`](docs/BUILD.md)** for building, testing and releasing, **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** for how the pieces fit, and **[`SECURITY.md`](SECURITY.md)** for reporting a security problem.

## Live

- **App:** https://app.directorlink.io
- **API console, debugging and logs:** https://console.directorlink.io
- **Website:** https://directorlink.io

## Status

1.0. The API is described and versioned: 1.x releases add to `/v1` without breaking existing clients, and a breaking change would get a new prefix (`/v2`). The roadmap is [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Disclaimer

DirectorLink is an independent open-source project and is not affiliated with or endorsed by Control4 or Snap One.

Installing third-party drivers or modifying a Control4 project can introduce compatibility, support, warranty, or recovery risks. Users are responsible for understanding those risks and should keep appropriate backups of their Control4 project.

## License

DirectorLink is licensed under the **Apache License 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
