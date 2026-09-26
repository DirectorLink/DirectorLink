# Building and testing C4Bridge

A C4Z is a ZIP-based Control4 driver package. C4Bridge packages `driver.xml`, `driver.lua` and the Lua modules under `driver/src/` at the archive root, plus the API description generated from `api/openapi.yaml`.

## Tools

- Python 3 with `pip install -r requirements-dev.txt` (PyYAML, openapi-spec-validator)
- Lua 5.1 (`lua5.1`, `luac5.1`) for syntax checks and the driver tests
- Node.js for the web JavaScript syntax check

## Everything CI runs

From the repository root:

```bash
find driver -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p   # Lua syntax
lua5.1 driver/tests/run.lua                                    # driver tests (fake Director)
python scripts/check_api.py                                    # spec is valid and matches the driver routes
python scripts/build.py                                        # dist/C4Bridge.c4z + dist/openapi.json
python scripts/check_package.py                                # package contents and contracts
python scripts/check_contract.py                               # real HTTP responses vs the spec
python scripts/check_web.py                                    # web app
for f in web/*.js; do node --check "$f"; done                  # web JavaScript syntax
```

## Package layout

```text
driver.xml
driver.lua
src/
  main.lua
  api/        HTTP server, router, handlers, generated openapi_spec.lua
  auth/       API keys and pairing
  adapters/   lights, thermostats
  control4/   discovery and normalization
  core/       json, log, registry, version
```

No Lua squishing or encryption is used, so package contents and errors stay easy to inspect. The build is reproducible: the same source produces the same package bytes. The source manifest `driver/C4Bridge.c4zproj` is kept for Snap One's Driver Packager, but official builds come from `scripts/build.py`.

## Driver tests

`driver/tests/` runs the real driver against a fake Director (`c4mock.lua`) in plain Lua 5.1. Requests go in as raw bytes through `OnServerDataIn`, exactly as on a controller, and the tests check responses, error codes, the Control4 commands each change produces, CORS, authentication, logging and that secrets never reach the log.

`scripts/check_contract.py` goes one step further: it serves the same driver on a local TCP port, calls every operation with a real HTTP client, and validates each response's status, Content-Type and body against `api/openapi.yaml`. It fails if any operation in the spec is not exercised.

## Local dev server

To work on the web app or an API client without a controller:

```bash
python scripts/build.py                        # optional: serve the real API description
python scripts/dev_server.py                   # driver + fake Director on http://localhost:41999
python -m http.server 8080 --directory web     # web app on http://localhost:8080
```

Use `localhost` as the controller address and the pairing code the dev server prints. The fake project has two rooms, three lights and one thermostat; commands are recorded but not executed.

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
C4Bridge.c4z
openapi.json
SHA256SUMS.txt
```

Release notes come from `docs/releases/v<version>.md`. The workflow refuses to replace an existing release.

## Minimum Director version

`driver.xml` declares `<minimum_os_version>3.3.0</minimum_os_version>` and the driver also checks the version at runtime.
