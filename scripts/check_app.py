#!/usr/bin/env python3
"""Static validation for the DirectorLink app (PWA) in app/."""

from html.parser import HTMLParser
import json
import re
from pathlib import Path
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
SPEC = ROOT / "api" / "openapi.yaml"

REQUIRED = [
    "index.html",
    "styles.css",
    "theme-boot.js",
    "app.js",
    "api-client.js",
    "js/i18n.js",
    "i18n/en.js",
    "manifest.webmanifest",
    "sw.js",
    "icons/icon.svg",
    "icons/icon-192.png",
    "icons/icon-512.png",
    "_headers",
]

# Endpoints and names from earlier APIs that must not come back. Access requests and the
# DirectorLink Access button were replaced by pairing codes in 0.8.0.
RETIRED = ['"/v1/pair"', "/v1/climate", "/actions/", "/v1/system/info", "/v1/diagnostics", "/v1/auth/requests"]

# Problems POST /v1/auth/pair can answer; the app explains each one (connect.errors.* in i18n).
PAIRING_PROBLEMS = {
    "INVALID_FIELD": "invalidCode",
    "PAIRING_CODE_INVALID": "wrongCode",
    "PAIRING_NOT_ACTIVE": "notActive",
    "PAIRING_RATE_LIMITED": "rateLimited",
    "KEY_LIMIT_REACHED": "keyLimit",
    "PAIRING_UNAVAILABLE": "unavailable",
}


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.manifests = []
        self.scripts = []
        self.ids = set()
        self.links = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "id" in values:
            self.ids.add(values["id"])
        if tag == "link" and values.get("rel") == "manifest":
            self.manifests.append(values.get("href"))
        if tag == "script" and values.get("src"):
            self.scripts.append(values.get("src"))
        if tag == "a" and values.get("href"):
            self.links.append(values.get("href"))


def parse(name):
    parser = PageParser()
    parser.feed((APP / name).read_text(encoding="utf-8"))
    return parser


def require(text, fragment, message):
    if fragment not in text:
        fail(message)


class DictionaryReader:
    """Reads the object a dictionary file (app/i18n/<code>.js) exports, without running it: an
    object literal of strings, numbers and nested objects, with comments."""

    ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}

    def __init__(self, text):
        self.text = text
        start = text.find("export default")
        if start < 0:
            raise ValueError("no export default")
        self.at = start + len("export default")

    def error(self, message):
        line = self.text.count("\n", 0, self.at) + 1
        raise ValueError(f"line {line}: {message}")

    def skip(self):
        while self.at < len(self.text):
            if self.text[self.at].isspace():
                self.at += 1
            elif self.text.startswith("//", self.at):
                end = self.text.find("\n", self.at)
                self.at = len(self.text) if end < 0 else end
            elif self.text.startswith("/*", self.at):
                end = self.text.find("*/", self.at)
                if end < 0:
                    self.error("unclosed comment")
                self.at = end + 2
            else:
                return

    def peek(self):
        self.skip()
        if self.at >= len(self.text):
            self.error("unexpected end")
        return self.text[self.at]

    def value(self):
        char = self.peek()
        if char == "{":
            return self.object()
        if char == "[":
            return self.array()
        if char in "\"'":
            return self.string()
        match = re.compile(r"-?\d+(?:\.\d+)?|true|false|null").match(self.text, self.at)
        if not match:
            self.error(f"unexpected {char!r}")
        self.at = match.end()
        word = match.group(0)
        if word in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[word]
        return float(word) if "." in word else int(word)

    def object(self):
        self.at += 1
        result = {}
        while self.peek() != "}":
            if self.text[self.at] in "\"'":
                key = self.string()
            else:
                match = re.compile(r"[A-Za-z_$][\w$]*|\d+").match(self.text, self.at)
                if not match:
                    self.error("expected a key")
                key = match.group(0)
                self.at = match.end()
            if self.peek() != ":":
                self.error(f"expected : after {key}")
            self.at += 1
            result[key] = self.value()
            if self.peek() == ",":
                self.at += 1
            elif self.peek() != "}":
                self.error(f"expected , or }} after {key}")
        self.at += 1
        return result

    def array(self):
        self.at += 1
        result = []
        while self.peek() != "]":
            result.append(self.value())
            if self.peek() == ",":
                self.at += 1
        self.at += 1
        return result

    def string(self):
        quote = self.text[self.at]
        self.at += 1
        chars = []
        while True:
            if self.at >= len(self.text) or self.text[self.at] == "\n":
                self.error("unclosed string")
            char = self.text[self.at]
            self.at += 1
            if char == quote:
                return "".join(chars)
            if char != "\\":
                chars.append(char)
                continue
            escape = self.text[self.at]
            self.at += 1
            if escape == "u":
                if self.text[self.at] == "{":
                    end = self.text.index("}", self.at)
                    code, self.at = self.text[self.at + 1 : end], end + 1
                else:
                    code, self.at = self.text[self.at : self.at + 4], self.at + 4
                chars.append(chr(int(code, 16)))
            elif escape == "x":
                chars.append(chr(int(self.text[self.at : self.at + 2], 16)))
                self.at += 2
            else:
                chars.append(self.ESCAPES.get(escape, escape))


def read_dictionary(text):
    return DictionaryReader(text).value()


def check_calendar_names(spec, dictionaries):
    """The Jewish calendar (1.2.0): the API sends months, holidays and weekly readings by key and
    number, and the app shows its own names for them. Every dictionary must name every Hebrew month
    and holiday key in api/openapi.yaml (HebrewMonth, HolidayKey) and every parasha id (Parasha)."""
    schemas = spec["components"]["schemas"]
    ids = schemas["Parasha"]["properties"]["ids"]["items"]
    groups = (
        ("months", [str(key) for key in schemas["HebrewMonth"]["enum"]]),
        ("holidays", [str(key) for key in schemas["HolidayKey"]["enum"]]),
        ("parashot", [str(number) for number in range(ids["minimum"], ids["maximum"] + 1)]),
    )
    for code, dictionary in dictionaries.items():
        calendar = dictionary.get("calendar") if isinstance(dictionary, dict) else None
        for group, keys in groups:
            names = calendar.get(group) if isinstance(calendar, dict) else None
            names = names if isinstance(names, dict) else {}
            missing = [key for key in keys if not isinstance(names.get(key), str) or not names[key].strip()]
            if missing:
                fail(f"app/i18n/{code}.js has no calendar.{group} name for: {', '.join(missing)}")
        rosh_chodesh = (calendar or {}).get("holidays", {}).get("rosh_chodesh", "")
        if "{month}" not in rosh_chodesh:
            fail(f"app/i18n/{code}.js: calendar.holidays.rosh_chodesh must name the month ({{month}})")


def main():
    for relative in REQUIRED:
        if not (APP / relative).is_file():
            fail(f"missing app file: app/{relative}")

    manifest = json.loads((APP / "manifest.webmanifest").read_text(encoding="utf-8"))
    for key in ("name", "short_name", "start_url", "display", "icons"):
        if key not in manifest:
            fail(f"manifest missing required field: {key}")
    if manifest["start_url"] != "/":
        fail("manifest start_url must remain /")
    if manifest["display"] != "standalone":
        fail("manifest display must be standalone")
    icon_sizes = {icon.get("sizes") for icon in manifest["icons"]}
    if "192x192" not in icon_sizes or "512x512" not in icon_sizes:
        fail("manifest must include 192x192 and 512x512 icons")

    index = parse("index.html")
    if "/manifest.webmanifest" not in index.manifests:
        fail("index.html does not link /manifest.webmanifest")
    if "/app.js" not in index.scripts:
        fail("index.html does not load /app.js")
    if "/theme-boot.js" not in index.scripts:
        fail("index.html must apply the saved palette and theme before the first paint (/theme-boot.js)")
    for element_id in ("tabbar", "main", "view"):
        if element_id not in index.ids:
            fail(f"index.html is missing #{element_id}")

    client = (APP / "api-client.js").read_text(encoding="utf-8")
    require(client, "export const API_PORT = 41999;", "api-client.js must use API port 41999")
    require(client, "targetAddressSpace: addressSpace(host)", "LAN requests must be annotated with targetAddressSpace")
    require(client, '? "loopback" : "local"', "controller requests must use the local address space (loopback only for localhost)")
    require(client, "Authorization = `Bearer ${apiKey}`", "requests must send the API key as a Bearer token")
    require(client, '"Content-Type"] = "application/json"', "request bodies must be sent as JSON")
    require(client, "export function normalizePairingCode", "api-client.js must accept pairing codes as 1234 5678")
    require(client, "export function formatPairingCode", "api-client.js must format pairing codes while typing")

    # The app is split into ES modules (app.js + js/**); check them together.
    modules = sorted([APP / "app.js", *(APP / "js").rglob("*.js")])
    app = "\n".join(path.read_text(encoding="utf-8") for path in modules)
    # Onboarding (0.8.0): the pairing code from Composer is the only way to get the first key.
    require(app, '"/v1/auth/pair"', "the app must pair with POST /v1/auth/pair")
    require(app, "pairing_code: code", "pairing must send the (normalized) code in the JSON body")
    require(app, "normalizePairingCode(", "the app must accept the code with or without its space")
    require(app, "saveApiKey(created.key)", "the app must store the API key it was issued")
    connect_view = (APP / "js" / "views" / "connect.js").read_text(encoding="utf-8")
    for fragment, message in (
        ('inputmode: "numeric"', "the pairing code field must bring up the number pad"),
        ('autocomplete: "one-time-code"', "the pairing code field must be marked as a one-time code"),
        ("formatPairingCode(", "the pairing code must be shown as 1234 5678 while typing"),
        ('placeholder: "1234 5678"', "the pairing code field must show the Composer format"),
    ):
        require(connect_view, fragment, message)
    session = (APP / "js" / "session.js").read_text(encoding="utf-8")
    for code in PAIRING_PROBLEMS:
        require(session, f'"{code}"', f"the app must explain the pairing problem {code}")
    require(session, '"/v1/api-keys/current", { method: "DELETE"', "Forget key must revoke the key (DELETE /v1/api-keys/current)")
    require(app, 't("settings.controller.pairAgain")', "Settings must offer Pair again")
    for gone in ("requestAccess", "cancelAccess", "cancel-access-button"):
        if gone in app:
            fail(f"the app still has {gone}; access requests were removed in 0.8.0 (pair with a code)")

    # Doorbells (0.9.2): polled with the other devices (404 on older drivers = none), a banner
    # on Home while a ring is recent, Open gate for doors keys only, notifications only after
    # the Settings button asked for them.
    for fragment, message in (
        ('optionalList("/v1/doorbells"', "doorbells must be polled, and an older driver's 404 must mean no doorbells"),
        ("`/v1/doorbells/${doorbell.id}/open`", "Open gate must POST /v1/doorbells/{id}/open"),
        ('if (!can("doors") || !doorbell.can_open) return null;', "Open gate must be offered only to doors keys, on doorbells that can open"),
        ("ringingDoorbells()", "Home must show the doorbell banner while a ring is recent"),
        ("dismissRing(", "the doorbell banner needs Dismiss"),
        ("live: true", "the doorbell banner's picture must refresh live"),
        ("trackRings(", "rings must be noticed as they come (a new last_ring_at)"),
    ):
        require(app, fragment, message)
    rings = (APP / "js" / "rings.js").read_text(encoding="utf-8")
    require(rings, "RING_WINDOW_MS = 2 * 60 * 1000", "a ring must count as recent for 2 minutes")
    require((APP / "js" / "i18n.js").read_text(encoding="utf-8"), "Intl.RelativeTimeFormat", "relative times must use Intl.RelativeTimeFormat")
    for path in modules:
        text = path.read_text(encoding="utf-8")
        relative = path.relative_to(APP).as_posix()
        if "requestPermission" in text and relative != "js/doorbells.js":
            fail(f"app/{relative} asks for notification permission; only Settings → Doorbell notifications may")
        if "enableNotifications(" in text and relative not in ("js/doorbells.js", "js/views/settings.js"):
            fail(f"app/{relative} turns on notifications; only the Settings button may")
    for path in ('"/v1/system"', '"/v1/rooms"', '"/v1/devices"', '"/v1/lights"', '"/v1/thermostats"'):
        require(app, path, f"the app must load {path}")
    require(app, 'method: "PATCH"', "device changes must use PATCH")
    require(app, "waitForLightConfirmation", "light changes must be confirmed from reported state")
    require(app, "brightness_reported", "the app must handle lights that do not report brightness")
    # Thermostats with heat and cool setpoints (1.1.0): both are shown and set, kept at least the
    # thermostat's deadband apart.
    require(app, "heat_setpoint", "the app must show and set the heat setpoint of dual-setpoint thermostats")
    require(app, "setpoint_deadband", "the app must keep heat and cool setpoints the thermostat's deadband apart")
    require(app, 'export const isDual = (thermostat) => thermostat?.setpoints === "dual";',
            "only thermostats that report setpoints: dual get heat and cool steppers (older drivers send no setpoints)")
    require(app, "handleUnauthorized", "a 401 must clear the saved API key")
    require(app, "snapshot_href", "cameras must load pictures from snapshot_href")
    require(app, 'id: "offline-status"', "settings must show the offline copy status")
    # The API console is its own site (console/); Settings opens it in a new tab, or the local
    # copy on port 8081 when the app itself runs on this computer.
    settings = (APP / "js" / "views" / "settings.js").read_text(encoding="utf-8")
    require(settings, '"https://console.directorlink.io"', "settings must link to the API console site")
    require(settings, '"http://127.0.0.1:8081"', "a local copy of the app must open the local console (port 8081)")
    require(settings, 'href: consoleUrl(), target: "_blank"', "settings must open the API console in a new tab")
    for path in APP.rglob("*"):
        if path.is_file() and path.suffix in (".html", ".js") and "/console.html" in path.read_text(encoding="utf-8"):
            fail(f"app/{path.relative_to(APP).as_posix()} still links to /console.html; the console is https://console.directorlink.io")
    for gone in ("console.html", "console.js", "console.css"):
        if (APP / gone).exists():
            fail(f"app/{gone} belongs to the console site now (console/)")
    # Old bookmarks of the console inside the app go to the console site (Cloudflare _redirects).
    redirects = (APP / "_redirects").read_text(encoding="utf-8") if (APP / "_redirects").is_file() else ""
    rules = [line.split() for line in redirects.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    for old in ("/console.html", "/console"):
        if [old, "https://console.directorlink.io", "301"] not in rules:
            fail(f"app/_redirects must send {old} to https://console.directorlink.io (301)")

    # Every language listed in js/i18n.js has a dictionary file, and each one explains every
    # pairing problem in its own words.
    i18n = (APP / "js" / "i18n.js").read_text(encoding="utf-8")
    for code in re.findall(r'\{ code: "([a-zA-Z-]+)"', i18n):
        dictionary_path = APP / "i18n" / f"{code}.js"
        if not dictionary_path.is_file():
            fail(f"language {code} is listed in js/i18n.js but app/i18n/{code}.js is missing")
        dictionary = dictionary_path.read_text(encoding="utf-8")
        for key in ("codeLabel", "codeHelp", "pairNew", "pairAgain", "pairAgainConfirm", "rateLimitedMinute", *PAIRING_PROBLEMS.values()):
            require(dictionary, f"{key}:", f"app/i18n/{code}.js is missing {key}")
        for key in ("atTheDoor", "lastRing", "noRings", "dismiss", "notificationTitle", "communication_failed", "justNow", "inventoryDoorbells"):
            require(dictionary, f"{key}:", f"app/i18n/{code}.js is missing the doorbell text {key}")
        for key in ("heatShort", "coolShort", "heatTarget", "coolTarget", "lowerHeat", "raiseHeat", "lowerCool", "raiseCool", "setpoints", "gap", "circulate"):
            require(dictionary, f"{key}:", f"app/i18n/{code}.js is missing the setpoint text {key}")
        for key in ("readOnly", "alarmOf", "entryDelay", "exitDelay", "armedAway", "armedHome", "notReady", "openZones", "delayLeft", "trouble"):
            require(dictionary, f"{key}:", f"app/i18n/{code}.js is missing the alarm text {key}")

    # The alarm's status (1.2.0, ADR-038): read-only, asked for and shown only for members and
    # admins once the installer turned it on; nothing in the app sends the alarm anything.
    alarm = (APP / "js" / "alarm.js").read_text(encoding="utf-8")
    require(alarm, 'state.system?.features?.alarm_status === true && Boolean(state.role) && can("member")',
            "the alarm must be asked for and shown only with Alarm Status on, and only for members and admins")
    require(alarm, 'api("/v1/alarm")', "the alarm's status must come from GET /v1/alarm")
    for path in (APP / "js" / "alarm.js", APP / "js" / "views" / "alarm.js"):
        if re.search(r"method:|onclick", path.read_text(encoding="utf-8")):
            fail(f"app/{path.relative_to(APP).as_posix()} must only read the alarm: it has nothing to send or press")

    # The Jewish calendar (1.2.0): each dictionary names every month, holiday and weekly reading the
    # API can send (api/openapi.yaml).
    dictionaries = {}
    for code in re.findall(r'\{ code: "([a-zA-Z-]+)"', i18n):
        try:
            dictionaries[code] = read_dictionary((APP / "i18n" / f"{code}.js").read_text(encoding="utf-8"))
        except ValueError as error:
            fail(f"app/i18n/{code}.js could not be read as a dictionary: {error}")
    check_calendar_names(yaml.safe_load(SPEC.read_text(encoding="utf-8")), dictionaries)

    for path in APP.rglob("*"):
        if path.is_file() and path.suffix in (".html", ".js", ".md") and "DirectorLink Access" in path.read_text(encoding="utf-8"):
            fail(f"app/{path.relative_to(APP).as_posix()} still mentions the DirectorLink Access button (removed in 0.8.0)")

    for path in [APP / "api-client.js", *modules]:
        text = path.read_text(encoding="utf-8")
        for retired in RETIRED:
            if retired in text:
                fail(f"app/{path.relative_to(APP).as_posix()} still uses the retired API: {retired}")

    # The update notice (1.1.0, ADR-035): only admin keys ask GitHub's releases API, only immutable
    # releases are offered, and the release notes (Markdown written on GitHub) never reach the page.
    updates = (APP / "js" / "updates.js").read_text(encoding="utf-8")
    require(updates, '"https://api.github.com/repos/IsraelCIL/DirectorLink/releases/latest"', "the update notice must ask GitHub's releases API")
    require(updates, 'role !== "admin"', "only admin keys may ask GitHub whether DirectorLink has a newer release")
    require(updates, "CHECK_INTERVAL_MS = 12 * 60 * 60 * 1000", "the app must ask GitHub at most every 12 hours (the privacy page says twice a day)")
    require(updates, "locked: answer.immutable === true", "the update notice must know which releases are immutable, whose files cannot be replaced")
    require(updates, "release.locked === true && compareVersions", "the update notice must offer only immutable releases")
    for path in (APP / "js" / "updates.js", APP / "js" / "views" / "updates.js"):
        if re.search(r"\.body\b|innerHTML", path.read_text(encoding="utf-8")):
            fail(f"app/{path.relative_to(APP).as_posix()} must not use a release's body: its text is not the app's to show")

    service_worker = (APP / "sw.js").read_text(encoding="utf-8")
    require(service_worker, "requestUrl.origin !== self.location.origin",
            "the service worker must ignore cross-origin/LAN requests")
    require(service_worker, 'request.method !== "GET"', "the service worker must only handle GET requests")
    require(service_worker, "response.redirected", "cached pages must be stored without redirects")
    require(service_worker, "NETWORK_TIMEOUT_MS", "the service worker must fall back to the cache when the network is slow")
    for asset in ("/index.html", "/api-client.js", "/theme-boot.js"):
        require(service_worker, f'"{asset}"', f"the service worker must cache {asset}")
    require(service_worker, 'addEventListener("notificationclick"', "a doorbell notification click must open the app")
    for special in ("/_redirects", "/_headers"):
        if f'"{special}"' in service_worker:
            fail(f"the service worker must not cache {special}: Cloudflare reads it, it is not served")
    if '"/console' in service_worker:
        fail("the service worker must not cache the old API console pages (it is console.directorlink.io now)")
    # The offline shell needs every module the app imports.
    for path in modules:
        asset = "/" + path.relative_to(APP).as_posix()
        require(service_worker, f'"{asset}"', f"the service worker must cache {asset}")
    config_text = "\n".join(
        line for line in (APP / "wrangler.jsonc").read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("//")
    )
    config = json.loads(config_text)
    if config.get("name") != "directorlink-app" or config.get("assets", {}).get("directory") != ".":
        fail("app/wrangler.jsonc must deploy this folder as the directorlink-app Worker")
    if {"pattern": "app.directorlink.io", "custom_domain": True} not in config.get("routes", []):
        fail("app/wrangler.jsonc must serve the app on the app.directorlink.io custom domain")
    if "previews" not in config:
        fail("app/wrangler.jsonc needs a previews block, or pull-request preview builds fail")
    if config.get("observability", {}).get("enabled") is not True:
        fail("app/wrangler.jsonc must keep Workers observability enabled, as production had it")
    ignored = (APP / ".assetsignore").read_text(encoding="utf-8").split()
    for name in ("wrangler.jsonc", "README.md"):
        if name not in ignored:
            fail(f"app/.assetsignore must keep {name} from being published")

    test_suffixes = (".test.js", ".test.mjs", ".spec.js", ".spec.mjs")
    if any(path.name.endswith(test_suffixes) for path in APP.rglob("*") if path.is_file()):
        fail("tests must not live in app/ (Cloudflare publishes everything there); use tests/app/")

    print("OK: DirectorLink app validated")


if __name__ == "__main__":
    main()
