# Roadmap

What is done is in the release notes: [`docs/releases/`](releases/), newest [v1.2.0](releases/v1.2.0.md). This page lists only what is still to come.

## 1.3.0 (in progress)

- **The pairing code is never sent.** The app and the controller use the code to lock their key exchange (CPace), so someone who changes traffic during pairing can only make it fail (ADR-039).
- **The API console's key expires after 24 hours.** It travels unprotected on the home network; an old console key stops working 24 hours after the update (ADR-040).
- **Find my controller:** the app's pairing screen looks for the controller in the address ranges homes use, instead of typing its address.
- **Sign in with Apple**, with the owner's approval for a join whose email does not match the invitation (Apple can hide the email), and Apple's account notifications (ADR-041).

## Later

- Releases signed on GitHub, the signature checked by the driver in plain Lua (the minimum OS stays 3.3.0).
- Fans with other than four speeds, from the fan's own speed list.
- Better diagnostics for devices DirectorLink does not support yet.
- KNX percentage dimming ([#11](https://github.directorlink.io/issues/11)).

## Not planned

- **Installing driver updates from the app, or automatically.** A driver can only replace itself through a way around Control4's file protection that Control4 does not document. Updates stay in Composer, with the app's guided notice (ADR-035).
- Editing the Control4 project (Composer programming, its scenes and schedules), and plugins.
