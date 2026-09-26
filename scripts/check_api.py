#!/usr/bin/env python3
"""Validates api/openapi.yaml and checks that the driver implements exactly what it describes."""

import re
import sys
from pathlib import Path

import yaml
from openapi_spec_validator import validate

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "api" / "openapi.yaml"
ROUTES = ROOT / "driver" / "src" / "api" / "routes.lua"

METHODS = ("get", "post", "put", "patch", "delete")
ROUTE_PATTERN = re.compile(
    r'\{\s*method\s*=\s*"([A-Z]+)",\s*path\s*=\s*"([^"]+)",\s*handler\s*=\s*"([^"]+)"(\s*,\s*public\s*=\s*true)?\s*\}'
)


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def spec_operations(spec):
    operations = {}
    for path, item in spec["paths"].items():
        for method in METHODS:
            if method in item:
                operations[(method.upper(), path)] = item[method]
    return operations


def driver_routes():
    text = ROUTES.read_text(encoding="utf-8")
    routes = {}
    for method, path, _handler, public in ROUTE_PATTERN.findall(text):
        key = (method, path)
        if key in routes:
            fail(f"duplicate route in routes.lua: {method} {path}")
        routes[key] = bool(public)
    declared = len(re.findall(r"\bmethod\s*=", text))
    if declared != len(routes):
        fail(f"could not parse every route in routes.lua ({len(routes)} of {declared})")
    return routes


def check_operation(key, operation, public):
    label = f"{key[0]} {key[1]}"
    for field in ("operationId", "summary", "tags"):
        if not operation.get(field):
            fail(f"{label} needs {field}")
    responses = operation.get("responses", {})
    if not any(str(code).startswith("2") for code in responses):
        fail(f"{label} documents no success response")
    if not public and "401" not in responses:
        fail(f"{label} requires an API key but does not document 401")


def main():
    spec = yaml.safe_load(SPEC.read_text(encoding="utf-8"))
    try:
        validate(spec)
    except Exception as exc:  # the validator raises several exception types
        fail(f"api/openapi.yaml is not a valid OpenAPI document: {exc}")

    operations = spec_operations(spec)
    routes = driver_routes()

    missing = sorted(set(operations) - set(routes))
    if missing:
        fail("described in the spec but not routed in the driver: " + ", ".join(f"{m} {p}" for m, p in missing))
    undocumented = sorted(set(routes) - set(operations))
    if undocumented:
        fail("routed in the driver but missing from the spec: " + ", ".join(f"{m} {p}" for m, p in undocumented))

    operation_ids = set()
    for key, operation in operations.items():
        spec_public = operation.get("security") == []
        if spec_public != routes[key]:
            fail(f"{key[0]} {key[1]}: public in {'spec' if spec_public else 'driver'} only")
        check_operation(key, operation, spec_public)
        if operation["operationId"] in operation_ids:
            fail(f"duplicate operationId {operation['operationId']}")
        operation_ids.add(operation["operationId"])

    public = sum(1 for is_public in routes.values() if is_public)
    print(f"OK: API spec valid; {len(routes)} operations match the driver ({public} public)")


if __name__ == "__main__":
    main()
