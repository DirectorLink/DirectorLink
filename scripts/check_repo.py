#!/usr/bin/env python3
"""Fails when the repository tracks files that must never be published: local tool configuration
(it holds account details) and secrets (keys, local variables, certificates).

`.claude.json` was once committed by accident with an account's email and ids (removed from the
whole history on 2026-09-28); this keeps it, and files like it, out.
"""

import fnmatch
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_package import relay_roots_problem  # noqa: E402

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
# trusts for the relay (docs/RELAY.md). They must hold exactly the pinned roots
# (scripts/check_package.py), never a key or another certificate.
ALLOWED = {
    "driver/certs/directorlink-roots.pem",
}


def main():
    # The index, not the working tree: what is staged is what gets committed.
    tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True, cwd=ROOT).stdout.splitlines()
    found = sorted({path for path in tracked for pattern in FORBIDDEN if fnmatch.fnmatch(path, pattern) and path not in ALLOWED})
    wrong = []
    for path in sorted(ALLOWED & set(tracked)):
        staged = subprocess.run(["git", "cat-file", "blob", f":{path}"], capture_output=True, check=True, cwd=ROOT).stdout
        problem = relay_roots_problem(staged)
        if problem:
            wrong.append(f"{path}: {problem}")
    if found:
        print("ERROR: these files must not be in the repository:", file=sys.stderr)
        for path in found:
            print(f"  {path}", file=sys.stderr)
        print("Remove them (git rm --cached) and add them to .gitignore.", file=sys.stderr)
    if wrong:
        print("ERROR: the staged relay roots are not the pinned ones (scripts/check_package.py):", file=sys.stderr)
        for problem in wrong:
            print(f"  {problem}", file=sys.stderr)
        print("Stage the file as it should be (git add), or restore it (git restore --staged --worktree).", file=sys.stderr)
    if found or wrong:
        raise SystemExit(1)
    print(f"OK: {len(tracked)} tracked files, none of them local configuration or secrets")


if __name__ == "__main__":
    main()
