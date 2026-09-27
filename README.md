# DirectorLink

**Direct to Director. End-to-end integration. Open source.**

DirectorLink is an open-source, local-first management layer for Control4 homeowners.

The goal is to provide simple device control, scenes, schedules, and everyday automation without requiring homeowners to use Composer Pro for routine changes.

## V1 scope

- Control4 Director OS **3.3.0+**
- `DirectorLink.c4z` is assumed to already be installed in the Control4 project
- Installation method is outside the scope of this project
- A standard REST API on the local LAN, described by OpenAPI 3.1, protected by API keys
- Cloudflare Pages PWA frontend; the browser connects directly to DirectorLink over the LAN
- LAN-only in V1; no cloud relay and no port forwarding
- One owner, with a separate named API key per browser, app or script
- Device adapters: lights, HVAC/climate, blinds, cameras (snapshots), KNX relays (doors and gates)
- Room names in several languages
- Unknown devices are exposed as unsupported
- DirectorLink owns its own scenes, schedules, and automations
- No import of Composer programming, scenes, or schedules
- Fixed-time, weekday, sunrise/sunset, and offset scheduling
- Director location/timezone used for solar scheduling
- No automatic `.c4z` self-update in V1

## Installation

DirectorLink itself does not depend on Composer Pro during normal operation. Composer is only one way to install the `DirectorLink.c4z` driver into a Control4 project.

### 1. Download DirectorLink

Download DirectorLink from **[GitHub Releases](https://github.com/IsraelCIL/C4Bridge/releases)**.

Current build: **DirectorLink v0.7.0**

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

- **Version:** the installed DirectorLink release
- **Status:** `Ready`
- **Controller OS:** your Director OS version
- **Inventory:** the number of rooms, devices, lights and thermostats found
- **API Status:** `Online`
- **Access Request:** what is waiting for approval with the DirectorLink Access button
- **Pairing Code:** 8 digits, a fallback way to pair a browser

If the status shows an error, open `GET /v1/logs` (see below) or capture the DirectorLink Lua log and open a GitHub issue.

### 4. Pair a browser

Open **https://app.directorlink.io**, enter the controller IP and click **Request access**, then press **DirectorLink Access** in your Control4 app within 2 minutes. The browser receives its own API key. (The 8-digit Pairing Code in the DirectorLink properties is a fallback.)

### Updating DirectorLink

Automatic self-update is intentionally **not** part of V1.

Update the installed driver manually through Composer Pro using the `DirectorLink.c4z` asset from the desired GitHub Release.

**Important:** before updating, make sure the local file is named exactly `DirectorLink.c4z`. Do not select `DirectorLink (1).c4z`, `DirectorLink (2).c4z`, etc. A real Director snapshot showed those suffixed filenames can be installed as separate driver files instead of replacing the canonical package.

To downgrade, download `DirectorLink.c4z` from an older release and install that version through Composer Pro. Downgrade compatibility is release-specific; release notes state whether a downgrade is safe once persistent scenes/schedules exist.

Do not remove and re-add the project instance unless a release specifically requires it.

## API

The LAN API is a standard REST API described by **[`api/openapi.yaml`](api/openapi.yaml)** (OpenAPI 3.1) — see **[`api/README.md`](api/README.md)** for conventions and examples.

```bash
curl http://<controller-ip>:41999/v1/lights -H "Authorization: Bearer <api key>"
curl -X PATCH http://<controller-ip>:41999/v1/lights/259 \
  -H "Authorization: Bearer <api key>" -H "Content-Type: application/json" \
  -d '{"brightness": 40}'
```

Resources: system, rooms, devices, lights, thermostats, logs, API keys. The running bridge serves its own description at `/v1/openapi.json`, so Postman, Swagger UI or Home Assistant can import it, and the app's **API console** lists and tries every endpoint.

## Design principle

DirectorLink depends on **Director**, not Composer.

```text
Cloudflare Pages PWA
        |
        | Local Network Access permission
        v
Browser / any API client
        |
        | LAN only, API key
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
app/       PWA: dashboard and API console (deployed by Cloudflare Pages from this folder)
scripts/   build and validation
docs/      specification, decisions, research, releases
```

See **[`docs/BUILD.md`](docs/BUILD.md)** for building, testing and releasing, and **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** for how the pieces fit.

## Live app

**https://app.directorlink.io**

## Status

Early development (`0.x`). The API is described and versioned, but may still change between minor releases.

## Disclaimer

DirectorLink is an independent open-source project and is not affiliated with or endorsed by Control4 or Snap One.

Installing third-party drivers or modifying a Control4 project can introduce compatibility, support, warranty, or recovery risks. Users are responsible for understanding those risks and should keep appropriate backups of their Control4 project.

## License

DirectorLink is licensed under the **Apache License 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
