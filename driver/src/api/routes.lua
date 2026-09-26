-- The API route table. It must match api/openapi.yaml exactly: scripts/check_api.py
-- fails the build when a method, path or public flag differs between the two.

return {
    { method = "GET", path = "/v1/health", handler = "system.health", public = true },
    { method = "GET", path = "/v1/openapi.json", handler = "system.openapi", public = true },
    { method = "GET", path = "/v1/system", handler = "system.info" },

    { method = "POST", path = "/v1/auth/pair", handler = "auth.pair", public = true },
    { method = "POST", path = "/v1/auth/requests", handler = "auth.create_request", public = true },
    { method = "GET", path = "/v1/auth/requests/{requestId}", handler = "auth.get_request", public = true },
    { method = "DELETE", path = "/v1/auth/requests/{requestId}", handler = "auth.delete_request", public = true },
    { method = "GET", path = "/v1/api-keys", handler = "auth.list_keys" },
    { method = "POST", path = "/v1/api-keys", handler = "auth.create_key" },
    { method = "DELETE", path = "/v1/api-keys/{keyId}", handler = "auth.delete_key" },

    { method = "GET", path = "/v1/rooms", handler = "rooms.list" },
    { method = "GET", path = "/v1/rooms/{roomId}", handler = "rooms.get" },

    { method = "GET", path = "/v1/devices", handler = "devices.list" },
    { method = "GET", path = "/v1/devices/{deviceId}", handler = "devices.get" },

    { method = "GET", path = "/v1/lights", handler = "lights.list" },
    { method = "GET", path = "/v1/lights/{lightId}", handler = "lights.get" },
    { method = "PATCH", path = "/v1/lights/{lightId}", handler = "lights.update" },

    { method = "GET", path = "/v1/thermostats", handler = "thermostats.list" },
    { method = "GET", path = "/v1/thermostats/{thermostatId}", handler = "thermostats.get" },
    { method = "PATCH", path = "/v1/thermostats/{thermostatId}", handler = "thermostats.update" },

    { method = "GET", path = "/v1/logs", handler = "logs.list" },
    { method = "GET", path = "/v1/logs/settings", handler = "logs.get_settings" },
    { method = "PATCH", path = "/v1/logs/settings", handler = "logs.update_settings" },
}
