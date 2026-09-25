# C4Bridge

C4Bridge is an open-source, local-first management layer for Control4 homeowners.

The goal is to provide simple device control, scenes, schedules, and everyday automation without requiring homeowners to use Composer Pro for routine changes.

## V1 scope

- Control4 Director OS **3.3.0+**
- `C4Bridge.c4z` is assumed to already be installed in the Control4 project
- Installation method is outside the scope of this project
- Cloudflare Pages PWA frontend
- Browser connects directly to C4Bridge over the local LAN
- LAN-only in V1; no cloud relay and no port forwarding
- One owner account
- Pairing + authenticated local API
- Initial device adapters: lights, HVAC/climate, shades/covers
- Unknown devices are exposed as `unsupported`
- C4Bridge owns its own scenes, schedules, and automations
- No import of Composer programming, scenes, or schedules
- Fixed-time, weekday, sunrise/sunset, and offset scheduling
- Director location/timezone used for solar scheduling
- No automatic `.c4z` self-update in V1

## Installation

C4Bridge itself does not depend on Composer Pro during normal operation. Composer is only one way to install the `C4Bridge.c4z` driver into a Control4 project.

### 1. Download C4Bridge

Download C4Bridge from **[GitHub Releases](https://github.com/IsraelCIL/C4Bridge/releases)**.

Current alpha build after this change lands: **C4Bridge v0.1.0-alpha.9**

Each release keeps its own `C4Bridge.c4z`, release notes, and SHA-256 checksum so users can upgrade or downgrade to a specific version.

### 2. Install Composer Pro

If you need Composer Pro for the initial driver installation, this project currently provides the following Control4-hosted installer link:

**Composer Pro 2026.3.18.506**

https://update2.control4.com/release/2026.3.18.506-res+Composer/win/ComposerPro-2026.3.18.506-res.exe

C4Bridge does not depend on this specific Composer version after the driver has been installed.

### 3. Add the driver to Composer

1. Open Composer Pro and connect to your Director.
2. In the top menu, choose **Driver → Add or Update Driver**.
3. Select `C4Bridge.c4z`.
4. Go to **System Design**.
5. Select any room in the project tree. C4Bridge only needs one instance in the project; the room is not functionally important.
6. Open the **Search** tab in the Items pane.
7. Make sure **Local** drivers are included and search for **C4Bridge**.
8. Double-click or drag **C4Bridge** into the selected room.
9. Select the C4Bridge device and check its Properties.

For the current discovery build, a successful install should show:

- **Bridge Version:** current C4Bridge build
- **Status:** `Ready (discovery complete)`
- **Director Version:** your Director OS version
- **System Type:** controller type reported by Director
- **Project Location:** project city/country when configured
- **Discovery Summary:** number of rooms, normalized devices, protocol drivers, recognized proxy types, and unsupported devices

If the status shows an error, capture the C4Bridge Lua log and open a GitHub issue.

### Updating C4Bridge

Automatic self-update is intentionally **not** part of V1.

For now, update the installed driver manually through Composer Pro using the `C4Bridge.c4z` asset from the desired GitHub Release.

**Important:** before updating, make sure the local file is named exactly `C4Bridge.c4z`. Do not select `C4Bridge (1).c4z`, `C4Bridge (2).c4z`, etc. A real Director snapshot showed those suffixed filenames can be installed as separate driver files instead of replacing the canonical package.

To downgrade, download `C4Bridge.c4z` from an older release and install that version through Composer Pro. Downgrade compatibility is release-specific; once C4Bridge begins storing persistent scenes/schedules/accounts, release notes will state whether a downgrade is safe.

Do not remove and re-add the project instance unless a release specifically requires it.

## Design principle

C4Bridge depends on **Director**, not Composer.

```text
Cloudflare Pages PWA
        |
        | Local Network Access permission
        v
Browser
        |
        | LAN only
        v
C4Bridge.c4z
        |
        v
Control4 Director
        |
        v
Existing Control4 devices
```

## Live web app

**https://app.c4bridge.io**

The alpha.9 build keeps one-owner pairing and adds the first Thermostat V2 climate adapter with live state, HVAC mode, fan mode, and Celsius single-setpoint control.

## Web app

The C4Bridge PWA source lives in [`web/`](web/). It is a framework-free static application intended for Cloudflare Pages.


The current alpha web build includes the installable/offline application shell, Director onboarding, Local Network Access permission, one-time owner pairing, authenticated LAN control, and live room/device/light discovery from Director.

## First milestone

1. Detect Director version and reject versions below 3.3.0.
2. Read system/project metadata.
3. Discover rooms and devices.
4. Preserve Control4 proxy/protocol relationships.
5. Normalize discovered entities into an internal registry.
6. Classify known proxies and mark everything else as unsupported.
7. Add light state/control only after discovery is reliable.

## Status

Early development. The protocol and driver internals are not yet stable.

## Disclaimer

C4Bridge is an independent open-source project and is not affiliated with or endorsed by Control4 or Snap One.

Installing third-party drivers or modifying a Control4 project can introduce compatibility, support, warranty, or recovery risks. Users are responsible for understanding those risks and should keep appropriate backups of their Control4 project.


## License

C4Bridge is licensed under the **Apache License 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
