# Roadmap

What is done is in the release notes: [`docs/releases/`](releases/), newest [v1.8.0](releases/v1.8.0.md). This page lists only what is still to come.

## Next: 1.9

- **Users and their devices.** "People" become **users**, on one screen, Settings → Users: each user with a name, Admin or Member and their access, and under them every device they connected (when each was last used, and Remove).
  - **One user, one set of permissions.** Two people who share one Google account are one user.
  - **Remote access:** a user adds a Google or Apple account. Every device signed in to that account belongs to that user and follows their permissions. A user without an account is allowed (a child's iPad, a kitchen tablet, a script), on the home network only.
  - **Up to 5 devices a user:** a sixth is refused with "Remove a device first", listing their devices with when each was last used.
  - **Devices of the same account become one user by themselves.** That includes users 1.8.0 split by device, such as an owner's computer and iPhone, which become one user with the owner's permissions.
  - **Pairing at home** asks which user the new device is for, instead of making a new user for each device.
  - The API keeps its names (`/v1/profiles`, `profile_id`) for existing apps and scripts.
- **Say or type a command.** A field in the app, with the microphone where the browser has one (on iPhone the keyboard's dictation), that understands simple sentences in English and Hebrew ("kitchen lights off", "living room AC to 23", "run Good night") by the user's own room, device and scene names, on the phone, without AI; within the user's rooms and permissions.
- **Later, an assistant (opt-in).** An AI that understands any sentence and proposes the actions to confirm, with the home's own AI key, called from the phone so that DirectorLink's servers never see it; its own privacy note first, because names and requests would reach the AI's company.

## Later

- Handing the home's ownership to another admin (today: Composer's Revoke All API Keys, and the next admin paired becomes the owner).
- A member's own new device approved by that member, not only by an admin (the controller then makes the invitation).
- Alerts that stay on when the app starts while the home can't be reached, and are confirmed at the next start.
- Releases signed on GitHub, the signature checked by the driver in plain Lua (the minimum OS stays 3.3.0).
- Fans with other than four speeds, from the fan's own speed list.
- Better diagnostics for devices DirectorLink does not support yet.
- KNX percentage dimming ([#11](https://github.directorlink.io/issues/11)).

## Not planned

- **Installing driver updates from the app, or automatically.** A driver can only replace itself through a way around Control4's file protection that Control4 does not document. Updates stay in Composer, with the app's guided notice (ADR-035).
- Editing the Control4 project (Composer programming, its scenes and schedules), and plugins.
- Changing DirectorLink's Composer settings from the app (built for 1.4.0, withdrawn: they stay in Composer).
