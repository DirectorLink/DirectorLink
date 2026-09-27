#!/usr/bin/env python3
"""Static validation for the DirectorLink app (PWA) in app/."""

from html.parser import HTMLParser
import json
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"

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

# Endpoints and names from the pre-OpenAPI alpha API that must not come back.
RETIRED = ['"/v1/pair"', "/v1/climate", "/actions/", "/v1/system/info", "/v1/diagnostics"]


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

    # The app is split into ES modules (app.js + js/**); check them together.
    modules = sorted([APP / "app.js", *(APP / "js").rglob("*.js")])
    app = "\n".join(path.read_text(encoding="utf-8") for path in modules)
    require(app, '"/v1/auth/pair"', "the app must pair with POST /v1/auth/pair")
    require(app, "pairing_code:", "pairing must send the code in the JSON body")
    require(app, '"/v1/auth/requests"', "the app must request access approved in the Control4 app")
    require(app, 'id: "cancel-access-button"', "the app needs a way to cancel a waiting access request")
    require(app, 'method: "DELETE"', "cancelling an access request must DELETE it")
    require(app, "saveApiKey(created.key)", "the app must store the API key it was issued")
    for path in ('"/v1/system"', '"/v1/rooms"', '"/v1/devices"', '"/v1/lights"', '"/v1/thermostats"'):
        require(app, path, f"the app must load {path}")
    require(app, 'method: "PATCH"', "device changes must use PATCH")
    require(app, "waitForLightConfirmation", "light changes must be confirmed from reported state")
    require(app, "brightness_reported", "the app must handle lights that do not report brightness")
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

    # Every language listed in js/i18n.js has a dictionary file.
    i18n = (APP / "js" / "i18n.js").read_text(encoding="utf-8")
    for code in re.findall(r'\{ code: "([a-zA-Z-]+)"', i18n):
        if not (APP / "i18n" / f"{code}.js").is_file():
            fail(f"language {code} is listed in js/i18n.js but app/i18n/{code}.js is missing")

    for path in [APP / "api-client.js", *modules]:
        text = path.read_text(encoding="utf-8")
        for retired in RETIRED:
            if retired in text:
                fail(f"app/{path.relative_to(APP).as_posix()} still uses the retired API: {retired}")

    service_worker = (APP / "sw.js").read_text(encoding="utf-8")
    require(service_worker, "requestUrl.origin !== self.location.origin",
            "the service worker must ignore cross-origin/LAN requests")
    require(service_worker, 'request.method !== "GET"', "the service worker must only handle GET requests")
    require(service_worker, "response.redirected", "cached pages must be stored without redirects")
    require(service_worker, "NETWORK_TIMEOUT_MS", "the service worker must fall back to the cache when the network is slow")
    for asset in ("/index.html", "/api-client.js", "/theme-boot.js"):
        require(service_worker, f'"{asset}"', f"the service worker must cache {asset}")
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
