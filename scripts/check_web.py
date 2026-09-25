#!/usr/bin/env python3
"""Static validation for the C4Bridge Pages/PWA shell."""

from html.parser import HTMLParser
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"

REQUIRED = [
    "index.html",
    "styles.css",
    "app.js",
    "manifest.webmanifest",
    "sw.js",
    "icons/icon.svg",
    "_headers",
]


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


class IndexParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.manifests = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "link" and values.get("rel") == "manifest":
            self.manifests.append(values.get("href"))
        if tag == "script" and values.get("src"):
            self.scripts.append(values.get("src"))


def main():
    for relative in REQUIRED:
        path = WEB / relative
        if not path.is_file():
            fail(f"missing web file: web/{relative}")

    manifest = json.loads((WEB / "manifest.webmanifest").read_text(encoding="utf-8"))

    for key in ("name", "short_name", "start_url", "display", "icons"):
        if key not in manifest:
            fail(f"manifest missing required project field: {key}")

    if manifest["start_url"] != "/":
        fail("manifest start_url must remain / for c4bridge.io")

    if manifest["display"] != "standalone":
        fail("manifest display must be standalone")

    if not manifest["icons"]:
        fail("manifest must include at least one icon")

    parser = IndexParser()
    parser.feed((WEB / "index.html").read_text(encoding="utf-8"))

    if "/manifest.webmanifest" not in parser.manifests:
        fail("index.html does not link /manifest.webmanifest")

    if "/app.js" not in parser.scripts:
        fail("index.html does not load /app.js")

    service_worker = (WEB / "sw.js").read_text(encoding="utf-8")
    if 'requestUrl.origin !== self.location.origin' not in service_worker:
        fail("service worker must explicitly ignore cross-origin/LAN requests")

    print("OK: C4Bridge web/PWA shell validated")


if __name__ == "__main__":
    main()
