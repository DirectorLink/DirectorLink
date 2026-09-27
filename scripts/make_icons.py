#!/usr/bin/env python3
"""Generates DirectorLink's icons without an image library.

Shapes are drawn with signed distance functions, so every size is anti-aliased. Run it after
changing a design; the outputs are committed.

    python scripts/make_icons.py            # everything
    python scripts/make_icons.py driver     # Composer device icons (driver/www/icons)
    python scripts/make_icons.py brand      # the DL mark: app icons, console and site favicons

The DL mark is a white D ("Director") and a blue L ("Link") on graphite. The app's PNGs fill the
whole square with the glyph inside the maskable safe zone (the manifest lists them as
"any maskable"); the SVGs have rounded corners because they are also shown as images.
"""

import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "driver" / "www" / "icons"

def box(px, py, x0, y0, x1, y1):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2, (y1 - y0) / 2
    dx, dy = abs(px - cx) - hx, abs(py - cy) - hy
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    return outside + min(max(dx, dy), 0.0)


def encode_png(size, pixels):
    """pixels: rows of (r, g, b, a) tuples."""
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for pixel in row:
            raw.extend(pixel)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


# ---- DL mark ---------------------------------------------------------------------------------
# Geometry on a 512 × 512 canvas (the SVG viewBox); the PNGs scale it.

GRAPHITE = (24, 24, 27)  # #18181b, the graphite palette's ink
WHITE = (255, 255, 255)
BLUE = (59, 130, 246)  # #3b82f6, between the graphite palette's light and dark primaries
CANVAS = 512
CORNER = 112  # SVG corner radius
STROKE = 54
TOP, BOTTOM = 158, 354  # letter height 196
D_LEFT, D_FLAT = 98, 190  # the D's stem edge and where its bowl starts
L_LEFT, L_RIGHT = 306, 418
OVERLAP = 8  # the D's bowl reaches into its straight part, so the join leaves no seam
SAFE_RADIUS = 0.4  # maskable icons: everything important within 40 % of the size from the centre


def d_outer(x, y):
    radius = (BOTTOM - TOP) / 2
    middle = (TOP + BOTTOM) / 2
    bowl = max(math.hypot(x - D_FLAT, y - middle) - radius, D_FLAT - OVERLAP - x)
    return min(box(x, y, D_LEFT, TOP, D_FLAT, BOTTOM), bowl)


def d_inner(x, y):
    radius = (BOTTOM - TOP) / 2 - STROKE
    middle = (TOP + BOTTOM) / 2
    bowl = max(math.hypot(x - D_FLAT, y - middle) - radius, D_FLAT - OVERLAP - x)
    return min(box(x, y, D_LEFT + STROKE, TOP + STROKE, D_FLAT, BOTTOM - STROKE), bowl)


def d_distance(x, y):
    return max(d_outer(x, y), -d_inner(x, y))


def l_distance(x, y):
    stem = box(x, y, L_LEFT, TOP, L_LEFT + STROKE, BOTTOM)
    foot = box(x, y, L_LEFT, BOTTOM - STROKE, L_RIGHT, BOTTOM)
    return min(stem, foot)


def brand_png(size):
    scale = CANVAS / size
    pixels = []
    for py in range(size):
        y = (py + 0.5) * scale
        line = []
        for px in range(size):
            x = (px + 0.5) * scale
            color = GRAPHITE
            for distance, ink in ((d_distance, WHITE), (l_distance, BLUE)):
                coverage = max(0.0, min(1.0, 0.5 - distance(x, y) / scale))
                if coverage:
                    color = tuple(c + (i - c) * coverage for c, i in zip(color, ink))
            line.append(tuple(round(c) for c in color) + (255,))
        pixels.append(line)
    return encode_png(size, pixels)


def brand_svg():
    radius = (BOTTOM - TOP) / 2
    inner = radius - STROKE
    d_path = (
        f"M{D_LEFT} {TOP}H{D_FLAT}A{radius:g} {radius:g} 0 0 1 {D_FLAT} {BOTTOM}H{D_LEFT}Z"
        f"M{D_LEFT + STROKE} {TOP + STROKE}V{BOTTOM - STROKE}H{D_FLAT}"
        f"A{inner:g} {inner:g} 0 0 0 {D_FLAT} {TOP + STROKE}Z"
    )
    l_path = f"M{L_LEFT} {TOP}h{STROKE}V{BOTTOM - STROKE}H{L_RIGHT}V{BOTTOM}H{L_LEFT}Z"
    hex_color = lambda rgb: "#%02x%02x%02x" % rgb  # noqa: E731
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" role="img" aria-label="DirectorLink">\n'
        f'  <rect width="{CANVAS}" height="{CANVAS}" rx="{CORNER}" fill="{hex_color(GRAPHITE)}"/>\n'
        f'  <path d="{d_path}" fill="{hex_color(WHITE)}" fill-rule="evenodd"/>\n'
        f'  <path d="{l_path}" fill="{hex_color(BLUE)}"/>\n'
        f"</svg>\n"
    )


def check_safe_zone():
    """The glyph's farthest corner must stay inside the maskable safe zone."""
    corners = [(D_LEFT, TOP), (D_LEFT, BOTTOM), (L_RIGHT, TOP), (L_RIGHT, BOTTOM)]
    farthest = max(math.hypot(x - CANVAS / 2, y - CANVAS / 2) for x, y in corners)
    if farthest > SAFE_RADIUS * CANVAS:
        raise SystemExit(f"the DL mark reaches {farthest:.0f}px from the centre; the safe zone is {SAFE_RADIUS * CANVAS:.0f}px")


def make_brand():
    check_safe_zone()
    svg = brand_svg()
    for folder in ("app", "console", "site"):
        (ROOT / folder / "icons").mkdir(parents=True, exist_ok=True)
        (ROOT / folder / "icons" / "icon.svg").write_text(svg, encoding="utf-8", newline="\n")
    for size in (192, 512):
        (ROOT / "app" / "icons" / f"icon-{size}.png").write_bytes(brand_png(size))
    print("Wrote the DL mark: app/icons (icon.svg, icon-192.png, icon-512.png), console/icons/icon.svg, site/icons/icon.svg")


def make_driver():
    # Composer's project tree shows these next to DirectorLink.
    OUT.mkdir(parents=True, exist_ok=True)
    for name, size in (("device_sm.png", 16), ("device_lg.png", 32)):
        (OUT / name).write_bytes(brand_png(size))
    print(f"Wrote device_sm.png and device_lg.png to {OUT}")


def main():
    targets = sys.argv[1:] or ["driver", "brand"]
    for target in targets:
        if target == "driver":
            make_driver()
        elif target == "brand":
            make_brand()
        else:
            raise SystemExit(f"unknown target {target!r}; use driver and/or brand")


if __name__ == "__main__":
    main()
