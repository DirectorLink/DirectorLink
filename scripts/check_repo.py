#!/usr/bin/env python3
"""Fails when the repository tracks files that must never be published: local tool configuration
(it holds account details) and secrets (keys, local variables, certificates).

`.claude.json` was once committed by accident with an account's email and ids (removed from the
whole history on 2026-09-28); this keeps it, and files like it, out.
"""

import fnmatch
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FORBIDDEN = (
    ".claude.json",
    ".claude/*",
    "*/.claude.json",
    ".dev.vars",
    "*/.dev.vars",
    ".env",
    ".env.*",
    "*/.env",
    "*.p8",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "id_rsa*",
    "id_ed25519*",
)

# Tracked on purpose although they match a pattern above: public root certificates the driver
# trusts for the relay (docs/RELAY.md). They may hold certificates only, never a key.
ALLOWED = {
    "driver/certs/directorlink-roots.pem",
}


def main():
    tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True, cwd=ROOT).stdout.splitlines()
    found = sorted({path for path in tracked for pattern in FORBIDDEN if fnmatch.fnmatch(path, pattern) and path not in ALLOWED})
    for path in sorted(ALLOWED & set(tracked)):
        text = (ROOT / path).read_text(encoding="ascii", errors="replace")
        blocks = re.findall(r"^-----BEGIN ([A-Z0-9 ]+)-----\r?$", text, re.M)
        if not blocks or set(blocks) != {"CERTIFICATE"} or "PRIVATE KEY" in text:
            found.append(f"{path} (must hold certificates only, found {sorted(set(blocks))})")
    if found:
        print("ERROR: these files must not be in the repository:", file=sys.stderr)
        for path in found:
            print(f"  {path}", file=sys.stderr)
        print("Remove them (git rm --cached) and add them to .gitignore.", file=sys.stderr)
        raise SystemExit(1)
    print(f"OK: {len(tracked)} tracked files, none of them local configuration or secrets")


if __name__ == "__main__":
    main()
