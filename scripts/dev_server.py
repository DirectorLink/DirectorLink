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
setpoint); two fans (one on at Medium, one off), which follow their commands; two blinds, two
cameras and a door relay.
Two more shades report their movement as KNX blinds do (one of them only opens and closes fully),
and every blind moves over some seconds, reported while the requests come in.
An alarm panel has two partitions (House, disarmed with a zone open; Garage, armed away) and a third
it does not use; Alarm Status is On in this fake home. Type "alarm off" or "alarm on" to switch it
as in Composer, and "var <device id> <variable id> <value>" for a partition to report a change
(e.g. "var 80 1007 ENTRY_DELAY"; the variables are listed in driver/tests/c4mock.lua).
The pairing code is printed at start (valid 15 minutes, works once); type "code" and Enter for a new
one, as the Composer action New Pairing Code would.
The Jewish calendar is Off, as it ships; --jewish-calendar starts with it On (the fake project is in
Tel Aviv, so there are Shabbat and holiday times for the app's screens), and "calendar on" or
"calendar off" switches it as in Composer.
"""

import argparse
import json
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

    def _ask(self, line, expected):
        with self.lock:
            self.process.stdin.write(line + "\n")
            self.process.stdin.flush()
            word, _, payload = self.process.stdout.readline().strip().partition(" ")
        if word != expected:
            raise RuntimeError(f"the bridge answered {word!r} to {line.split(' ', 1)[0]!r}")
        return payload

    def set_property(self, name, value):
        """Sets a Composer property of DirectorLink, as an installer would (OnPropertyChanged)."""
        self._ask(f"property {name.encode().hex()} {value.encode().hex()}", "PROPERTY")

    def report_variable(self, device_id, variable_id, value):
        """A device of the fake project reports a variable; returns how many listeners heard it."""
        return int(self._ask(f"variable {int(device_id)} {int(variable_id)} {str(value).encode().hex()}", "VARIABLE"))

    def seal(self, key, key_id, request):
        """The envelope the app would send to POST /v1/sealed for `request` ({method, path, body})."""
        asked = json.dumps({"key": key, "key_id": key_id, "request": request})
        return json.loads(bytes.fromhex(self._ask(f"seal {asked.encode().hex()}", "SEALED")))

    def unseal(self, key, envelope):
        """The answer inside a sealed envelope: {id, ts, status, content_type, body}, or None."""
        asked = json.dumps({"key": key, "envelope": envelope})
        return json.loads(bytes.fromhex(self._ask(f"open {asked.encode().hex()}", "OPENED")))

    def open_pairing(self, isk, envelope):
        """The new key inside the sealed answer of a pairing with CPace (the ISK, bytes), or None."""
        asked = json.dumps({"isk": isk.hex(), "envelope": envelope})
        return json.loads(bytes.fromhex(self._ask(f"open {asked.encode().hex()}", "OPENED")))


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
    parser.add_argument("--jewish-calendar", action="store_true", help="start with the Composer property Jewish Calendar = On")
    args = parser.parse_args()
    if not args.lua:
        sys.exit("Lua 5.1 not found; install it or pass --lua")

    spec = ROOT / "dist" / "openapi.json"
    bridge = Bridge(args.lua, spec if spec.is_file() else None)
    if args.jewish_calendar:
        bridge.set_property("Jewish Calendar", "On")
    with Server(("127.0.0.1", args.port), make_handler(bridge)) as server:
        print(f"DirectorLink dev server on http://localhost:{args.port} (fake Director)")
        print(f"Pairing code: {bridge.pairing_code}")
        if args.jewish_calendar:
            print("Jewish Calendar: On")
        if not spec.is_file():
            print("Note: run scripts/build.py first to serve the real API description.")
        print('Type "code" + Enter for a new pairing code; "alarm off" / "alarm on"; "calendar on" / "calendar off"; "var <device> <variable> <value>".')
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for line in sys.stdin:
                words = line.split()
                if words == ["code"]:
                    print(f"Pairing code: {bridge.new_pairing_code()}")
                elif len(words) == 2 and words[0] == "alarm" and words[1] in ("on", "off"):
                    bridge.set_property("Alarm Status", words[1].capitalize())
                    print(f"Alarm Status: {words[1].capitalize()}")
                elif len(words) == 2 and words[0] == "calendar" and words[1] in ("on", "off"):
                    bridge.set_property("Jewish Calendar", words[1].capitalize())
                    print(f"Jewish Calendar: {words[1].capitalize()}")
                elif len(words) >= 3 and words[0] == "var" and words[1].isdigit() and words[2].isdigit():
                    value = line.split(None, 3)[3].strip() if len(words) > 3 else ""
                    print(f"Reported to {bridge.report_variable(words[1], words[2], value)} listener(s)")
        except KeyboardInterrupt:
            pass
        server.shutdown()


if __name__ == "__main__":
    main()
