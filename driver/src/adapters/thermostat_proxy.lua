local Log = require("src.core.log")
local Setpoints = require("src.adapters.thermostat_setpoints")
local Units = require("src.adapters.thermostat_units")

-- The Control4 thermostat proxy (control4_thermostat_proxy.c4i), used by Control4-branded
-- thermostats. It has Thermostat V2's variable IDs (1100-1150) but separate heat and cool
-- setpoints, reports every value in both scales and takes setpoints in the project's scale. The
-- IDs, values and commands were read on a live Director with five of these thermostats in a
-- °F project (bkwagner, #16); the °C command form has not run on hardware.
--
-- The API's main fields stay in °C (a °F thermostat's are also given in °F since 1.10.2, ADR-076).
-- Setpoints are compared in native units (thermostat_units.lua) and sent in the project's scale:
-- whole °F in a °F project, °C to 0.1 in a °C project; the plan is thermostat_setpoints.lua's.
--
-- The record this adapter keeps is what the API layer reads (views, thermostat and scene
-- handlers):
--   capabilities: setpoints = "dual", scale = "F"|"C", hvac_modes, fan_modes (proxy casing),
--     has_heat, has_cool, deadband_native, deadband_c, target_temperature_min_c/max_c (5/35,
--     one range for both setpoints)
--   state: connected, scale (raw 1100), current_temperature_c, heat_native, cool_native,
--     heat_setpoint_c, cool_setpoint_c, target_temperature_c (the setpoint of the mode: heat in
--     heat, cool in cool, nil otherwise), hvac_mode, hvac_state (lowercase), fan_mode;
--     current_temperature_f and target_temperature_f (1.10.2), the same in °F on a °F thermostat.
--     A setpoint or room temperature the thermostat does not report is nil (1.10.2).
--   actions: set_hvac_mode, set_temperature, set_setpoints, and set_fan_mode when 1121 lists any
local ThermostatProxy = {}

local VARIABLE_SCALE = 1100
local VARIABLE_HVAC_MODE = 1104
local VARIABLE_FAN_MODE = 1105
local VARIABLE_HVAC_STATE = 1107
local VARIABLE_IS_CONNECTED = 1112
local VARIABLE_HVAC_MODES_LIST = 1120
local VARIABLE_FAN_MODES_LIST = 1121
local VARIABLE_TEMPERATURE_F = 1130
local VARIABLE_TEMPERATURE_C = 1131
local VARIABLE_HEAT_SETPOINT_F = 1132
local VARIABLE_HEAT_SETPOINT_C = 1133
local VARIABLE_COOL_SETPOINT_F = 1134
local VARIABLE_COOL_SETPOINT_C = 1135
local VARIABLE_DEADBAND_F = 1146
local VARIABLE_DEADBAND_C = 1147

-- Every variable the adapter reads, all watched: the deadband too, so a changed one is seen.
local WATCHED = {
    VARIABLE_SCALE,
    VARIABLE_HVAC_MODE,
    VARIABLE_FAN_MODE,
    VARIABLE_HVAC_STATE,
    VARIABLE_IS_CONNECTED,
    VARIABLE_HVAC_MODES_LIST,
    VARIABLE_FAN_MODES_LIST,
    VARIABLE_TEMPERATURE_F,
    VARIABLE_TEMPERATURE_C,
    VARIABLE_HEAT_SETPOINT_F,
    VARIABLE_HEAT_SETPOINT_C,
    VARIABLE_COOL_SETPOINT_F,
    VARIABLE_COOL_SETPOINT_C,
    VARIABLE_DEADBAND_F,
    VARIABLE_DEADBAND_C,
}

local IS_WATCHED = {}
for _, variableId in ipairs(WATCHED) do
    IS_WATCHED[variableId] = true
end

local tracked = {}

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function lowerOrNil(value)
    local v = lower(value)
    return v ~= "" and v or nil
end

local function safeGetVariable(deviceId, variableId)
    local ok, value = pcall(function()
        return C4:GetVariable(deviceId, variableId)
    end)
    if ok then
        return value
    end
    return nil
end

local function boolValue(value)
    local v = lower(value)
    return v == "1" or v == "true" or v == "on" or v == "yes"
end

local function parseList(value)
    local result = {}
    for item in tostring(value or ""):gmatch("[^,]+") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then
            table.insert(result, item)
        end
    end
    return result
end

-- The proxy's own spelling of a mode or fan speed, matched case-insensitively.
local function findInList(list, requested)
    local wanted = lower(requested)
    for _, entry in ipairs(list or {}) do
        if lower(entry) == wanted then
            return entry
        end
    end
    return nil
end

local function fanValue(value)
    local v = lower(value)
    return (v ~= "" and v ~= "undefined") and v or nil
end

-- "<id>=<name>:<value>, ..." for 1100-1150, logged at Debug when a thermostat starts: one field
-- log then answers what these proxies really report (limits, deadband, mode spellings).
local function logVariables(deviceId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(deviceId)
    end)
    local entries = {}
    if ok and type(variables) == "table" then
        for id, variable in pairs(variables) do
            local number = tonumber(id)
            if number and number >= 1100 and number <= 1150 and type(variable) == "table" then
                entries[#entries + 1] = tostring(id) .. "=" .. tostring(variable.name or "") .. ":" .. tostring(variable.value)
            end
        end
    end
    table.sort(entries)
    Log.debug("climate", "thermostat proxy variables", { device_id = deviceId, variables = table.concat(entries, ", ") })
end

local function hasPair(raw, fahrenheitVariable, celsiusVariable)
    return raw[fahrenheitVariable] ~= nil or raw[celsiusVariable] ~= nil
end

-- Rebuilds capabilities, state and actions from the raw values and the lists.
local function refresh(device)
    local info = tracked[device.id]
    local raw = info.raw
    -- An unknown scale keeps the last known one (onVariableChanged logs it).
    local scale = Units.scale(raw[VARIABLE_SCALE]) or info.scale
    info.scale = scale

    -- A setpoint left at 0 (or one no thermostat works to) is not reported (1.10.2): nil.
    local function read(fahrenheitVariable, celsiusVariable)
        return Units.setpointNative(raw[fahrenheitVariable], raw[celsiusVariable], scale)
    end

    local modes = info.hvacModes
    local anyHeat = findInList(modes, "heat") ~= nil or findInList(modes, "auto") ~= nil
    local anyCool = findInList(modes, "cool") ~= nil or findInList(modes, "auto") ~= nil
    local deadband = Units.deltaNative(raw[VARIABLE_DEADBAND_F], raw[VARIABLE_DEADBAND_C], scale)

    local capabilities = device.capabilities
    capabilities.setpoints = "dual"
    capabilities.scale = scale
    capabilities.hvac_modes = info.hvacModes
    capabilities.fan_modes = info.fanModes
    capabilities.has_heat = hasPair(raw, VARIABLE_HEAT_SETPOINT_F, VARIABLE_HEAT_SETPOINT_C) and anyHeat
    capabilities.has_cool = hasPair(raw, VARIABLE_COOL_SETPOINT_F, VARIABLE_COOL_SETPOINT_C) and anyCool
    capabilities.deadband_native = deadband
    capabilities.deadband_c = Units.deltaCelsius(deadband, scale)
    capabilities.target_temperature_min_c = Setpoints.MIN_C
    capabilities.target_temperature_max_c = Setpoints.MAX_C

    local state = device.state
    local heatNative = read(VARIABLE_HEAT_SETPOINT_F, VARIABLE_HEAT_SETPOINT_C)
    local coolNative = read(VARIABLE_COOL_SETPOINT_F, VARIABLE_COOL_SETPOINT_C)
    Setpoints.reported(info.lastSent, heatNative, coolNative)
    state.connected = raw[VARIABLE_IS_CONNECTED] == nil and true or boolValue(raw[VARIABLE_IS_CONNECTED])
    state.scale = raw[VARIABLE_SCALE]
    -- Not reported (0 in both, #75): nil, never 0 °C.
    state.current_temperature_c, state.current_temperature_f = Units.roomTemperature(raw[VARIABLE_TEMPERATURE_F], raw[VARIABLE_TEMPERATURE_C], scale)
    state.heat_native = heatNative
    state.cool_native = coolNative
    state.heat_setpoint_c = Units.celsius(heatNative, scale)
    state.cool_setpoint_c = Units.celsius(coolNative, scale)
    state.hvac_mode = lowerOrNil(raw[VARIABLE_HVAC_MODE])
    state.hvac_state = lowerOrNil(raw[VARIABLE_HVAC_STATE])
    state.fan_mode = fanValue(raw[VARIABLE_FAN_MODE])
    -- One target for clients that know only target_temperature: the setpoint the mode uses.
    if state.hvac_mode == "heat" then
        state.target_temperature_c = state.heat_setpoint_c
    elseif state.hvac_mode == "cool" then
        state.target_temperature_c = state.cool_setpoint_c
    else
        state.target_temperature_c = nil
    end
    state.target_temperature_f = nil
    if scale == "F" then
        state.target_temperature_f = (state.hvac_mode == "heat" and heatNative) or (state.hvac_mode == "cool" and coolNative) or nil
    end

    device.actions = { "set_hvac_mode", "set_temperature", "set_setpoints" }
    if #info.fanModes > 0 then
        table.insert(device.actions, "set_fan_mode")
    end
end

function ThermostatProxy.matches(device)
    local driver = lower(device and device.proxy and device.proxy.driver)
    return driver == "control4_thermostat_proxy.c4i"
end

function ThermostatProxy.reset()
    tracked = {}
end

function ThermostatProxy.initialize(device)
    logVariables(device.id)

    local raw = {}
    for _, variableId in ipairs(WATCHED) do
        raw[variableId] = safeGetVariable(device.id, variableId)
    end

    -- Never guess the scale: a °C home read as °F would get FAHRENHEIT = 22.
    local scale = Units.scale(raw[VARIABLE_SCALE])
    if not scale then
        return false, "Thermostat scale is unknown"
    end
    if raw[VARIABLE_HVAC_MODE] == nil then
        return false, "Thermostat HVAC mode (1104) is unavailable"
    end
    if raw[VARIABLE_TEMPERATURE_F] == nil and raw[VARIABLE_TEMPERATURE_C] == nil then
        return false, "Thermostat temperature (1130/1131) is unavailable"
    end
    if not hasPair(raw, VARIABLE_HEAT_SETPOINT_F, VARIABLE_HEAT_SETPOINT_C)
        and not hasPair(raw, VARIABLE_COOL_SETPOINT_F, VARIABLE_COOL_SETPOINT_C) then
        return false, "Thermostat heat and cool setpoints (1132-1135) are unavailable"
    end

    for _, variableId in ipairs(WATCHED) do
        if raw[variableId] ~= nil then
            local ok = pcall(function()
                C4:RegisterVariableListener(device.id, variableId)
            end)
            if not ok then
                return false, "Unable to register thermostat state listener " .. tostring(variableId)
            end
        end
    end

    local hvacModes = parseList(raw[VARIABLE_HVAC_MODES_LIST])
    if #hvacModes == 0 then
        hvacModes = { "Off", "Heat", "Cool", "Auto" }
    end

    -- Tracked only now: the values Director reports right after each registration are the ones
    -- just read, so they are dropped.
    tracked[device.id] = {
        raw = raw,
        scale = scale,
        hvacModes = hvacModes,
        -- No fallback: a thermostat that lists no fan speeds gets no fan control.
        fanModes = parseList(raw[VARIABLE_FAN_MODES_LIST]),
        -- The setpoints sent and not yet reported (native value and when): { heat = , cool = }.
        lastSent = {},
    }

    device.supported = true
    device.adapter_error = nil
    device.capabilities = {}
    device.state = {}
    refresh(device)

    Log.info("climate", "initialized dual-setpoint thermostat", {
        device_id = device.id,
        scale = scale,
        hvac_modes = hvacModes,
        fan_modes = tracked[device.id].fanModes,
        heat_setpoint_c = device.state.heat_setpoint_c,
        cool_setpoint_c = device.state.cool_setpoint_c,
        deadband_c = device.capabilities.deadband_c,
    })

    return true
end

function ThermostatProxy.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    if not info or not device.state then
        return false
    end

    variableId = tonumber(variableId)
    if not IS_WATCHED[variableId] then
        return false
    end

    info.raw[variableId] = value
    if variableId == VARIABLE_HVAC_MODES_LIST then
        local modes = parseList(value)
        if #modes > 0 then
            info.hvacModes = modes
        end
    elseif variableId == VARIABLE_FAN_MODES_LIST then
        info.fanModes = parseList(value)
    elseif variableId == VARIABLE_SCALE then
        local scale = Units.scale(value)
        if not scale then
            Log.warn("climate", "thermostat scale is unknown; keeping the last one", {
                device_id = device.id,
                value = value,
                scale = info.scale,
            })
        elseif scale ~= info.scale then
            Log.info("climate", "thermostat scale changed", { device_id = device.id, scale = scale })
        end
    end
    refresh(device)

    Log.debug("climate_state", "thermostat variable changed", {
        device_id = device.id,
        variable_id = variableId,
        value = value,
    })
    return true
end

local function unsupported(message)
    return { code = "ACTION_NOT_SUPPORTED", message = message }
end

local function send(deviceId, command, params)
    Log.info("climate_command", "sending thermostat command", {
        device_id = deviceId,
        command = command,
        params = params,
    })

    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, command, params)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

-- Checks a command without sending anything (Manager.prepare): a request that also changes the mode
-- is refused before the mode is sent when its setpoints cannot be applied.
function ThermostatProxy.prepare(device, action, params)
    local info = device and tracked[device.id]
    if not info then
        return false, { code = "DEVICE_NOT_SUPPORTED", message = "Thermostat adapter is not initialized" }
    end
    params = params or {}

    if action == "set_hvac_mode" then
        if not findInList(info.hvacModes, params.value or params.mode) then
            return false, { code = "HVAC_MODE_NOT_SUPPORTED", message = "This thermostat does not support " .. tostring(params.value or params.mode) }
        end
    elseif action == "set_fan_mode" then
        if not findInList(info.fanModes, params.value or params.mode) then
            return false, unsupported("This thermostat does not support fan speed " .. tostring(params.value or params.mode))
        end
    elseif action == "set_temperature" or action == "set_setpoints" then
        local _, failure = Setpoints.plan(device, info.lastSent, action, params)
        if failure then
            return false, failure
        end
    end
    return true
end

function ThermostatProxy.execute(device, action, params)
    local info = tracked[device.id]
    if not info then
        return false, {
            code = "DEVICE_NOT_SUPPORTED",
            message = "Thermostat adapter is not initialized",
        }
    end
    params = params or {}

    if action == "set_hvac_mode" then
        local mode = findInList(info.hvacModes, params.value or params.mode)
        if not mode then
            return false, {
                code = "HVAC_MODE_NOT_SUPPORTED",
                message = "This thermostat does not support " .. tostring(params.value or params.mode),
            }
        end
        local ok, err = send(device.id, "SET_MODE_HVAC", { MODE = mode })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = mode }
    end

    if action == "set_fan_mode" then
        local mode = findInList(info.fanModes, params.value or params.mode)
        if not mode then
            return false, unsupported("This thermostat does not support fan speed " .. tostring(params.value or params.mode))
        end
        local ok, err = send(device.id, "SET_MODE_FAN", { MODE = mode })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = mode }
    end

    if action == "set_temperature" or action == "set_setpoints" then
        return Setpoints.execute(device, info.lastSent, action, params, send)
    end

    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Unsupported thermostat action: " .. tostring(action),
    }
end

return ThermostatProxy
