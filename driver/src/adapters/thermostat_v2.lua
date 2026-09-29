local Log = require("src.core.log")
local Units = require("src.adapters.thermostat_units")

local Climate = {}

local VARIABLE_SCALE = 1100
local VARIABLE_HVAC_MODE = 1104
local VARIABLE_FAN_MODE = 1105
local VARIABLE_HVAC_STATE = 1107
local VARIABLE_IS_CONNECTED = 1112
local VARIABLE_HVAC_MODES_LIST = 1120
local VARIABLE_TEMPERATURE_C = 1131
local VARIABLE_HEAT_SETPOINT_C = 1133
local VARIABLE_SINGLE_SETPOINT_F = 1149
local VARIABLE_SINGLE_SETPOINT_C = 1150

-- Floor heating set through its heat setpoint may be parked well below comfort temperature.
local HEAT_SETPOINT_MIN_C = 5
local SINGLE_SETPOINT_MIN_C = 16

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

-- "Undefined" (or nothing) is how a zone without a fan reports its fan mode: no fan speed.
local function fanValue(value)
    local v = lower(value)
    return (v ~= "" and v ~= "undefined") and v or nil
end

local function hasMode(modes, name)
    for _, mode in ipairs(modes or {}) do
        if lower(mode) == name then
            return true
        end
    end
    return false
end

-- Heat and neither cool nor auto. No AC zone is ever heat-only, so the heat setpoint path below
-- cannot reach one.
local function isHeatOnly(modes)
    return hasMode(modes, "heat") and not hasMode(modes, "cool") and not hasMode(modes, "auto")
end

-- Some heat-only zones (floor heating seen on a real °F project, #19) leave the single
-- setpoint at 0 in both scales, keep their real target in the heat setpoint (1133) and accept only
-- SET_SETPOINT_HEAT. Both 1149 and 1150 reading 0 is never a real target: a real 0 °C reads
-- 1149 = 32 and a real 0 °F reads 1150 = -17.8. A missing 1150 keeps the single setpoint, and so
-- does a heat setpoint of 0, which means it is not reported yet. The rule is checked again on
-- every change, so a zone that reads 0 while Director restarts goes back once its values arrive.
local function usesHeatSetpoint(info)
    return info.heatOnly == true
        and tonumber(info.singleF) == 0
        and tonumber(info.singleC) == 0
        and info.heatC ~= nil and info.heatC ~= 0
end

-- The Debug log of a heat-only zone lists the proxy's thermostat variables (1100-1150) with their
-- names and values, so a field log shows what the zone really has. Nothing depends on these
-- names; they are unverified, and read only at Debug. Returns true when it logged them.
local function logVariableNames(deviceId)
    if Log.getLevel() ~= "debug" then
        return false
    end
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(deviceId)
    end)
    local names = {}
    if ok and type(variables) == "table" then
        for id, variable in pairs(variables) do
            local number = tonumber(id)
            if number and number >= 1100 and number <= 1150 and type(variable) == "table" then
                names[#names + 1] = tostring(id) .. "=" .. tostring(variable.name or "") .. ":" .. tostring(variable.value)
            end
        end
    end
    table.sort(names)
    Log.debug("climate", "heat-only thermostat variables", { device_id = deviceId, variables = table.concat(names, ", ") })
    return true
end

-- A heat-only zone reads and watches the single setpoint in °C (1150) and the heat setpoint (1133).
-- AC zones never get here, and neither does a zone in use on its single setpoint (lookAgain).
-- Returns true when it read one it did not have.
local function watchHeatSetpoint(device, info)
    if not info.heatOnly then
        return false
    end
    local found = false
    if not info.watching[VARIABLE_SINGLE_SETPOINT_C] then
        local value = safeGetVariable(device.id, VARIABLE_SINGLE_SETPOINT_C)
        if value ~= nil then
            info.singleC = value
            info.watching[VARIABLE_SINGLE_SETPOINT_C] = registerListener(device.id, VARIABLE_SINGLE_SETPOINT_C)
            found = true
        end
    end
    if not info.watching[VARIABLE_HEAT_SETPOINT_C] then
        local value = safeGetVariable(device.id, VARIABLE_HEAT_SETPOINT_C)
        if value ~= nil then
            info.heatC = tonumber(value)
            info.watching[VARIABLE_HEAT_SETPOINT_C] = registerListener(device.id, VARIABLE_HEAT_SETPOINT_C)
            found = true
        end
    end
    if not info.variablesLogged then
        info.variablesLogged = logVariableNames(device.id)
    end
    return found
end

-- Only a zone whose single setpoint reads 0 can move to its heat setpoint, so only such a zone
-- reads 1133 and 1150, at start-up and whenever it looks again: after start-up it can turn
-- heat-only (its mode list arrives late), and 1133 or 1150 can appear. A zone in use on its single
-- setpoint starts and runs as in 1.0.0; if its single setpoint drops to 0, the change looks again.
local function lookAgain(device, info)
    return tonumber(info.singleF) == 0 and watchHeatSetpoint(device, info)
end

-- A zone whose mode list loses Cool loses its fan control too, as a zone without Cool never gets
-- it at start-up. A zone that keeps Cool keeps its fan.
local function dropFanControl(device, info)
    info.hasFanMode = false
    info.fanModes = {}
    device.capabilities.fan_modes = {}
    for index = #device.actions, 1, -1 do
        if device.actions[index] == "set_fan_mode" then
            table.remove(device.actions, index)
        end
    end
end

local function targetOf(info)
    if info.useHeat then
        return info.heatC
    end
    return fahrenheitToCelsius(info.singleF)
end

-- Follows the setpoint the zone really uses. Returns true when the path changed, after moving
-- the range and the reported target with it.
local function applySetpointPath(device)
    local info = tracked[device.id]
    local useHeat = usesHeatSetpoint(info)
    if useHeat == info.useHeat then
        return false
    end
    info.useHeat = useHeat
    device.capabilities.setpoint_source = useHeat and "heat" or "single"
    device.capabilities.target_temperature_min_c = useHeat and HEAT_SETPOINT_MIN_C or SINGLE_SETPOINT_MIN_C
    device.state.target_temperature_c = targetOf(info)
    Log.info("climate", "setpoint path changed", {
        device_id = device.id,
        setpoint_source = device.capabilities.setpoint_source,
        single_f = info.singleF,
        single_c = info.singleC,
        heat_c = info.heatC,
    })
    return true
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

    -- Only a heat-only zone whose single setpoint reads 0 reads and watches the heat setpoint and
    -- the single setpoint in °C; every other zone starts with the reads and listeners of 1.0.0.
    local info = {
        hvacModes = hvacModes,
        heatOnly = isHeatOnly(hvacModes),
        singleF = setpointF,
        watching = {},
    }
    lookAgain(device, info)

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

    info.hasFanMode = hasFanControl
    info.fanModes = fanModes
    info.useHeat = usesHeatSetpoint(info)
    tracked[device.id] = info

    device.supported = true
    device.capabilities = {
        hvac_modes = hvacModes,
        fan_modes = fanModes,
        single_setpoint = true,
        -- Internal: "heat" when the target is the heat setpoint (1133), never shown by the API.
        setpoint_source = info.useHeat and "heat" or "single",
        temperature_unit = "C",
        -- The range Control4 itself allows these zones (an AC that is off is often left at 32 °C).
        -- Narrower here, DirectorLink would report a target it then refuses to set.
        target_temperature_min_c = info.useHeat and HEAT_SETPOINT_MIN_C or SINGLE_SETPOINT_MIN_C,
        target_temperature_max_c = 32,
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
        target_temperature_c = targetOf(info),
        hvac_mode = normalizeMode(hvacMode),
        hvac_state = normalizeMode(hvacState),
        fan_mode = fanValue(fanMode),
    }

    local logged = {
        device_id = device.id,
        hvac_modes = hvacModes,
        fan_mode = fanMode,
        current_temperature_c = tempC,
        target_temperature_c = device.state.target_temperature_c,
    }
    -- A zone that looked at its heat setpoint also logs which setpoint it follows and the values
    -- that decided it; every other zone logs the line of 1.0.0.
    if info.heatOnly and tonumber(setpointF) == 0 then
        logged.setpoint_source = device.capabilities.setpoint_source
        logged.single_f = setpointF
        logged.single_c = info.singleC
        logged.heat_c = info.heatC
    end
    Log.info("climate", "initialized thermostat", logged)

    return true
end

function Climate.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    if not info or not device.state then
        return false
    end

    variableId = tonumber(variableId)

    if variableId == VARIABLE_TEMPERATURE_C then
        local n = tonumber(value)
        if n ~= nil then device.state.current_temperature_c = n end
        -- The room temperature changes often; a heat setpoint that appeared since is found here.
        if lookAgain(device, info) then
            applySetpointPath(device)
        end
    elseif variableId == VARIABLE_SINGLE_SETPOINT_F then
        info.singleF = value
        lookAgain(device, info)
        local changed = applySetpointPath(device)
        if not info.useHeat then
            device.state.target_temperature_c = fahrenheitToCelsius(value)
        elseif not changed then
            return false
        end
    elseif variableId == VARIABLE_SINGLE_SETPOINT_C then
        info.singleC = value
        if not applySetpointPath(device) then
            return false
        end
    elseif variableId == VARIABLE_HEAT_SETPOINT_C then
        info.heatC = tonumber(value)
        local changed = applySetpointPath(device)
        if info.useHeat then
            device.state.target_temperature_c = info.heatC
        elseif not changed then
            -- A zone on its single setpoint: the heat setpoint is not its target.
            return false
        end
    elseif variableId == VARIABLE_HVAC_MODE then
        device.state.hvac_mode = normalizeMode(value)
    elseif variableId == VARIABLE_FAN_MODE then
        device.state.fan_mode = fanValue(value)
    elseif variableId == VARIABLE_HVAC_STATE then
        device.state.hvac_state = normalizeMode(value)
    elseif variableId == VARIABLE_IS_CONNECTED then
        device.state.connected = boolValue(value)
    elseif variableId == VARIABLE_HVAC_MODES_LIST then
        local modes = parseList(value)
        if #modes > 0 then
            info.hvacModes = modes
            device.capabilities.hvac_modes = modes
        end
        info.heatOnly = isHeatOnly(info.hvacModes)
        if info.hasFanMode and not hasMode(info.hvacModes, "cool") then
            dropFanControl(device, info)
        end
        -- A zone that just turned heat-only reads its heat setpoint now, before the path is chosen.
        lookAgain(device, info)
        applySetpointPath(device)
    elseif variableId == VARIABLE_SCALE then
        device.state.scale = tostring(value or "")
    else
        return false
    end

    Log.debug("climate_state", "thermostat variable changed", {
        device_id = device.id,
        variable_id = variableId,
        value = value,
    })
    return true
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
        local minTarget = device.capabilities and device.capabilities.target_temperature_min_c or SINGLE_SETPOINT_MIN_C
        local maxTarget = device.capabilities and device.capabilities.target_temperature_max_c or 32
        if not target or target < minTarget or target > maxTarget then
            return false, {
                code = "INVALID_TEMPERATURE",
                message = "Temperature is outside this thermostat's DirectorLink range",
            }
        end

        target = math.floor(target * 10 + 0.5) / 10
        local ok, err
        if info.useHeat then
            -- The heat setpoint goes in the project's scale. In °F it is whole degrees, with the
            -- parameter a real zone lists (#19). Neither form has run from DirectorLink on
            -- hardware yet.
            local scale = Units.scale(device.state and device.state.scale) == "F" and "F" or "C"
            ok, err = send(device.id, "SET_SETPOINT_HEAT", Units.param(Units.toNative(target, scale), scale))
        else
            ok, err = send(device.id, "SET_SETPOINT_SINGLE", { CELSIUS = target })
        end
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
