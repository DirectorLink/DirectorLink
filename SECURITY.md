# Security

DirectorLink controls homes: lights, climate, cameras, and doors and gates, and can show whether the alarm is armed. Security reports are welcome and are handled first.

## Reporting a problem

Please report privately, on GitHub: **Security → Report a vulnerability** in this repository. If you cannot, open an issue that says only that you have something to report, without the details, and we will find a private way.

Say what you found, where (file and line, or the request), and what someone could do with it. A report from reading the code is as welcome as one tested on a controller. Please do not test against homes or accounts that are not yours.

## Supported versions

Fixes go into the latest release. The Composer driver, the app (app.directorlink.io) and the cloud (api.directorlink.io) are updated together; the app and the cloud update themselves, the driver is updated in Composer.

## How DirectorLink is protected

- `docs/ACCOUNTS.md`: the end-to-end lock, pairing, claiming a home, invitations, and **what the lock does not protect**.
- `docs/RELAY.md`: the controller's connection to the cloud.
- `docs/DECISIONS.md`: ADR-025 (roles and Door Control), ADR-028 (stored keys), ADR-029 (accounts and the lock), ADR-032 (the 1.0.0 security fixes), ADR-036 (door relays pulse-only), ADR-038 (the alarm's status: off by default, read-only, never for viewers, sealed only), ADR-039 (pairing never sends the code: CPace), ADR-040 (the API console's own key lasts a day), ADR-041 (Sign in with Apple; another email joins only with the owner's approval, checked with a code; Apple's account notifications).
- `directorlink.io/privacy`: what the cloud stores.
