-- End-to-end tests: the real driver against the fake Director, requests sent as raw bytes.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

local function start()
    local mock = Mock.startDriver()
    local key = T.pair(mock)
    return mock, key
end

local function lastCommand(mock)
    return mock.commands[#mock.commands]
end

local function byId(items, id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
end

function tests.driver_starts_the_api_and_reports_ready()
    local mock = Mock.startDriver()
    T.truthy(mock.servers[41999], "API server created on port 41999")
    T.eq(mock.servers[41999].delimiter, "", "raw mode: no delimiter")
    T.eq(mock.properties["Status"], "Ready")
    T.eq(mock.properties["API Status"], "Online")
    T.eq(mock.properties["Inventory"], "2 rooms, 9 devices, 3 lights, 1 thermostats, 2 blinds, 2 cameras")
    T.truthy(mock.properties["Pairing Code"]:match("^%d%d%d%d%d%d%d%d$"), "pairing code shown")
end

function tests.health_and_api_description_are_public()
    local mock = Mock.startDriver()
    local health = T.http(mock, "GET", "/v1/health")
    T.eq(health.status, 200)
    T.eq(health.json.status, "ok")
    T.eq(health.json.api_version, "1")
    T.truthy(isNull(health.json.detail), "detail is null when ok")
    T.truthy(health.closed, "connection closed after the response")

    local spec = T.http(mock, "GET", "/v1/openapi.json")
    T.eq(spec.status, 200)
    T.eq(spec.json.openapi, "3.1.0")
end

function tests.protected_routes_need_a_valid_key()
    local mock = Mock.startDriver()
    local response = T.http(mock, "GET", "/v1/system")
    T.eq(response.status, 401)
    T.eq(response.headers["content-type"], "application/problem+json")
    T.eq(response.json.code, "UNAUTHORIZED")
    T.eq(response.json.type, "about:blank")
    T.eq(response.json.title, "Unauthorized")
    T.contains(response.headers["www-authenticate"], "Bearer")

    T.eq(T.http(mock, "GET", "/v1/system", { key = "ak_wrong" }).status, 401)
    T.eq(T.http(mock, "GET", "/v1/system", { headers = { Authorization = "Basic abc" } }).status, 401)
end

function tests.pairing_issues_a_key_and_rotates_the_code()
    local mock = Mock.startDriver()
    local code = mock.properties["Pairing Code"]

    local wrong = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = "00000000" } })
    T.eq(wrong.status, 403)
    T.eq(wrong.json.code, "PAIRING_CODE_INVALID")
    T.eq(wrong.json.attempts_remaining, 4)

    local paired = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code, name = "Chrome" } })
    T.eq(paired.status, 201)
    T.eq(paired.json.name, "Chrome")
    T.truthy(paired.json.key:match("^ak_%x+$"), "key format")
    T.truthy(paired.json.id:match("^%x%x%x%x%x%x%x%x$"), "key id format")
    T.eq(mock.properties["API Keys"], "1")

    T.truthy(mock.properties["Pairing Code"] ~= code, "code rotated after use")
    local reused = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code } })
    T.eq(reused.status, 403, "a used code cannot pair again")

    T.eq(T.http(mock, "GET", "/v1/system", { key = paired.json.key }).status, 200)
end

function tests.pairing_is_rate_limited()
    local mock = Mock.startDriver()
    local response
    for _ = 1, 5 do
        response = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = "00000000" } })
    end
    T.eq(response.status, 429)
    T.eq(response.json.code, "PAIRING_RATE_LIMITED")
    T.eq(response.headers["retry-after"], "60")
    local locked = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = mock.properties["Pairing Code"] } })
    T.eq(locked.status, 429, "even the right code waits for the lock")
end

function tests.pairing_validates_its_body()
    local mock = Mock.startDriver()
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = "123" } }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = { code = "12345678" } }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = "[1]" }).json.code, "INVALID_REQUEST")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = "{nope" }).json.code, "INVALID_JSON")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = "{}", contentType = "text/plain" }).status, 415)
end

function tests.system_reports_controller_location_and_inventory()
    local mock, key = start()
    local system = T.http(mock, "GET", "/v1/system", { key = key }).json
    T.eq(system.bridge.status, "ok")
    T.eq(system.controller.platform, "control4")
    T.eq(system.controller.os_version, "3.4.3.727848-res")
    T.eq(system.controller.model, "XDT_CORE1")
    T.eq(system.location.country_code, "IL")
    T.eq(system.location.latitude, 32.08)
    T.eq(system.location.timezone, "Asia/Jerusalem")
    T.same(system.inventory, { rooms = 2, devices = 9, supported_devices = 8, lights = 3, thermostats = 1, blinds = 2, cameras = 2 })
    T.eq(system.lifecycle.reload_count, 1)
    T.eq(system.lifecycle.last_init_type, "DIT_STARTUP")
end

function tests.rooms_list_and_get()
    local mock, key = start()
    local rooms = T.http(mock, "GET", "/v1/rooms", { key = key }).json.items
    T.eq(#rooms, 2)
    T.eq(rooms[1].name, "Kitchen")
    T.eq(rooms[1].floor.name, "Ground Floor")
    T.eq(rooms[1].device_count, 4)
    T.eq(rooms[2].name, "Living Room")

    T.eq(T.http(mock, "GET", "/v1/rooms/11", { key = key }).json.name, "Living Room")
    T.eq(T.http(mock, "GET", "/v1/rooms/999", { key = key }).status, 404)
    T.eq(T.http(mock, "GET", "/v1/rooms/abc", { key = key }).json.code, "INVALID_PARAMETER")
end

function tests.devices_use_logical_types_and_filters()
    local mock, key = start()
    local all = T.http(mock, "GET", "/v1/devices", { key = key }).json.items
    T.eq(#all, 9)
    local camera = byId(all, 40)
    T.eq(camera.type, "other")
    T.eq(camera.supported, false)
    T.truthy(isNull(camera.href), "unsupported devices have no href")
    T.eq(byId(all, 30).href, "/v1/thermostats/30")
    T.eq(byId(all, 50).type, "blind")
    T.eq(byId(all, 50).href, "/v1/blinds/50")
    T.eq(byId(all, 20).room.name, "Kitchen")

    for _, device in ipairs(all) do
        T.eq(device.proxy, nil, "no Control4 proxy data in the API")
        T.eq(device.protocols, nil, "no Control4 protocol data in the API")
    end

    T.eq(#T.http(mock, "GET", "/v1/devices?type=light", { key = key }).json.items, 3)
    T.eq(#T.http(mock, "GET", "/v1/devices?supported=false", { key = key }).json.items, 1)
    T.eq(#T.http(mock, "GET", "/v1/devices?room_id=10", { key = key }).json.items, 4)
    T.eq(byId(all, 60).href, "/v1/cameras/60")
    T.eq(#T.http(mock, "GET", "/v1/devices?type=blind", { key = key }).json.items, 2)
    T.eq(T.http(mock, "GET", "/v1/devices?type=lamp", { key = key }).status, 400)
    T.eq(T.http(mock, "GET", "/v1/devices?supported=maybe", { key = key }).status, 400)
    T.eq(T.http(mock, "GET", "/v1/devices/40", { key = key }).json.name, "Front Door")
end

function tests.lights_report_state_and_capabilities()
    local mock, key = start()
    local lights = T.http(mock, "GET", "/v1/lights", { key = key }).json.items
    T.eq(#lights, 3)

    local knx = byId(lights, 20)
    T.eq(knx.on, true)
    T.eq(knx.dimmable, true)
    T.eq(knx.brightness_reported, false, "KNX dimmers do not report their level")

    local switch = byId(lights, 21)
    T.eq(switch.on, false)
    T.eq(switch.dimmable, false)
    T.truthy(isNull(switch.brightness), "on/off lights have null brightness")

    T.eq(byId(lights, 22).brightness, 40)
    T.eq(#T.http(mock, "GET", "/v1/lights?room_id=11", { key = key }).json.items, 2)
    T.eq(T.http(mock, "GET", "/v1/lights/30", { key = key }).status, 404, "a thermostat is not a light")
end

function tests.light_patch_maps_to_control4_commands()
    local mock, key = start()

    local on = T.http(mock, "PATCH", "/v1/lights/21", { key = key, body = { on = true } })
    T.eq(on.status, 202)
    T.eq(on.json.id, 21)
    T.same(lastCommand(mock), { device = 21, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } })

    T.http(mock, "PATCH", "/v1/lights/21", { key = key, body = { on = false } })
    T.same(lastCommand(mock).params, { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2 })

    T.http(mock, "PATCH", "/v1/lights/20", { key = key, body = { brightness = 60 } })
    T.same(lastCommand(mock), { device = 20, command = "RAMP_TO_LEVEL", params = { LEVEL = 60, TIME = 0 } })

    T.http(mock, "PATCH", "/v1/lights/22", { key = key, body = { on = true, brightness = 35 } })
    T.same(lastCommand(mock), { device = 22, command = "SET_BRIGHTNESS_TARGET", params = { PERCENT = 35 } })
end

function tests.light_patch_validates_input()
    local mock, key = start()
    local before = #mock.commands
    local function patch(body, options)
        options = options or {}
        options.key = key
        options.body = body
        return T.http(mock, "PATCH", options.path or "/v1/lights/22", options)
    end

    T.eq(patch({}).json.code, "INVALID_REQUEST")
    T.eq(patch({ on = "yes" }).json.code, "INVALID_FIELD")
    T.eq(patch({ brightness = 101 }).json.code, "INVALID_FIELD")
    T.eq(patch({ brightness = 12.5 }).json.code, "INVALID_FIELD")
    T.eq(patch('{"brightness": null}').json.code, "INVALID_FIELD")
    T.eq(patch({ color = "red" }).json.code, "INVALID_FIELD")
    T.eq(patch({ on = false, brightness = 20 }).json.code, "INVALID_REQUEST")
    T.eq(patch({ brightness = 20 }, { path = "/v1/lights/21" }).json.code, "NOT_SUPPORTED")
    T.eq(patch({ on = true }, { path = "/v1/lights/99" }).status, 404)
    T.eq(#mock.commands, before, "no command is sent for invalid requests")
end

function tests.thermostats_report_state_and_options()
    local mock, key = start()
    local thermostat = T.http(mock, "GET", "/v1/thermostats", { key = key }).json.items[1]
    T.eq(thermostat.id, 30)
    T.eq(thermostat.online, true)
    T.eq(thermostat.current_temperature, 26)
    T.eq(thermostat.target_temperature, 22)
    T.eq(thermostat.mode, "cool")
    T.same(thermostat.modes, { "off", "heat", "cool" })
    T.eq(thermostat.activity, "cooling")
    T.eq(thermostat.fan_speed, "low")
    T.same(thermostat.fan_speeds, { "low", "medium", "high" })
    T.eq(thermostat.target_temperature_min, 16)
    T.eq(thermostat.target_temperature_max, 25)
end

function tests.thermostat_patch_applies_fields_in_order()
    local mock, key = start()
    local before = #mock.commands
    local response = T.http(mock, "PATCH", "/v1/thermostats/30", {
        key = key,
        body = { target_temperature = 23, fan_speed = "high", mode = "heat" },
    })
    T.eq(response.status, 202)
    T.eq(#mock.commands, before + 3)
    T.same(mock.commands[before + 1], { device = 30, command = "SET_MODE_HVAC", params = { MODE = "Heat" } })
    T.same(mock.commands[before + 2], { device = 30, command = "SET_MODE_FAN", params = { MODE = "High" } })
    T.same(mock.commands[before + 3], { device = 30, command = "SET_SETPOINT_SINGLE", params = { CELSIUS = 23 } })
end

function tests.thermostat_patch_validates_input()
    local mock, key = start()
    local before = #mock.commands
    local function patch(body)
        return T.http(mock, "PATCH", "/v1/thermostats/30", { key = key, body = body })
    end
    T.eq(patch({ mode = "auto" }).json.code, "MODE_NOT_SUPPORTED")
    T.eq(patch({ mode = "Cool" }).json.code, "INVALID_FIELD", "modes are lowercase")
    T.eq(patch({ target_temperature = 30 }).json.code, "INVALID_FIELD", "AC zones stop at 25")
    T.eq(patch({ fan_speed = "turbo" }).json.code, "INVALID_FIELD")
    T.eq(patch({ fan_speed = "auto" }).json.code, "NOT_SUPPORTED")
    T.eq(patch({ humidity = 40 }).json.code, "INVALID_FIELD")
    T.eq(#mock.commands, before, "nothing is sent when validation fails")
end

function tests.blinds_report_their_position()
    local mock, key = start()
    local blinds = T.http(mock, "GET", "/v1/blinds", { key = key }).json.items
    T.eq(#blinds, 2)
    T.eq(blinds[1].name, "Kitchen Shutter", "sorted by name")
    T.truthy(isNull(blinds[1].position), "an unknown level (-255) is null")
    T.eq(blinds[1].position_reported, true)
    T.eq(byId(blinds, 50).position, 40)
    T.eq(byId(blinds, 50).room.name, "Living Room")
    T.eq(#T.http(mock, "GET", "/v1/blinds?room_id=11", { key = key }).json.items, 1)
    T.eq(T.http(mock, "GET", "/v1/blinds/20", { key = key }).status, 404, "a light is not a blind")

    OnWatchedVariableChanged(51, 1000, "75")
    T.eq(T.http(mock, "GET", "/v1/blinds/51", { key = key }).json.position, 75)
    OnWatchedVariableChanged(51, 1000, "-255")
    T.truthy(isNull(T.http(mock, "GET", "/v1/blinds/51", { key = key }).json.position))
end

function tests.blind_commands_use_the_blind_proxy()
    local mock, key = start()
    local response = T.http(mock, "PATCH", "/v1/blinds/50", { key = key, body = { position = 100 } })
    T.eq(response.status, 202)
    T.eq(response.json.id, 50)
    T.same(lastCommand(mock), { device = 50, command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = 100 } })

    T.http(mock, "PATCH", "/v1/blinds/51", { key = key, body = { position = 30 } })
    T.same(lastCommand(mock), { device = 51, command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = 30 } })

    T.eq(T.http(mock, "POST", "/v1/blinds/50/stop", { key = key }).status, 202)
    T.same(lastCommand(mock), { device = 50, command = "STOP", params = {} })
end

function tests.blind_patch_validates_input()
    local mock, key = start()
    local before = #mock.commands
    local function patch(body, path)
        return T.http(mock, "PATCH", path or "/v1/blinds/50", { key = key, body = body })
    end
    T.eq(patch({}).json.code, "INVALID_REQUEST")
    T.eq(patch({ position = 101 }).json.code, "INVALID_FIELD")
    T.eq(patch({ position = 50.5 }).json.code, "INVALID_FIELD")
    T.eq(patch({ position = "open" }).json.code, "INVALID_FIELD")
    T.eq(patch({ open = true }).json.code, "INVALID_FIELD")
    T.eq(patch({ position = 0 }, "/v1/blinds/99").status, 404)
    T.eq(T.http(mock, "POST", "/v1/blinds/99/stop", { key = key }).status, 404)
    T.eq(#mock.commands, before, "no command is sent for invalid requests")
end

function tests.cameras_are_listed_without_secrets()
    local mock, key = start()
    local cameras = T.http(mock, "GET", "/v1/cameras", { key = key }).json.items
    T.eq(#cameras, 2)
    T.eq(cameras[1].name, "Driveway")
    T.eq(cameras[1].room.name, "Kitchen")
    T.eq(cameras[1].snapshot_href, "/v1/cameras/60/snapshot")
    T.eq(#T.http(mock, "GET", "/v1/cameras?room_id=11", { key = key }).json.items, 1)
    T.eq(T.http(mock, "GET", "/v1/cameras/61", { key = key }).json.name, "Gate")
    T.eq(T.http(mock, "GET", "/v1/cameras/20", { key = key }).status, 404, "a light is not a camera")

    local raw = T.http(mock, "GET", "/v1/cameras", { key = key }).body
    T.truthy(not raw:find("s3cret", 1, true) and not raw:find("192.168.1.81", 1, true), "no camera login or address in the API")
end

function tests.snapshot_with_digest_login()
    local mock, key = start()
    local response = T.http(mock, "GET", "/v1/cameras/60/snapshot?width=1280", { key = key })
    T.eq(response.status, 200)
    T.eq(response.headers["content-type"], "image/jpeg")
    T.eq(response.headers["cache-control"], "no-store")
    T.truthy(response.body:find("^\255\216"), "JPEG bytes passed through")
    T.eq(#mock.urlRequests, 2, "challenge, then the digest answer")
    T.eq(mock.urlRequests[1].url, "http://192.168.1.81/ISAPI/Streaming/channels/101/picture?snapShotImageType=JPEG&size=1280x720")
    T.truthy(mock.urlRequests[2].headers.Authorization:find('^Digest username="admin"'))

    for _, entry in ipairs(mock.debugLog) do
        T.truthy(not entry:find("s3cret", 1, true), "the camera password is never logged")
    end
end

function tests.snapshot_with_basic_login_and_port()
    local mock, key = start()
    local response = T.http(mock, "GET", "/v1/cameras/61/snapshot", { key = key })
    T.eq(response.status, 200)
    T.eq(#mock.urlRequests, 1)
    T.eq(mock.urlRequests[1].url, "http://192.168.1.117:8080/bha-api/image.cgi")
    T.eq(mock.urlRequests[1].headers.Authorization, "Basic dXNlcjpkb29y")
end

function tests.snapshot_failures_are_problems()
    local mock, key = start()
    T.eq(T.http(mock, "GET", "/v1/cameras/60/snapshot?width=500", { key = key }).json.code, "INVALID_PARAMETER")
    T.eq(T.http(mock, "GET", "/v1/cameras/99/snapshot", { key = key }).status, 404)
    T.eq(T.http(mock, "GET", "/v1/cameras/60/snapshot").status, 401)

    mock.camerasOffline = true
    local offline = T.http(mock, "GET", "/v1/cameras/60/snapshot", { key = key })
    T.eq(offline.status, 502)
    T.eq(offline.json.code, "CAMERA_UNREACHABLE")

    local project = Mock.project()
    project.cameras[60].camera_password = "changed on the camera"
    local rejected = Mock.startDriver(project)
    local login = T.http(rejected, "GET", "/v1/cameras/60/snapshot", { key = T.pair(rejected) })
    T.eq(login.status, 502)
    T.eq(login.json.code, "CAMERA_LOGIN_FAILED")
end

function tests.api_keys_can_be_listed_created_and_revoked()
    local mock, key = start()
    local list = T.http(mock, "GET", "/v1/api-keys", { key = key }).json.items
    T.eq(#list, 1)
    T.eq(list[1].current, true)
    T.eq(list[1].key, nil, "secrets are never listed")
    T.truthy(type(list[1].last_used_at) == "string", "last use is tracked")

    local created = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Home Assistant" } })
    T.eq(created.status, 201)
    T.eq(created.json.current, false)
    T.eq(T.http(mock, "GET", "/v1/lights", { key = created.json.key }).status, 200)
    T.eq(T.http(mock, "POST", "/v1/api-keys", { key = key, body = {} }).json.code, "INVALID_FIELD")

    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. created.json.id, { key = key }).status, 204)
    T.eq(T.http(mock, "GET", "/v1/lights", { key = created.json.key }).status, 401, "revoked keys stop working")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/deadbeef", { key = key }).status, 404)
    T.eq(mock.properties["API Keys"], "1")
end

function tests.keys_survive_a_driver_restart()
    local mock, key = start()
    local persisted = mock.persist["c4bridge_api_keys"]
    T.truthy(persisted and persisted:find(key, 1, true), "key stored in encrypted persistence")

    local project = Mock.project()
    local restarted = Mock.startDriver(project)
    for name, value in pairs(mock.persist) do
        restarted.persist[name] = value
    end
    OnDriverLateInit("DIT_UPDATING")
    T.eq(T.http(restarted, "GET", "/v1/system", { key = key }).status, 200)
end

function tests.composer_action_revokes_all_keys()
    local mock, key = start()
    ExecuteCommand("LUA_ACTION", { ACTION = "REVOKE_API_KEYS" })
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).status, 401)
    T.eq(mock.properties["API Keys"], "0")

    local code = mock.properties["Pairing Code"]
    ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    T.truthy(mock.properties["Pairing Code"] ~= code, "new pairing code on request")
end

function tests.logs_record_requests_and_filter()
    local mock, key = start()
    T.http(mock, "PATCH", "/v1/logs/settings", { key = key, body = { level = "debug" } })
    T.eq(mock.properties["Log Level"], "Debug", "Composer property follows the API")
    T.http(mock, "GET", "/v1/rooms", { key = key })
    T.http(mock, "GET", "/v1/nope", { key = key })

    local logs = T.http(mock, "GET", "/v1/logs?category=api", { key = key }).json
    T.eq(logs.level, "debug")
    local messages = {}
    for _, entry in ipairs(logs.items) do
        messages[#messages + 1] = entry.message
        T.eq(entry.category, "api")
    end
    local joined = table.concat(messages, "\n")
    T.contains(joined, "GET /v1/rooms -> 200")
    T.contains(joined, "GET /v1/nope -> 404")

    local newer = T.http(mock, "GET", "/v1/logs?after=" .. logs.last_seq, { key = key }).json
    T.truthy(#newer.items <= 1, "only entries after last_seq")
    local warnings = T.http(mock, "GET", "/v1/logs?level=warn", { key = key }).json.items
    for _, entry in ipairs(warnings) do
        T.truthy(entry.level == "warn" or entry.level == "error", "level filter")
    end

    T.eq(T.http(mock, "GET", "/v1/logs?level=loud", { key = key }).status, 400)
    T.eq(T.http(mock, "GET", "/v1/logs?limit=0", { key = key }).status, 400)
    T.eq(T.http(mock, "PATCH", "/v1/logs/settings", { key = key, body = { level = "verbose" } }).status, 400)
end

function tests.secrets_never_reach_the_log()
    local mock = Mock.startDriver()
    local code = mock.properties["Pairing Code"]
    local key = T.pair(mock)
    T.http(mock, "GET", "/v1/system", { key = key })
    local everything = table.concat(mock.debugLog, "\n")
    T.notContains(everything, key, "API key in driver log")
    T.notContains(everything, code, "pairing code in driver log")
end

function tests.cors_allows_the_web_app_and_rejects_other_origins()
    local mock, key = start()
    local preflight = T.http(mock, "OPTIONS", "/v1/lights/20", { headers = { Origin = "https://app.c4bridge.io" } })
    T.eq(preflight.status, 204)
    T.eq(preflight.headers["access-control-allow-origin"], "https://app.c4bridge.io")
    T.contains(preflight.headers["access-control-allow-methods"], "PATCH")
    T.eq(preflight.headers["access-control-allow-private-network"], "true")

    local fromApp = T.http(mock, "GET", "/v1/lights", { key = key, headers = { Origin = "https://app.c4bridge.io" } })
    T.eq(fromApp.headers["access-control-allow-origin"], "https://app.c4bridge.io")
    T.eq(T.http(mock, "GET", "/v1/lights", { key = key, headers = { Origin = "http://localhost:8080" } }).status, 200)

    local evil = T.http(mock, "GET", "/v1/lights", { key = key, headers = { Origin = "https://evil.example" } })
    T.eq(evil.status, 403)
    T.eq(evil.json.code, "ORIGIN_NOT_ALLOWED")
    T.eq(evil.headers["access-control-allow-origin"], nil)
end

function tests.unknown_routes_and_methods()
    local mock, key = start()
    T.eq(T.http(mock, "GET", "/v1/unknown", { key = key }).json.code, "NOT_FOUND")
    local wrongMethod = T.http(mock, "DELETE", "/v1/lights/20", { key = key })
    T.eq(wrongMethod.status, 405)
    T.eq(wrongMethod.headers["allow"], "GET, PATCH")
end

function tests.requests_can_arrive_in_small_chunks()
    local mock, key = start()
    local get = T.http(mock, "GET", "/v1/lights/22", { key = key, chunkSize = 7 })
    T.eq(get.status, 200)
    T.eq(get.json.name, "Desk Lamp")
    local patch = T.http(mock, "PATCH", "/v1/lights/22", { key = key, body = { brightness = 70 }, chunkSize = 5 })
    T.eq(patch.status, 202)
    T.same(lastCommand(mock).params, { PERCENT = 70 })
end

function tests.malformed_http_gets_a_problem_response()
    local mock = Mock.startDriver()
    OnServerDataIn(900, "NONSENSE\r\n\r\n", "192.168.1.50", "1")
    T.contains(mock.sent[900], "HTTP/1.1 400 Bad Request")
    T.contains(mock.sent[900], "application/problem+json")
    T.truthy(mock.closed[900], "connection closed")
end

function tests.unsupported_controller_os_disables_the_api()
    local project = Mock.project()
    project.osVersion = "3.2.9"
    local mock = Mock.startDriver(project)
    T.eq(mock.servers[41999], nil, "no server on unsupported OS")
    T.contains(mock.properties["Status"], "Unsupported controller OS")
    T.eq(mock.properties["API Status"], "Disabled")
end

return tests
