local Log = require("src.core.log")
local LightCapabilities = require("src.control4.light_capabilities")

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

local function hasProtocolDriver(device, driverName)
    local expected = string.lower(tostring(driverName or ""))
    for _, protocol in ipairs(device.protocols or {}) do
        if string.lower(tostring(protocol.driver or "")) == expected then
            return true
        end
    end
    return false
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

    -- A dimmer or a switch: what its driver declares, else whether it has a level variable (the
    -- Light V2 proxy gives switches one too, at 0 or 100: src/control4/light_capabilities.lua).
    local brightnessValue = safeGetVariable(device.id, VARIABLE_BRIGHTNESS)
    local hasLevel = brightnessValue ~= nil
    local dimmable, dimmableBy = LightCapabilities.dimmable(device, hasLevel)
    local watchLevel = dimmable and hasLevel
    local brightness = watchLevel and clampPercent(brightnessValue) or nil
    local power = boolValue(stateValue)

    -- The KNX dimmer's level was not seen to follow a change of brightness (alpha.6): it counts as
    -- reported once it reports a level between 0 and 100, which only a dimmer reporting its level
    -- does (it does report 0 and 100 when it turns off and on).
    local knxDimmer = dimmable and hasProtocolDriver(device, "knx_dimmer.c4i")

    tracked[device.id] = {
        dimmable = dimmable,
        knx_dimmer = knxDimmer,
    }

    device.supported = true
    device.adapter_error = nil
    device.capabilities = {
        on_off = true,
        brightness = dimmable,
        brightness_feedback = watchLevel and (not knxDimmer or (brightness ~= nil and brightness > 0 and brightness < 100)),
    }
    device.state = {
        power = power,
        brightness = brightness,
    }
    device.actions = { "on", "off" }
    if dimmable then
        table.insert(device.actions, "set_brightness")
    end
    Log.debug("light_state", "light", {
        device_id = device.id,
        dimmable = dimmable,
        by = dimmableBy,
        level_variable = hasLevel,
    })

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

    -- A switch's level (0 or 100) says nothing Light State does not.
    if watchLevel then
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
        Log.debug("light_state", "state variable changed", {
            device_id = device.id,
            variable_id = VARIABLE_STATE,
            value = value,
            power = device.state.power,
        })
        return true
    end

    if variableId == VARIABLE_BRIGHTNESS and info.dimmable then
        local brightness = clampPercent(value)
        if brightness ~= nil then
            device.state.brightness = brightness
            device.state.power = brightness > 0
            if info.knx_dimmer and device.capabilities and not device.capabilities.brightness_feedback
                and brightness > 0 and brightness < 100 then
                device.capabilities.brightness_feedback = true
                Log.info("light_state", "the KNX dimmer reports its level", { device_id = device.id, brightness = brightness })
            end
            Log.debug("light_state", "brightness variable changed", {
                device_id = device.id,
                variable_id = VARIABLE_BRIGHTNESS,
                value = value,
                brightness = brightness,
            })
            return true
        end
    end

    return false
end

-- A level, as Snap One documents SET_BRIGHTNESS_TARGET for Light V2 (1.10.2, ADR-077): the level
-- in LIGHT_BRIGHTNESS_TARGET (0-100) and RATE, the ramp in milliseconds (0: at once). The KNX
-- dimmer's driver reads exactly these (its own presets aside); PERCENT, sent up to 1.10.1, is read
-- by neither, and RAMP_TO_LEVEL did not move it either (#11).
local function sendBrightnessTarget(deviceId, target)
    local params = {
        LIGHT_BRIGHTNESS_TARGET = target,
        RATE = 0,
    }
    Log.info("light_command", "sending brightness target", {
        device_id = deviceId,
        command = "SET_BRIGHTNESS_TARGET",
        params = params,
    })

    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, "SET_BRIGHTNESS_TARGET", params)
    end)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function sendBrightnessPreset(deviceId, presetId)
    Log.info("light_command", "sending light preset", {
        device_id = deviceId,
        command = "SET_BRIGHTNESS_TARGET",
        params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = presetId },
    })

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
        result.control_path = "light_v2_target"
        result.command = "SET_BRIGHTNESS_TARGET"
        result.requested_brightness = target
        result.rate_ms = 0
    else
        return false, {
            code = "ACTION_NOT_SUPPORTED",
            message = "Unsupported light action: " .. tostring(action),
        }
    end

    if not sent then
        Log.error("light_command", "Control4 command failed", {
            device_id = device.id,
            action = action,
            error = sendError,
        })
        return false, {
            code = "CONTROL4_COMMAND_FAILED",
            message = "Director rejected the light command: " .. tostring(sendError),
        }
    end

    Log.info("light_command", "Control4 command dispatched", result)
    return true, result
end

-- Its driver was updated in Composer: what it declares is read again (Manager.setUpAgain).
function LightV2.forget(device)
    LightCapabilities.forget(device)
end

function LightV2.reset()
    tracked = {}
    LightCapabilities.reset()
end

return LightV2
