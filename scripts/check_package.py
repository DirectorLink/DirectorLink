#!/usr/bin/env python3
"""Checks the built dist/C4Bridge.c4z against the source tree and the release contract."""

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "driver"
PACKAGE = ROOT / "dist" / "C4Bridge.c4z"
SPEC_MODULE = "src/api/openapi_spec.lua"

REQUIRED_PROPERTIES = (
    "Status",
    "Version",
    "Controller OS",
    "Inventory",
    "API Status",
    "API Port",
    "API Keys",
    "Pairing Code",
    "Pairing Status",
    "Access Request",
    "Log Level",
    "Reload Counter",
    "Last Init Type",
    "Last Init Time",
    "Last Destroy Type",
    "Last Destroy Time",
)

REQUIRED_ACTIONS = ("NEW_PAIRING_CODE", "REVOKE_API_KEYS", "SHOW_ACCESS_BUTTON")

ACCESS_BUTTON_BINDING = "5001"

# Source fragments that encode security decisions; removing one should be deliberate.
SECURITY_CONTRACT = {
    "src/api/server.lua": (
        "if not match.route.public then",
        'string.lower(scheme) ~= "bearer"',
        '["https://app.c4bridge.io"] = true',
    ),
    "src/auth/keys.lua": (
        "C4:PersistSetValue(STORE_KEY, Json.encode({ version = 1, keys = records }), true)",
        "C4:PersistGetValue(STORE_KEY, true)",
        'C4:UUID("RANDOM")',
        "constantTimeEqual(presented, key.secret)",
    ),
    "src/auth/approvals.lua": (
        "constantTimeEqual(id, request.id)",
        "MAX_REQUESTS_PER_WINDOW = 5",
    ),
    "src/auth/pairing.lua": (
        "CODE_TTL_SECONDS = 15 * 60",
        "MAX_FAILED_ATTEMPTS = 5",
        "LOCK_SECONDS = 60",
        "constantTimeEqual(code, state.code)",
    ),
    "src/core/log.lua": (
        "pairing_code = true",
        "authorization = true",
    ),
}


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def expected_versions():
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    if not match:
        fail(f"VERSION must be MAJOR.MINOR.PATCH, got {version!r}")
    major, minor, patch = (int(part) for part in match.groups())
    return version, str(major * 10000 + minor * 100 + patch)


def check_reproducible(infos):
    """Metadata that must not depend on the build machine, so checksums match across OSes."""
    for info in infos:
        if info.date_time != (2026, 1, 1, 0, 0, 0):
            fail(f"{info.filename} has timestamp {info.date_time}; builds must use the fixed timestamp")
        if info.create_system != 3:
            fail(f"{info.filename} was written with create_system {info.create_system}; builds must use 3 (Unix)")


def check_contents(names):
    expected = {"driver.xml", "driver.lua", SPEC_MODULE}
    expected.update(path.relative_to(DRIVER).as_posix() for path in (DRIVER / "src").rglob("*.lua"))
    expected.update(path.relative_to(DRIVER).as_posix() for path in (DRIVER / "www").rglob("*") if path.is_file())
    missing = expected - names
    if missing:
        fail(f"package is missing files: {sorted(missing)}")
    extra = names - expected
    if extra:
        fail(f"package contains unexpected files: {sorted(extra)}")


def check_driver_xml(text, driver_version):
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        fail(f"packaged driver.xml is not valid XML: {exc}")
    # Director's broker reads driver.xml as "<xml>" + contents + "</xml>". If that does not parse
    # (e.g. an <?xml ...?> declaration), it rejects the driver and "Update Driver" never reloads it.
    try:
        ET.fromstring("<xml>" + text + "</xml>")
    except ET.ParseError as exc:
        fail(f"driver.xml must parse inside <xml>...</xml> like the Control4 broker reads it: {exc}")
    if root.tag != "devicedata":
        fail("driver.xml root must be <devicedata>")
    script = root.find("./config/script")
    if script is None or script.attrib.get("file") != "driver.lua":
        fail("driver.xml must load driver.lua")
    if root.findtext("minimum_os_version") != "3.3.0":
        fail("minimum_os_version must be 3.3.0")
    if root.findtext("auto_update") != "false":
        fail("auto_update must stay false")
    if root.findtext("version") != driver_version:
        fail(f"packaged driver.xml version is {root.findtext('version')!r}, expected {driver_version}")

    properties = {node.findtext("name") for node in root.findall("./config/properties/property")}
    for name in REQUIRED_PROPERTIES:
        if name not in properties:
            fail(f"driver.xml is missing property {name!r}")
    button = [proxy for proxy in root.findall("./proxies/proxy") if proxy.text == "uibutton"]
    if not button or button[0].get("proxybindingid") != ACCESS_BUTTON_BINDING:
        fail("driver.xml must declare the uibutton proxy on binding 5001 (C4Bridge Access)")
    if root.findtext("combo") is not None:
        fail("C4Bridge must not be a combo driver: Director does not create the C4Bridge Access button for combo drivers")
    connection_ids = {node.findtext("id") for node in root.findall("./connections/connection")}
    if ACCESS_BUTTON_BINDING not in connection_ids:
        fail("driver.xml needs the UIBUTTON connection for binding 5001")
    names = set(ZipFile(PACKAGE).namelist())
    for icon in root.iter("Icon"):
        path = "www/" + icon.text.split("controller://driver/C4Bridge/", 1)[-1]
        if path not in names:
            fail(f"driver.xml references {icon.text}, which is not in the package")
    actions = {node.findtext("command") for node in root.findall("./config/actions/action")}
    for command in REQUIRED_ACTIONS:
        if command not in actions:
            fail(f"driver.xml is missing Composer action {command!r}")


def check_requires(files):
    pattern = re.compile(r"""require\s*\(\s*["']([^"']+)["']\s*\)""")
    for name, text in files.items():
        if not name.endswith(".lua"):
            continue
        for module in pattern.findall(text):
            target = module.replace(".", "/") + ".lua"
            if target not in files:
                fail(f"{name} requires {module}, which is not in the package")


def check_embedded_spec(text, version):
    match = re.search(r"return \[(=*)\[(.*)\]\1\]\s*$", text, re.S)
    if not match:
        fail(f"{SPEC_MODULE} does not return a long string")
    try:
        spec = json.loads(match.group(2))
    except json.JSONDecodeError as exc:
        fail(f"embedded API description is not valid JSON: {exc}")
    if not str(spec.get("openapi", "")).startswith("3.1"):
        fail("embedded API description must be OpenAPI 3.1")
    if spec.get("info", {}).get("version") != version:
        fail("embedded API description version does not match VERSION")


def check_security_contract(files):
    for name, fragments in SECURITY_CONTRACT.items():
        text = files.get(name, "")
        for fragment in fragments:
            if fragment not in text:
                fail(f"{name} is missing security contract: {fragment}")


def main():
    if not PACKAGE.is_file():
        fail("dist/C4Bridge.c4z is missing; run python scripts/build.py")
    version, driver_version = expected_versions()

    with ZipFile(PACKAGE) as archive:
        names = set(archive.namelist())
        check_contents(names)
        check_reproducible(archive.infolist())
        files = {name: archive.read(name).decode("utf-8") for name in names if not name.startswith("www/")}

    check_driver_xml(files["driver.xml"], driver_version)
    if f'Version.BRIDGE_VERSION = "{version}"' not in files["src/core/version.lua"]:
        fail("packaged src/core/version.lua was not stamped with VERSION")
    check_requires(files)
    check_embedded_spec(files[SPEC_MODULE], version)
    check_security_contract(files)
    print(f"OK: validated {len(files)} packaged files for version {version}")


if __name__ == "__main__":
    main()
