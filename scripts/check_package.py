#!/usr/bin/env python3
"""Checks the built dist/DirectorLink.c4z against the source tree and the release contract."""

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "driver"
PACKAGE = ROOT / "dist" / "DirectorLink.c4z"
SPEC_MODULE = "src/api/openapi_spec.lua"

# The Composer properties, in order: what an installer needs, nothing more (0.8.0).
REQUIRED_PROPERTIES = (
    "Status",
    "Version",
    "API Status",
    "Pairing Code",
    "Pairing Status",
    "API Keys",
    "Door Control",
    "Remote Access",
    "Remote Status",
    "Log Level",
    "Inventory",
)

REQUIRED_ACTIONS = ("NEW_PAIRING_CODE", "REVOKE_API_KEYS")

# Source fragments that encode security decisions; removing one should be deliberate.
SECURITY_CONTRACT = {
    "src/api/server.lua": (
        "if not match.route.public then",
        'string.lower(scheme) ~= "bearer"',
        '["https://app.directorlink.io"] = true',
    ),
    "src/auth/keys.lua": (
        # Only hashes are stored, never the keys themselves.
        "return Store.write(STORE_KEY, { version = 3, keys = records }, false)",
        "        records[#records + 1] = {\n"
        "            id = key.id,\n"
        "            name = key.name,\n"
        "            role = key.role,\n"
        "            alg = key.alg,\n"
        "            hash = key.hash,\n"
        "            lock = key.lock,\n"
        "            created_at = key.created_at,\n"
        "        }\n",
        'C4:Hash(algorithm.c4, text, { return_encoding = "HEX" })',
        'C4:UUID("RANDOM")',
        "constantTimeEqual(hashes[key.alg], key.hash)",
        "Store.write(OLD_STORE_KEY, { version = 2, keys = Json.array() }, true)",
    ),
    "src/auth/pairing.lua": (
        "Pairing.CODE_TTL_SECONDS = 15 * 60",
        "MAX_FAILED_ATTEMPTS = 5",
        "LOCK_SECONDS = 60",
        "constantTimeEqual(input, state.code)",
        'close("Used at "',
    ),
    "src/cloud/relay.lua": (
        # Plain relayed requests (version 0) never reach the API: the relay cannot read a home.
        'code = "RELAY_REQUESTS_RETIRED"',
        "refuseRequest(message)",
        "Store.write(IDENTITY_KEY, identity, false)",
    ),
    # The end-to-end lock (docs/ACCOUNTS.md): the MAC is checked before anything is decrypted,
    # requests are fresh and used once, claims come only from the home network, and invitation
    # secrets are never stored.
    "src/cloud/lock.lua": (
        "Lock.WINDOW_SECONDS = 120",
        "if not sameText(expected, Base64.toHex(mac)) then\n        return nil, \"BAD_MAC\"\n    end\n    local plaintext = C4:Decrypt(",
        'local DEVICE_LABEL = "DirectorLink e2e v1"',
    ),
    "src/cloud/remote.lua": (
        "if seen[requestId] then",
        "math.abs(now - ts) > Lock.WINDOW_SECONDS or ts < state.startedAt",
        # Replays across a restart: ids of requests dated ahead of the clock are saved and loaded.
        "remember(keyId, requestId, ts, now)",
        "state.seen[item.k][item.i] = state.startedAt",
        # A claim token dies with its admin key.
        'return owner ~= nil and owner.role == "admin"',
        "state.services.invitations.consume(invitationId)",
        "state.services.keys.remote(keyId)",
    ),
    "src/api/handlers/remote.lua": (
        "if ctx.apiKey.remote then",
    ),
    "src/auth/invitations.lua": (
        "items[#items + 1] = { id = item.id, role = item.role, lock = item.lock, created_at = item.created_at, expires = item.expires, created_by = item.created_by }",
    ),
    # Director hands stored JSON back decoded (ADR-028); keys must stay readable.
    "src/core/store.lua": (
        'local PREFIX = "json:"',
        "C4:PersistSetValue(name, PREFIX .. Json.encode(value), encrypted == true)",
        'if type(raw) == "table" then',
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

    properties = [node.findtext("name") for node in root.findall("./config/properties/property")]
    if tuple(properties) != REQUIRED_PROPERTIES:
        fail(f"driver.xml properties must be exactly {', '.join(REQUIRED_PROPERTIES)} (got {', '.join(properties)})")
    # A self-contained device: combo driver whose only proxy is itself; no child proxies, no button.
    if root.findtext("combo") != "true":
        fail("driver.xml must declare <combo>true</combo>")
    proxies = [proxy.text for proxy in root.findall("./proxies/proxy")]
    if proxies != ["DirectorLink"]:
        fail(f"driver.xml must declare exactly one proxy, DirectorLink (got {proxies})")
    if root.find("connections") is not None:
        fail("driver.xml must not declare connections: DirectorLink has no child proxies")
    names = set(ZipFile(PACKAGE).namelist())
    for icon in root.iter("Icon"):
        path = "www/" + icon.text.split("controller://driver/DirectorLink/", 1)[-1]
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
        fail("dist/DirectorLink.c4z is missing; run python scripts/build.py")
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
