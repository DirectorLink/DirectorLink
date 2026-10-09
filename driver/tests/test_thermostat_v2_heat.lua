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

-- An AC zone never takes the heat setpoint path, even when its single setpoint reads 0. Since
-- 1.10.2 (ADR-076, #75) such a zone reads its heat and cool setpoints, as a Nest reports them, and
-- follows them when it has one: here only heat, so in Cool it has no target ("—", never -18°).
function tests.an_ac_zone_with_a_heat_setpoint_and_no_single_one_follows_its_setpoints()
    local project = Mock.project()
    project.variables[30][1149] = "0"
    project.variables[30][1150] = "0"
    project.variables[30][1133] = "20"
    local mock, key, get, patch = start(project)
    local thermostat = get()
    T.eq(thermostat.setpoints, "dual")
    T.eq(thermostat.heat_setpoint, 20)
    T.truthy(isNull(thermostat.cool_setpoint), "no cool setpoint reported")
    T.truthy(isNull(thermostat.target_temperature), "in Cool, the cool setpoint: not reported")
    local before = #mock.commands
    T.eq(patch({ target_temperature = 23 }).status, 409, "no cool setpoint to set")
    T.eq(#mock.commands, before)
    T.truthy(listening(mock, 30, 1133) and listening(mock, 30, 1150), "the setpoints it has are watched")

    OnWatchedVariableChanged(30, 1104, "Heat")
    T.eq(get().target_temperature, 20)
    T.eq(patch({ target_temperature = 23 }).status, 202)
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_HEAT", params = { CELSIUS = 23 } })

    local logs = T.http(mock, "GET", "/v1/logs?category=climate", { key = key }).json.items
    T.eq(logs[1].message, "initialized thermostat")
    T.eq(logs[1].data.setpoint_source, "dual")
    T.eq(logs[1].data.target_temperature_c, nil, "not -18")
end

-- An AC zone whose single setpoint reads 0 and that reports no other setpoint keeps its single
-- setpoint: no target to show ("—"), and one can still be set, as in 1.0.0.
function tests.an_ac_zone_without_any_setpoint_reported_stays_on_its_single_setpoint()
    local project = Mock.project()
    project.variables[30][1149] = "0"
    project.variables[30][1150] = "0"
    local mock, _, get, patch = start(project)
    local thermostat = get()
    T.eq(thermostat.setpoints, "single")
    T.truthy(isNull(thermostat.target_temperature), "0 °F is not a target")
    T.eq(thermostat.target_temperature_min, 16)
    T.eq(patch({ target_temperature = 23 }).status, 202)
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_SINGLE", params = { CELSIUS = 23 } })
    T.eq(patch({ target_temperature = 15 }).status, 400)
    OnWatchedVariableChanged(30, 1149, "73.4")
    T.eq(get().target_temperature, 23, "once it is reported")
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
    -- In a °F project, whole °F in the project's scale (1.10.2, #75).
    T.same(lastCommand(mock), { device = 30, command = "SET_SETPOINT_SINGLE", params = { FAHRENHEIT = 72 } })
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

-- The mode list can arrive after start-up too: until then the zone counts as Off,Heat,Cool, and
-- since 1.10.2 one whose single setpoint reads 0 follows the heat setpoint it reports as a Nest's
-- (ADR-076). When it turns heat-only, it is on its heat setpoint as floor heating.
function tests.a_mode_list_that_arrives_late_can_move_a_zone_to_its_heat_setpoint()
    local project = heatOnlyProject("FAHRENHEIT")
    project.variables[30][1120] = ""
    local mock, _, get, patch = start(project)
    local thermostat = get()
    T.same(thermostat.modes, { "off", "heat", "cool" })
    T.eq(thermostat.setpoints, "dual", "not heat-only yet")
    -- In a °F project, in whole °F (71 °F, 21.7 °C), as the thermostat takes it.
    T.eq(thermostat.target_temperature_f, 71, "in Heat, its heat setpoint")
    T.eq(thermostat.target_temperature, 21.7)
    T.truthy(listening(mock, 30, 1133) and listening(mock, 30, 1150))

    project.variables[30][1120] = "Off,Heat"
    OnWatchedVariableChanged(30, 1120, "Off,Heat")
    thermostat = get()
    T.same(thermostat.modes, { "off", "heat" })
    T.eq(thermostat.setpoints, "single")
    T.eq(thermostat.target_temperature, 21.5, "the heat setpoint, not 0 °F")
    T.eq(thermostat.target_temperature_min, 5)
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

-- A floor zone in use on its single setpoint never reads 1133 or 1150: not at start-up, as in
-- 1.0.0, and not on later changes, even when they are missing.
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
    T.eq(reads, 0, "not at start-up")
    OnWatchedVariableChanged(30, 1149, "73.4")
    OnWatchedVariableChanged(30, 1131, "21.5")
    OnWatchedVariableChanged(30, 1120, "Off,Heat")
    T.eq(reads, 0, "nor later")
    T.truthy(not listening(mock, 30, 1133) and not listening(mock, 30, 1150))
    local thermostat = get()
    T.eq(thermostat.target_temperature, 23)
    T.eq(thermostat.target_temperature_min, 16)
end

-- What 1.0.0 (d7e111f) did for zone 30 when it started, recorded from its adapter on the fake
-- Director: the reads, then the listeners of the three required variables, then each optional one
-- read again and watched when it exists. It never read 1133 or 1150, nor listed the variables.
local START_100 = {
    "get 1131", "get 1104", "get 1149", "get 1105", "get 1107", "get 1112", "get 1120", "get 1100",
    "watch 1131", "watch 1104", "watch 1149",
    "get 1105", "watch 1105", "get 1107", "watch 1107", "get 1112", "watch 1112",
    "get 1120", "watch 1120", "get 1100", "watch 1100",
}

local function without(list, left)
    local result = {}
    for _, entry in ipairs(list) do
        if entry ~= left then
            result[#result + 1] = entry
        end
    end
    return result
end

-- The test system's zones (14 AC zones, and 8 floor-heating zones on their single setpoint) start
-- with exactly the reads, listeners and log line of 1.0.0, at Info and at Debug.
function tests.zones_on_their_single_setpoint_start_exactly_as_in_1_0_0()
    local floor = { [1100] = "CELSIUS", [1104] = "Heat", [1107] = "Heat", [1120] = "Off,Heat", [1149] = "71.6" }
    local shapes = {
        {
            name = "AC zone in cool", calls = START_100,
            log = '{"current_temperature_c":26,"device_id":30,"fan_mode":"Low","hvac_modes":["Off","Heat","Cool"],"target_temperature_c":22}',
        },
        {
            name = "AC zone off at 32 °C", variables = { [1104] = "Off", [1107] = "Off", [1149] = "89.6" }, calls = START_100,
            log = '{"current_temperature_c":26,"device_id":30,"fan_mode":"Low","hvac_modes":["Off","Heat","Cool"],"target_temperature_c":32}',
        },
        {
            name = "AC zone with 1133 and 1150", variables = { [1133] = "22", [1150] = "22" }, calls = START_100,
            log = '{"current_temperature_c":26,"device_id":30,"fan_mode":"Low","hvac_modes":["Off","Heat","Cool"],"target_temperature_c":22}',
        },
        {
            name = "AC zone without a mode list", variables = { [1120] = false }, calls = without(START_100, "watch 1120"),
            log = '{"current_temperature_c":26,"device_id":30,"fan_mode":"Low","hvac_modes":["Off","Heat","Cool"],"target_temperature_c":22}',
        },
        {
            name = "floor heating with 1133 and 1150", variables = { [1105] = "Undefined", [1133] = "22", [1150] = "22" }, base = floor,
            calls = START_100,
            log = '{"current_temperature_c":26,"device_id":30,"fan_mode":"Undefined","hvac_modes":["Off","Heat"],"target_temperature_c":22}',
        },
        {
            name = "floor heating without 1133, 1150 or a fan", variables = { [1105] = false }, base = floor,
            calls = without(START_100, "watch 1105"),
            log = '{"current_temperature_c":26,"device_id":30,"hvac_modes":["Off","Heat"],"target_temperature_c":22}',
        },
    }
    for _, level in ipairs({ "Info", "Debug" }) do
        for _, shape in ipairs(shapes) do
            local project = Mock.project()
            for id, value in pairs(shape.base or {}) do
                project.variables[30][id] = value
            end
            for id, value in pairs(shape.variables or {}) do
                project.variables[30][id] = value or nil
            end
            local calls, lines = {}, {}
            Mock.startDriver(project, nil, nil, function()
                Properties["Log Level"] = level
                local getVariable, register, deviceVariables, debugLog = C4.GetVariable, C4.RegisterVariableListener, C4.GetDeviceVariables, C4.DebugLog
                C4.GetVariable = function(self, deviceId, variableId)
                    if deviceId == 30 then
                        calls[#calls + 1] = "get " .. tostring(variableId)
                    end
                    return getVariable(self, deviceId, variableId)
                end
                C4.RegisterVariableListener = function(self, deviceId, variableId)
                    if deviceId == 30 then
                        calls[#calls + 1] = "watch " .. tostring(variableId)
                    end
                    return register(self, deviceId, variableId)
                end
                C4.GetDeviceVariables = function(self, deviceId)
                    if deviceId == 30 then
                        calls[#calls + 1] = "list variables"
                    end
                    return deviceVariables(self, deviceId)
                end
                C4.DebugLog = function(self, message)
                    if message:find("[climate]", 1, true) then
                        lines[#lines + 1] = message
                    end
                    return debugLog(self, message)
                end
            end)
            local label = shape.name .. " at " .. level
            T.same(calls, shape.calls, label)
            T.same(lines, { "[DirectorLink][INFO][climate] initialized thermostat " .. shape.log }, label)
        end
    end
end

-- The zone's variable list is read for the Debug log only, once.
function tests.a_heat_only_zone_lists_its_variables_only_at_debug()
    for _, level in ipairs({ "Info", "Debug" }) do
        local lists = 0
        local mock, key = start(heatOnlyProject("FAHRENHEIT"), function()
            Properties["Log Level"] = level
            local deviceVariables = C4.GetDeviceVariables
            C4.GetDeviceVariables = function(self, deviceId)
                if deviceId == 30 then
                    lists = lists + 1
                end
                return deviceVariables(self, deviceId)
            end
        end)
        OnWatchedVariableChanged(30, 1131, "20.5")
        OnWatchedVariableChanged(30, 1149, "0")
        local debug = level == "Debug"
        T.eq(lists, debug and 1 or 0, level)
        local found
        for _, entry in ipairs(T.http(mock, "GET", "/v1/logs?category=climate&level=debug", { key = key }).json.items) do
            if entry.message == "heat-only thermostat variables" then
                found = entry.data.variables
            end
        end
        if debug then
            T.contains(found, "1133=1133:21.5")
        else
            T.eq(found, nil, level)
        end
    end
end

-- A mode list that arrives after start-up without Cool takes the fan control away, as a zone
-- without Cool never gets it at start-up. A zone that keeps Cool keeps its fan.
function tests.a_zone_that_loses_cool_loses_its_fan_control()
    local project = heatOnlyProject("FAHRENHEIT")
    project.variables[30][1120] = ""
    local mock, key, get, patch = start(project)
    T.same(get().fan_speeds, { "low", "medium", "high" }, "counted as Off,Heat,Cool until its list comes")

    OnWatchedVariableChanged(30, 1120, "Off,Heat")
    local thermostat = get()
    T.same(thermostat.modes, { "off", "heat" })
    T.eq(#thermostat.fan_speeds, 0)
    T.eq(thermostat.target_temperature, 21.5)
    local before = #mock.commands
    local refused = patch({ fan_speed = "low" })
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "NOT_SUPPORTED")
    T.eq(#mock.commands, before, "no SET_MODE_FAN to floor heating")
    local ran = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
        { type = "climate", device_ids = { 30 }, set = { mode = "heat", target_temperature = 21, fan_speed = "high" } },
    } } })
    T.eq(ran.status, 202, ran.body)
    for index = before + 1, #mock.commands do
        T.truthy(mock.commands[index].command ~= "SET_MODE_FAN", "a scene sends it no fan speed either")
    end
    T.same(mock.commands[#mock.commands], { device = 30, command = "SET_SETPOINT_HEAT", params = { FAHRENHEIT = 70 } })

    local fresh = heatOnlyProject("FAHRENHEIT")
    local _, _, getFresh = start(fresh)
    T.same(getFresh().fan_speeds, thermostat.fan_speeds, "as a fresh start of the same zone")

    local acMock, _, getAc, patchAc = start(Mock.project())
    OnWatchedVariableChanged(30, 1120, "Off,Heat,Cool,Auto")
    T.same(getAc().fan_speeds, { "low", "medium", "high" }, "an AC zone keeps its fan")
    T.eq(patchAc({ fan_speed = "medium" }).status, 202)
    T.same(lastCommand(acMock), { device = 30, command = "SET_MODE_FAN", params = { MODE = "Medium" } })
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
