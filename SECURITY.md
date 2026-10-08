# Security

DirectorLink controls homes: lights, climate, cameras, and doors and gates, and can show whether the alarm is armed. Security reports are welcome and are handled first.

## Reporting a problem

Please report privately, on GitHub: **Security → Report a vulnerability** in this repository. If you cannot, open an issue that says only that you have something to report, without the details, and we will find a private way.

Say what you found, where (file and line, or the request), and what someone could do with it. A report from reading the code is as welcome as one tested on a controller. Please do not test against homes or accounts that are not yours.

## Supported versions

Fixes go into the latest release. The Composer driver, the app (app.directorlink.io) and the cloud (api.directorlink.io) are updated together; the app and the cloud update themselves, the driver is updated in Composer.

## Verify what you are served

The app, the console and the website are static files from this repository, published only by GitHub Actions after the owner approves each deploy (ADR-075). Each site serves `/build.json`, the commit it was built from. To check that the commit is on `main` and that every file the sites serve, their headers and redirects, and the short link, are exactly the source:

```bash
node scripts/verify_live.mjs
```

Node 22 or later, nothing to install, no secrets: in a clone it reads the clone, anywhere else the public repository on GitHub. Exit code 0 means everything served is the same as the source; otherwise the report says what differs, or what could not be checked. The same check runs every hour (`.github/workflows/watch-live.yml`) and opens the issue "The live site differs from the source" when something differs. If it finds a difference you did not expect, please report it privately, as above.

## How DirectorLink is protected

- `docs/ACCOUNTS.md`: the end-to-end lock, pairing, claiming a home, invitations, and **what the lock does not protect**.
- `docs/RELAY.md`: the controller's connection to the cloud.
- `docs/DECISIONS.md`: ADR-025 (roles and Door Control), ADR-028 (stored keys), ADR-029 (accounts and the lock), ADR-032 (the 1.0.0 security fixes), ADR-036 (door relays pulse-only), ADR-038 (the alarm's status: off by default, read-only, never for viewers, sealed only), ADR-039 (pairing never sends the code: CPace), ADR-040 (the API console's own key lasts a day), ADR-041 (Sign in with Apple; another email joins only with the owner's approval, checked with a code; Apple's account notifications), ADR-042 (backups: a backup holds every key's lock key and the home secret, so it goes only in sealed requests and is saved only encrypted with a password; a restore brings no revoked key back, and moves another home's identity only when asked), ADR-075 (deploys and releases only after the owner's approval; the hourly public check of what is served).
- `directorlink.io/privacy`: what the cloud stores.
