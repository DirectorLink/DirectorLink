# Roadmap

What is done is in the release notes: [`docs/releases/`](releases/), newest [v1.3.0](releases/v1.3.0.md). This page lists only what is still to come.

## 1.4.0 (in progress)

- **Backup and restore:** admins download a backup of everything DirectorLink keeps (scenes, schedules, each person's settings, room names and order, which devices have access, the link to the account), locked with a password in the browser, and restore it after the driver was removed, the controller replaced or the project rebuilt.

- **Driver settings in the app:** admins change, in the app, the settings that are safe to change there:
  - the Jewish calendar on or off;
  - schedules on or paused;
  - the log level;
  - Refresh Project.

  Admins also see the Inventory, the statuses and the schedules-and-scenes printout there.

  Door Control, Relay Hold, Remote Access, Alarm Status and the emergency actions (New Pairing Code, Revoke All API Keys, Reset Remote Identity) stay in Composer only.

  When a setting changes in the app, the driver updates its own Composer property, so Composer shows the same value, and every change is logged with who made it.

## Later

- An automatic daily backup to the home's account, locked end to end like remote access.
- Releases signed on GitHub, the signature checked by the driver in plain Lua (the minimum OS stays 3.3.0).
- Fans with other than four speeds, from the fan's own speed list.
- Better diagnostics for devices DirectorLink does not support yet.
- KNX percentage dimming ([#11](https://github.directorlink.io/issues/11)).

## Not planned

- **Installing driver updates from the app, or automatically.** A driver can only replace itself through a way around Control4's file protection that Control4 does not document. Updates stay in Composer, with the app's guided notice (ADR-035).
- Editing the Control4 project (Composer programming, its scenes and schedules), and plugins.
