# Roadmap

What is done is in the release notes: [`docs/releases/`](releases/), newest [v1.7.0](releases/v1.7.0.md). This page lists only what is still to come.

## Next

- **Camera pictures at the same time.** The app asks for several pictures at once instead of one after another, and the controller fetches them side by side inside the home, a few at a time per camera and per NVR (an NVR's channels share one device). The controller keeps a camera's login challenge between pictures, so each picture is one request to the camera instead of two, and tiles showing the same camera share one picture. Measured first, on a real controller, through the account and at home.
- **Sonos in scenes:** a scene (and so a schedule) plays a Sonos favorite in a room at a chosen volume, sets the volume, or resumes, besides pausing and stopping. Only favorites saved in Sonos, and no grouping (ADR-044).
- **Older drivers can be turned away.** The account service already knows which DirectorLink version each home runs; it gets a minimum version it enforces, so that if a flaw is found in the remote protocol, drivers without the fix stop connecting until they are updated, and the app and Composer say so.

## Later

- A notification when a new device asks to join, so the approving device need not have the app open.
- A member's own new device approved by that member, not only by an admin (the controller then makes the invitation).
- Alerts that stay on when the app starts while the home can't be reached, and are confirmed at the next start.
- Refrigerators: switches only for the features the model has, once the refrigerator driver reports them.
- Releases signed on GitHub, the signature checked by the driver in plain Lua (the minimum OS stays 3.3.0).
- Fans with other than four speeds, from the fan's own speed list.
- Better diagnostics for devices DirectorLink does not support yet.
- KNX percentage dimming ([#11](https://github.directorlink.io/issues/11)).

## Not planned

- **Installing driver updates from the app, or automatically.** A driver can only replace itself through a way around Control4's file protection that Control4 does not document. Updates stay in Composer, with the app's guided notice (ADR-035).
- Editing the Control4 project (Composer programming, its scenes and schedules), and plugins.
- Changing DirectorLink's Composer settings from the app (built for 1.4.0, withdrawn: they stay in Composer).
