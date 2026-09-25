# Cloudflare Pages Setup

C4Bridge uses Cloudflare Pages only to host the static PWA. Cloudflare is **not** in the Control4 command path.

## Target architecture

```text
app.c4bridge.io
    |
    | HTTPS static assets
    v
Cloudflare Pages
    |
    v
Browser / installed PWA
    |
    | Local Network Access permission
    | authenticated local connection
    v
C4Bridge.c4z on Director
```

Normal V1 control traffic is intended to stay between the browser and the Director on the user's LAN.

## One-time Cloudflare setup

In the Cloudflare dashboard:

1. Open **Workers & Pages**.
2. Choose **Create application**.
3. Choose **Pages**.
4. Choose **Import an existing Git repository**.
5. Connect GitHub if needed.
6. Select **IsraelCIL/C4Bridge**.
7. Configure:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | None |
| Root directory | `web` |
| Build command | `exit 0` |
| Build output directory | `.` |

8. Deploy.

Cloudflare will create a temporary `*.pages.dev` URL and automatically deploy new commits to `main`. Pull requests can receive preview deployments.

## Custom domain

After the first successful Pages deployment:

1. Open the Pages project.
2. Go to **Custom domains**.
3. Add **app.c4bridge.io**.
4. Because the domain is already managed in the same Cloudflare account, allow Cloudflare to configure the required DNS record.
5. Optionally add **www.app.c4bridge.io**.

The canonical production origin for the application should be:

```text
https://app.app.c4bridge.io
```

## Build watch paths

The repository also contains the Control4 driver and documentation. To avoid unnecessary Pages deployments, Cloudflare Pages can later be configured to build only when web files change.

Recommended include path:

```text
web/*
```

This optimization is optional; it is not required for correctness.

## Local Network Access

The public site is served over HTTPS. Browser requests from a public origin to a private/local network are security-sensitive and are gated by Local Network Access rules in modern Chromium.

The future Director transport should:

- be initiated by a clear user action;
- use the saved Director IP or `.local` hostname;
- support browser CORS behavior;
- support Local Network Access permission;
- authenticate every request;
- never expose raw Control4 commands to the browser;
- not be intercepted/cached by the service worker.

The current PWA shell does **not** attempt a Director connection until the DriverWorks LAN endpoint is implemented and tested.
