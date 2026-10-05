# Roadmap

What is done is in the release notes: [`docs/releases/`](releases/), newest [v1.9.0](releases/v1.9.0.md). This page lists only what is still to come.

## Next

- **Every DirectorLink camera driver on one agreement, and UniFi Protect.** DirectorLink recognizes a camera driver of DirectorLink Drivers by a marker the driver sets, not by its file name, so any such driver works without new code in DirectorLink:
  - its detections are camera alerts ("Person at Garden at 21:14"), as the Hikvision driver's are today;
  - a doorbell camera's ring is a doorbell ring, with Home's banner and the ring alert;
  - its pictures are in the Cameras grid.

  The Hikvision drivers keep working (recognized by their file names too, until they set the marker).

  A new free driver, **DirectorLink · UniFi Protect for Control4**, in its own repository:
  - it works through Ubiquiti's official Protect API, with an API key from the UniFi console (no username or password);
  - it offers the console's cameras and doorbells, their pictures and live video, and their detections and rings.

  Tested with a client's UniFi system through their Director logs before release, since the owner has no UniFi hardware.
- **An assistant (opt-in).** An AI that understands any sentence and proposes the actions to confirm, with the home's own AI key, called from the phone so that DirectorLink's servers never see it; its own privacy note first, because names and requests would reach the AI's company.
- **Commands that do more:** two things in one sentence, and relative changes ("warmer", "a bit brighter"), still without AI.

## Later

- Alerts that stay on when the app starts while the home can't be reached, and are confirmed at the next start.
- Releases signed on GitHub, the signature checked by the driver in plain Lua (the minimum OS stays 3.3.0).
- Fans with other than four speeds, from the fan's own speed list.
- Better diagnostics for devices DirectorLink does not support yet.
- KNX percentage dimming ([#11](https://github.directorlink.io/issues/11)).

## Not planned

- **Installing driver updates from the app, or automatically.** A driver can only replace itself through a way around Control4's file protection that Control4 does not document. Updates stay in Composer, with the app's guided notice (ADR-035).
- Editing the Control4 project (Composer programming, its scenes and schedules), and plugins.
- Changing DirectorLink's Composer settings from the app (built for 1.4.0, withdrawn: they stay in Composer).
