#!/usr/bin/env python3
"""Fails when the repository tracks files that must never be published: local tool configuration
(it holds account details) and secrets (keys, local variables, certificates).

`.claude.json` was once committed by accident with an account's email and ids (removed from the
whole history on 2026-09-28); this keeps it, and files like it, out.
"""

import fnmatch
import subprocess
import sys

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


def main():
    tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.splitlines()
    found = sorted({path for path in tracked for pattern in FORBIDDEN if fnmatch.fnmatch(path, pattern)})
    if found:
        print("ERROR: these files must not be in the repository:", file=sys.stderr)
        for path in found:
            print(f"  {path}", file=sys.stderr)
        print("Remove them (git rm --cached) and add them to .gitignore.", file=sys.stderr)
        raise SystemExit(1)
    print(f"OK: {len(tracked)} tracked files, none of them local configuration or secrets")


if __name__ == "__main__":
    main()
