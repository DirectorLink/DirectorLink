local LightV2 = {}

local VARIABLE_STATE = 1000
local VARIABLE_BRIGHTNESS = 1001

local tracked = {}

local function clampPercent(value)
    local number = tonumber(value)
    if not number then
        return nil
    end

    number = math.floor(number + 0.5)
    if number < 0 then
        return 0
    end
    if number > 100 then
        return 100
    end
    return number
end

local function boolValue(value)
    local normalized = string.lower(tostring(value or ""))
    return normalized == "1" or normalized == "true" or normalized == "on"
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

function LightV2.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "light_v2.c4i" or driver == "light_v2.c4z"
end

function LightV2.initialize(device)
    local stateValue = safeGetVariable(device.id, VARIABLE_STATE)
    if stateValue == nil then
        device.supported = false
        device.adapter_error = "Light State variable (1000) is unavailable"
        return false, device.adapter_error
    end

    local brightnessValue = safeGetVariable(device.id, VARIABLE_BRIGHTNESS)
    local dimmable = brightnessValue ~= nil
    local brightness = dimmable and clampPercent(brightnessValue) or nil
    local power = boolValue(stateValue)

    tracked[device.id] = {
        dimmable = dimmable,
    }

    device.supported = true
    device.adapter_error = nil
    device.capabilities = {
        on_off = true,
        brightness = dimmable,
    }
    device.state = {
        power = power,
        brightness = brightness,
    }
    device.actions = { "on", "off" }
    if dimmable then
        table.insert(device.actions, "set_brightness")
    end

    -- Register only variables that actually exist. RegisterVariableListener invokes
    -- OnWatchedVariableChanged immediately after successful registration.
    local stateListenerOk, stateListenerError = pcall(function()
        C4:RegisterVariableListener(device.id, VARIABLE_STATE)
    end)

    if not stateListenerOk then
        tracked[device.id] = nil
        device.supported = false
        device.adapter_error = "Unable to watch Light State: " .. tostring(stateListenerError)
        return false, device.adapter_error
    end

    if dimmable then
        local brightnessListenerOk, brightnessListenerError = pcall(function()
            C4:RegisterVariableListener(device.id, VARIABLE_BRIGHTNESS)
        end)

        if not brightnessListenerOk then
            pcall(function()
                C4:UnregisterVariableListener(device.id, VARIABLE_STATE)
            end)
            tracked[device.id] = nil
            device.supported = false
            device.adapter_error = "Unable to watch brightness: " .. tostring(brightnessListenerError)
            return false, device.adapter_error
        end
    end

    return true
end

function LightV2.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    if not info or not device.state then
        return false
    end

    variableId = tonumber(variableId)

    if variableId == VARIABLE_STATE then
        device.state.power = boolValue(value)
        return true
    end

    if variableId == VARIABLE_BRIGHTNESS and info.dimmable then
        local brightness = clampPercent(value)
        if brightness ~= nil then
            device.state.brightness = brightness
            device.state.power = brightness > 0
            return true
        end
    end

    return false
end

local function sendBrightnessTarget(deviceId, target)
    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, "SET_BRIGHTNESS_TARGET", {
            LIGHT_BRIGHTNESS_TARGET = target,
            RATE = 0,
        })
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function sendBrightnessPreset(deviceId, presetId)
    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, "SET_BRIGHTNESS_TARGET", {
            LIGHT_BRIGHTNESS_TARGET_PRESET_ID = presetId,
        })
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

function LightV2.execute(device, action, params)
    local info = tracked[device.id]
    if not info or not device.supported then
        return false, {
            code = "DEVICE_NOT_SUPPORTED",
            message = "This light is not initialized as a supported Light V2 device",
        }
    end

    local sent
    local sendError
    local result = {
        device_id = device.id,
        action = action,
    }

    if action == "on" then
        -- Light V2 static preset ID 1 is the configured "On" preset.
        sent, sendError = sendBrightnessPreset(device.id, 1)
        result.requested_preset_id = 1
    elseif action == "off" then
        -- Light V2 static preset ID 2 is the configured "Off" preset.
        sent, sendError = sendBrightnessPreset(device.id, 2)
        result.requested_preset_id = 2
    elseif action == "set_brightness" then
        if not info.dimmable then
            return false, {
                code = "ACTION_NOT_SUPPORTED",
                message = "This light does not expose dimmer brightness",
            }
        end

        local target = clampPercent(params and (params.value or params.brightness))
        if target == nil then
            return false, {
                code = "INVALID_BRIGHTNESS",
                message = "Brightness must be a number from 0 to 100",
            }
        end

        sent, sendError = sendBrightnessTarget(device.id, target)
        result.requested_brightness = target
        result.rate_ms = 0
    else
        return false, {
            code = "ACTION_NOT_SUPPORTED",
            message = "Unsupported light action: " .. tostring(action),
        }
    end

    if not sent then
        return false, {
            code = "CONTROL4_COMMAND_FAILED",
            message = "Director rejected the light command: " .. tostring(sendError),
        }
    end

    return true, result
end

function LightV2.reset()
    tracked = {}
end

return LightV2
