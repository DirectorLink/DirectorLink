-- Thermostats with separate heat and cool setpoints (the Control4 thermostat proxy, #16) through
-- the API: the public fields, PATCH /v1/thermostats/{id} with heat_setpoint/cool_setpoint and a
-- mode-aware target_temperature, and nothing sent when a request is refused. The default
-- project's zone 30 (Thermostat V2) must answer as before, with the new keys null.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

-- The default project plus the dual thermostat 31 (Mock.withDualThermostat options). The fake
-- Director does not act on commands, so every request starts from the fixture's values.
local function start(options, change)
    local project = Mock.withDualThermostat(Mock.project(), options)
    if change then
        change(project)
    end
    local mock = Mock.startDriver(project)
    local key = T.pair(mock)
    local function get(id)
        return T.http(mock, "GET", "/v1/thermostats/" .. tostring(id or 31), { key = key }).json
    end
    local function patch(body, id)
        return T.http(mock, "PATCH", "/v1/thermostats/" .. tostring(id or 31), { key = key, body = body })
    end
    return mock, key, get, patch
end

-- What one PATCH sent, as { command, params } pairs, and its response.
local function sent(mock, patch, body, id)
    local before = #mock.commands
    local response = patch(body, id)
    local list = {}
    for index = before + 1, #mock.commands do
        local command = mock.commands[index]
        T.eq(command.device, id or 31, "only to the thermostat patched")
        list[#list + 1] = { command.command, command.params }
    end
    return list, response
end

-- A request that is refused with `status` and `code`, and sends nothing at all.
local function refused(mock, patch, body, status, code, id)
    local list, response = sent(mock, patch, body, id)
    T.eq(response.status, status, response.body)
    T.eq(response.json.code, code, response.body)
    T.eq(#list, 0, "nothing is sent")
    return response.json
end

function tests.a_dual_thermostat_reports_both_setpoints_in_celsius()
    local mock, key, get = start({ scale = "FAHRENHEIT" })
    local thermostat = get()
    T.eq(thermostat.setpoints, "dual")
    T.eq(thermostat.heat_setpoint, 20, "68 °F")
    T.eq(thermostat.cool_setpoint, 24.4, "76 °F")
    T.eq(thermostat.current_temperature, 21.7, "71 °F")
    T.eq(thermostat.setpoint_deadband, 1.7, "3 °F is a difference of 1.7 °C")
    T.truthy(isNull(thermostat.target_temperature), "in auto there is no single target")
    T.eq(thermostat.mode, "auto")
    T.same(thermostat.modes, { "off", "heat", "cool", "auto" })
    T.eq(thermostat.fan_speed, "auto")
    T.same(thermostat.fan_speeds, { "auto", "on" })
    T.eq(thermostat.target_temperature_min, 5, "one range for both setpoints")
    T.eq(thermostat.target_temperature_max, 35)
    T.eq(thermostat.room.id, 10)
    T.eq(thermostat.online, true)
    local items = T.http(mock, "GET", "/v1/thermostats", { key = key }).json.items
    T.eq(#items, 2, "listed next to the V2 zone")
end

function tests.one_setpoint_is_sent_in_whole_fahrenheit()
    local mock, _, _, patch = start()
    local before = #mock.commands
    T.eq(patch({ heat_setpoint = 21 }).status, 202)
    T.eq(#mock.commands, before + 1, "cool stays: 76 °F is far enough above 70 °F")
    T.same(mock.commands[before + 1], { device = 31, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 70 } })
    local list = sent(mock, patch, { cool_setpoint = 24 })
    T.same(list, { { "SET_SETPOINT_COOL", { FAHRENHEIT = 75 } } })
end

function tests.one_setpoint_pushes_the_other_to_keep_the_deadband()
    local mock, _, _, patch = start()
    local list, response = sent(mock, patch, { heat_setpoint = 23.5 })
    T.eq(response.status, 202, response.body)
    T.same(list, {
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 77 } },
        { "SET_SETPOINT_HEAT", { FAHRENHEIT = 74 } },
    }, "cool rises first, so the pair never comes closer than 3 °F")
end

function tests.both_setpoints_must_already_keep_the_deadband()
    local mock, _, _, patch = start()
    local answer = refused(mock, patch, { heat_setpoint = 22, cool_setpoint = 23 }, 400, "INVALID_FIELD")
    T.eq(answer.errors[1].field, "cool_setpoint")
    T.contains(answer.detail, "1.7")
    -- Refused before the mode is sent too.
    refused(mock, patch, { mode = "heat", heat_setpoint = 22, cool_setpoint = 23 }, 400, "INVALID_FIELD")
end

function tests.both_setpoints_go_in_an_order_that_keeps_the_deadband()
    local mock, _, _, patch = start()
    T.same(sent(mock, patch, { heat_setpoint = 22, cool_setpoint = 26 }), {
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 79 } },
        { "SET_SETPOINT_HEAT", { FAHRENHEIT = 72 } },
    }, "cool rises: cool first")
    T.same(sent(mock, patch, { heat_setpoint = 18, cool_setpoint = 22 }), {
        { "SET_SETPOINT_HEAT", { FAHRENHEIT = 64 } },
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 72 } },
    }, "cool falls: heat first")
    local list, response = sent(mock, patch, { mode = "auto", heat_setpoint = 20, cool_setpoint = 24 })
    T.eq(response.status, 202, response.body)
    T.same(list, {
        { "SET_MODE_HVAC", { MODE = "Auto" } },
        { "SET_SETPOINT_HEAT", { FAHRENHEIT = 68 } },
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 75 } },
    }, "the mode first, in the proxy's spelling")
end

function tests.target_temperature_sets_the_setpoint_of_the_mode()
    local mock, _, get, patch = start()
    local list, response = sent(mock, patch, { mode = "cool", target_temperature = 24 })
    T.eq(response.status, 202, response.body)
    T.same(list, {
        { "SET_MODE_HVAC", { MODE = "Cool" } },
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 75 } },
    }, "the mode in the request wins over the reported auto")
    local answer = refused(mock, patch, { target_temperature = 22 }, 409, "NOT_SUPPORTED")
    T.contains(answer.detail, "heat_setpoint and cool_setpoint")
    refused(mock, patch, { target_temperature = 22, heat_setpoint = 20 }, 400, "INVALID_REQUEST")

    OnWatchedVariableChanged(31, 1104, "Heat")
    T.eq(get().target_temperature, 20, "in heat, the heat setpoint")
    T.same(sent(mock, patch, { target_temperature = 21 }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 70 } } })
    -- A target that needs the other setpoint moved is pushed like a heat_setpoint.
    T.same(sent(mock, patch, { target_temperature = 23.5 }), {
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 77 } },
        { "SET_SETPOINT_HEAT", { FAHRENHEIT = 74 } },
    })
end

function tests.setpoints_stay_within_the_range()
    local mock, _, _, patch = start()
    local answer = refused(mock, patch, { cool_setpoint = 6 }, 400, "INVALID_FIELD")
    T.eq(answer.errors[1].field, "cool_setpoint", "no room below 6 °C for the heat setpoint")
    answer = refused(mock, patch, { heat_setpoint = 4 }, 400, "INVALID_FIELD")
    T.eq(answer.errors[1].field, "heat_setpoint")
    refused(mock, patch, { cool_setpoint = 36 }, 400, "INVALID_FIELD")
    refused(mock, patch, { heat_setpoint = "20" }, 400, "INVALID_FIELD")
    answer = refused(mock, patch, { mode = "heat", target_temperature = 34.5 }, 400, "INVALID_FIELD")
    T.eq(answer.errors[1].field, "target_temperature", "no room above it for the cool setpoint")
end

function tests.a_celsius_project_sends_celsius_to_a_tenth()
    local mock, _, get, patch = start({ scale = "CELSIUS" })
    local thermostat = get()
    T.eq(thermostat.heat_setpoint, 20.5)
    T.eq(thermostat.cool_setpoint, 24)
    T.eq(thermostat.setpoint_deadband, 2)
    T.same(sent(mock, patch, { heat_setpoint = 21.5 }), { { "SET_SETPOINT_HEAT", { CELSIUS = 21.5 } } })
    T.same(sent(mock, patch, { heat_setpoint = 22.5 }), {
        { "SET_SETPOINT_COOL", { CELSIUS = 24.5 } },
        { "SET_SETPOINT_HEAT", { CELSIUS = 22.5 } },
    })

    local tight, _, _, patchTight = start({ scale = "CELSIUS", deadband = "1.7" })
    local list, response = sent(tight, patchTight, { heat_setpoint = 22.3, cool_setpoint = 24.0 })
    T.eq(response.status, 202, "24.0 - 22.3 keeps a 1.7 deadband: " .. tostring(response.body))
    T.same(list, {
        { "SET_SETPOINT_HEAT", { CELSIUS = 22.3 } },
        { "SET_SETPOINT_COOL", { CELSIUS = 24 } },
    })
end

function tests.reported_changes_update_the_setpoints()
    local mock, _, get, patch = start()
    OnWatchedVariableChanged(31, 1132, "70")
    T.eq(get().heat_setpoint, 21.1)
    OnWatchedVariableChanged(31, 1104, "Heat")
    local thermostat = get()
    T.eq(thermostat.mode, "heat")
    T.eq(thermostat.target_temperature, 21.1)
    OnWatchedVariableChanged(31, 1146, "4")
    T.eq(get().setpoint_deadband, 2.2)

    -- The project switched to °C: the °C variables are read and commands go in °C.
    OnWatchedVariableChanged(31, 1100, "CELSIUS")
    thermostat = get()
    T.eq(thermostat.heat_setpoint, 20, "1133")
    T.eq(thermostat.cool_setpoint, 24.4, "1135")
    T.eq(thermostat.setpoint_deadband, 1.7, "1147")
    T.same(sent(mock, patch, { heat_setpoint = 21 }), { { "SET_SETPOINT_HEAT", { CELSIUS = 21 } } })
end

-- The room temperature is shown as measured. Setpoints are whole °F in a °F project; a measured
-- 71.6 °F is 22.0 °C, not 72 °F (22.2 °C).
function tests.the_room_temperature_is_not_rounded_to_whole_fahrenheit()
    local _, _, get = start({ scale = "FAHRENHEIT" }, function(project)
        project.variables[31][1130] = "71.6"
        project.variables[31][1131] = "22"
    end)
    T.eq(get().current_temperature, 22)
    OnWatchedVariableChanged(31, 1130, "70.7")
    T.eq(get().current_temperature, 21.5)
    OnWatchedVariableChanged(31, 1100, "CELSIUS")
    T.eq(get().current_temperature, 22, "1131 in a °C project")
end

-- A thermostat whose modes use only one setpoint reports only that one, even when the proxy has
-- the other one's variables: the app shows and pushes every setpoint reported.
function tests.a_thermostat_with_one_mode_reports_only_its_setpoint()
    local mock, _, get, patch = start({ scale = "FAHRENHEIT" }, function(project)
        project.variables[31][1120] = "Off,Cool"
        project.variables[31][1104] = "Cool"
    end)
    local thermostat = get()
    T.truthy(isNull(thermostat.heat_setpoint), "no heat mode, no heat setpoint")
    T.eq(thermostat.cool_setpoint, 24.4)
    T.eq(thermostat.target_temperature, 24.4)
    T.same(sent(mock, patch, { cool_setpoint = 21.5 }), { { "SET_SETPOINT_COOL", { FAHRENHEIT = 71 } } }, "the heat setpoint is not pushed")
    OnWatchedVariableChanged(31, 1104, "Off")
    thermostat = get()
    T.truthy(isNull(thermostat.heat_setpoint), "in Off too")
    T.eq(thermostat.cool_setpoint, 24.4)

    mock, _, get, patch = start({ scale = "FAHRENHEIT" }, function(project)
        project.variables[31][1120] = "Off,Heat"
        project.variables[31][1104] = "Heat"
    end)
    thermostat = get()
    T.eq(thermostat.heat_setpoint, 20)
    T.truthy(isNull(thermostat.cool_setpoint))
    T.same(sent(mock, patch, { heat_setpoint = 25 }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 77 } } }, "above the unused cool setpoint")
end

-- Without a reported deadband cool still stays above heat, as scene steps and the app require.
function tests.without_a_deadband_cool_stays_above_heat()
    local mock, _, _, patch = start({ scale = "FAHRENHEIT", deadband = false })
    T.same(sent(mock, patch, { heat_setpoint = 25 }),
        { { "SET_SETPOINT_COOL", { FAHRENHEIT = 78 } }, { "SET_SETPOINT_HEAT", { FAHRENHEIT = 77 } } })
    local answer = refused(mock, patch, { heat_setpoint = 22, cool_setpoint = 22 }, 400, "INVALID_FIELD")
    T.eq(answer.errors[1].field, "cool_setpoint")
    refused(mock, patch, { heat_setpoint = 22.5, cool_setpoint = 23 }, 400, "INVALID_FIELD")
end

function tests.fan_speeds_are_the_ones_the_api_knows()
    local mock, _, get, patch = start()
    T.same(sent(mock, patch, { fan_speed = "on" }), { { "SET_MODE_FAN", { MODE = "On" } } })
    refused(mock, patch, { fan_speed = "low" }, 409, "NOT_SUPPORTED")
    refused(mock, patch, { fan_speed = "circulate" }, 409, "NOT_SUPPORTED")
    refused(mock, patch, { fan_speed = "humidify" }, 400, "INVALID_FIELD")

    OnWatchedVariableChanged(31, 1121, "Auto,On,Circulate,Humidify")
    T.same(get().fan_speeds, { "auto", "on", "circulate" }, "a speed the API has no name for is not offered")
    T.same(sent(mock, patch, { fan_speed = "circulate" }), { { "SET_MODE_FAN", { MODE = "Circulate" } } })
end

function tests.a_single_setpoint_zone_is_unchanged_and_refuses_setpoints()
    local mock, _, get, patch = start()
    local thermostat = get(30)
    T.eq(thermostat.setpoints, "single")
    T.truthy(isNull(thermostat.heat_setpoint))
    T.truthy(isNull(thermostat.cool_setpoint))
    T.truthy(isNull(thermostat.setpoint_deadband))
    T.eq(thermostat.target_temperature, 22)
    T.same(thermostat.fan_speeds, { "low", "medium", "high" })
    local keys = {}
    for name in pairs(thermostat) do
        keys[#keys + 1] = name
    end
    table.sort(keys)
    T.same(keys, {
        "activity", "cool_setpoint", "current_temperature", "fan_speed", "fan_speeds", "heat_setpoint", "id",
        "mode", "modes", "name", "online", "room", "setpoint_deadband", "setpoints", "target_temperature",
        "target_temperature_max", "target_temperature_min",
    }, "the 1.0.0 keys and the four new ones")

    local answer = refused(mock, patch, { heat_setpoint = 20 }, 409, "NOT_SUPPORTED", 30)
    T.contains(answer.detail, "send target_temperature")
    refused(mock, patch, { mode = "heat", cool_setpoint = 24 }, 409, "NOT_SUPPORTED", 30)
    T.same(sent(mock, patch, { mode = "heat", target_temperature = 23 }, 30), {
        { "SET_MODE_HVAC", { MODE = "Heat" } },
        { "SET_SETPOINT_SINGLE", { CELSIUS = 23 } },
    }, "the mode in the request does not change a single target")
end

function tests.a_failed_send_says_which_setpoints_went_out()
    local mock, _, _, patch = start()
    local send = C4.SendToDevice
    C4.SendToDevice = function(self, deviceId, command, params)
        if command == "SET_SETPOINT_HEAT" then
            error("device offline")
        end
        return send(self, deviceId, command, params)
    end
    local response = patch({ mode = "heat", heat_setpoint = 23.5 })
    C4.SendToDevice = send
    T.eq(response.status, 502, response.body)
    T.eq(response.json.code, "CONTROLLER_COMMAND_FAILED")
    T.eq(response.json.failed_field, "heat_setpoint")
    T.same(response.json.applied, { "mode", "cool_setpoint" }, "the mode and the pushed cool setpoint were sent")
end

function tests.a_thermostat_that_cannot_start_is_listed_as_unsupported()
    for _, change in ipairs({
        function(project)
            project.variables[31][1100] = "KELVIN"
        end,
        function(project)
            project.variables[31][1104] = nil
        end,
        function(project)
            for id = 1132, 1135 do
                project.variables[31][id] = nil
            end
        end,
    }) do
        local project = Mock.withDualThermostat(Mock.project())
        change(project)
        local mock = Mock.startDriver(project)
        local key = T.pair(mock)
        local device = T.http(mock, "GET", "/v1/devices/31", { key = key }).json
        T.eq(device.type, "thermostat")
        T.eq(device.supported, false)
        T.truthy(isNull(device.href))
        T.eq(T.http(mock, "GET", "/v1/thermostats/31", { key = key }).status, 404)
    end
end

return tests
