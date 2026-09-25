local Diagnostics = require("src.core.diagnostics")

local ClimateV2 = {}

local VARIABLE_SCALE = 1100
local VARIABLE_HVAC_MODE = 1104
local VARIABLE_FAN_MODE = 1105
local VARIABLE_HVAC_STATE = 1107
local VARIABLE_IS_CONNECTED = 1112
local VARIABLE_HVAC_MODES_LIST = 1120
local VARIABLE_TEMPERATURE_F = 1130
local VARIABLE_TEMPERATURE_C = 1131
local VARIABLE_HEAT_SETPOINT_F = 1132
local VARIABLE_HEAT_SETPOINT_C = 1133
local VARIABLE_COOL_SETPOINT_F = 1134
local VARIABLE_COOL_SETPOINT_C = 1135

local tracked = {}

local WATCHED_VARIABLES = {
    VARIABLE_SCALE,
    VARIABLE_HVAC_MODE,
    VARIABLE_FAN_MODE,
    VARIABLE_HVAC_STATE,
    VARIABLE_IS_CONNECTED,
    VARIABLE_HVAC_MODES_LIST,
    VARIABLE_TEMPERATURE_F,
    VARIABLE_TEMPERATURE_C,
    VARIABLE_HEAT_SETPOINT_F,
    VARIABLE_HEAT_SETPOINT_C,
    VARIABLE_COOL_SETPOINT_F,
    VARIABLE_COOL_SETPOINT_C,
}

local function safeGetVariable(deviceId, variableId)
    local ok, value = pcall(function()
        return C4:GetVariable(deviceId, variableId)
    end)

    if ok then
        return value
    end

    return nil
end

local function numberValue(value)
    local number = tonumber(value)
    if number == nil then
        return nil
    end
    return number
end

local function boolValue(value)
    local normalized = string.lower(tostring(value or ""))
    if normalized == "1" or normalized == "true" or normalized == "on" or normalized == "yes" then
        return true
    end
    if normalized == "0" or normalized == "false" or normalized == "off" or normalized == "no" then
        return false
    end
    return nil
end

local function cleanString(value)
    if value == nil then
        return nil
    end
    local result = tostring(value)
    if result == "" then
        return nil
    end
    return result
end

local function normalizeScale(value, variables)
    local normalized = string.upper(tostring(value or ""))
    if normalized == "CELSIUS" or normalized == "C" then
        return "C"
    end
    if normalized == "FAHRENHEIT" or normalized == "F" then
        return "F"
    end

    if variables[VARIABLE_TEMPERATURE_C] ~= nil then
        return "C"
    end
    if variables[VARIABLE_TEMPERATURE_F] ~= nil then
        return "F"
    end
    return nil
end

local function parseModes(value)
    local result = {}
    local raw = cleanString(value)
    if not raw then
        return result
    end

    for item in raw:gmatch("[^,]+") do
        local mode = item:gsub("^%s+", ""):gsub("%s+$", "")
        if mode ~= "" then
            table.insert(result, mode)
        end
    end

    return result
end

local function updateDerivedState(device)
    local info = tracked[device.id]
    if not info then
        return
    end

    local values = info.values
    local scale = normalizeScale(values[VARIABLE_SCALE], values)

    device.state.scale = scale
    device.state.temperature_c = numberValue(values[VARIABLE_TEMPERATURE_C])
    device.state.temperature_f = numberValue(values[VARIABLE_TEMPERATURE_F])
    device.state.heat_setpoint_c = numberValue(values[VARIABLE_HEAT_SETPOINT_C])
    device.state.heat_setpoint_f = numberValue(values[VARIABLE_HEAT_SETPOINT_F])
    device.state.cool_setpoint_c = numberValue(values[VARIABLE_COOL_SETPOINT_C])
    device.state.cool_setpoint_f = numberValue(values[VARIABLE_COOL_SETPOINT_F])

    if scale == "C" then
        device.state.temperature = device.state.temperature_c
        device.state.heat_setpoint = device.state.heat_setpoint_c
        device.state.cool_setpoint = device.state.cool_setpoint_c
    elseif scale == "F" then
        device.state.temperature = device.state.temperature_f
        device.state.heat_setpoint = device.state.heat_setpoint_f
        device.state.cool_setpoint = device.state.cool_setpoint_f
    else
        device.state.temperature = device.state.temperature_c or device.state.temperature_f
        device.state.heat_setpoint = device.state.heat_setpoint_c or device.state.heat_setpoint_f
        device.state.cool_setpoint = device.state.cool_setpoint_c or device.state.cool_setpoint_f
    end

    device.state.hvac_mode = cleanString(values[VARIABLE_HVAC_MODE])
    device.state.hvac_state = cleanString(values[VARIABLE_HVAC_STATE])
    device.state.fan_mode = cleanString(values[VARIABLE_FAN_MODE])
    device.state.connected = boolValue(values[VARIABLE_IS_CONNECTED])
    device.state.allowed_hvac_modes = parseModes(values[VARIABLE_HVAC_MODES_LIST])
end

function ClimateV2.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "thermostatv2.c4i" or driver == "thermostatv2.c4z"
end

function ClimateV2.initialize(device)
    local values = {}
    local available = {}

    for _, variableId in ipairs(WATCHED_VARIABLES) do
        local value = safeGetVariable(device.id, variableId)
        if value ~= nil then
            values[variableId] = value
            available[variableId] = true
        end
    end

    local hasTemperature =
        available[VARIABLE_TEMPERATURE_C] == true or
        available[VARIABLE_TEMPERATURE_F] == true
    local hasMode = available[VARIABLE_HVAC_MODE] == true

    if not hasTemperature and not hasMode then
        device.supported = false
        device.adapter_error = "Thermostat V2 state variables are unavailable"
        return false, device.adapter_error
    end

    tracked[device.id] = {
        values = values,
        available = available,
    }

    device.supported = true
    device.adapter_error = nil
    device.capabilities = {
        temperature = hasTemperature,
        hvac_mode = hasMode,
        fan_mode = available[VARIABLE_FAN_MODE] == true,
        heat_setpoint =
            available[VARIABLE_HEAT_SETPOINT_C] == true or
            available[VARIABLE_HEAT_SETPOINT_F] == true,
        cool_setpoint =
            available[VARIABLE_COOL_SETPOINT_C] == true or
            available[VARIABLE_COOL_SETPOINT_F] == true,
        read_only = true,
    }
    device.state = {}
    device.actions = {}

    updateDerivedState(device)

    local registered = {}
    for _, variableId in ipairs(WATCHED_VARIABLES) do
        if available[variableId] then
            local ok, err = pcall(function()
                C4:RegisterVariableListener(device.id, variableId)
            end)

            if not ok then
                for _, registeredId in ipairs(registered) do
                    pcall(function()
                        C4:UnregisterVariableListener(device.id, registeredId)
                    end)
                end

                tracked[device.id] = nil
                device.supported = false
                device.adapter_error =
                    "Unable to watch thermostat variable " ..
                    tostring(variableId) .. ": " .. tostring(err)
                return false, device.adapter_error
            end

            table.insert(registered, variableId)
        end
    end

    Diagnostics.info("climate", "thermostat initialized", {
        device_id = device.id,
        proxy_driver = device.proxy and device.proxy.driver or nil,
        scale = device.state.scale,
        temperature = device.state.temperature,
        hvac_mode = device.state.hvac_mode,
        watched_variables = registered,
    })

    return true
end

function ClimateV2.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    if not info or not device.state then
        return false
    end

    variableId = tonumber(variableId)
    if not info.available[variableId] then
        return false
    end

    info.values[variableId] = value
    updateDerivedState(device)

    Diagnostics.info("climate_state", "thermostat variable changed", {
        device_id = device.id,
        variable_id = variableId,
        value = value,
        scale = device.state.scale,
        temperature = device.state.temperature,
        hvac_mode = device.state.hvac_mode,
        hvac_state = device.state.hvac_state,
        fan_mode = device.state.fan_mode,
        heat_setpoint = device.state.heat_setpoint,
        cool_setpoint = device.state.cool_setpoint,
    })

    return true
end

function ClimateV2.execute(device, action)
    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message =
            "Climate controls are read-only in this alpha; unsupported action: " ..
            tostring(action),
    }
end

function ClimateV2.reset()
    tracked = {}
end

return ClimateV2
