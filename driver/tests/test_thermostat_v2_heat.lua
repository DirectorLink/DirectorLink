-- Thermostat V2 zones that keep their target in the heat setpoint (src/adapters/thermostat_v2.lua):
-- heat-only floor heating whose single setpoint reads 0 in both scales (#19). Every case changes
-- the default project's zone 30, so no inventory count moves; AC zones must not change at all.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

local function listening(mock, deviceId, variableId)
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId and entry[2] == variableId then
            return true
        end
    end
    return false
end

-- Zone 30 as a heat-only floor zone on its heat setpoint, as seen on a real °F project.
local function heatOnlyProject(scale)
    local project = Mock.project()
    local variables = project.variables[30]
    variables[1100] = scale or "FAHRENHEIT"
    variables[1104] = "Heat"
    variables[1105] = "Undefined"
    variables[1107] = "Heat"
    variables[1120] = "Off,Heat"
    variables[1131] = "20"
    variables[1133] = "21.5"
    variables[1149] = "0"
    variables[1150] = "0"
    return project
end

local function start(project, prepare)
    local mock = Mock.startDriver(project, nil, nil, prepare)
    local key = T.pair(mock)
    local function get()
        return T.http(mock, "GET", "/v1/thermostats/30", { key = key }).json
    end
    local function patch(body)
        return T.http(mock, "PATCH", "/v1/thermostats/30", { key = key, body = body })
    end
    return mock, key, get, patch
end

local function lastCommand(mock)
    return mock.commands[#mock.commands]
end

function tests.a_heat_only_zone_follows_its_heat_setpoint_in_fahrenheit()
    local mock, _, get, patch = start(heatOnlyProject("FAHRENHEIT"))
    local thermostat = get()
    T.eq(thermostat.target_temperature, 21.5, "the heat setpoint, not 0 °F")
    T.eq(thermostat.target_temperature_min, 5, "floor heating can be parked low")
    T.eq(thermostat.target_temperature_max, 32)
    T.same(thermostat.modes, { "off", "heat" })
    T.eq(#thermostat.fan_speeds, 0)
    T.truthy(isNull(thermostat.fan_speed), "an Undefined fan mode is no fan speed")

    T.eq(patch({ target_temperature = 23 }).status, 202)
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 73 } }, "whole °F")
    T.eq(patch({ target_temperature = 5 }).status, 202)
    T.same(lastCommand(mock).params, { FAHRENHEIT = 41 })
    local before = #mock.commands
    T.eq(patch({ target_temperature = 4 }).json.code, "INVALID_FIELD")
    T.eq(#mock.commands, before)

    OnWatchedVariableChanged(30, 1133, "22.8")
    T.eq(get().target_temperature, 22.8)
    T.truthy(listening(mock, 30, 1133) and listening(mock, 30, 1150), "the heat setpoint and the single °C setpoint are watched")
end

function tests.a_heat_only_zone_in_celsius_sends_celsius()
    local mock, _, get, patch = start(heatOnlyProject("CELSIUS"))
    T.eq(get().target_temperature, 21.5)
    patch({ target_temperature = 23 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { CELSIUS = 23 } })
    patch({ target_temperature = 21.5 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { CELSIUS = 21.5 } })
end

-- An AC zone never takes the heat setpoint path, even when its single setpoint reads 0.
function tests.an_ac_zone_stays_on_its_single_setpoint()
    local project = Mock.project()
    project.variables[30][1149] = "0"
    project.variables[30][1150] = "0"
    project.variables[30][1133] = "20"
    local mock, key, get, patch = start(project)
    T.eq(get().target_temperature_min, 16)
    T.eq(patch({ target_temperature = 23 }).status, 202)
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_SINGLE", params = { CELSIUS = 23 } })
    T.eq(patch({ target_temperature = 15 }).status, 400)
    T.truthy(not listening(mock, 30, 1133) and not listening(mock, 30, 1150), "nothing new is read or watched")
    OnWatchedVariableChanged(30, 1149, "0")
    OnWatchedVariableChanged(30, 1120, "Off,Heat,Cool")
    T.truthy(not listening(mock, 30, 1133) and not listening(mock, 30, 1150), "nor after later changes")
    T.eq(get().target_temperature_min, 16)

    local logs = T.http(mock, "GET", "/v1/logs?category=climate", { key = key }).json.items
    T.eq(logs[1].message, "initialized thermostat")
    T.eq(logs[1].data.setpoint_source, "single")
end

-- The owner's floor zones: heat-only, with a real single setpoint. Same state, command and range.
function tests.a_heat_only_zone_with_a_real_single_setpoint_is_unchanged()
    local project = Mock.project()
    local variables = project.variables[30]
    variables[1120] = "Off,Heat"
    variables[1149] = "71.6"
    variables[1150] = "22"
    variables[1133] = "20"
    local mock, _, get, patch = start(project)
    local thermostat = get()
    T.eq(thermostat.target_temperature, 22)
    T.eq(thermostat.target_temperature_min, 16)
    patch({ target_temperature = 21 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_SINGLE", params = { CELSIUS = 21 } })
    OnWatchedVariableChanged(30, 1133, "19")
    T.eq(get().target_temperature, 22, "the heat setpoint is not its target")
end

function tests.a_missing_or_real_single_setpoint_keeps_the_single_path()
    local missing = heatOnlyProject("FAHRENHEIT")
    missing.variables[30][1150] = nil
    local mock, _, get, patch = start(missing)
    T.eq(get().target_temperature_min, 16, "without 1150 nothing says the single setpoint is unused")
    patch({ target_temperature = 22 })
    T.eq(lastCommand(mock).command, "SET_SETPOINT_SINGLE")

    local zero = heatOnlyProject("CELSIUS")
    zero.variables[30][1149] = "32"
    zero.variables[30][1150] = "0"
    local _, _, getZero = start(zero)
    local thermostat = getZero()
    T.eq(thermostat.target_temperature, 0, "a real 0 °C target reads 32 °F")
    T.eq(thermostat.target_temperature_min, 16)
end

-- Values read while Director restarts can be 0; the path follows the values that arrive later.
function tests.the_setpoint_path_follows_later_values()
    local mock, key, get, patch = start(heatOnlyProject("FAHRENHEIT"))
    T.eq(get().target_temperature_min, 5)
    OnWatchedVariableChanged(30, 1149, "71.6")
    OnWatchedVariableChanged(30, 1150, "22")
    local thermostat = get()
    T.eq(thermostat.target_temperature, 22)
    T.eq(thermostat.target_temperature_min, 16)
    patch({ target_temperature = 22 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_SINGLE", params = { CELSIUS = 22 } })
    local logs = T.http(mock, "GET", "/v1/logs?category=climate", { key = key }).json.items
    T.eq(logs[#logs].message, "setpoint path changed")
    T.eq(logs[#logs].data.setpoint_source, "single")

    local real = heatOnlyProject("FAHRENHEIT")
    real.variables[30][1149] = "71.6"
    real.variables[30][1150] = "22"
    real.variables[30][1133] = "20"
    local mockReal, _, getReal, patchReal = start(real)
    T.eq(getReal().target_temperature, 22)
    OnWatchedVariableChanged(30, 1149, "0")
    OnWatchedVariableChanged(30, 1150, "0")
    thermostat = getReal()
    T.eq(thermostat.target_temperature, 20, "now from the heat setpoint")
    T.eq(thermostat.target_temperature_min, 5)
    patchReal({ target_temperature = 21 })
    T.same(lastCommand(mockReal), { device = 30, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 70 } })
end

-- The mode list can arrive after start-up too: until then the zone counts as Off,Heat,Cool and
-- reads nothing of its heat setpoint. When it turns heat-only, 1133 and 1150 are read and watched.
function tests.a_mode_list_that_arrives_late_can_move_a_zone_to_its_heat_setpoint()
    local project = heatOnlyProject("FAHRENHEIT")
    project.variables[30][1120] = ""
    local mock, _, get, patch = start(project)
    local thermostat = get()
    T.same(thermostat.modes, { "off", "heat", "cool" })
    T.eq(thermostat.target_temperature_min, 16)
    T.truthy(not listening(mock, 30, 1133) and not listening(mock, 30, 1150), "not heat-only yet")

    project.variables[30][1120] = "Off,Heat"
    OnWatchedVariableChanged(30, 1120, "Off,Heat")
    thermostat = get()
    T.same(thermostat.modes, { "off", "heat" })
    T.eq(thermostat.target_temperature, 21.5, "the heat setpoint, not 0 °F")
    T.eq(thermostat.target_temperature_min, 5)
    T.truthy(listening(mock, 30, 1133) and listening(mock, 30, 1150), "now watched")
    patch({ target_temperature = 23 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 73 } })
    OnWatchedVariableChanged(30, 1133, "22.8")
    T.eq(get().target_temperature, 22.8)
end

-- A heat setpoint that is not there at start-up is looked for again when the single setpoint
-- changes, so a later value is not missed for want of a listener.
function tests.a_heat_setpoint_missing_at_start_up_is_looked_for_again()
    local project = heatOnlyProject("FAHRENHEIT")
    project.variables[30][1133] = nil
    local mock, _, get, patch = start(project)
    T.eq(get().target_temperature_min, 16, "no heat setpoint to follow yet")
    T.truthy(not listening(mock, 30, 1133))

    project.variables[30][1133] = "21.5"
    OnWatchedVariableChanged(30, 1149, "0")
    T.truthy(listening(mock, 30, 1133), "watched once it exists")
    local thermostat = get()
    T.eq(thermostat.target_temperature, 21.5)
    T.eq(thermostat.target_temperature_min, 5)
    patch({ target_temperature = 21 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 70 } })
    local count = 0
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == 30 and entry[2] == 1133 then
            count = count + 1
        end
    end
    OnWatchedVariableChanged(30, 1149, "0")
    local again = 0
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == 30 and entry[2] == 1133 then
            again = again + 1
        end
    end
    T.eq(again, count, "registered once")
end

-- The single setpoint of such a zone stays at 0, so the room temperature is where a heat setpoint
-- that appears later is found.
function tests.a_later_heat_setpoint_is_found_on_a_temperature_change()
    local project = heatOnlyProject("CELSIUS")
    project.variables[30][1133] = nil
    local mock, _, get, patch = start(project)
    T.eq(get().target_temperature_min, 16)
    OnWatchedVariableChanged(30, 1131, "20.5")
    T.truthy(not listening(mock, 30, 1133), "still missing")
    T.eq(get().current_temperature, 20.5)

    project.variables[30][1133] = "22"
    OnWatchedVariableChanged(30, 1131, "20.6")
    T.truthy(listening(mock, 30, 1133))
    local thermostat = get()
    T.eq(thermostat.current_temperature, 20.6)
    T.eq(thermostat.target_temperature, 22)
    T.eq(thermostat.target_temperature_min, 5)
    patch({ target_temperature = 21 })
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { CELSIUS = 21 } })
end

-- A floor zone in use on its single setpoint reads 1133 and 1150 once at start-up, as before, and
-- not again on later changes, even when they are missing.
function tests.a_zone_on_its_single_setpoint_reads_nothing_more_later()
    local project = Mock.project()
    local variables = project.variables[30]
    variables[1120] = "Off,Heat"
    variables[1149] = "71.6"
    local reads = 0
    local mock, _, get = start(project, function()
        local getVariable = C4.GetVariable
        C4.GetVariable = function(self, deviceId, variableId)
            if deviceId == 30 and (variableId == 1133 or variableId == 1150) then
                reads = reads + 1
            end
            return getVariable(self, deviceId, variableId)
        end
    end)
    T.eq(reads, 2, "read once at start-up")
    OnWatchedVariableChanged(30, 1149, "73.4")
    OnWatchedVariableChanged(30, 1131, "21.5")
    OnWatchedVariableChanged(30, 1120, "Off,Heat")
    T.eq(reads, 2, "not again")
    T.truthy(not listening(mock, 30, 1133) and not listening(mock, 30, 1150))
    local thermostat = get()
    T.eq(thermostat.target_temperature, 23)
    T.eq(thermostat.target_temperature_min, 16)
end

function tests.an_undefined_fan_mode_is_no_fan_speed()
    local _, _, get = start(Mock.project())
    T.eq(get().fan_speed, "low")
    OnWatchedVariableChanged(30, 1105, "Undefined")
    T.truthy(isNull(get().fan_speed))
end

-- A scene uses the zone's own range: 10 °C is not raised to 16 on floor heating.
function tests.a_scene_sets_a_heat_setpoint_zone_below_sixteen()
    local mock, key = start(heatOnlyProject("FAHRENHEIT"))
    local before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
        { type = "climate", device_ids = { 30 }, set = { mode = "heat", target_temperature = 10 } },
    } } })
    T.eq(ran.status, 202, ran.body)
    T.eq(ran.json.ran, 1)
    T.eq(#mock.commands, before + 2)
    T.same(mock.commands[before + 1], { device = 30, command = "SET_MODE_HVAC", params = { MODE = "Heat" } })
    T.same(mock.commands[before + 2], { device = 30, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 50 } })
end

return tests
