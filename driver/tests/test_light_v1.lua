-- The legacy Light proxy (light.c4i, src/adapters/light_v1.lua): the same /v1/lights API as
-- Light V2, sent as ON / OFF / SET_LEVEL.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

local function byId(items, id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
end

local function start(prepare)
    local mock = Mock.startDriver(Mock.withLegacyLights(Mock.project()), nil, nil, prepare)
    return mock, T.pair(mock)
end

local function lastCommand(mock)
    return mock.commands[#mock.commands]
end

local function listening(mock, deviceId, variableId)
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId and entry[2] == variableId then
            return true
        end
    end
    return false
end

function tests.legacy_lights_are_lights()
    local mock, key = start()
    T.contains(mock.properties["Inventory"], "5 lights")
    local lights = T.http(mock, "GET", "/v1/lights", { key = key }).json.items
    T.eq(#lights, 5)

    local dimmer = byId(lights, 25)
    T.eq(dimmer.on, true)
    T.eq(dimmer.brightness, 65)
    T.eq(dimmer.dimmable, true)
    T.eq(dimmer.brightness_reported, true, "no KNX exception: a legacy dimmer reports its level")

    local switch = byId(lights, 26)
    T.eq(switch.on, false)
    T.eq(switch.dimmable, false)
    T.eq(switch.brightness_reported, false)
    T.truthy(isNull(switch.brightness), "on/off lights have null brightness")

    T.eq(byId(lights, 27), nil, "no Light State: not controllable")
    local broken = T.http(mock, "GET", "/v1/devices/27", { key = key }).json
    T.eq(broken.type, "light")
    T.eq(broken.supported, false)
    T.truthy(isNull(broken.href), "an unsupported light has no href")
    T.eq(T.http(mock, "GET", "/v1/devices/25", { key = key }).json.href, "/v1/lights/25")

    T.truthy(listening(mock, 25, 1000) and listening(mock, 25, 1001) and listening(mock, 26, 1000))
    T.truthy(not listening(mock, 26, 1001), "a switch has no level to watch")
end

function tests.legacy_light_patch_sends_on_off_set_level()
    local mock, key = start()
    T.eq(T.http(mock, "PATCH", "/v1/lights/26", { key = key, body = { on = true } }).status, 202)
    T.same(lastCommand(mock), { device = 26, command = "ON", params = {} })
    T.http(mock, "PATCH", "/v1/lights/26", { key = key, body = { on = false } })
    T.same(lastCommand(mock), { device = 26, command = "OFF", params = {} })

    T.eq(T.http(mock, "PATCH", "/v1/lights/25", { key = key, body = { brightness = 60 } }).status, 202)
    T.same(lastCommand(mock), { device = 25, command = "SET_LEVEL", params = { LEVEL = 60 } }, "LEVEL is a number, no TIME")
    T.http(mock, "PATCH", "/v1/lights/25", { key = key, body = { on = true, brightness = 35 } })
    T.same(lastCommand(mock), { device = 25, command = "SET_LEVEL", params = { LEVEL = 35 } })

    local before = #mock.commands
    local refused = T.http(mock, "PATCH", "/v1/lights/26", { key = key, body = { brightness = 20 } })
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "NOT_SUPPORTED")
    T.eq(#mock.commands, before, "nothing is sent to a switch for a level")

    -- Light V2 lights are unchanged.
    T.http(mock, "PATCH", "/v1/lights/22", { key = key, body = { brightness = 35 } })
    T.same(lastCommand(mock), { device = 22, command = "SET_BRIGHTNESS_TARGET", params = { PERCENT = 35 } })
end

function tests.legacy_light_state_follows_its_variables()
    local mock, key = start()
    local function light(id)
        return T.http(mock, "GET", "/v1/lights/" .. id, { key = key }).json
    end
    OnWatchedVariableChanged(25, 1001, "30")
    T.eq(light(25).brightness, 30)
    T.eq(light(25).on, true)
    OnWatchedVariableChanged(25, "1001", "0")
    T.eq(light(25).on, false, "level 0 is off")
    OnWatchedVariableChanged(26, 1000, "1")
    T.eq(light(26).on, true)
    OnWatchedVariableChanged(26, 1001, "50")
    T.truthy(isNull(light(26).brightness), "a switch never gets a level")
end

function tests.a_scene_sets_legacy_and_v2_lights_alike()
    local mock, key = start()
    local before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
        { type = "lights", device_ids = { 25, 26, 22 }, set = { brightness = 40 } },
        { type = "lights", room_id = 10, set = { on = false } },
    } } }).json
    T.eq(ran.ran, 5)
    local sent = {}
    for index = before + 1, #mock.commands do
        sent[#sent + 1] = mock.commands[index]
    end
    T.eq(#sent, 5)
    T.same(sent[1], { device = 25, command = "SET_LEVEL", params = { LEVEL = 40 } })
    T.same(sent[2], { device = 26, command = "ON", params = {} }, "an on/off light turns on")
    T.same(sent[3], { device = 22, command = "SET_BRIGHTNESS_TARGET", params = { PERCENT = 40 } })
    local kitchen = {}
    for index = 4, #sent do
        kitchen[sent[index].device] = sent[index]
    end
    T.same(kitchen[25], { device = 25, command = "OFF", params = {} })
    T.same(kitchen[20], { device = 20, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2 } })
end

function tests.a_legacy_dimmer_whose_level_cannot_be_watched_is_unsupported()
    local mock, key = start(function(mock)
        local register = C4.RegisterVariableListener
        function C4:RegisterVariableListener(deviceId, variableId)
            if deviceId == 25 and variableId == 1001 then
                error("listener refused")
            end
            return register(self, deviceId, variableId)
        end
        mock.patched = true
    end)
    T.truthy(mock.patched)
    local pantry = T.http(mock, "GET", "/v1/devices/25", { key = key }).json
    T.eq(pantry.type, "light")
    T.eq(pantry.supported, false)
    T.eq(T.http(mock, "GET", "/v1/lights/25", { key = key }).status, 404)
    T.eq(T.http(mock, "GET", "/v1/lights/26", { key = key }).json.on, false, "the switch still works")
end

function tests.the_debug_log_lists_what_a_legacy_light_has()
    local mock = start(function()
        Properties["Log Level"] = "Debug"
    end)
    local log = table.concat(mock.debugLog, "\n")
    T.contains(log, "legacy light")
    T.contains(log, '"variables":"1000=LIGHT_STATE, 1001=LIGHT_LEVEL"')
    T.contains(log, "ldz_dimmer.c4i", "the protocol driver, for the next field log")
end

return tests
