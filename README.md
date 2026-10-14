# DirectorLink

**Direct to Director. End-to-end integration. Open source.**

DirectorLink is an open-source, local-first management layer for Control4 homeowners: simple device control, scenes, schedules and everyday automation, without Composer Pro for routine changes.

> **DirectorLink is an independent project, not affiliated with Control4 or Snap One.**

**See it first:** [try the app on a demo home](https://directorlink.io/try/), with made-up rooms and devices, in your browser. Nothing to install.

## What it does

- **Every device in one app:** lights and dimmers, AC and floor heating, fans, blinds, cameras, doorbells, doors and gates (a second tap to open), Sonos, Samsung refrigerators and the alarm's status (read only).
- **At home and away:** at home the app talks to the controller directly; away it goes through your Google or Apple account, locked end to end so DirectorLink's servers can't read it ([`docs/ACCOUNTS.md`](docs/ACCOUNTS.md)).
- **Scenes and schedules:** one tap for many devices; by the clock, sunrise and sunset, and the weather. The controller runs them on its own ([`docs/SCENES.md`](docs/SCENES.md), [`docs/SCHEDULES.md`](docs/SCHEDULES.md)).
- **Say or type a command:** *kitchen lights off*, *living room AC to 23*, in English, Hebrew, Spanish or Italian, understood on your phone without AI.
- **Geofencing and Siri:** a private link per scene for iPhone Shortcuts, Android automation apps and NFC tags ([`docs/SCENES.md`](docs/SCENES.md#links-for-automations-170-adr-051)).
- **Alerts:** doorbell rings, camera detections, doors opened, the home offline and more, on phones, computers and the home's TVs ([`docs/NOTIFY_DRIVERS.md`](docs/NOTIFY_DRIVERS.md)).
- **The family:** admins and members, each with their own rooms, devices, scenes, language and favorites, and up to five devices.
- **History and backups:** what ran and who opened which door for 30 days; backups locked with your password, also every night to your account ([`docs/HISTORY.md`](docs/HISTORY.md), [`docs/BACKUP.md`](docs/BACKUP.md)).
- **An API:** REST, described by OpenAPI 3.1, with a key and a role for every app or script ([below](#api)).
- **More drivers:** free, open-source [DirectorLink Drivers](https://directorlink.io/drivers) for DoorBird, Hikvision, UniFi Protect, LG and Android TVs, and Samsung appliances.

It needs Control4 OS 3.3.0 or newer, works on the home network first, and keeps its own scenes and schedules: it doesn't change or import your Composer programming. More in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Installation

You need **Composer Pro** to add DirectorLink to your project and to update it; after that the app, scenes and schedules never need Composer. Every step, property and action is in **[`docs/INSTALL.md`](docs/INSTALL.md)**.

1. **Download** `DirectorLink.c4z` from **[GitHub Releases](https://github.directorlink.io/releases)**.
2. **Get Composer Pro** (a Control4 account with Composer access), or ask your Control4 installer to add DirectorLink.
3. **Add the driver:** in Composer, Driver → Add or Update Driver → `DirectorLink.c4z`, then drag **DirectorLink** into any room. Its Properties show `Ready` and a **Pairing Code**.
4. **Pair:** open **https://app.directorlink.io** on a computer or an Android phone at home, and enter the controller's address and the pairing code. iPhones and iPads join through the account afterwards ([`docs/INSTALL.md`](docs/INSTALL.md#4-pair-the-owners-device)).

**Updating:** install the new `DirectorLink.c4z` the same way in Composer; the app tells admins when one is out. Keep the file name exactly `DirectorLink.c4z`: a browser's `DirectorLink (1).c4z` installs as a separate driver.

## API

The local API is described by **[`api/openapi.yaml`](api/openapi.yaml)** (OpenAPI 3.1); see **[`api/README.md`](api/README.md)** for conventions and examples, and the API console at https://console.directorlink.io.

```bash
curl http://<controller-ip>:41999/v1/lights -H "Authorization: Bearer <api key>"
```

Give each script its own key, as a user with only the rooms and devices it needs. The app never sends its key: it seals every request.

## Repository

```text
api/         OpenAPI contract
driver/      DriverWorks driver (Lua 5.1) and its tests
app/         the app (PWA)                       → https://app.directorlink.io
console/     API console, debugging and logs      → https://console.directorlink.io
site/        website                              → https://directorlink.io
github-link/ short link to this repository        → https://github.directorlink.io
cloud/       accounts and the relay (Worker)      → https://api.directorlink.io
tests/       app and cloud tests, shared vectors
scripts/     build and validation
docs/        specification, decisions, research, releases
```

See **[`docs/BUILD.md`](docs/BUILD.md)** for building, testing and releasing, **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** for how the pieces fit, and **[`SECURITY.md`](SECURITY.md)** for reporting a security problem.

## Built on Control4's DriverWorks API

DirectorLink is a Lua driver for Control4's DriverWorks platform. It runs inside Director like any other driver and is added and updated with Composer Pro.

- Every DriverWorks function it calls is described in Snap One's public [DriverWorks API reference](https://snap-one.github.io/docs-driverworks-api/), and devices are controlled through their Control4 proxies. The few details not in the public guides are listed in [`docs/RESEARCH.md`](docs/RESEARCH.md#outside-the-public-guides).
- It changes nothing in Control4's software, licensing or Composer programming, and does not use Control4's cloud services.
- It is not certified, reviewed or endorsed by Control4 or Snap One.

## Status

Used every day in a real home. The API is versioned: 1.x releases add to `/v1` without breaking existing clients. The roadmap is [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Disclaimer

DirectorLink is an independent project, not affiliated with Control4 or Snap One. It is open source and is not endorsed by Control4 or Snap One. Control4 and DriverWorks are trademarks of Snap One, LLC, named here only to describe compatibility.

## License

DirectorLink is licensed under the **Apache License 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
