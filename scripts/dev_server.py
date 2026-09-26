#!/usr/bin/env python3
"""Serves the real C4Bridge driver on localhost against a fake Director.

The driver runs in Lua 5.1 with driver/tests/c4mock.lua standing in for Director, so the web app
and API clients can be developed without a controller:

    python scripts/build.py                        # optional: serve the real API description
    python scripts/dev_server.py                   # API on http://localhost:41999
    python -m http.server 8080 --directory web     # web app; use "localhost" as the controller

The fake project has two rooms, three lights, one thermostat, two blinds and two cameras. The pairing code is printed at start;
type "press" and Enter to press the C4Bridge Access button (approves a waiting access request).
"""

import argparse
import shutil
import socketserver
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class Bridge:
    """One Lua process running the driver; requests are serialized because the driver is single-threaded."""

    def __init__(self, lua, spec_path):
        self.process = subprocess.Popen(
            [lua, "driver/tests/dev_bridge.lua", str(spec_path or "")],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        ready = self.process.stdout.readline().strip()
        if not ready.startswith("READY"):
            raise SystemExit(f"driver failed to start: {ready!r}")
        self.pairing_code = ready.split(" ", 1)[1]
        self.lock = threading.Lock()
        self.handles = 0

    def new_handle(self):
        with self.lock:
            self.handles += 1
            return self.handles

    def press_access_button(self):
        """Simulates pressing C4Bridge Access in the Control4 app."""
        with self.lock:
            self.process.stdin.write("press\n")
            self.process.stdin.flush()
            self.process.stdout.readline()

    def exchange(self, handle, data):
        with self.lock:
            self.process.stdin.write(f"{handle} {data.hex()}\n")
            self.process.stdin.flush()
            closed, _, payload = self.process.stdout.readline().strip().partition(" ")
            return closed == "1", bytes.fromhex(payload)


def make_handler(bridge):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            handle = bridge.new_handle()
            while True:
                chunk = self.request.recv(65536)
                if not chunk:
                    bridge.exchange(handle, b"")
                    return
                closed, response = bridge.exchange(handle, chunk)
                if response:
                    self.request.sendall(response)
                if closed:
                    return

    return Handler


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=41999)
    parser.add_argument("--lua", default=shutil.which("lua5.1") or shutil.which("lua"))
    args = parser.parse_args()
    if not args.lua:
        sys.exit("Lua 5.1 not found; install it or pass --lua")

    spec = ROOT / "dist" / "openapi.json"
    bridge = Bridge(args.lua, spec if spec.is_file() else None)
    with Server(("127.0.0.1", args.port), make_handler(bridge)) as server:
        print(f"C4Bridge dev server on http://localhost:{args.port} (fake Director)")
        print(f"Pairing code: {bridge.pairing_code}")
        if not spec.is_file():
            print("Note: run scripts/build.py first to serve the real API description.")
        print('Type "press" + Enter to press the C4Bridge Access button.')
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for line in sys.stdin:
                if line.strip() == "press":
                    bridge.press_access_button()
                    print("C4Bridge Access pressed")
        except KeyboardInterrupt:
            pass
        server.shutdown()


if __name__ == "__main__":
    main()
