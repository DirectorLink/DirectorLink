#!/usr/bin/env python3
"""Serves the real DirectorLink driver on localhost against a fake Director.

The driver runs in Lua 5.1 with driver/tests/c4mock.lua standing in for Director, so the app
and API clients can be developed without a controller:

    python scripts/build.py                        # optional: serve the real API description
    python scripts/dev_server.py                   # API on http://localhost:41999
    python -m http.server 8080 --directory app     # app; use "localhost" as the controller

The fake project has two rooms; five lights (two of them older Light proxies), plus an older light
that cannot be read and is listed as unsupported; three thermostats (an AC zone, and two that report
in °F: a Control4 thermostat with heat and cool setpoints, and floor heating set through its heat
setpoint); two blinds, two cameras and a door relay.
The pairing code is printed at start (valid 15 minutes, works once); type "code" and Enter for a new
one, as the Composer action New Pairing Code would.
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

    def new_pairing_code(self):
        """Runs the Composer action New Pairing Code; returns the code as Composer shows it."""
        with self.lock:
            self.process.stdin.write("code\n")
            self.process.stdin.flush()
            self.pairing_code = self.process.stdout.readline().strip().partition(" ")[2]
            return self.pairing_code

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
        print(f"DirectorLink dev server on http://localhost:{args.port} (fake Director)")
        print(f"Pairing code: {bridge.pairing_code}")
        if not spec.is_file():
            print("Note: run scripts/build.py first to serve the real API description.")
        print('Type "code" + Enter for a new pairing code.')
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for line in sys.stdin:
                if line.strip() == "code":
                    print(f"Pairing code: {bridge.new_pairing_code()}")
        except KeyboardInterrupt:
            pass
        server.shutdown()


if __name__ == "__main__":
    main()
