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
        'C4:SendToDevice(deviceId, "SET_BRIGHTNESS_TARGET"',
        "PERCENT = target",
        "knx_dimmer.c4i",
        "brightness_control",
        "brightness_feedback",
        "C4:RegisterVariableListener",
    ]

    for token in required:
        if token not in source:
            fail(f"Light V2 adapter missing required contract: {token}")

    climate_path = DRIVER / "src" / "adapters" / "climate_v2.lua"
    if not climate_path.is_file():
        fail("Thermostat V2 climate adapter is missing")

    climate = climate_path.read_text(encoding="utf-8")
    for token in (
        "VARIABLE_SCALE = 1100",
        "VARIABLE_HVAC_MODE = 1104",
        "VARIABLE_FAN_MODE = 1105",
        "VARIABLE_HVAC_STATE = 1107",
        "VARIABLE_IS_CONNECTED = 1112",
        "VARIABLE_HVAC_MODES_LIST = 1120",
        "VARIABLE_TEMPERATURE_F = 1130",
        "VARIABLE_TEMPERATURE_C = 1131",
        "VARIABLE_HEAT_SETPOINT_F = 1132",
        "VARIABLE_HEAT_SETPOINT_C = 1133",
        "VARIABLE_COOL_SETPOINT_F = 1134",
        "VARIABLE_COOL_SETPOINT_C = 1135",
        "thermostatv2.c4i",
        "read_only = true",
        "C4:RegisterVariableListener",
    ):
        if token not in climate:
            fail(f"Climate adapter missing required read-only contract: {token}")

    pairing_path = DRIVER / "src" / "auth" / "pairing.lua"
    if not pairing_path.is_file():
        fail("owner pairing module is missing")

    pairing = pairing_path.read_text(encoding="utf-8")
    for token in (
        'C4:PersistGetValue(key, encrypted == true)',
        'C4:PersistSetValue(key, tostring(value or ""), encrypted == true)',
        'MAX_FAILED_ATTEMPTS = 5',
        'LOCK_SECONDS = 60',
        'CODE_TTL_SECONDS = 15 * 60',
        'C4:UUID("RANDOM")',
    ):
        if token not in pairing:
            fail(f"pairing module missing security contract: {token}")

    server = (DRIVER / "src" / "server" / "http.lua").read_text(encoding="utf-8")
    if "/v1/lights" not in server:
        fail("LAN API is missing /v1/lights")
    if "/v1/climate" not in server:
        fail("LAN API is missing /v1/climate")
    if "/v1/devices/(%d+)/actions/" not in server:
        fail("LAN API is missing normalized device action routing")
    if "/v1/diagnostics" not in server:
        fail("LAN API is missing authenticated diagnostics endpoint")
    if 'request.path ~= "/v1/pair"' not in server:
        fail("LAN API is missing owner pairing route")
    if 'x-c4bridge-pairing-code' not in server:
        fail("pairing route must use the dedicated pairing-code header")
    if "PAIRING_RATE_LIMITED" not in server:
        fail("pairing route must handle rate limiting")

    root = ET.parse(DRIVER / "driver.xml").getroot()
    property_names = {
        node.findtext("name")
        for node in root.findall("./config/properties/property")
    }
    for name in (
        "Reload Counter",
        "Last Init Type",
        "Last Init Time",
        "Last Destroy Type",
        "Last Destroy Time",
        "Pairing Code",
        "Pairing Status",
        "Supported Climate",
    ):
        if name not in property_names:
            fail(f"driver.xml missing lifecycle diagnostic property: {name}")


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
