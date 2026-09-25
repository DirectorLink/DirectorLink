local Diagnostics = require("src.core.diagnostics")

local Climate = {}

local VARIABLE_SCALE = 1100
local VARIABLE_HVAC_MODE = 1104
local VARIABLE_FAN_MODE = 1105
local VARIABLE_HVAC_STATE = 1107
local VARIABLE_IS_CONNECTED = 1112
local VARIABLE_HVAC_MODES_LIST = 1120
local VARIABLE_TEMPERATURE_C = 1131
local VARIABLE_SINGLE_SETPOINT_F = 1149

local tracked = {}

local function lower(value)
    return string.lower(tostring(value or ""))
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

local function registerListener(deviceId, variableId)
    return pcall(function()
        C4:RegisterVariableListener(deviceId, variableId)
    end)
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

local function boolValue(value)
    local v = lower(value)
    return v == "1" or v == "true" or v == "on" or v == "yes"
end

local function fahrenheitToCelsius(value)
    local f = tonumber(value)
    if not f then
        return nil
    end
    local c = (f - 32) * 5 / 9
    return math.floor(c + 0.5)
end

local function normalizeMode(value)
    local v = lower(value)
    if v == "off" then return "off" end
    if v == "heat" then return "heat" end
    if v == "cool" then return "cool" end
    if v == "auto" then return "auto" end
    return v ~= "" and v or nil
end

local function titleMode(value)
    local v = lower(value)
    if v == "off" then return "Off" end
    if v == "heat" then return "Heat" end
    if v == "cool" then return "Cool" end
    if v == "auto" then return "Auto" end
    return nil
end

local function titleFan(value)
    local v = lower(value)
    if v == "low" then return "Low" end
    if v == "medium" then return "Medium" end
    if v == "high" then return "High" end
    if v == "auto" then return "Auto" end
    if v == "top" then return "Top" end
    return nil
end

function Climate.matches(device)
    local driver = lower(device and device.proxy and device.proxy.driver)
    return driver == "thermostatv2.c4i" or driver == "thermostatv2.c4z"
end

function Climate.reset()
    tracked = {}
end

function Climate.initialize(device)
    local tempC = tonumber(safeGetVariable(device.id, VARIABLE_TEMPERATURE_C))
    local hvacMode = safeGetVariable(device.id, VARIABLE_HVAC_MODE)
    local setpointF = safeGetVariable(device.id, VARIABLE_SINGLE_SETPOINT_F)

    if tempC == nil or hvacMode == nil or setpointF == nil then
        return false, "Required Thermostat V2 state variables are unavailable"
    end

    local fanMode = safeGetVariable(device.id, VARIABLE_FAN_MODE)
    local hvacState = safeGetVariable(device.id, VARIABLE_HVAC_STATE)
    local connectedValue = safeGetVariable(device.id, VARIABLE_IS_CONNECTED)
    local hvacModesValue = safeGetVariable(device.id, VARIABLE_HVAC_MODES_LIST)
    local scale = safeGetVariable(device.id, VARIABLE_SCALE)

    local required = {
        VARIABLE_TEMPERATURE_C,
        VARIABLE_HVAC_MODE,
        VARIABLE_SINGLE_SETPOINT_F,
    }
    for _, variableId in ipairs(required) do
        local ok = registerListener(device.id, variableId)
        if not ok then
            return false, "Unable to register Thermostat V2 state listener " .. tostring(variableId)
        end
    end

    local optional = {
        VARIABLE_FAN_MODE,
        VARIABLE_HVAC_STATE,
        VARIABLE_IS_CONNECTED,
        VARIABLE_HVAC_MODES_LIST,
        VARIABLE_SCALE,
    }
    for _, variableId in ipairs(optional) do
        if safeGetVariable(device.id, variableId) ~= nil then
            registerListener(device.id, variableId)
        end
    end

    local hvacModes = parseList(hvacModesValue)
    if #hvacModes == 0 then
        hvacModes = { "Off", "Heat", "Cool" }
    end

    local hasCool = false
    for _, mode in ipairs(hvacModes) do
        if lower(mode) == "cool" then
            hasCool = true
            break
        end
    end

    local fanModes = {}
    local hasFanControl = fanMode ~= nil and hasCool
    if hasFanControl then
        -- The AC zones in the real test system expose Low/Medium/High.
        -- Heat-only floor zones intentionally do not expose fan controls here.
        fanModes = { "Low", "Medium", "High" }
    end

    tracked[device.id] = {
        hasFanMode = hasFanControl,
        hvacModes = hvacModes,
        fanModes = fanModes,
    }

    device.supported = true
    device.capabilities = {
        hvac_modes = hvacModes,
        fan_modes = fanModes,
        single_setpoint = true,
        temperature_unit = "C",
        target_temperature_min_c = 16,
        target_temperature_max_c = hasCool and 25 or 32,
    }
    device.actions = {
        "set_hvac_mode",
        "set_temperature",
    }
    if hasFanControl then
        table.insert(device.actions, "set_fan_mode")
    end

    device.state = {
        connected = connectedValue == nil and true or boolValue(connectedValue),
        scale = tostring(scale or "CELSIUS"),
        current_temperature_c = tempC,
        target_temperature_c = fahrenheitToCelsius(setpointF),
        hvac_mode = normalizeMode(hvacMode),
        hvac_state = normalizeMode(hvacState),
        fan_mode = fanMode and lower(fanMode) or nil,
    }

    Diagnostics.info("climate", "initialized thermostat", {
        device_id = device.id,
        hvac_modes = hvacModes,
        fan_mode = fanMode,
        current_temperature_c = tempC,
        target_temperature_c = device.state.target_temperature_c,
    })

    return true
end

function Climate.onVariableChanged(device, variableId, value)
    if not tracked[device.id] or not device.state then
        return false
    end

    variableId = tonumber(variableId)

    if variableId == VARIABLE_TEMPERATURE_C then
        local n = tonumber(value)
        if n ~= nil then device.state.current_temperature_c = n end
    elseif variableId == VARIABLE_SINGLE_SETPOINT_F then
        device.state.target_temperature_c = fahrenheitToCelsius(value)
    elseif variableId == VARIABLE_HVAC_MODE then
        device.state.hvac_mode = normalizeMode(value)
    elseif variableId == VARIABLE_FAN_MODE then
        device.state.fan_mode = lower(value)
    elseif variableId == VARIABLE_HVAC_STATE then
        device.state.hvac_state = normalizeMode(value)
    elseif variableId == VARIABLE_IS_CONNECTED then
        device.state.connected = boolValue(value)
    elseif variableId == VARIABLE_HVAC_MODES_LIST then
        local modes = parseList(value)
        if #modes > 0 then
            tracked[device.id].hvacModes = modes
            device.capabilities.hvac_modes = modes
        end
    elseif variableId == VARIABLE_SCALE then
        device.state.scale = tostring(value or "")
    else
        return false
    end

    Diagnostics.info("climate_state", "thermostat variable changed", {
        device_id = device.id,
        variable_id = variableId,
        value = value,
    })
    return true
end

local function send(deviceId, command, params)
    Diagnostics.info("climate_command", "sending thermostat command", {
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

function Climate.execute(device, action, params)
    local info = tracked[device.id]
    if not info then
        return false, {
            code = "DEVICE_NOT_SUPPORTED",
            message = "Thermostat adapter is not initialized",
        }
    end

    if action == "set_hvac_mode" then
        local requested = titleMode(params and (params.value or params.mode))
        if not requested then
            return false, {
                code = "INVALID_HVAC_MODE",
                message = "HVAC mode must be off, heat, cool, or auto",
            }
        end

        local allowed = false
        for _, mode in ipairs(info.hvacModes or {}) do
            if lower(mode) == lower(requested) then allowed = true break end
        end
        if not allowed then
            return false, {
                code = "HVAC_MODE_NOT_SUPPORTED",
                message = "This thermostat does not support " .. requested,
            }
        end

        local ok, err = send(device.id, "SET_MODE_HVAC", { MODE = requested })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = requested }
    end

    if action == "set_fan_mode" then
        if not info.hasFanMode then
            return false, {
                code = "ACTION_NOT_SUPPORTED",
                message = "Fan mode is unavailable on this thermostat",
            }
        end

        local requested = titleFan(params and (params.value or params.mode))
        if not requested then
            return false, {
                code = "INVALID_FAN_MODE",
                message = "Fan mode is invalid",
            }
        end

        local ok, err = send(device.id, "SET_MODE_FAN", { MODE = requested })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = requested }
    end

    if action == "set_temperature" then
        local target = tonumber(params and (params.value or params.celsius))
        local maxTarget = device.capabilities and device.capabilities.target_temperature_max_c or 32
        if not target or target < 16 or target > maxTarget then
            return false, {
                code = "INVALID_TEMPERATURE",
                message = "Temperature is outside this thermostat's C4Bridge range",
            }
        end

        target = math.floor(target * 10 + 0.5) / 10
        local ok, err = send(device.id, "SET_SETPOINT_SINGLE", { CELSIUS = target })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_celsius = target }
    end

    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Unsupported thermostat action: " .. tostring(action),
    }
end

return Climate
