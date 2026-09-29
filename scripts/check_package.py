#!/usr/bin/env python3
"""Checks the built dist/DirectorLink.c4z against the source tree and the release contract."""

import base64
import binascii
import hashlib
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
    # What DirectorLink automates, visible to the installer (0.15.0): a pause switch, a summary
    # and the last run.
    "Schedules",
    "Schedule Status",
    "Last Automation",
    "Log Level",
    "Inventory",
)

# Refresh Project (1.1.0) reads the project again after changes in Composer, without a restart.
REQUIRED_ACTIONS = ("NEW_PAIRING_CODE", "REVOKE_API_KEYS", "PRINT_AUTOMATION", "REFRESH_PROJECT", "RESET_REMOTE_IDENTITY")

# Source fragments that encode security decisions; removing one should be deliberate.
SECURITY_CONTRACT = {
    "src/api/server.lua": (
        "if not match.route.public then",
        'string.lower(scheme) ~= "bearer"',
        '["https://app.directorlink.io"] = true',
    ),
    "src/auth/keys.lua": (
        # Only hashes are stored, never the keys themselves.
        "local ok = Store.write(STORE_KEY, { version = 3, keys = records }, false)",
        "        records[#records + 1] = {\n"
        "            id = key.id,\n"
        "            name = key.name,\n"
        "            role = key.role,\n"
        "            alg = key.alg,\n"
        "            hash = key.hash,\n"
        "            lock = key.lock,\n"
        "            created_at = key.created_at,\n"
        "            profile = key.profile,\n"
        "        }\n",
        'C4:Hash(algorithm.c4, text, { return_encoding = "HEX" })',
        "return Random.hex(32)",
        "constantTimeEqual(hashes[key.alg], key.hash)",
        "Store.write(OLD_STORE_KEY, { version = 2, keys = Json.array() }, true)",
    ),
    # Secrets never come from Director's UUIDs alone: they are mixed into a pool that moves on.
    "src/core/random.lua": (
        'out = out .. hash(state.pool .. "|out|" .. state.counter .. "|" .. sources())',
        'state.pool = hash(state.pool .. "|next|" .. state.counter .. "|" .. sources())',
        # Only a hash of the pool is kept: a copy of the driver's data does not tell what follows.
        'pool = hash("seed|" .. state.pool)',
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
        # Key ids only: never names, roles or secrets; and never a list that may be short.
        "ids[#ids + 1] = key.id",
        "if state.services.keys.complete and not state.services.keys.complete() then",
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
        # A sealed request never carries another (it would run as one from the home network).
        'if path:gsub("/+$", "") == "/v1/sealed" then',
        "state.services.keys.remote(keyId)",
    ),
    # Doors and gates in a scene: only a pulse (never held closed), only for keys with door access,
    # and only with Door Control on.
    "src/api/handlers/scenes.lua": (
        'if not Roles.allows(ctx.apiKey.role, "doors") then',
        "elseif not services.doorControlEnabled() then",
        'return { { action = "pulse" } }',
    ),
    "src/core/scenes.lua": (
        'return set.action == "pulse" and { action = "pulse" } or nil',
    ),
    # A schedule runs its scene like a member's key: never doors or gates.
    "src/core/scheduler.lua": (
        '{ id = "schedule:" .. schedule.id, role = "member" }',
    ),
    "src/api/handlers/remote.lua": (
        "if ctx.apiKey.remote then",
    ),
    "src/auth/invitations.lua": (
        "items[#items + 1] = { id = item.id, role = item.role, lock = item.lock, created_at = item.created_at, expires = item.expires, created_by = item.created_by, profile = item.profile }",
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
    # Director checks the relay's certificate only when asked (NetPortOptions VERIFY_MODE); the CA
    # file is checked in check_relay_roots.
    "src/cloud/websocket.lua": (
        'VERIFY_MODE = "peer",',
        "CACERTFILE = WebSocket.CA_FILE,",
    ),
}

# The roots the relay connection trusts: the authorities Cloudflare issues from (docs/RELAY.md),
# in file order, each with the SHA-256 of its certificate (checked against certifi 2026.07.22). A
# label alone would let a rebuild put the wrong certificate under the right name; remote access
# would then fail only on the controller. Today's chain ends at GTS Root R4.
RELAY_ROOTS = {
    "ISRG Root X1": "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6",
    "ISRG Root X2": "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470",
    "GTS Root R1": "d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf",
    "GTS Root R3": "34d8a73ee208d9bcdb0d956520934b4e40e69482596e8b6f73c8426b010a6f48",
    "GTS Root R4": "349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d",
    "SSL.com TLS RSA Root CA 2022": "8faf7d2e2cb4709bb8e0b33666bf75a5dd45b5de480f8ea8d4bfe6bebc17f2ed",
    "SSL.com TLS ECC Root CA 2022": "c32ffd9f46f936d16c3673990959434b9ad60aafbb9e7cf33654f144cc1ba143",
    "SSL.com Root Certification Authority RSA": "85666a562ee0be5ce925c1d8890a6f76a87ec16d4d7d5f29ea7419cf20123b69",
    "SSL.com Root Certification Authority ECC": "3417bb06cc6007da1b961c920b8ab4ce3fad820e4aa30b9acbc4a74ebdcebc65",
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
    expected.update(path.relative_to(DRIVER).as_posix() for path in (DRIVER / "certs").glob("*.pem"))
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


def check_relay_roots(files):
    """The CA file websocket.lua names is in the package and holds exactly the relay's roots."""
    match = re.search(r'WebSocket\.CA_FILE = "\./([^"]+)"', files.get("src/cloud/websocket.lua", ""))
    if not match:
        fail('src/cloud/websocket.lua must set WebSocket.CA_FILE = "./<path in the package>"')
    name = match.group(1)
    if name not in files:
        fail(f"the relay's CA file {name} is not in the package; with VERIFY_MODE peer no connection would verify")
    text = files[name]
    blocks = re.findall(r"^-----BEGIN ([A-Z0-9 ]+)-----$", text, re.M)
    if set(blocks) != {"CERTIFICATE"} or "PRIVATE KEY" in text:
        fail(f"{name} must hold certificates only (found {sorted(set(blocks))})")
    labels = re.findall(r"^# (.+)\n-----BEGIN CERTIFICATE-----$", text, re.M)
    if tuple(labels) != tuple(RELAY_ROOTS) or len(blocks) != len(RELAY_ROOTS):
        fail(f"{name} must hold exactly the roots {', '.join(RELAY_ROOTS)} (found {', '.join(labels)})")
    # Each certificate is the one its label names: the SHA-256 of its DER bytes is pinned above.
    bodies = re.findall(r"^-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+?)\n-----END CERTIFICATE-----$", text, re.M)
    if len(bodies) != len(labels):
        fail(f"{name} has a certificate block that is not plain base64")
    for label, body in zip(labels, bodies):
        try:
            der = base64.b64decode("".join(body.split()), validate=True)
        except binascii.Error:
            fail(f"{name}: the certificate under '# {label}' is not valid base64")
        digest = hashlib.sha256(der).hexdigest()
        if digest != RELAY_ROOTS[label]:
            fail(f"{name}: the certificate under '# {label}' is not {label} (SHA-256 {digest})")
    # The header lists every root's SHA-256 for readers; it must list the same ones.
    header = {
        subject: fingerprint.replace(":", "").lower()
        for subject, fingerprint in re.findall(r"^# CN=([^,\n]+),[^\n]*\n#   for: [^\n]*\n#   SHA-256: ([0-9A-F:]+)$", text, re.M)
    }
    if header != RELAY_ROOTS:
        fail(f"the SHA-256 list at the top of {name} does not match its certificates")


def check_remote_methods(files):
    """Sealed requests (the app's, at home and through the account) may use every method the API
    routes: one missing from src/cloud/remote.lua fails everywhere, as PUT /v1/rooms/order did in 1.0.0."""
    routed = set(re.findall(r'\bmethod\s*=\s*"([A-Z]+)"', files.get("src/api/routes.lua", "")))
    match = re.search(r"^local METHODS = \{([^}]*)\}", files.get("src/cloud/remote.lua", ""), re.M)
    if not routed or not match:
        fail("could not read the methods of src/api/routes.lua and src/cloud/remote.lua (local METHODS = { ... })")
    allowed = set(re.findall(r"\b([A-Z]+)\s*=\s*true\b", match.group(1)))
    missing = sorted(routed - allowed)
    if missing:
        fail(f"src/cloud/remote.lua refuses {', '.join(missing)}, which src/api/routes.lua uses: sealed requests with it would fail")


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
    check_remote_methods(files)
    check_relay_roots(files)
    print(f"OK: validated {len(files)} packaged files for version {version}")


if __name__ == "__main__":
    main()
