#!/usr/bin/env python3
"""Contract test: runs the real driver (fake Director) on a local port, calls every API operation
with a real HTTP client, and validates each response against api/openapi.yaml.

Checks per response: the status code is declared for the operation, the Content-Type matches the
declared media type, and the JSON body validates against the declared schema. Fails if any
operation in the spec was not exercised.
"""

import json
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


def template_regex(path):
    return re.compile("^" + re.sub(r"\\\{[^}]+\\\}", "[^/]+", re.escape(path)) + "$")


OPERATIONS = [
    (method.upper(), path, template_regex(path), item[method])
    for path, item in SPEC["paths"].items()
    for method in METHODS
    if method in item
]


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.key = None
        self.covered = set()
        self.checked = 0

    def check(self, method, target, expected, body=None, auth=True, headers=None):
        path = target.split("?", 1)[0]
        operation = next((op for op in OPERATIONS if op[0] == method and op[2].match(path)), None)
        if not operation:
            fail(f"{method} {path} is not an operation in the spec")
        _, template, _, definition = operation

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

        label = f"{method} {target} -> {status}"
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
            validator = Draft202012Validator({"$ref": "urn:spec#" + schema["$ref"][1:]} if "$ref" in schema else schema,
                                             registry=REGISTRY)
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


def approval_scenario(client, bridge):
    created = client.check("POST", "/v1/auth/requests", 201, body={"name": "contract approval"}, auth=False)
    client.check("POST", "/v1/auth/requests", 409, body={"name": "second"}, auth=False)
    client.check("GET", f"/v1/auth/requests/{created['id']}", 200, auth=False)
    bridge.press_access_button()
    approved = client.check("GET", f"/v1/auth/requests/{created['id']}", 200, auth=False)
    if approved["status"] != "approved" or not approved["api_key"]:
        fail("an approved request must hand over its API key")
    client.check("GET", f"/v1/auth/requests/{created['id']}", 404, auth=False)
    cancelled = client.check("POST", "/v1/auth/requests", 201, auth=False)
    client.check("DELETE", f"/v1/auth/requests/{cancelled['id']}", 204, auth=False)
    client.check("DELETE", f"/v1/auth/requests/{cancelled['id']}", 404, auth=False)
    client.check("POST", "/v1/auth/requests", 400, body={"name": ""}, auth=False)


def scenario(client, pairing_code):
    client.check("GET", "/v1/health", 200)
    client.check("GET", "/v1/openapi.json", 200)
    client.check("GET", "/v1/system", 401)
    client.check("POST", "/v1/auth/pair", 403, body={"pairing_code": "00000000"})
    client.check("POST", "/v1/auth/pair", 400, body={"pairing_code": "12"})
    paired = client.check("POST", "/v1/auth/pair", 201, body={"pairing_code": pairing_code, "name": "contract test"})
    client.key = paired["key"]

    client.check("GET", "/v1/system", 200)
    client.check("GET", "/v1/rooms", 200)
    client.check("GET", "/v1/rooms/10", 200)
    client.check("GET", "/v1/rooms/999", 404)
    client.check("GET", "/v1/rooms/abc", 400)
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

    client.check("GET", "/v1/cameras", 200)
    client.check("GET", "/v1/cameras/60", 200)
    client.check("GET", "/v1/cameras/20", 404)
    client.check("GET", "/v1/cameras/60/snapshot", 200)
    client.check("GET", "/v1/cameras/61/snapshot?width=320", 200)
    client.check("GET", "/v1/cameras/60/snapshot?width=500", 400)
    client.check("GET", "/v1/cameras/99/snapshot", 404)

    created = client.check("POST", "/v1/api-keys", 201, body={"name": "second key"})
    client.check("POST", "/v1/api-keys", 400, body={"name": ""})
    client.check("GET", "/v1/api-keys", 200)
    client.check("DELETE", f"/v1/api-keys/{created['id']}", 204)
    client.check("DELETE", "/v1/api-keys/deadbeef", 404)

    client.check("PATCH", "/v1/logs/settings", 200, body={"level": "debug"})
    client.check("GET", "/v1/logs/settings", 200)
    client.check("GET", "/v1/logs?category=api&limit=50", 200)
    client.check("GET", "/v1/logs?level=loud", 400)
    client.check("PATCH", "/v1/logs/settings", 400, body={"level": "verbose"})
    client.check("GET", "/v1/logs", 401, auth=False)

    # Last, because it locks pairing for a minute.
    for _ in range(4):
        client.check("POST", "/v1/auth/pair", 403, body={"pairing_code": "00000000"})
    client.check("POST", "/v1/auth/pair", 429, body={"pairing_code": "00000000"})


def main():
    lua = shutil.which("lua5.1") or shutil.which("lua")
    if not lua:
        fail("Lua 5.1 is required")
    spec_json = ROOT / "dist" / "openapi.json"
    bridge = dev_server.Bridge(lua, spec_json if spec_json.is_file() else None)
    server = dev_server.Server(("127.0.0.1", 0), dev_server.make_handler(bridge))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    client = Client(server.server_address[1])
    try:
        scenario(client, bridge.pairing_code)
        approval_scenario(client, bridge)
    finally:
        server.shutdown()
        bridge.process.terminate()

    missing = sorted({(op[0], op[1]) for op in OPERATIONS} - client.covered)
    if missing:
        fail("operations never exercised: " + ", ".join(f"{m} {p}" for m, p in missing))
    print(f"OK: {client.checked} responses match the API spec; all {len(OPERATIONS)} operations covered")


if __name__ == "__main__":
    main()
