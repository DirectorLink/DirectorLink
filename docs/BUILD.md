# Building C4Bridge.c4z

A C4Z is a ZIP-based Control4 driver package. C4Bridge packages `driver.xml`, `driver.lua`, and the Lua modules under `driver/src/` at the archive root.

## Recommended local build

From the repository root:

```bash
python scripts/build.py
```

Output:

```text
dist/C4Bridge.c4z
```

The archive layout is:

```text
driver.xml
driver.lua
src/
  main.lua
  core/
  control4/
  adapters/
```

## Driver Packager

The source manifest is also retained at:

```text
driver/C4Bridge.c4zproj
```

so the project can be opened/packaged with Snap One's Driver Packager tooling if desired.

No Lua squishing or encryption is used during early development so package contents and errors remain easy to inspect.

## Minimum Director version

The driver declares:

```xml
<minimum_os_version>3.3.0</minimum_os_version>
```

and also performs a runtime version check.

## Release policy

During early development, `dist/C4Bridge.c4z` may be committed as a convenience test build. Source files remain authoritative; the package should always be reproducible with `scripts/build.py`.
