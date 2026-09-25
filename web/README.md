# C4Bridge Web PWA

This directory is the Cloudflare Pages frontend for C4Bridge.

## Current status

The PWA shell is implemented:

- responsive UI
- installable web-app manifest
- offline shell via service worker
- local Director address storage
- browser/security diagnostics
- architecture/status screen

The LAN transport is intentionally **not implemented yet**. The browser cannot speak the DriverWorks TCP server directly, so C4Bridge must first expose a browser-compatible authenticated HTTP/WebSocket endpoint on Director.

## Cloudflare Pages settings

Connect the GitHub repository `IsraelCIL/C4Bridge` to Cloudflare Pages with:

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Framework preset | None |
| Root directory | `web` |
| Build command | `exit 0` |
| Build output directory | `.` |

No environment variables are required for the current shell.

After the first deployment, attach:

- `c4bridge.io` as the production custom domain
- optionally `www.c4bridge.io`, redirected to `c4bridge.io`

## Local Network Access

The production site must be served over HTTPS. Modern Chromium browsers gate requests from a public HTTPS origin to local-network devices behind Local Network Access permission.

The future C4Bridge transport must:

1. be initiated by an explicit user action;
2. target the user-configured Director IP/local hostname;
3. handle CORS correctly;
4. handle browser Local Network Access requirements;
5. authenticate every C4Bridge request;
6. never rely on a cloud relay for normal V1 control.

The service worker intentionally ignores all cross-origin requests so LAN traffic is never cached or proxied by the PWA.
