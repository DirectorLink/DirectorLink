#!/usr/bin/env python3
"""Static checks for the C4Bridge source/package."""

from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "driver"
PACKAGE = ROOT / "dist" / "C4Bridge.c4z"
VERSION_FILE = ROOT / "VERSION"
VERSION_SOURCE = DRIVER / "src" / "core" / "version.lua"
DRIVER_VERSION_FILE = ROOT / "DRIVER_VERSION"


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def source_files():
    files = {
        "driver.xml": DRIVER / "driver.xml",
        "driver.lua": DRIVER / "driver.lua",
    }
    for path in sorted((DRIVER / "src").rglob("*.lua")):
        files[path.relative_to(DRIVER).as_posix()] = path
    return files


def check_xml():
    path = DRIVER / "driver.xml"
    try:
        root = ET.parse(path).getroot()
    except Exception as exc:
        fail(f"driver.xml is not valid XML: {exc}")

    if root.tag != "devicedata":
        fail("driver.xml root must be <devicedata>")

    script = root.find("./config/script")
    if script is None or script.attrib.get("file") != "driver.lua":
        fail("driver.xml must load driver.lua")

    minimum = root.findtext("minimum_os_version")
    if minimum != "3.3.0":
        fail(f"minimum_os_version must be 3.3.0, got {minimum!r}")

    auto_update = root.findtext("auto_update")
    if auto_update != "false":
        fail("V1 must keep auto_update=false")


def check_version():
    if not VERSION_FILE.is_file():
        fail("VERSION file is missing")

    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not version:
        fail("VERSION is empty")

    source = VERSION_SOURCE.read_text(encoding="utf-8")
    expected = f'Version.BRIDGE_VERSION = "{version}"'
    if expected not in source:
        fail(f"driver source version does not match VERSION ({version})")


def check_driver_version():
    if not DRIVER_VERSION_FILE.is_file():
        fail("DRIVER_VERSION file is missing")

    expected = DRIVER_VERSION_FILE.read_text(encoding="utf-8").strip()
    if not expected.isdigit():
        fail(f"DRIVER_VERSION must be an integer, got {expected!r}")

    root = ET.parse(DRIVER / "driver.xml").getroot()
    actual = (root.findtext("version") or "").strip()
    if actual != expected:
        fail(f"driver.xml version {actual!r} does not match DRIVER_VERSION {expected!r}")


def check_requires(files):
    module_paths = set(files)
    pattern = re.compile(r"""require\s*\(\s*["']([^"']+)["']\s*\)""")

    for archive_path, source_path in files.items():
        if not archive_path.endswith(".lua"):
            continue
        content = source_path.read_text(encoding="utf-8")
        for module in pattern.findall(content):
            target = module.replace(".", "/") + ".lua"
            if target not in module_paths:
                fail(f"{archive_path} requires missing module {target}")


def check_light_adapter():
    path = DRIVER / "src" / "adapters" / "light_v2.lua"
    if not path.is_file():
        fail("Light V2 adapter is missing")

    source = path.read_text(encoding="utf-8")
    required = [
        "VARIABLE_STATE = 1000",
        "VARIABLE_BRIGHTNESS = 1001",
        'C4:SendToDevice(deviceId, "SET_BRIGHTNESS_TARGET"',
        "LIGHT_BRIGHTNESS_TARGET_PRESET_ID = presetId",
        'C4:SendToDevice(deviceId, "RAMP_TO_LEVEL"',
        "LEVEL = target",
        "TIME = 0",
        "C4:RegisterVariableListener",
    ]

    for token in required:
        if token not in source:
            fail(f"Light V2 adapter missing required contract: {token}")

    server = (DRIVER / "src" / "server" / "http.lua").read_text(encoding="utf-8")
    if "/v1/lights" not in server:
        fail("LAN API is missing /v1/lights")
    if "/v1/devices/(%d+)/actions/" not in server:
        fail("LAN API is missing normalized device action routing")


def check_package(files):
    if not PACKAGE.is_file():
        fail("dist/C4Bridge.c4z is missing; run python scripts/build.py")

    with ZipFile(PACKAGE, "r") as archive:
        names = set(archive.namelist())
        expected = set(files)

        missing = expected - names
        if missing:
            fail(f"package is missing files: {sorted(missing)}")

        if "driver.xml" not in names or "driver.lua" not in names:
            fail("package root must contain driver.xml and driver.lua")

        bad = [name for name in names if name.startswith("driver/")]
        if bad:
            fail("driver files must be at C4Z root, not under driver/")


def main():
    files = source_files()
    check_xml()
    check_version()
    check_driver_version()
    check_requires(files)
    check_light_adapter()
    check_package(files)
    print(f"OK: validated {len(files)} packaged files")


if __name__ == "__main__":
    main()
