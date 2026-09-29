#!/usr/bin/env python3
"""Contract test: runs the real driver (fake Director) on a local port, calls every API operation
with a real HTTP client, and validates each response against api/openapi.yaml.

Checks per response: the status code is declared for the operation, the Content-Type matches the
declared media type, and the JSON body validates against the declared schema. Fails if any
operation in the spec was not exercised.

It also validates the hand-written calendar examples the app's tests read
(tests/vectors/calendar/api-examples.json): each group is named after the schema its examples match.
"""

import base64
import json
import os
import re
import shutil
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_server  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SPEC = yaml.safe_load((ROOT / "api" / "openapi.yaml").read_text(encoding="utf-8"))
REGISTRY = Registry().with_resource("urn:spec", Resource.from_contents(SPEC, default_specification=DRAFT202012))
METHODS = ("get", "post", "put", "patch", "delete")
EXAMPLES_FILE = ROOT / "tests" / "vectors" / "calendar" / "api-examples.json"
EXAMPLES = json.loads(EXAMPLES_FILE.read_text(encoding="utf-8"))


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def resolve(node):
    while isinstance(node, dict) and "$ref" in node:
        target = SPEC
        for part in node["$ref"].lstrip("#/").split("/"):
            target = target[part]
        node = target
    return node


def x25519_public(private):
    """The X25519 public key (RFC 7748) of 32 private bytes, for pairing with a key exchange."""
    p = 2**255 - 19
    scalar = bytearray(private)
    scalar[0] &= 248
    scalar[31] &= 127
    scalar[31] |= 64
    k = int.from_bytes(scalar, "little")
    x1, x2, z2, x3, z3, swap = 9, 1, 0, 9, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % p, (x2 - z2) % p
        aa, bb = a * a % p, b * b % p
        e = (aa - bb) % p
        c, d = (x3 + z3) % p, (x3 - z3) % p
        da, cb = d * a % p, c * b % p
        x3, z3 = (da + cb) ** 2 % p, x1 * (da - cb) ** 2 % p
        x2, z2 = aa * bb % p, e * (aa + 121665 * e) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def absolute(schema):
    """The schema with its references pointing into the spec (also inside oneOf, items, ...)."""
    if isinstance(schema, dict):
        return {key: ("urn:spec#" + value[1:] if key == "$ref" and isinstance(value, str) and value.startswith("#") else absolute(value))
                for key, value in schema.items()}
    if isinstance(schema, list):
        return [absolute(item) for item in schema]
    return schema


def template_regex(path):
    return re.compile("^" + re.sub(r"\\\{[^}]+\\\}", "[^/]+", re.escape(path)) + "$")


def check_examples():
    """Every example in api-examples.json matches the schema its group is named after (dates and
    times included). Returns how many there are."""
    count = 0
    for group, examples in EXAMPLES.items():
        if group == "about":
            continue
        if group not in SPEC["components"]["schemas"]:
            fail(f"{EXAMPLES_FILE.name}: {group} is not a schema in api/openapi.yaml")
        validator = Draft202012Validator({"$ref": f"urn:spec#/components/schemas/{group}"}, registry=REGISTRY,
                                         format_checker=Draft202012Validator.FORMAT_CHECKER)
        for name, example in examples.items():
            if not isinstance(example, dict) or "value" not in example:
                fail(f"{EXAMPLES_FILE.name}: {group}.{name} has no value")
            errors = sorted(validator.iter_errors(example["value"]), key=lambda e: list(e.path))
            if errors:
                details = "; ".join(f"{'/'.join(map(str, e.path)) or '(root)'}: {e.message}" for e in errors[:5])
                fail(f"{EXAMPLES_FILE.name}: {group}.{name} does not match the spec: {details}")
            count += 1
    return count


OPERATIONS = [
    (method.upper(), path, template_regex(path), item[method])
    for path, item in SPEC["paths"].items()
    for method in METHODS
    if method in item
]


def operation_for(method, target):
    path = target.split("?", 1)[0]
    operation = next((op for op in OPERATIONS if op[0] == method and op[2].match(path)), None)
    if not operation:
        fail(f"{method} {path} is not an operation in the spec")
    return operation[1], operation[3]


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.key = None
        self.key_id = None
        self.covered = set()
        self.checked = 0

    def check(self, method, target, expected, body=None, auth=True, headers=None):
        template, definition = operation_for(method, target)

        request = urllib.request.Request(self.base + target, method=method, headers=dict(headers or {}))
        if body is not None:
            request.data = json.dumps(body).encode()
            request.add_header("Content-Type", "application/json")
        if auth and self.key:
            request.add_header("Authorization", f"Bearer {self.key}")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                status, content_type, raw = response.status, response.headers.get("Content-Type", ""), response.read()
                response_headers = response.headers
        except urllib.error.HTTPError as error:
            status, content_type, raw = error.code, error.headers.get("Content-Type", ""), error.read()
            response_headers = error.headers
        return self.validate(f"{method} {target} -> {status}", method, template, definition, expected, status, content_type, raw, response_headers)

    def check_sealed(self, bridge, method, target, expected, body=None):
        """The request sealed as the app seals it at home (POST /v1/sealed, no Authorization
        header), and the answer inside the sealed envelope checked against the operation."""
        template, definition = operation_for(method, target)
        request = {"method": method, "path": target}
        if body is not None:
            request["body"] = body
        envelope = bridge.seal(self.key, self.key_id, request)
        sealed = self.check("POST", "/v1/sealed", 200, body={"envelope": envelope}, auth=False)
        answer = bridge.unseal(self.key, sealed["envelope"])
        if not isinstance(answer, dict):
            fail(f"sealed {method} {target}: the answer does not open with the key's lock key")
        raw = answer.get("body", "").encode()
        content_type = answer.get("content_type", "")
        return self.validate(f"sealed {method} {target} -> {answer.get('status')}", method, template, definition, expected,
                             answer.get("status"), content_type, raw, {})

    def validate(self, label, method, template, definition, expected, status, content_type, raw, response_headers):
        if status != expected:
            fail(f"{label}, expected {expected}: {raw[:300]!r}")
        declared = resolve(definition["responses"].get(str(status)))
        if declared is None:
            fail(f"{label}: status {status} is not documented for {method} {template}")

        content = declared.get("content")
        if not content:
            if raw:
                fail(f"{label}: expected an empty body")
        else:
            media_type = next(iter(content))
            if content_type.split(";")[0].strip() != media_type:
                fail(f"{label}: Content-Type {content_type!r}, spec says {media_type}")
            if not media_type.endswith("json"):
                if not raw:
                    fail(f"{label}: expected a {media_type} body")
                self.covered.add((method, template))
                self.checked += 1
                return raw
            data = json.loads(raw)
            schema = content[media_type].get("schema", {})
            validator = Draft202012Validator(absolute(schema), registry=REGISTRY)
            errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
            if errors:
                details = "; ".join(f"{'/'.join(map(str, e.path)) or '(root)'}: {e.message}" for e in errors[:5])
                fail(f"{label}: response does not match the spec: {details}")
            for name in resolve(declared).get("headers", {}):
                if name not in response_headers:
                    fail(f"{label}: missing documented header {name}")

        self.covered.add((method, template))
        self.checked += 1
        return json.loads(raw) if raw else None


def scenario(client, bridge):
    client.check("GET", "/v1/health", 200)
    client.check("GET", "/v1/openapi.json", 200)
    client.check("GET", "/v1/system", 401)
    client.check("POST", "/v1/auth/pair", 403, body={"pairing_code": "00000000"})
    client.check("POST", "/v1/auth/pair", 400, body={"pairing_code": "12"})
    paired = client.check("POST", "/v1/auth/pair", 201, body={"pairing_code": bridge.pairing_code, "name": "contract test"})
    client.key, client.key_id = paired["key"], paired["id"]
    client.check("POST", "/v1/auth/pair", 403, body={"pairing_code": bridge.pairing_code})  # used: works once

    client.check("GET", "/v1/system", 200)
    client.check("GET", "/v1/rooms", 200)
    client.check("GET", "/v1/rooms/10", 200)
    client.check("GET", "/v1/rooms/999", 404)
    client.check("GET", "/v1/rooms/abc", 400)
    client.check("PATCH", "/v1/rooms/10", 200, body={"names": {"en": "Kitchen", "he": "מטבח"}})
    client.check("PATCH", "/v1/rooms/10", 400, body={"names": {"english": "Kitchen"}})
    client.check("PATCH", "/v1/rooms/999", 404, body={"names": {"en": "x"}})
    client.check("GET", "/v1/devices", 200)
    client.check("GET", "/v1/devices?type=light&supported=true&room_id=11", 200)
    client.check("GET", "/v1/devices?type=lamp", 400)
    client.check("GET", "/v1/devices/40", 200)
    client.check("GET", "/v1/devices/9", 404)

    client.check("GET", "/v1/lights", 200)
    client.check("GET", "/v1/lights?room_id=10", 200)
    client.check("GET", "/v1/lights/20", 200)
    client.check("GET", "/v1/lights/99", 404)
    client.check("PATCH", "/v1/lights/20", 202, body={"brightness": 50})
    client.check("PATCH", "/v1/lights/21", 202, body={"on": True})
    client.check("PATCH", "/v1/lights/21", 409, body={"brightness": 50})
    client.check("PATCH", "/v1/lights/21", 400, body={"on": "yes"})
    client.check("PATCH", "/v1/lights/99", 404, body={"on": True})

    client.check("GET", "/v1/thermostats", 200)
    client.check("GET", "/v1/thermostats/30", 200)
    client.check("GET", "/v1/thermostats/20", 404)
    client.check("PATCH", "/v1/thermostats/30", 202, body={"mode": "heat", "target_temperature": 21, "fan_speed": "medium"})
    client.check("PATCH", "/v1/thermostats/30", 409, body={"mode": "auto"})
    client.check("PATCH", "/v1/thermostats/30", 400, body={"target_temperature": 99})

    # The 1.1.0 device families (Mock.demoProject): older lights (25 dimmer, 26 switch), a
    # thermostat with heat and cool setpoints (31, in auto) and floor heating on its heat setpoint (32).
    client.check("GET", "/v1/lights/25", 200)
    client.check("PATCH", "/v1/lights/25", 202, body={"brightness": 40})
    client.check("PATCH", "/v1/lights/26", 409, body={"brightness": 40})
    client.check("GET", "/v1/thermostats/31", 200)
    client.check("PATCH", "/v1/thermostats/31", 202, body={"mode": "auto", "heat_setpoint": 20, "cool_setpoint": 24})
    client.check("PATCH", "/v1/thermostats/31", 202, body={"mode": "cool", "target_temperature": 24})
    client.check("PATCH", "/v1/thermostats/31", 202, body={"fan_speed": "on"})
    client.check("PATCH", "/v1/thermostats/31", 400, body={"heat_setpoint": 22, "cool_setpoint": 23})
    client.check("PATCH", "/v1/thermostats/31", 400, body={"target_temperature": 22, "heat_setpoint": 20})
    client.check("PATCH", "/v1/thermostats/31", 409, body={"target_temperature": 22})
    client.check("PATCH", "/v1/thermostats/30", 409, body={"heat_setpoint": 20})
    client.check("GET", "/v1/thermostats/32", 200)
    client.check("PATCH", "/v1/thermostats/32", 202, body={"target_temperature": 6})

    client.check("GET", "/v1/blinds", 200)
    client.check("GET", "/v1/blinds?room_id=11", 200)
    client.check("GET", "/v1/blinds/50", 200)
    client.check("GET", "/v1/blinds/51", 200)
    client.check("GET", "/v1/blinds/20", 404)
    client.check("PATCH", "/v1/blinds/50", 202, body={"position": 100})
    client.check("PATCH", "/v1/blinds/50", 400, body={"position": 101})
    client.check("PATCH", "/v1/blinds/99", 404, body={"position": 0})
    client.check("POST", "/v1/blinds/50/stop", 202)
    client.check("POST", "/v1/blinds/99/stop", 404)
    # Shades that say what they can do (1.1.0, Mock.withShades): 52 goes anywhere and stops, 53
    # only opens and closes fully and cannot stop. The dev bridge moves them as KNX blinds move.
    client.check("PATCH", "/v1/blinds/52", 202, body={"position": 60})
    moving = client.check("GET", "/v1/blinds/52", 200)
    if (moving["moving"], moving["direction"], moving["target_position"]) != (True, "opening", 60):
        fail(f"GET /v1/blinds/52 should show the shade opening to 60: {moving}")
    client.check("POST", "/v1/blinds/52/stop", 202)
    client.check("PATCH", "/v1/blinds/53", 409, body={"position": 50})
    client.check("PATCH", "/v1/blinds/53", 202, body={"position": 100})
    client.check("POST", "/v1/blinds/53/stop", 409)

    client.check("GET", "/v1/cameras", 200)
    client.check("GET", "/v1/cameras/60", 200)
    client.check("GET", "/v1/cameras/20", 404)
    client.check("GET", "/v1/cameras/60/snapshot", 200)
    client.check("GET", "/v1/cameras/61/snapshot?width=320", 200)
    client.check("GET", "/v1/cameras/60/snapshot?width=500", 400)
    client.check("GET", "/v1/cameras/99/snapshot", 404)

    client.check("GET", "/v1/relays", 200)
    client.check("GET", "/v1/relays/70", 200)
    client.check("GET", "/v1/relays/20", 404)
    client.check("PATCH", "/v1/relays/70", 202, body={"state": "open"})
    # Holding a relay closed holds its door open: refused while Relay Hold is Not allowed (1.1.1).
    held = client.check("PATCH", "/v1/relays/70", 409, body={"state": "closed"})
    if held["code"] != "HOLD_NOT_ALLOWED":
        fail(f"PATCH /v1/relays/70 closed should be refused with HOLD_NOT_ALLOWED: {held}")
    client.check("PATCH", "/v1/relays/70", 400, body={"state": "unlocked"})
    client.check("POST", "/v1/relays/70/pulse", 202)
    client.check("POST", "/v1/relays/99/pulse", 404)

    client.check("GET", "/v1/doorbells", 200)
    client.check("GET", "/v1/doorbells/93", 200)
    client.check("GET", "/v1/doorbells/92", 404)
    client.check("POST", "/v1/doorbells/93/open", 202)
    client.check("POST", "/v1/doorbells/99/open", 404)

    # The alarm's status (1.2.0, ADR-038): read-only, off by default (the dev bridge's fake home
    # has it on), and while it is on only in sealed answers (Mock.withPartitions: 80 House, 81
    # Garage, 82 unused).
    bridge.set_property("Alarm Status", "Off")
    off = client.check("GET", "/v1/alarm", 200)
    if off != {"enabled": False, "partitions": []}:
        fail(f"GET /v1/alarm with Alarm Status Off should say only that: {off}")
    if client.check("GET", "/v1/system", 200)["features"]["alarm_status"] is not False:
        fail("GET /v1/system should say that the alarm status is off")
    if client.check_sealed(bridge, "GET", "/v1/alarm", 200) != off:
        fail("a sealed GET /v1/alarm should say only that it is off")
    bridge.set_property("Alarm Status", "On")
    clear = client.check("GET", "/v1/alarm", 403)
    if clear["code"] != "SEALED_REQUEST_REQUIRED":
        fail(f"GET /v1/alarm in the clear should be refused with SEALED_REQUEST_REQUIRED: {clear}")
    alarm = client.check_sealed(bridge, "GET", "/v1/alarm", 200)
    if [partition["id"] for partition in alarm["partitions"]] != [81, 80]:
        fail(f"GET /v1/alarm should list Garage and House, and not the partition the panel does not use: {alarm}")
    for variable, value in ((1007, "ENTRY_DELAY"), (1008, "30"), (1009, "12"), (1003, "1"), (1011, "Fire"), (1005, "Low battery")):
        if bridge.report_variable(80, variable, value) != 1:
            fail(f"partition 80 should watch variable {variable}")
    house = client.check_sealed(bridge, "GET", "/v1/alarm", 200)["partitions"][1]
    if (house["delay"], house["alarm_type"], house["trouble"]) != ({"type": "entry", "remaining": 12, "total": 30}, "Fire", "Low battery"):
        fail(f"GET /v1/alarm should show House's entry delay, fire alarm and trouble: {house}")
    if client.check("GET", "/v1/system", 200)["features"]["alarm_status"] is not True:
        fail("GET /v1/system should say that the alarm status is on")

    # Remote access is off on the dev bridge: status, and the refusals that follow from it.
    client.check("GET", "/v1/remote", 200)
    client.check("POST", "/v1/remote/claim", 409)
    client.check("POST", "/v1/remote/secret", 409)
    client.check("GET", "/v1/invitations", 200)
    client.check("POST", "/v1/invitations", 409, body={"role": "member"})
    client.check("POST", "/v1/invitations", 400, body={"role": "owner"})
    client.check("DELETE", "/v1/invitations/0123abcd", 404)

    # Profiles: the caller's own, and the admin's list; the home's room order.
    profile = client.check("GET", "/v1/profile", 200)
    client.check("PATCH", "/v1/profile", 200, body={"prefs": {"language": "he", "theme": "dark", "favorites": ["light:20"]}})
    client.check("PATCH", "/v1/profile", 200, body={"prefs": {"theme": None}})
    client.check("PATCH", "/v1/profile", 400, body={"prefs": {"theme": "neon"}})
    client.check("PATCH", "/v1/profile", 409, body={"prefs": {"language": "en"}, "version": 0})
    client.check("GET", "/v1/profiles", 200)
    client.check("PATCH", f"/v1/profiles/{profile['id']}", 200, body={"name": "Owner"})
    client.check("PATCH", f"/v1/profiles/{profile['id']}", 400, body={"name": ""})
    client.check("PATCH", "/v1/profiles/deadbeef", 404, body={"name": "Someone"})
    client.check("GET", "/v1/profile", 401, auth=False)
    client.check("PUT", "/v1/rooms/order", 200, body={"room_ids": [11, 10]})
    client.check("PUT", "/v1/rooms/order", 400, body={"room_ids": [999]})
    client.check("PATCH", "/v1/profile", 200, body={"prefs": {"hidden_rooms": [11]}})

    # Scenes: made by admins, run by members; a door in a scene runs with door access.
    night = {
        "name": "Good night",
        "icon": "moon",
        "show_on_home": True,
        "steps": [
            {"type": "lights", "set": {"on": False}},
            {"type": "climate", "room_id": 11, "set": {"mode": "cool", "target_temperature": 24}},
            {"type": "blinds", "room_id": None, "set": {"position": 0}},
            {"type": "lights", "room_id": 10, "device_ids": [20], "set": {"brightness": 30}},
            {"type": "relays", "device_ids": [70], "set": {"action": "pulse"}},
        ],
    }
    scene = client.check("POST", "/v1/scenes", 201, body=night)
    client.check("POST", "/v1/scenes", 400, body={"name": "Bad", "steps": [{"type": "lights", "set": {"on": True, "brightness": 5}}]})
    client.check("GET", "/v1/scenes", 200)
    client.check("GET", f"/v1/scenes/{scene['id']}", 200)
    client.check("GET", "/v1/scenes/deadbeef", 404)
    client.check("GET", "/v1/scenes/nothex", 400)
    client.check("PATCH", f"/v1/scenes/{scene['id']}", 200, body={"name": "Night", "version": 1})
    client.check("PATCH", f"/v1/scenes/{scene['id']}", 409, body={"name": "Late", "version": 1})
    client.check("PATCH", f"/v1/scenes/{scene['id']}", 400, body={"icon": "rocket"})
    client.check("PATCH", "/v1/scenes/deadbeef", 404, body={"name": "Gone"})
    client.check("POST", f"/v1/scenes/{scene['id']}/run", 202)
    client.check("POST", "/v1/scenes/deadbeef/run", 404)
    client.check("POST", "/v1/scenes/try", 202, body={"steps": [{"type": "lights", "device_ids": [20], "set": {"on": True}}]})
    client.check("POST", "/v1/scenes/try", 400, body={"steps": [{"type": "fans", "set": {}}]})
    auto = {"type": "climate", "device_ids": [31], "set": {"mode": "auto", "heat_setpoint": 20, "cool_setpoint": 24}}
    dual = client.check("POST", "/v1/scenes", 201, body={"name": "Study auto", "steps": [auto]})
    client.check("POST", "/v1/scenes/try", 202, body={"steps": [auto]})
    client.check("POST", f"/v1/scenes/{dual['id']}/run", 202)
    client.check("POST", "/v1/scenes", 400, body={"name": "Bad", "steps": [{"type": "climate", "set": {"heat_setpoint": 24, "cool_setpoint": 20}}]})
    client.check("DELETE", f"/v1/scenes/{dual['id']}", 204)
    spare = client.check("POST", "/v1/scenes", 201, body={"name": "Spare"})
    client.check("DELETE", f"/v1/scenes/{spare['id']}", 204)
    client.check("DELETE", f"/v1/scenes/{spare['id']}", 404)
    client.check("GET", "/v1/scenes", 401, auth=False)

    # Schedules run scenes by time, sun and weather; the weather view works without the internet.
    client.check("GET", "/v1/weather", 200)
    timed = client.check("POST", "/v1/schedules", 201, body={
        "scene_id": scene["id"], "trigger": {"type": "time", "at": "06:45"}, "days": [0, 1, 2, 3, 4], "only_if": {"not_raining": True},
    })
    client.check("POST", "/v1/schedules", 201, body={"scene_id": scene["id"], "trigger": {"type": "sun", "event": "sunset", "offset": -30}, "days": [5, 6]})
    hot = client.check("POST", "/v1/schedules", 201, body={
        "scene_id": scene["id"], "trigger": {"type": "weather", "kind": "heat", "above": 30, "from": "12:00", "to": "20:00"}, "days": [0, 1, 2, 3, 4, 5, 6],
    })
    client.check("POST", "/v1/schedules", 400, body={"scene_id": scene["id"], "trigger": {"type": "time", "at": "25:00"}, "days": [0]})
    client.check("GET", "/v1/schedules", 200)
    client.check("GET", f"/v1/schedules/{timed['id']}", 200)
    client.check("GET", "/v1/schedules/deadbeef", 404)
    client.check("GET", "/v1/schedules/nothex", 400)
    client.check("PATCH", f"/v1/schedules/{timed['id']}", 200, body={"enabled": False, "version": 1})
    client.check("PATCH", f"/v1/schedules/{timed['id']}", 409, body={"enabled": True, "version": 1})
    client.check("PATCH", f"/v1/schedules/{timed['id']}", 400, body={"days": []})
    client.check("PATCH", "/v1/schedules/deadbeef", 404, body={"enabled": True})
    client.check("DELETE", f"/v1/scenes/{scene['id']}", 409)
    client.check("DELETE", f"/v1/schedules/{hot['id']}", 204)
    client.check("DELETE", f"/v1/schedules/{hot['id']}", 404)

    # The Jewish calendar (1.2.0) ships off, and the API says so: nothing is worked out, and
    # nothing that uses it can be set. Ordinary schedules run as usual on Shabbat.
    features = client.check("GET", "/v1/system", 200)["features"]
    if features.get("jewish_calendar") is not False:
        fail(f"GET /v1/system should show the Jewish calendar off: {features}")
    calendar = client.check("GET", "/v1/calendar", 200)
    if calendar != EXAMPLES["Calendar"]["off"]["value"]:
        fail(f"GET /v1/calendar while it is off should answer as Calendar.off in {EXAMPLES_FILE.name}: {calendar}")
    refused = [
        client.check("PATCH", "/v1/calendar/settings", 409, body={"candle_lighting_minutes": 30, "version": 1}),
        client.check("POST", "/v1/schedules", 409, body={
            "scene_id": scene["id"], "trigger": {"type": "shabbat", "event": "candle_lighting", "offset": -30}, "days": [0, 1, 2, 3, 4, 5, 6],
        }),
        client.check("POST", "/v1/schedules", 409, body={
            "scene_id": scene["id"], "trigger": {"type": "time", "at": "06:30"}, "days": [0, 1, 2, 3, 4], "during_shabbat": "skip",
        }),
    ]
    for answer in refused:
        if answer["code"] != "JEWISH_CALENDAR_OFF":
            fail(f"the calendar is off: expected JEWISH_CALENDAR_OFF, got {answer}")
    client.check("PATCH", "/v1/calendar/settings", 400, body={"havdalah_minutes": 10})
    ordinary = client.check("PATCH", f"/v1/schedules/{timed['id']}", 200, body={"during_shabbat": "run"})
    if (timed["during_shabbat"], timed["calendar_status"], ordinary["during_shabbat"]) != ("run", None, "run"):
        fail(f"an ordinary schedule runs as usual on Shabbat and has no calendar status: {ordinary}")

    created = client.check("POST", "/v1/api-keys", 201, body={"name": "second key"})
    client.check("POST", "/v1/api-keys", 400, body={"name": ""})
    client.check("GET", "/v1/api-keys", 200)
    client.check("GET", "/v1/api-keys/current", 200)
    client.check("PATCH", f"/v1/api-keys/{created['id']}", 200, body={"role": "viewer"})
    client.check("PATCH", f"/v1/api-keys/{created['id']}", 400, body={"role": "owner"})
    client.check("PATCH", "/v1/api-keys/deadbeef", 404, body={"role": "viewer"})
    me = client.check("GET", "/v1/api-keys/current", 200)
    client.check("PATCH", f"/v1/api-keys/{me['id']}", 409, body={"role": "member"})
    admin_key, client.key = client.key, created["key"]
    client.check("GET", "/v1/lights", 200)
    client.check("PATCH", "/v1/lights/20", 403, body={"on": True})
    client.check("POST", "/v1/relays/70/pulse", 403)
    if client.check("GET", "/v1/alarm", 403)["code"] != "FORBIDDEN":
        fail("a viewer key must not read the alarm")
    client.check("GET", "/v1/api-keys", 403)
    client.check("GET", "/v1/profiles", 403)
    client.check("PUT", "/v1/rooms/order", 403, body={"room_ids": [10]})
    client.check("GET", "/v1/profile", 200)
    client.check("GET", "/v1/scenes", 200)
    client.check("POST", f"/v1/scenes/{scene['id']}/run", 403)
    client.check("POST", "/v1/scenes", 403, body={"name": "Mine"})
    client.check("PATCH", f"/v1/scenes/{scene['id']}", 403, body={"name": "Mine"})
    client.check("DELETE", f"/v1/scenes/{scene['id']}", 403)
    client.check("POST", "/v1/scenes/try", 403, body={"steps": []})
    client.check("GET", "/v1/schedules", 200)
    client.check("GET", "/v1/weather", 200)
    client.check("POST", "/v1/schedules", 403, body={"scene_id": scene["id"], "trigger": {"type": "time", "at": "06:45"}, "days": [0]})
    client.check("PATCH", f"/v1/schedules/{timed['id']}", 403, body={"enabled": True})
    client.check("DELETE", f"/v1/schedules/{timed['id']}", 403)
    client.check("GET", "/v1/calendar", 200)
    client.check("PATCH", "/v1/calendar/settings", 403, body={"havdalah_minutes": 50})
    client.check("DELETE", "/v1/api-keys/current", 204)
    client.check("GET", "/v1/lights", 401)
    client.key = admin_key
    client.check("DELETE", f"/v1/api-keys/{created['id']}", 404)
    client.check("DELETE", "/v1/api-keys/deadbeef", 404)

    client.check("PATCH", "/v1/logs/settings", 200, body={"level": "debug"})
    client.check("GET", "/v1/logs/settings", 200)
    client.check("GET", "/v1/logs?category=api&limit=50", 200)
    client.check("GET", "/v1/logs?level=loud", 400)
    client.check("PATCH", "/v1/logs/settings", 400, body={"level": "verbose"})
    client.check("GET", "/v1/logs", 401, auth=False)

    # Sealed requests on the home network: what sealing needs, and refusals (the driver's own tests
    # open real ones). Pairing with a key exchange answers sealed.
    info = client.check("GET", "/v1/sealed", 200, auth=False)
    stray = {"v": 1, "home": info["home"], "key": "deadbeef", "iv": "AAAAAAAAAAAAAAAAAAAAAA==", "ct": "AAAAAAAAAAAAAAAAAAAAAA==", "mac": "A" * 43 + "="}
    client.check("POST", "/v1/sealed", 401, body={"envelope": stray}, auth=False)
    client.check("POST", "/v1/sealed", 400, body={"envelope": "not an envelope", "extra": 1}, auth=False)
    bridge.new_pairing_code()
    exchange = {"public_key": base64.b64encode(x25519_public(os.urandom(32))).decode()}
    client.check("POST", "/v1/auth/pair", 201, body={"pairing_code": bridge.pairing_code, "name": "sealed pairing", "exchange": exchange}, auth=False)

    # Last, because it locks pairing for a minute.
    bridge.new_pairing_code()
    for _ in range(4):
        client.check("POST", "/v1/auth/pair", 403, body={"pairing_code": "00000000"})
    client.check("POST", "/v1/auth/pair", 429, body={"pairing_code": "00000000"})


def main():
    examples = check_examples()
    lua = shutil.which("lua5.1") or shutil.which("lua")
    if not lua:
        fail("Lua 5.1 is required")
    spec_json = ROOT / "dist" / "openapi.json"
    bridge = dev_server.Bridge(lua, spec_json if spec_json.is_file() else None)
    server = dev_server.Server(("127.0.0.1", 0), dev_server.make_handler(bridge))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    client = Client(server.server_address[1])
    try:
        scenario(client, bridge)
    finally:
        server.shutdown()
        bridge.process.terminate()

    missing = sorted({(op[0], op[1]) for op in OPERATIONS} - client.covered)
    if missing:
        fail("operations never exercised: " + ", ".join(f"{m} {p}" for m, p in missing))
    print(f"OK: {client.checked} responses match the API spec; all {len(OPERATIONS)} operations covered; {examples} calendar examples match it")


if __name__ == "__main__":
    main()
