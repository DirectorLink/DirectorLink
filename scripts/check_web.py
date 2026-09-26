#!/usr/bin/env python3
"""Static validation for the C4Bridge Pages/PWA web app."""

from html.parser import HTMLParser
import json
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"

REQUIRED = [
    "index.html",
    "console.html",
    "styles.css",
    "console.css",
    "theme-boot.js",
    "app.js",
    "console.js",
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
    if "/theme-boot.js" not in index.scripts:
        fail("index.html must apply the saved palette and theme before the first paint (/theme-boot.js)")
    if "/console.html" not in index.links:
        fail("index.html must link to the API console")
    for element_id in ("tabbar", "main", "view"):
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
    require(client, "targetAddressSpace: addressSpace(host)", "LAN requests must be annotated with targetAddressSpace")
    require(client, '? "loopback" : "local"', "controller requests must use the local address space (loopback only for localhost)")
    require(client, "Authorization = `Bearer ${apiKey}`", "requests must send the API key as a Bearer token")
    require(client, '"Content-Type"] = "application/json"', "request bodies must be sent as JSON")

    # The app is split into ES modules (app.js + js/**); check them together.
    modules = sorted([WEB / "app.js", *(WEB / "js").rglob("*.js")])
    app = "\n".join(path.read_text(encoding="utf-8") for path in modules)
    require(app, '"/v1/auth/pair"', "the web app must pair with POST /v1/auth/pair")
    require(app, "pairing_code:", "pairing must send the code in the JSON body")
    require(app, '"/v1/auth/requests"', "the web app must request access approved in the Control4 app")
    require(app, 'id: "cancel-access-button"', "the app needs a way to cancel a waiting access request")
    require(app, 'method: "DELETE"', "cancelling an access request must DELETE it")
    require(app, "saveApiKey(created.key)", "the web app must store the API key it was issued")
    for path in ('"/v1/system"', '"/v1/rooms"', '"/v1/devices"', '"/v1/lights"', '"/v1/thermostats"'):
        require(app, path, f"the web app must load {path}")
    require(app, 'method: "PATCH"', "device changes must use PATCH")
    require(app, "waitForLightConfirmation", "light changes must be confirmed from reported state")
    require(app, "brightness_reported", "the web app must handle lights that do not report brightness")
    require(app, "handleUnauthorized", "a 401 must clear the saved API key")
    require(app, "snapshot_href", "cameras must load pictures from snapshot_href")
    require(app, 'id: "offline-status"', "settings must show the offline copy status")
    require(app, 'href: "/console.html"', "settings must link to the API console")

    # Every language listed in js/i18n.js has a dictionary file.
    i18n = (WEB / "js" / "i18n.js").read_text(encoding="utf-8")
    for code in re.findall(r'\{ code: "([a-zA-Z-]+)"', i18n):
        if not (WEB / "i18n" / f"{code}.js").is_file():
            fail(f"language {code} is listed in js/i18n.js but web/i18n/{code}.js is missing")

    console_js = (WEB / "console.js").read_text(encoding="utf-8")
    require(console_js, '"/v1/openapi.json"', "the console must load the API description from the controller")
    require(console_js, "/v1/logs?", "the console must be able to follow the log")

    for path in [WEB / "console.js", WEB / "api-client.js", *modules]:
        text = path.read_text(encoding="utf-8")
        for retired in RETIRED:
            if retired in text:
                fail(f"web/{path.relative_to(WEB).as_posix()} still uses the retired API: {retired}")

    service_worker = (WEB / "sw.js").read_text(encoding="utf-8")
    require(service_worker, "requestUrl.origin !== self.location.origin",
            "the service worker must ignore cross-origin/LAN requests")
    require(service_worker, 'request.method !== "GET"', "the service worker must only handle GET requests")
    require(service_worker, "response.redirected", "cached pages must be stored without redirects")
    require(service_worker, "NETWORK_TIMEOUT_MS", "the service worker must fall back to the cache when the network is slow")
    for asset in ("/console.html", "/console", "/index.html", "/console.js", "/api-client.js", "/console.css", "/theme-boot.js"):
        require(service_worker, f'"{asset}"', f"the service worker must cache {asset}")
    # The offline shell needs every module the app imports.
    for path in modules:
        asset = "/" + path.relative_to(WEB).as_posix()
        require(service_worker, f'"{asset}"', f"the service worker must cache {asset}")
    config_text = "\n".join(
        line for line in (WEB / "wrangler.jsonc").read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("//")
    )
    config = json.loads(config_text)
    if config.get("name") != "c4bridge" or config.get("assets", {}).get("directory") != ".":
        fail("web/wrangler.jsonc must deploy this folder as the c4bridge Worker")
    if "previews" not in config:
        fail("web/wrangler.jsonc needs a previews block, or pull-request preview builds fail")
    if config.get("observability", {}).get("enabled") is not True:
        fail("web/wrangler.jsonc must keep Workers observability enabled, as production had it")
    if "wrangler.jsonc" not in (WEB / ".assetsignore").read_text(encoding="utf-8").split():
        fail("web/.assetsignore must keep wrangler.jsonc from being published")

    test_suffixes = (".test.js", ".test.mjs", ".spec.js", ".spec.mjs")
    if any(path.name.endswith(test_suffixes) for path in WEB.rglob("*") if path.is_file()):
        fail("tests must not live in web/ (Cloudflare publishes everything there); use tests/web/")

    print("OK: C4Bridge web app validated")


if __name__ == "__main__":
    main()
