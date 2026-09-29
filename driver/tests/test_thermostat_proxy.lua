-- The Control4 thermostat proxy adapter (src/adapters/thermostat_proxy.lua), driven directly:
-- the record it keeps for the API layer, the setpoint plan (deadband push and send order) in °F
-- and °C projects, and Manager.prepare, which checks a request before anything is sent.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

-- A fresh adapter on the fake Director with the dual thermostat 31 (Mock.withDualThermostat).
-- `change(project)` edits the project before the adapter starts.
local function setup(options, change)
    local project = Mock.withDualThermostat(Mock.project(), options)
    if change then
        change(project)
    end
    local mock = Mock.install(project)
    package.loaded["src.adapters.thermostat_proxy"] = nil
    package.loaded["src.adapters.thermostat_units"] = nil
    local Proxy = require("src.adapters.thermostat_proxy")
    local device = {
        id = 31,
        name = "Study",
        kind = "climate",
        supported = false,
        proxy = { id = 31, driver = "control4_thermostat_proxy.c4i" },
        protocols = {},
    }
    local ok, err = Proxy.initialize(device)
    return {
        mock = mock,
        Proxy = Proxy,
        device = device,
        ok = ok,
        err = err,
        project = project,
    }
end

local function commandsSince(mock, before)
    local list = {}
    for index = before + 1, #mock.commands do
        local command = mock.commands[index]
        list[#list + 1] = { command.command, command.params }
    end
    return list
end

-- Runs one action and returns what it sent (or nil and the failure).
local function run(s, action, params)
    local before = #s.mock.commands
    local ok, result = s.Proxy.execute(s.device, action, params)
    if not ok then
        T.eq(#s.mock.commands, before, "nothing is sent when " .. action .. " is refused")
        return nil, result
    end
    return commandsSince(s.mock, before), result
end

local function listening(mock, deviceId, variableId)
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId and entry[2] == variableId then
            return true
        end
    end
    return false
end

function tests.a_fahrenheit_thermostat_keeps_the_record_the_api_reads()
    local s = setup({ scale = "FAHRENHEIT" })
    T.eq(s.ok, true, s.err)
    T.eq(s.device.supported, true)
    local capabilities, state = s.device.capabilities, s.device.state
    T.eq(capabilities.setpoints, "dual")
    T.eq(capabilities.scale, "F")
    T.same(capabilities.hvac_modes, { "Off", "Heat", "Cool", "Auto" }, "the proxy's own casing")
    T.same(capabilities.fan_modes, { "Auto", "On" })
    T.eq(capabilities.has_heat, true)
    T.eq(capabilities.has_cool, true)
    T.eq(capabilities.deadband_native, 3, "whole °F")
    T.eq(capabilities.deadband_c, 1.7, "a difference: 3 × 5/9")
    T.eq(capabilities.target_temperature_min_c, 5)
    T.eq(capabilities.target_temperature_max_c, 35)

    T.eq(state.connected, true)
    T.eq(state.scale, "FAHRENHEIT")
    T.eq(state.current_temperature_c, 21.7, "read from 1130 (71 °F)")
    T.eq(state.heat_native, 68)
    T.eq(state.cool_native, 76)
    T.eq(state.heat_setpoint_c, 20)
    T.eq(state.cool_setpoint_c, 24.4)
    T.eq(state.target_temperature_c, nil, "no single target in auto")
    T.eq(state.hvac_mode, "auto")
    T.eq(state.hvac_state, "off")
    T.eq(state.fan_mode, "auto")
    T.same(s.device.actions, { "set_hvac_mode", "set_temperature", "set_setpoints", "set_fan_mode" })

    for _, variableId in ipairs({ 1100, 1104, 1105, 1107, 1112, 1120, 1121, 1130, 1131, 1132, 1133, 1134, 1135, 1146, 1147 }) do
        T.truthy(listening(s.mock, 31, variableId), "watches " .. variableId)
    end
end

function tests.a_celsius_thermostat_reads_the_celsius_variables()
    local s = setup({ scale = "CELSIUS" })
    T.eq(s.ok, true, s.err)
    local capabilities, state = s.device.capabilities, s.device.state
    T.eq(capabilities.scale, "C")
    T.eq(capabilities.deadband_native, 20, "tenths of a °C")
    T.eq(capabilities.deadband_c, 2)
    T.eq(state.heat_native, 205)
    T.eq(state.heat_setpoint_c, 20.5)
    T.eq(state.cool_setpoint_c, 24)
    T.eq(state.current_temperature_c, 21)
end

-- The plan table of the design (°F, heat 68, cool 76, deadband 3).
function tests.fahrenheit_setpoints_push_and_order()
    local s = setup({ scale = "FAHRENHEIT" })
    T.same(run(s, "set_setpoints", { heat = 21 }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 70 } } }, "whole °F")
    T.same(run(s, "set_setpoints", { cool = 24 }), { { "SET_SETPOINT_COOL", { FAHRENHEIT = 75 } } })
    T.same(run(s, "set_setpoints", { heat = 23.5 }),
        { { "SET_SETPOINT_COOL", { FAHRENHEIT = 77 } }, { "SET_SETPOINT_HEAT", { FAHRENHEIT = 74 } } },
        "heat into the deadband pushes cool up, sent first")
    T.same(run(s, "set_setpoints", { heat = 22, cool = 26 }),
        { { "SET_SETPOINT_COOL", { FAHRENHEIT = 79 } }, { "SET_SETPOINT_HEAT", { FAHRENHEIT = 72 } } },
        "cool rises: cool first")
    T.same(run(s, "set_setpoints", { heat = 18, cool = 22 }),
        { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 64 } }, { "SET_SETPOINT_COOL", { FAHRENHEIT = 72 } } },
        "cool falls: heat first")

    local sent, failure = run(s, "set_setpoints", { heat = 22, cool = 23 })
    T.eq(sent, nil, "72 and 73 °F are closer than the deadband")
    T.eq(failure.code, "INVALID_TEMPERATURE")
    T.eq(failure.field, "cool_setpoint")
    T.contains(failure.message, "at least 1.7° above heat_setpoint")

    sent, failure = run(s, "set_setpoints", { cool = 6 })
    T.eq(sent, nil, "heat would have to fall below 5 °C")
    T.eq(failure.field, "cool_setpoint")
    sent, failure = run(s, "set_setpoints", { heat = 34 })
    T.eq(sent, nil, "cool would have to rise above 35 °C")
    T.eq(failure.field, "heat_setpoint")
    sent, failure = run(s, "set_setpoints", { heat = 4 })
    T.eq(failure.code, "INVALID_TEMPERATURE")
    T.eq(failure.field, "heat_setpoint")

    local _, result = run(s, "set_setpoints", { heat = 23.5 })
    T.same(result.requested, { heat_c = 23.5 })
    T.eq(#result.sent, 2)
    T.eq(result.sent[1].command, "SET_SETPOINT_COOL")
end

function tests.celsius_setpoints_are_sent_in_celsius()
    local s = setup({ scale = "CELSIUS" })
    T.same(run(s, "set_setpoints", { heat = 21.5 }), { { "SET_SETPOINT_HEAT", { CELSIUS = 21.5 } } })
    T.same(run(s, "set_setpoints", { heat = 22.5 }),
        { { "SET_SETPOINT_COOL", { CELSIUS = 24.5 } }, { "SET_SETPOINT_HEAT", { CELSIUS = 22.5 } } })

    -- In tenths there is no float trap: 24.0 - 22.3 is exactly a 1.7 deadband.
    local exact = setup({ scale = "CELSIUS", deadband = "1.7" })
    T.eq(exact.device.capabilities.deadband_c, 1.7)
    T.same(run(exact, "set_setpoints", { heat = 22.3, cool = 24.0 }),
        { { "SET_SETPOINT_HEAT", { CELSIUS = 22.3 } }, { "SET_SETPOINT_COOL", { CELSIUS = 24 } } })
end

-- target_temperature sets the setpoint of the mode: the one sent with it, else the current one.
function tests.set_temperature_follows_the_mode()
    local s = setup({ scale = "FAHRENHEIT" })
    T.same(run(s, "set_temperature", { value = 24, mode = "cool" }), { { "SET_SETPOINT_COOL", { FAHRENHEIT = 75 } } })
    T.same(run(s, "set_temperature", { value = 21, mode = "heat" }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 70 } } })

    local sent, failure = run(s, "set_temperature", { value = 22 })
    T.eq(sent, nil, "in auto there is no single target")
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")
    T.contains(failure.message, "send heat_setpoint and cool_setpoint")
    sent, failure = run(s, "set_temperature", { value = 22, mode = "off" })
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")

    s.Proxy.onVariableChanged(s.device, 1104, "Heat")
    T.eq(s.device.state.target_temperature_c, 20)
    T.same(run(s, "set_temperature", { value = 21 }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 70 } } })
    sent, failure = run(s, "set_temperature", { value = 34 })
    T.eq(sent, nil)
    T.eq(failure.code, "INVALID_TEMPERATURE")
    T.eq(failure.field, "target_temperature", "the field of the request")
end

function tests.modes_and_fan_speeds_use_the_proxy_spelling()
    local s = setup({ scale = "FAHRENHEIT" })
    T.same(run(s, "set_hvac_mode", { value = "cool" }), { { "SET_MODE_HVAC", { MODE = "Cool" } } })
    local _, failure = run(s, "set_hvac_mode", { value = "dry" })
    T.eq(failure.code, "HVAC_MODE_NOT_SUPPORTED")
    T.same(run(s, "set_fan_mode", { value = "on" }), { { "SET_MODE_FAN", { MODE = "On" } } })
    _, failure = run(s, "set_fan_mode", { value = "low" })
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")

    local noFan = setup({ scale = "FAHRENHEIT" }, function(project)
        project.variables[31][1121] = nil
    end)
    T.same(noFan.device.capabilities.fan_modes, {})
    T.same(noFan.device.actions, { "set_hvac_mode", "set_temperature", "set_setpoints" }, "no fan list, no fan control")
    s.Proxy.onVariableChanged(s.device, 1121, "Auto,On,Circulate")
    T.same(s.device.capabilities.fan_modes, { "Auto", "On", "Circulate" })
end

function tests.variable_changes_update_the_record()
    local s = setup({ scale = "FAHRENHEIT" })
    T.eq(s.Proxy.onVariableChanged(s.device, 1132, "70"), true)
    T.eq(s.device.state.heat_setpoint_c, 21.1)
    s.Proxy.onVariableChanged(s.device, "1104", "Heat")
    T.eq(s.device.state.target_temperature_c, 21.1)
    s.Proxy.onVariableChanged(s.device, 1104, "Cool")
    T.eq(s.device.state.target_temperature_c, 24.4)
    s.Proxy.onVariableChanged(s.device, 1146, "4")
    T.eq(s.device.capabilities.deadband_c, 2.2, "a deadband read once would never change")
    s.Proxy.onVariableChanged(s.device, 1105, "Undefined")
    T.eq(s.device.state.fan_mode, nil)
    s.Proxy.onVariableChanged(s.device, 1112, "0")
    T.eq(s.device.state.connected, false)
    T.eq(s.Proxy.onVariableChanged(s.device, 1108, "On"), false, "FAN_STATE is not used")
end

function tests.the_scale_follows_variable_1100()
    local s = setup({ scale = "FAHRENHEIT" })
    s.Proxy.onVariableChanged(s.device, 1100, "CELSIUS")
    local capabilities, state = s.device.capabilities, s.device.state
    T.eq(capabilities.scale, "C")
    T.eq(state.heat_setpoint_c, 20, "now from 1133")
    T.eq(state.cool_setpoint_c, 24.4, "now from 1135")
    T.eq(capabilities.deadband_c, 1.7, "now from 1147")
    T.same(run(s, "set_setpoints", { heat = 21.5 }), { { "SET_SETPOINT_HEAT", { CELSIUS = 21.5 } } })

    s.Proxy.onVariableChanged(s.device, 1100, "KELVIN")
    T.eq(s.device.capabilities.scale, "C", "an unknown scale keeps the last one")
    T.same(run(s, "set_setpoints", { heat = 21.5 }), { { "SET_SETPOINT_HEAT", { CELSIUS = 21.5 } } })
    T.contains(table.concat(s.mock.debugLog, "\n"), "thermostat scale is unknown")
end

function tests.initialize_refuses_what_it_cannot_read()
    local cases = {
        { "no HVAC mode", function(v) v[1104] = nil end, "1104" },
        { "no scale", function(v) v[1100] = nil end, "scale is unknown" },
        { "an unknown scale", function(v) v[1100] = "KELVIN" end, "scale is unknown" },
        { "no temperature", function(v) v[1130], v[1131] = nil, nil end, "temperature" },
        { "no setpoints", function(v) v[1132], v[1133], v[1134], v[1135] = nil, nil, nil, nil end, "setpoints" },
    }
    for _, case in ipairs(cases) do
        local s = setup({ scale = "FAHRENHEIT" }, function(project)
            case[2](project.variables[31])
        end)
        T.eq(s.ok, false, case[1])
        T.contains(s.err, case[3], case[1])
        T.eq(#s.mock.listeners, 0, case[1] .. ": nothing watched")
    end

    -- A listener Director refuses fails the thermostat too.
    local failing = setup({ scale = "FAHRENHEIT" })
    function C4:RegisterVariableListener(_deviceId, variableId)
        if variableId == 1146 then
            error("listener refused")
        end
    end
    failing.Proxy.reset()
    local ok, err = failing.Proxy.initialize(failing.device)
    T.eq(ok, false)
    T.contains(err, "1146")
end

-- Director reports each variable right after it is registered. Those values are the ones just
-- read, so the adapter drops them: it is tracked only once every listener is in place.
function tests.values_reported_during_registration_are_dropped()
    local s = setup({ scale = "FAHRENHEIT" })
    s.Proxy.reset()
    local answers = {}
    function C4:RegisterVariableListener(deviceId, variableId)
        answers[#answers + 1] = s.Proxy.onVariableChanged(s.device, variableId, "1")
    end
    T.eq(s.Proxy.initialize(s.device), true)
    T.eq(#answers, 15)
    for _, answer in ipairs(answers) do
        T.eq(answer, false)
    end
    T.eq(s.device.state.heat_native, 68)
end

-- A thermostat without cool or auto: its cool setpoint is never pushed or set.
function tests.a_heat_only_proxy_never_pushes_the_cool_setpoint()
    local s = setup({ scale = "FAHRENHEIT" }, function(project)
        project.variables[31][1120] = "Off,Heat"
        project.variables[31][1104] = "Heat"
    end)
    T.eq(s.device.capabilities.has_heat, true)
    T.eq(s.device.capabilities.has_cool, false)
    T.same(run(s, "set_setpoints", { heat = 23.5 }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 74 } } })
    local _, failure = run(s, "set_setpoints", { cool = 24 })
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")
    T.eq(failure.field, nil, "a missing setpoint is not a bad value")
end

-- Without a reported deadband, cool still stays above heat by one native step, as scene steps and
-- the app require: never both at the same value.
function tests.without_a_deadband_cool_stays_above_heat()
    local s = setup({ scale = "FAHRENHEIT", deadband = false })
    T.eq(s.device.capabilities.deadband_native, nil)
    T.eq(s.device.capabilities.deadband_c, nil)
    T.same(run(s, "set_setpoints", { heat = 23.5 }), { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 74 } } })
    T.same(run(s, "set_setpoints", { heat = 25 }),
        { { "SET_SETPOINT_COOL", { FAHRENHEIT = 78 } }, { "SET_SETPOINT_HEAT", { FAHRENHEIT = 77 } } }, "cool 1 °F above")
    T.same(run(s, "set_setpoints", { cool = 20 }),
        { { "SET_SETPOINT_HEAT", { FAHRENHEIT = 67 } }, { "SET_SETPOINT_COOL", { FAHRENHEIT = 68 } } }, "heat 1 °F below")
    for _, pair in ipairs({ { 25, 24 }, { 22, 22 }, { 22.5, 23 } }) do
        -- 22.5 and 23 °C are both 73 °F.
        local _, failure = run(s, "set_setpoints", { heat = pair[1], cool = pair[2] })
        T.eq(failure.field, "cool_setpoint", pair[1] .. "/" .. pair[2])
        T.eq(failure.message, "cool_setpoint must be above heat_setpoint")
    end

    local celsius = setup({ scale = "CELSIUS", deadband = false })
    T.same(run(celsius, "set_setpoints", { heat = 23.9 }), { { "SET_SETPOINT_HEAT", { CELSIUS = 23.9 } } }, "below cool (24 °C)")
    T.same(run(celsius, "set_setpoints", { heat = 25 }),
        { { "SET_SETPOINT_COOL", { CELSIUS = 25.1 } }, { "SET_SETPOINT_HEAT", { CELSIUS = 25 } } }, "cool 0.1 °C above")
    T.same(run(celsius, "set_setpoints", { heat = 22, cool = 22.1 }),
        { { "SET_SETPOINT_HEAT", { CELSIUS = 22 } }, { "SET_SETPOINT_COOL", { CELSIUS = 22.1 } } })
    local _, failure = run(celsius, "set_setpoints", { heat = 22, cool = 22 })
    T.eq(failure.message, "cool_setpoint must be above heat_setpoint")
end

function tests.a_failed_send_says_what_was_already_applied()
    local s = setup({ scale = "FAHRENHEIT" })
    local count = 0
    function C4:SendToDevice(_deviceId, command)
        count = count + 1
        if command == "SET_SETPOINT_HEAT" then
            error("Director said no")
        end
    end
    local ok, failure = s.Proxy.execute(s.device, "set_setpoints", { heat = 23.5 })
    T.eq(ok, false)
    T.eq(count, 2, "cool was sent first")
    T.eq(failure.code, "COMMAND_FAILED")
    T.eq(failure.field, "heat_setpoint")
    T.same(failure.applied, { "cool_setpoint" })
end

function tests.prepare_checks_without_sending()
    local s = setup({ scale = "FAHRENHEIT" })
    local before = #s.mock.commands
    T.eq(s.Proxy.prepare(s.device, "set_setpoints", { heat = 21 }), true)
    T.eq(s.Proxy.prepare(s.device, "set_temperature", { value = 24, mode = "cool" }), true)
    local ok, failure = s.Proxy.prepare(s.device, "set_setpoints", { heat = 22, cool = 23 })
    T.eq(ok, false)
    T.eq(failure.field, "cool_setpoint")
    ok, failure = s.Proxy.prepare(s.device, "set_temperature", { value = 22 })
    T.eq(ok, false)
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")
    T.eq(s.Proxy.prepare(s.device, "set_hvac_mode", { value = "heat" }), true)
    T.eq((s.Proxy.prepare(s.device, "set_hvac_mode", { value = "dry" })), false)
    T.eq((s.Proxy.prepare(s.device, "set_fan_mode", { value = "low" })), false)
    T.eq(#s.mock.commands, before, "prepare never sends")
end

-- Manager.prepare, as the handlers call it: adapters without prepare (Thermostat V2) pass.
function tests.the_manager_prepares_through_the_adapter()
    local mock = Mock.startDriver(Mock.withDualThermostat(Mock.project(), { scale = "FAHRENHEIT" }))
    local Manager = require("src.adapters.manager")
    local before = #mock.commands
    local ok, failure = Manager.prepare(31, "set_setpoints", { heat = 22, cool = 23 })
    T.eq(ok, false)
    T.eq(failure.code, "INVALID_TEMPERATURE")
    T.eq(failure.field, "cool_setpoint")
    T.eq(Manager.prepare(31, "set_setpoints", { heat = 21 }), true)
    T.eq(Manager.prepare(30, "set_temperature", { value = 22 }), true, "Thermostat V2 has no prepare")
    T.eq(Manager.prepare(999, "set_temperature", { value = 22 }), true, "unknown devices fail in execute")
    T.eq(#mock.commands, before)
    T.contains(mock.properties["Inventory"], "2 thermostats")
end

function tests.the_debug_log_lists_the_thermostat_variables()
    local mock = Mock.startDriver(Mock.withDualThermostat(Mock.project(), { scale = "FAHRENHEIT" }), nil, nil, function()
        Properties["Log Level"] = "Debug"
    end)
    local log = table.concat(mock.debugLog, "\n")
    T.contains(log, "thermostat proxy variables")
    T.contains(log, "1146=DEADBAND_F:3")
    T.contains(log, "1100=SCALE:FAHRENHEIT")
end

-- The dev server's project: every 1.1.0 family starts next to the default devices.
function tests.the_demo_project_starts_every_family()
    local mock = Mock.startDriver(Mock.demoProject())
    T.contains(mock.properties["Inventory"], "5 lights, 3 thermostats")
    local key = T.pair(mock)
    T.eq(T.http(mock, "GET", "/v1/thermostats/31", { key = key }).status, 200)
    local floor = T.http(mock, "GET", "/v1/thermostats/32", { key = key }).json
    T.eq(floor.target_temperature, 21.5)
    T.eq(floor.target_temperature_min, 5)
    T.eq(T.http(mock, "GET", "/v1/lights/25", { key = key }).json.brightness, 65)
end

return tests
