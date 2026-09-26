#!/usr/bin/env python3
"""Static validation for the C4Bridge Pages/PWA web app."""

from html.parser import HTMLParser
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"

REQUIRED = [
    "index.html",
    "console.html",
    "styles.css",
    "app.js",
    "console.js",
    "api-client.js",
    "manifest.webmanifest",
    "sw.js",
    "icons/icon.svg",
    "icons/icon-192.png",
    "icons/icon-512.png",
    "_headers",
]

# Endpoints and names from the pre-OpenAPI alpha API that must not come back.
RETIRED = ['"/v1/pair"', "/v1/climate", "/actions/", "/v1/system/info", "/v1/diagnostics", "c4bridge.apiToken"]


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
    parser.feed((WEB / name).read_text(encoding="utf-8"))
    return parser


def require(text, fragment, message):
    if fragment not in text:
        fail(message)


def main():
    for relative in REQUIRED:
        if not (WEB / relative).is_file():
            fail(f"missing web file: web/{relative}")

    manifest = json.loads((WEB / "manifest.webmanifest").read_text(encoding="utf-8"))
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
    if "/console.html" not in index.links:
        fail("index.html must link to the API console")
    for element_id in ("pairing-code", "light-list", "thermostat-list", "room-list", "device-list"):
        if element_id not in index.ids:
            fail(f"index.html is missing #{element_id}")

    console = parse("console.html")
    if "/console.js" not in console.scripts:
        fail("console.html does not load /console.js")
    for element_id in ("operation-select", "request-body", "send-button", "log-list", "log-follow"):
        if element_id not in console.ids:
            fail(f"console.html is missing #{element_id}")

    client = (WEB / "api-client.js").read_text(encoding="utf-8")
    require(client, "export const API_PORT = 41999;", "api-client.js must use API port 41999")
    require(client, 'targetAddressSpace: "local"', "LAN requests must be annotated with targetAddressSpace")
    require(client, "Authorization = `Bearer ${apiKey}`", "requests must send the API key as a Bearer token")
    require(client, '"Content-Type"] = "application/json"', "request bodies must be sent as JSON")

    app = (WEB / "app.js").read_text(encoding="utf-8")
    require(app, '"/v1/auth/pair"', "the web app must pair with POST /v1/auth/pair")
    require(app, "pairing_code:", "pairing must send the code in the JSON body")
    require(app, "saveApiKey(created.key)", "the web app must store the API key it was issued")
    for path in ('"/v1/system"', '"/v1/rooms"', '"/v1/devices"', '"/v1/lights"', '"/v1/thermostats"'):
        require(app, path, f"the web app must load {path}")
    require(app, 'method: "PATCH"', "device changes must use PATCH")
    require(app, "waitForLightConfirmation", "light changes must be confirmed from reported state")
    require(app, "brightness_reported", "the web app must handle lights that do not report brightness")

    console_js = (WEB / "console.js").read_text(encoding="utf-8")
    require(console_js, '"/v1/openapi.json"', "the console must load the API description from the controller")
    require(console_js, "/v1/logs?", "the console must be able to follow the log")

    for name in ("app.js", "console.js", "api-client.js"):
        text = (WEB / name).read_text(encoding="utf-8")
        for retired in RETIRED:
            if retired in text:
                fail(f"web/{name} still uses the retired API: {retired}")

    service_worker = (WEB / "sw.js").read_text(encoding="utf-8")
    require(service_worker, "requestUrl.origin !== self.location.origin",
            "the service worker must ignore cross-origin/LAN requests")
    for asset in ("/console.html", "/console.js", "/api-client.js"):
        require(service_worker, f'"{asset}"', f"the service worker must cache {asset}")

    print("OK: C4Bridge web app validated")


if __name__ == "__main__":
    main()
