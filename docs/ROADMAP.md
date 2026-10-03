# Roadmap

What is done is in the release notes: [`docs/releases/`](releases/), newest [v1.6.0](releases/v1.6.0.md). This page lists only what is still to come.

## Next: 1.7.0

- Samsung refrigerators (the DirectorLink Samsung Refrigerator driver for Control4): temperatures, doors and the water filter in the app; Power Cool, Power Freeze, Ice Maker and Sabbath Mode as controls, in scenes and in Shabbat schedules.
- DirectorLink in numbers on the website: homes and people using an account, and driver downloads. The account service counts them once an hour and gives totals only (never anything about one home); directorlink.io shows them once there are 25 homes. Nothing new leaves a home: no device counts.
- Scene links: a private link per scene for the phone's own automations (iPhone Shortcuts "when I arrive home", Android automation apps, Siri, NFC tags). Scenes that open doors or gates get none; links can be revoked, and every run is in History.

## Later

- Releases signed on GitHub, the signature checked by the driver in plain Lua (the minimum OS stays 3.3.0).
- Fans with other than four speeds, from the fan's own speed list.
- Better diagnostics for devices DirectorLink does not support yet.
- KNX percentage dimming ([#11](https://github.directorlink.io/issues/11)).

## Not planned

- **Installing driver updates from the app, or automatically.** A driver can only replace itself through a way around Control4's file protection that Control4 does not document. Updates stay in Composer, with the app's guided notice (ADR-035).
- Editing the Control4 project (Composer programming, its scenes and schedules), and plugins.
- Changing DirectorLink's Composer settings from the app (built for 1.4.0, withdrawn: they stay in Composer).
