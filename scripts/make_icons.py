#!/usr/bin/env python3
"""Generates the PNG icons for the C4Bridge Access button (driver/www/icons).

A key glyph drawn with signed distance functions, so every size is anti-aliased without an
image library. Run it after changing the design; the PNGs are committed.
"""

import math
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "driver" / "www" / "icons"

# Button states shown in the Control4 app; colors suit its dark tiles.
STATES = {
    "idle": (208, 213, 221),
    "waiting": (247, 144, 9),
    "approved": (18, 183, 106),
}
APP_SIZES = (70, 90, 300, 512, 1024)


def box(px, py, x0, y0, x1, y1):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2, (y1 - y0) / 2
    dx, dy = abs(px - cx) - hx, abs(py - cy) - hy
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    return outside + min(max(dx, dy), 0.0)


def key_distance(x, y):
    """Signed distance (in units of the icon size) to a key: ring bow, shaft, two teeth."""
    ring = abs(math.hypot(x - 0.32, y - 0.5) - 0.145) - 0.055
    shaft = box(x, y, 0.44, 0.46, 0.86, 0.54)
    tooth_a = box(x, y, 0.70, 0.54, 0.76, 0.64)
    tooth_b = box(x, y, 0.80, 0.54, 0.86, 0.68)
    return min(ring, shaft, tooth_a, tooth_b)


def alpha_mask(size):
    rows = []
    for py in range(size):
        y = (py + 0.5) / size
        row = []
        for px in range(size):
            distance = key_distance((px + 0.5) / size, y) * size
            row.append(max(0.0, min(1.0, 0.5 - distance)))
        rows.append(row)
    return rows


def png(size, mask, color, background=None):
    raw = bytearray()
    for row in mask:
        raw.append(0)
        for coverage in row:
            if background:
                pixel = [round(b + (c - b) * coverage) for b, c in zip(background, color)] + [255]
            else:
                pixel = list(color) + [round(255 * coverage)]
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


def main():
    (OUT / "access").mkdir(parents=True, exist_ok=True)
    for size in APP_SIZES:
        mask = alpha_mask(size)
        for state, color in STATES.items():
            (OUT / "access" / f"{state}_{size}.png").write_bytes(png(size, mask, color))
    # Composer project-tree icons: the key on the C4Bridge dark blue.
    for name, size in (("device_sm.png", 16), ("device_lg.png", 32)):
        (OUT / name).write_bytes(png(size, alpha_mask(size), (255, 255, 255), background=(15, 23, 42)))
    print(f"Wrote {len(APP_SIZES) * len(STATES) + 2} icons to {OUT}")


if __name__ == "__main__":
    main()
