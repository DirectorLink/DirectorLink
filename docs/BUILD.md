# Building and testing DirectorLink

A C4Z is a ZIP-based Control4 driver package. DirectorLink packages `driver.xml`, `driver.lua` and the Lua modules under `driver/src/` at the archive root, plus the API description generated from `api/openapi.yaml`.

## Tools

- Python 3 with `pip install -r requirements-dev.txt` (PyYAML, openapi-spec-validator, jsonschema)
- Lua 5.1 (`lua5.1`, `luac5.1`) for syntax checks and the driver tests
- Node.js 22 for the JavaScript syntax check and the app tests; the cloud tests also run `wrangler dev` (`npx wrangler@4.143.0`)

## Everything CI runs

From the repository root:

```bash
find driver -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p   # Lua syntax
lua5.1 driver/tests/run.lua                                    # driver tests (fake Director)
python scripts/check_repo.py                                   # no local tool configuration or secrets tracked
python scripts/check_api.py                                    # spec is valid and matches the driver routes
python scripts/build.py                                        # dist/DirectorLink.c4z + dist/openapi.json
python scripts/check_package.py                                # package contents and contracts
(cd dist && sha256sum DirectorLink.c4z openapi.json)           # checksums, compared with the release's
python scripts/check_contract.py                               # real HTTP responses vs the spec
python scripts/check_app.py                                    # the app
python scripts/check_sites.py                                  # console and landing page
find app console cloud -name '*.js' -print0 | xargs -0 -n1 node --check   # JavaScript syntax
node --test tests/app/*.test.mjs                               # app: lock, sealed requests, pairing code, offline mode, …
```

Not in CI (they start `wrangler dev`): `node --test tests/cloud/*.test.mjs`, the account service and relay against a local D1.

## Package layout

```text
driver.xml
driver.lua
src/
  main.lua
  api/        HTTP server, router, handlers, generated openapi_spec.lua
  auth/       API keys, roles, pairing, profiles, invitations
  adapters/   Light V2, Light V1 (legacy Light proxy), Thermostat V2, Control4 thermostat proxy,
              blinds, cameras, KNX Contact/Relay, DoorBird
  cloud/      relay connection, WebSocket, the end-to-end lock, sealed requests
  control4/   discovery and normalization
  core/       json, log, store, random, x25519, registry, version, scenes, schedules, sun, weather, …
certs/
  directorlink-roots.pem   the roots the relay's certificate is checked against (docs/RELAY.md)
www/
  icons/      the device's icons in Composer and the Control4 app
```

No Lua squishing or encryption is used, so package contents and errors stay easy to inspect. The source manifest `driver/DirectorLink.c4zproj` is kept for Snap One's Driver Packager, but official builds come from `scripts/build.py`.

## Checksums and reproducible builds

The build is byte-for-byte reproducible on every OS: fixed zip timestamps, a fixed "creating system" in the zip headers, and LF line endings in `openapi.json`. The same commit therefore produces the same SHA-256 on Windows, macOS and Linux, and `check_package.py` fails if a package breaks those rules.

To check that a file matches a release, compare it with that release's `SHA256SUMS.txt`:

```bash
sha256sum DirectorLink.c4z openapi.json          # or: certutil -hashfile DirectorLink.c4z SHA256
```

A package built locally from the release's commit gives the same values, and so does the installed package on a controller (`/mnt/internal/c4z/DirectorLink.c4z`). CI prints the checksums of every build in the "Show package checksums" step.

## Driver tests

`driver/tests/` runs the real driver against a fake Director (`c4mock.lua`) in plain Lua 5.1. Requests go in as raw bytes through `OnServerDataIn`, exactly as on a controller, and the tests check responses, error codes, the Control4 commands each change produces, CORS, authentication, logging and that secrets never reach the log.

`scripts/check_contract.py` goes one step further: it serves the same driver on a local TCP port, calls every operation with a real HTTP client, and validates each response's status, Content-Type and body against `api/openapi.yaml`. It fails if any operation in the spec is not exercised.

## Local dev server

To work on the app or an API client without a controller:

```bash
python scripts/build.py                        # optional: serve the real API description
python scripts/dev_server.py                   # driver + fake Director on http://localhost:41999
python -m http.server 8080 --directory app     # app on http://localhost:8080
```

Use `localhost` as the controller address and the pairing code the dev server prints. The fake project has two rooms, three lights, a thermostat, two blinds, two cameras, a DoorBird and a KNX door relay, and answers the weather itself; commands are recorded but not executed.

## Versions

`VERSION` holds `MAJOR.MINOR.PATCH` (for example `0.2.0`, no suffixes) and is the only file to edit for a release. The build stamps it into the package:

- `src/core/version.lua` → `Version.BRIDGE_VERSION = "0.2.0"` (the source keeps `"dev"`)
- `driver.xml` `<version>` → `MAJOR*10000 + MINOR*100 + PATCH` (0.2.0 → 200), the increasing integer Control4 uses for driver updates
- the embedded and published API description → `info.version`

## Release policy

Built `.c4z` files are not committed. Every official build is produced by GitHub Actions and attached to an immutable GitHub Release.

1. Work on a `dev/<feature>` branch and merge it to `main` through a pull request.
2. Changing `VERSION` on `main` triggers the release workflow, which runs the tests and checks, builds, and publishes the `v<version>` release with:

```text
DirectorLink.c4z
openapi.json
SHA256SUMS.txt
```

Release notes come from `docs/releases/v<version>.md`. The workflow refuses to replace an existing release.

## Deploying the sites

`.github/workflows/deploy.yml` publishes `app/`, `console/` and `site/` to Cloudflare Workers (static assets) with `wrangler deploy` whenever one of them changes on `main`; pull requests from this repository get preview versions. Each folder's `wrangler.jsonc` names its Worker and custom domain:

| Folder | Worker | Domain |
| --- | --- | --- |
| `app/` | `directorlink-app` | `app.directorlink.io` |
| `console/` | `directorlink-console` | `console.directorlink.io` |
| `site/` | `directorlink-site` | `directorlink.io`, `www.directorlink.io` |

The workflow needs two repository secrets: `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` (an API token for the account with *Workers Scripts: Edit* and, for the `directorlink.io` zone, *Workers Routes: Edit* and *DNS: Edit* — custom domains create their DNS records). Without them the jobs succeed and deploy nothing.

The workflows' actions are pinned to exact commits (Dependabot proposes updates, `.github/dependabot.yml`) and wrangler to an exact version. The cloud (`cloud/`) is not deployed by a workflow: see `cloud/README.md`.

The driver only answers browsers from `https://app.directorlink.io` and `https://console.directorlink.io` (since 1.0.0, not `localhost` either), so a preview URL can show a site but cannot talk to a controller. The dev server (`scripts/dev_server.py`) also allows `http://localhost` and `http://127.0.0.1`, for local testing.

## Minimum Director version

`driver.xml` declares `<minimum_os_version>3.3.0</minimum_os_version>` and the driver also checks the version at runtime.
