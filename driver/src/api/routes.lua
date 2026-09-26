-- The API route table. It must match api/openapi.yaml exactly: scripts/check_api.py fails the
-- build when a method, path, public flag or role (x-c4bridge-role) differs between the two.
-- `role` is the least API key role that may call the route (src/auth/roles.lua).

return {
    { method = "GET", path = "/v1/health", handler = "system.health", public = true },
    { method = "GET", path = "/v1/openapi.json", handler = "system.openapi", public = true },
    { method = "GET", path = "/v1/system", handler = "system.info", role = "viewer" },

    { method = "POST", path = "/v1/auth/pair", handler = "auth.pair", public = true },
    { method = "POST", path = "/v1/auth/requests", handler = "auth.create_request", public = true },
    { method = "GET", path = "/v1/auth/requests/{requestId}", handler = "auth.get_request", public = true },
    { method = "DELETE", path = "/v1/auth/requests/{requestId}", handler = "auth.delete_request", public = true },
    { method = "GET", path = "/v1/api-keys", handler = "auth.list_keys", role = "admin" },
    { method = "POST", path = "/v1/api-keys", handler = "auth.create_key", role = "admin" },
    { method = "GET", path = "/v1/api-keys/current", handler = "auth.current_key", role = "viewer" },
    { method = "DELETE", path = "/v1/api-keys/current", handler = "auth.revoke_current_key", role = "viewer" },
    { method = "PATCH", path = "/v1/api-keys/{keyId}", handler = "auth.update_key", role = "admin" },
    { method = "DELETE", path = "/v1/api-keys/{keyId}", handler = "auth.delete_key", role = "admin" },

    { method = "GET", path = "/v1/rooms", handler = "rooms.list", role = "viewer" },
    { method = "GET", path = "/v1/rooms/{roomId}", handler = "rooms.get", role = "viewer" },
    { method = "PATCH", path = "/v1/rooms/{roomId}", handler = "rooms.update", role = "admin" },

    { method = "GET", path = "/v1/devices", handler = "devices.list", role = "viewer" },
    { method = "GET", path = "/v1/devices/{deviceId}", handler = "devices.get", role = "viewer" },

    { method = "GET", path = "/v1/lights", handler = "lights.list", role = "viewer" },
    { method = "GET", path = "/v1/lights/{lightId}", handler = "lights.get", role = "viewer" },
    { method = "PATCH", path = "/v1/lights/{lightId}", handler = "lights.update", role = "member" },

    { method = "GET", path = "/v1/thermostats", handler = "thermostats.list", role = "viewer" },
    { method = "GET", path = "/v1/thermostats/{thermostatId}", handler = "thermostats.get", role = "viewer" },
    { method = "PATCH", path = "/v1/thermostats/{thermostatId}", handler = "thermostats.update", role = "member" },

    { method = "GET", path = "/v1/blinds", handler = "blinds.list", role = "viewer" },
    { method = "GET", path = "/v1/blinds/{blindId}", handler = "blinds.get", role = "viewer" },
    { method = "PATCH", path = "/v1/blinds/{blindId}", handler = "blinds.update", role = "member" },
    { method = "POST", path = "/v1/blinds/{blindId}/stop", handler = "blinds.stop", role = "member" },

    { method = "GET", path = "/v1/cameras", handler = "cameras.list", role = "viewer" },
    { method = "GET", path = "/v1/cameras/{cameraId}", handler = "cameras.get", role = "viewer" },
    { method = "GET", path = "/v1/cameras/{cameraId}/snapshot", handler = "cameras.snapshot", role = "viewer" },

    { method = "GET", path = "/v1/relays", handler = "relays.list", role = "viewer" },
    { method = "GET", path = "/v1/relays/{relayId}", handler = "relays.get", role = "viewer" },
    { method = "PATCH", path = "/v1/relays/{relayId}", handler = "relays.update", role = "doors" },
    { method = "POST", path = "/v1/relays/{relayId}/pulse", handler = "relays.pulse", role = "doors" },

    { method = "GET", path = "/v1/logs", handler = "logs.list", role = "admin" },
    { method = "GET", path = "/v1/logs/settings", handler = "logs.get_settings", role = "admin" },
    { method = "PATCH", path = "/v1/logs/settings", handler = "logs.update_settings", role = "admin" },
}
