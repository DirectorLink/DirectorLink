#!/usr/bin/env python3
"""Static validation for the two small DirectorLink sites:

  console/  API console, debugging and logs  -> https://console.directorlink.io
  site/     landing page                     -> https://directorlink.io (and www)

Checks the published files, the Cloudflare configuration, the security headers, that the
console uses the app's API client unchanged, and that the pages keep to the CSP (no inline
scripts or styles, no scripts from elsewhere).
"""

from html.parser import HTMLParser
import json
import re
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
CONSOLE = ROOT / "console"
SITE = ROOT / "site"
APP = ROOT / "app"

GITHUB = "https://github.com/IsraelCIL/DirectorLink"
NOT_AFFILIATED = "not affiliated with Control4 or Snap One"
SLOGAN = ("Direct to Director.", "End-to-end integration.", "Open source.")

REQUIRED = {
    CONSOLE: [
        "index.html",
        "console.js",
        "console.css",
        "api-client.js",
        "icons/icon.svg",
        "_headers",
        ".assetsignore",
        "wrangler.jsonc",
        "README.md",
    ],
    SITE: [
        "index.html",
        "site.css",
        "icons/icon.svg",
        "_headers",
        ".assetsignore",
        "wrangler.jsonc",
    ],
}

WORKERS = {
    CONSOLE: ("directorlink-console", ["console.directorlink.io"]),
    SITE: ("directorlink-site", ["directorlink.io", "www.directorlink.io"]),
}

TEST_SUFFIXES = (".test.js", ".test.mjs", ".spec.js", ".spec.mjs")


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text, fragment, message):
    if fragment not in text:
        fail(message)


def rel(path):
    return path.relative_to(ROOT).as_posix()


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.scripts = []
        self.stylesheets = []
        self.links = []
        self.inline_scripts = 0
        self.inline_handlers = []
        self.style_attributes = 0
        self.style_elements = 0
        self.landmarks = set()
        self.icon = None
        self.lang = None
        self.title = ""
        self._in_title = False
        self._in_script = False

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "html":
            self.lang = values.get("lang")
        if "id" in values:
            self.ids.add(values["id"])
        if "style" in values:
            self.style_attributes += 1
        for name in values:
            if name.startswith("on"):
                self.inline_handlers.append(f"<{tag} {name}>")
        if tag == "script":
            self._in_script = True
            if values.get("src"):
                self.scripts.append(values["src"])
        if tag == "style":
            self.style_elements += 1
        if tag == "link" and values.get("rel") == "stylesheet":
            self.stylesheets.append(values.get("href"))
        if tag == "link" and values.get("rel") == "icon":
            self.icon = values.get("href")
        if tag == "a" and values.get("href"):
            self.links.append(values["href"])
        if tag in ("header", "main", "footer", "nav"):
            self.landmarks.add(tag)
        if tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "script":
            self._in_script = False
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_script and data.strip():
            self.inline_scripts += 1
        if self._in_title:
            self.title += data


def parse(path):
    parser = PageParser()
    parser.feed(path.read_text(encoding="utf-8"))
    return parser


def jsonc(path):
    text = "\n".join(line for line in path.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("//"))
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        fail(f"{rel(path)} is not valid JSON (with // comment lines): {error}")


def published_files(folder):
    ignored = set((folder / ".assetsignore").read_text(encoding="utf-8").split())
    for path in folder.rglob("*"):
        if path.is_file() and path.relative_to(folder).as_posix() not in ignored:
            yield path


def check_common(folder):
    name = folder.name
    for relative in REQUIRED[folder]:
        if not (folder / relative).is_file():
            fail(f"missing file: {name}/{relative}")

    worker, domains = WORKERS[folder]
    config = jsonc(folder / "wrangler.jsonc")
    if config.get("name") != worker:
        fail(f"{name}/wrangler.jsonc must name the Worker {worker}")
    if config.get("assets", {}).get("directory") != ".":
        fail(f"{name}/wrangler.jsonc must publish this folder (assets.directory \".\")")
    routes = config.get("routes", [])
    expected = [{"pattern": domain, "custom_domain": True} for domain in domains]
    if routes != expected:
        fail(f"{name}/wrangler.jsonc routes must be exactly the custom domains {', '.join(domains)}")
    if "previews" not in config:
        fail(f"{name}/wrangler.jsonc needs a previews block, or pull-request preview builds fail")
    if config.get("observability", {}).get("enabled") is not True:
        fail(f"{name}/wrangler.jsonc must enable Workers observability")
    if "main" in config:
        fail(f"{name}/wrangler.jsonc is a static site: no Worker script (main)")

    ignored = (folder / ".assetsignore").read_text(encoding="utf-8").split()
    for entry in ("wrangler.jsonc", ".assetsignore", "README.md"):
        if entry not in ignored:
            fail(f"{name}/.assetsignore must keep {entry} from being published")

    headers = (folder / "_headers").read_text(encoding="utf-8")
    if not headers.startswith("/*"):
        fail(f"{name}/_headers must apply to every path (/*)")
    csp_lines = [line.strip() for line in headers.splitlines() if line.strip().lower().startswith("content-security-policy:")]
    if len(csp_lines) != 1:
        fail(f"{name}/_headers must set one Content-Security-Policy")
    csp = csp_lines[0]
    for directive in ("default-src", "script-src", "object-src 'none'", "frame-ancestors 'none'", "base-uri"):
        require(csp, directive, f"{name}/_headers CSP must set {directive}")
    script_src = re.search(r"script-src ([^;]*)", csp).group(1).split()
    for unsafe in ("'unsafe-inline'", "'unsafe-eval'", "*", "http:", "https:"):
        if unsafe in script_src:
            fail(f"{name}/_headers CSP must not allow {unsafe} scripts")
    for header in ("X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "X-Frame-Options: DENY"):
        require(headers, header, f"{name}/_headers must set {header}")

    for path in folder.rglob("*"):
        if path.is_file() and path.name.endswith(TEST_SUFFIXES):
            fail(f"tests must not live in {name}/ (Cloudflare publishes everything there): {rel(path)}")

    # The old name must not come back on the new sites.
    for path in folder.rglob("*"):
        if path.is_file() and path.suffix in (".html", ".css", ".js", ".svg", ".md", ".jsonc", "") and path.name != ".assetsignore":
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"c4bridge", text, re.IGNORECASE):
                fail(f"{rel(path)} still says {match.group(0)!r}; the project is DirectorLink")

    page = parse(folder / "index.html")
    if page.lang != "en":
        fail(f"{name}/index.html must declare lang=\"en\"")
    if page.inline_scripts or page.inline_handlers:
        fail(f"{name}/index.html has inline script ({page.inline_handlers or 'a <script> body'}); the CSP only allows files")
    if page.style_attributes or page.style_elements:
        fail(f"{name}/index.html has inline styles; the CSP only allows stylesheets")
    for src in page.scripts:
        if not src.startswith("/"):
            fail(f"{name}/index.html loads a script from elsewhere: {src}")
    if page.icon != "/icons/icon.svg":
        fail(f"{name}/index.html must use /icons/icon.svg as its icon")
    for landmark in ("header", "main", "footer"):
        if landmark not in page.landmarks:
            fail(f"{name}/index.html needs a <{landmark}> landmark")
    if "main" not in page.ids:
        fail(f"{name}/index.html needs #main (the skip link target)")
    if "#main" not in page.links:
        fail(f"{name}/index.html needs a skip link to #main")
    html = (folder / "index.html").read_text(encoding="utf-8")
    require(html, NOT_AFFILIATED, f"{name}/index.html footer must say DirectorLink is {NOT_AFFILIATED}")
    if GITHUB not in page.links:
        fail(f"{name}/index.html must link to {GITHUB}")
    require(html, "DirectorLink", f"{name}/index.html must name DirectorLink")

    # Every local reference resolves to a published file.
    published = {"/" + path.relative_to(folder).as_posix() for path in published_files(folder)}
    for reference in [*page.scripts, *page.stylesheets, page.icon]:
        if reference and reference.startswith("/") and reference not in published:
            fail(f"{name}/index.html references {reference}, which is not published")
    css_files = [path for path in folder.rglob("*.css")]
    for path in css_files:
        css = path.read_text(encoding="utf-8")
        require(css, "prefers-color-scheme: dark", f"{rel(path)} must have a dark variant (prefers-color-scheme)")
        require(css, ":focus-visible", f"{rel(path)} must style keyboard focus")
    return page


def check_console():
    page = check_common(CONSOLE)
    if "/console.js" not in page.scripts:
        fail("console/index.html must load /console.js")
    require((CONSOLE / "index.html").read_text(encoding="utf-8"), 'type="module" src="/console.js"', "console.js is an ES module")
    if (CONSOLE / "sw.js").exists() or (CONSOLE / "manifest.webmanifest").exists():
        fail("the console is not a PWA: no service worker or manifest")

    client = (CONSOLE / "api-client.js").read_bytes()
    if client != (APP / "api-client.js").read_bytes():
        fail("console/api-client.js must be an exact copy of app/api-client.js (cp app/api-client.js console/)")

    headers = (CONSOLE / "_headers").read_text(encoding="utf-8")
    csp = next(line for line in headers.splitlines() if "Content-Security-Policy" in line)
    for directive in ("script-src 'self'", "connect-src 'self' http: https:", "img-src 'self' data: blob:", "style-src 'self'"):
        require(csp, directive, f"console/_headers CSP must include {directive} (the controller is plain HTTP on the LAN)")

    modules = sorted([CONSOLE / "console.js", *(CONSOLE / "js").rglob("*.js")])
    code = "\n".join(path.read_text(encoding="utf-8") for path in modules)

    # Static elements the console looks up by id must exist in index.html.
    for element_id in sorted(set(re.findall(r'byId\(\s*[`"]([A-Za-z0-9_-]+)[`"]\s*\)', code))):
        if element_id not in page.ids:
            fail(f"console JavaScript uses #{element_id}, which console/index.html does not have")
    for tab in re.findall(r'const TABS = \[([^\]]*)\]', code)[0].replace('"', "").split(","):
        tab = tab.strip()
        if tab and f"view-{tab}" not in page.ids:
            fail(f"console/index.html is missing #view-{tab}")
    for element_id in re.findall(r'querySelector(?:All)?\(\s*"#([A-Za-z0-9_-]+)', code):
        if element_id not in page.ids:
            fail(f"console JavaScript uses #{element_id}, which console/index.html does not have")

    for fragment, message in (
        ('"/v1/openapi.json"', "the API tab must load the API description from the controller"),
        ('"x-directorlink-role"', "the API tab must show each operation's role"),
        ('"/v1/auth/requests"', "the console must request admin access"),
        ('role: "admin"', "the access request must ask for the admin role"),
        ('name: CLIENT_NAME', "requests must name the key DirectorLink Console"),
        ('export const CLIENT_NAME = "DirectorLink Console"', "the console's key name is DirectorLink Console"),
        ('"/v1/auth/pair"', "the console must pair with a code from Composer"),
        ('pairing_code:', "pairing must send the code in the JSON body"),
        ('"/v1/api-keys/current"', "the console must read (and revoke) its own key"),
        ('"/v1/api-keys"', "the Keys tab must list and create keys"),
        ("/v1/logs?", "the Logs tab must follow the log"),
        ('"/v1/logs/settings"', "the Logs tab must read and change the recording level"),
        ('"/v1/health"', "the System tab must test the connection"),
        ('"/v1/system"', "the console must load the system information"),
        ("$DIRECTORLINK_KEY", "Copy as curl must use the $DIRECTORLINK_KEY placeholder"),
        ("apiImage", "binary responses (camera snapshots) must be fetched as images"),
        ("saveApiKey", "the console must store its key with saveApiKey"),
        ("handleUnauthorized", "a 401 must clear the key"),
        ('"directorlink.console.tab"', "the console must remember the last tab"),
    ):
        require(code, fragment, message)
    if "localStorage.setItem(\"directorlink.apiKey\"" in code or "sessionStorage" in code:
        fail("the console must store the key only through api-client.js")

    # Copy as curl and the diagnostics must never contain the key.
    curl = re.search(r"export function curlCommand[\s\S]*?\n}\n", code)
    if not curl or "apiKey" in curl.group(0):
        fail("curlCommand must not use the API key")
    diagnostics = re.search(r"export function diagnosticsText[\s\S]*?\n}\n", code)
    if not diagnostics:
        fail("the System tab needs diagnosticsText()")
    for secret in ("apiKey", "pairing", "api_key", ".key}", "state.key.key"):
        if secret in diagnostics.group(0):
            fail(f"the diagnostics report must never include the API key or a pairing code ({secret})")

    # Every module the console imports exists.
    for path in modules:
        for target in re.findall(r'from\s+"(\.[^"]+)"', path.read_text(encoding="utf-8")):
            if not (path.parent / target).resolve().is_file():
                fail(f"{rel(path)} imports {target}, which does not exist")


def check_site():
    page = check_common(SITE)
    if page.scripts:
        fail("site/index.html is a static page: no scripts")
    html = (SITE / "index.html").read_text(encoding="utf-8")
    text = re.sub(r"<[^>]+>", " ", html)
    text = re.sub(r"\s+", " ", text)
    for part in SLOGAN:
        require(text, part, f"site/index.html must carry the slogan ({part})")
    for link in ("https://app.directorlink.io", "https://console.directorlink.io", GITHUB):
        if link not in page.links:
            fail(f"site/index.html must link to {link}")
    require(text, "Apache-2.0", "site/index.html footer must name the license (Apache-2.0)")
    require(text, "DirectorLink Access", "How it works must mention the DirectorLink Access button")
    for stylesheet in page.stylesheets:
        if not stylesheet.startswith("/"):
            fail(f"site/index.html loads a stylesheet from elsewhere ({stylesheet}); the site makes no external requests")
    headers = (SITE / "_headers").read_text(encoding="utf-8")
    require(headers, "script-src 'none'", "site/_headers CSP must forbid scripts (the page has none)")


def png_size(path):
    """Width and height of a PNG, after checking every chunk's CRC and the image data."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{rel(path)} is not a PNG")
    position, size, image = 8, None, b""
    while position < len(data):
        if position + 12 > len(data):
            fail(f"{rel(path)} is corrupt (truncated)")
        (length,) = struct.unpack(">I", data[position : position + 4])
        if position + 12 + length > len(data):
            fail(f"{rel(path)} is corrupt (truncated)")
        kind = data[position + 4 : position + 8]
        body = data[position + 8 : position + 8 + length]
        (crc,) = struct.unpack(">I", data[position + 8 + length : position + 12 + length])
        if zlib.crc32(kind + body) & 0xFFFFFFFF != crc:
            fail(f"{rel(path)} is corrupt (bad {kind.decode(errors='replace')} checksum)")
        if kind == b"IHDR":
            size = struct.unpack(">II", body[:8])
        elif kind == b"IDAT":
            image += body
        position += 12 + length
    try:
        zlib.decompress(image)
    except zlib.error as error:
        fail(f"{rel(path)} is corrupt ({error})")
    return size


def check_icons():
    # One DL mark everywhere (scripts/make_icons.py brand writes all of them).
    mark = (APP / "icons" / "icon.svg").read_bytes()
    for folder in (CONSOLE, SITE):
        if (folder / "icons" / "icon.svg").read_bytes() != mark:
            fail(f"{folder.name}/icons/icon.svg must be the DL mark (python scripts/make_icons.py brand)")
    manifest = json.loads((APP / "manifest.webmanifest").read_text(encoding="utf-8"))
    for icon in manifest["icons"]:
        if icon.get("type") == "image/png":
            path = APP / icon["src"].lstrip("/")
            width, height = png_size(path)
            if icon.get("sizes") != f"{width}x{height}":
                fail(f"{rel(path)} is {width}x{height}, but the manifest says {icon.get('sizes')}")


def main():
    check_console()
    check_site()
    check_icons()
    print("OK: DirectorLink console and site validated")


if __name__ == "__main__":
    main()
