#!/usr/bin/env python3
"""Build the C4Bridge Control4 driver package."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

REPO_ROOT = Path(__file__).resolve().parents[1]
DRIVER_ROOT = REPO_ROOT / "driver"
OUTPUT_DIR = REPO_ROOT / "dist"
OUTPUT_FILE = OUTPUT_DIR / "C4Bridge.c4z"

REQUIRED = [
    DRIVER_ROOT / "driver.xml",
    DRIVER_ROOT / "driver.lua",
]


def package_files():
    for path in REQUIRED:
        if not path.is_file():
            raise FileNotFoundError(f"Missing required driver file: {path}")

    yield from REQUIRED

    src = DRIVER_ROOT / "src"
    if not src.is_dir():
        raise FileNotFoundError(f"Missing source directory: {src}")

    for path in sorted(src.rglob("*.lua")):
        yield path


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    with ZipFile(OUTPUT_FILE, "w", compression=ZIP_DEFLATED) as archive:
        for path in package_files():
            archive.write(path, path.relative_to(DRIVER_ROOT).as_posix())

    print(f"Built {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
