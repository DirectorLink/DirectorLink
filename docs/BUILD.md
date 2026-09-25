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

Built `.c4z` files are **not committed to `main`**.

The repository source is authoritative. Every official build is produced by GitHub Actions from the versioned source and attached to a GitHub Release.

Release assets:

```text
C4Bridge.c4z
SHA256SUMS.txt
```

The release version is stored in the repository root `VERSION` file. Updating `VERSION` on `main` triggers the release workflow, which:

1. verifies the source version matches `VERSION`;
2. builds `C4Bridge.c4z`;
3. validates the package;
4. calculates SHA-256;
5. creates the `v<version>` Git tag;
6. creates the GitHub Release;
7. uploads the driver and checksum.

Versions containing a hyphen, for example `0.1.0-alpha.1`, are published as GitHub prereleases.
