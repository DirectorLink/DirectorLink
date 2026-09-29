local Clock = require("src.core.clock")
local Log = require("src.core.log")
local Units = require("src.adapters.thermostat_units")

-- The Control4 thermostat proxy (control4_thermostat_proxy.c4i), used by Control4-branded
-- thermostats. It has Thermostat V2's variable IDs (1100-1150) but separate heat and cool
-- setpoints, reports every value in both scales and takes setpoints in the project's scale. The
-- IDs, values and commands were read on a live Director with five of these thermostats in a
-- °F project (bkwagner, #16); the °C command form has not run on hardware.
--
-- The API stays in °C. Setpoints are compared in native units (thermostat_units.lua) and sent in
-- the project's scale: whole °F in a °F project, °C to 0.1 in a °C project.
--
-- The record this adapter keeps is what the API layer reads (views, thermostat and scene
-- handlers):
--   capabilities: setpoints = "dual", scale = "F"|"C", hvac_modes, fan_modes (proxy casing),
--     has_heat, has_cool, deadband_native, deadband_c, target_temperature_min_c/max_c (5/35,
--     one range for both setpoints)
--   state: connected, scale (raw 1100), current_temperature_c, heat_native, cool_native,
--     heat_setpoint_c, cool_setpoint_c, target_temperature_c (the setpoint of the mode: heat in
--     heat, cool in cool, nil otherwise), hvac_mode, hvac_state (lowercase), fan_mode
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

-- Sanity bounds for both setpoints, in °C. The proxy does not report limits of its own (that we
-- know of); the thermostat still applies its own on top of these.
local SETPOINT_MIN_C = 5
local SETPOINT_MAX_C = 35

-- A setpoint DirectorLink sent counts until the thermostat reports that value, or this long.
local SENT_MS = 10000

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

local function degrees(value)
    if value == math.floor(value) then
        return string.format("%d", value)
    end
    return string.format("%.1f", value)
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

    local function read(fahrenheitVariable, celsiusVariable)
        return Units.readNative(raw[fahrenheitVariable], raw[celsiusVariable], scale)
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
    capabilities.target_temperature_min_c = SETPOINT_MIN_C
    capabilities.target_temperature_max_c = SETPOINT_MAX_C

    local state = device.state
    local heatNative = read(VARIABLE_HEAT_SETPOINT_F, VARIABLE_HEAT_SETPOINT_C)
    local coolNative = read(VARIABLE_COOL_SETPOINT_F, VARIABLE_COOL_SETPOINT_C)
    -- A setpoint sent is no longer pending once the thermostat reports that value.
    if info.lastSent.heat and info.lastSent.heat.value == heatNative then
        info.lastSent.heat = nil
    end
    if info.lastSent.cool and info.lastSent.cool.value == coolNative then
        info.lastSent.cool = nil
    end
    state.connected = raw[VARIABLE_IS_CONNECTED] == nil and true or boolValue(raw[VARIABLE_IS_CONNECTED])
    state.scale = raw[VARIABLE_SCALE]
    state.current_temperature_c = Units.measuredCelsius(raw[VARIABLE_TEMPERATURE_F], raw[VARIABLE_TEMPERATURE_C], scale)
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

local function invalid(field, message)
    return { code = "INVALID_TEMPERATURE", field = field, message = message }
end

local function unsupported(message)
    return { code = "ACTION_NOT_SUPPORTED", message = message }
end

-- The heat and cool setpoints the thermostat has as far as DirectorLink knows, in native units.
-- Director reports a setpoint only some time after the command, so a request that comes before
-- then starts from what was last sent: judged against the old report, it could skip a push it
-- needs or send its setpoints in an order that breaks the deadband in between.
local function currentSetpoints(device)
    local lastSent, state = tracked[device.id].lastSent, device.state
    local now = Clock.millis()
    for _, name in ipairs({ "heat", "cool" }) do
        if lastSent[name] and now - lastSent[name].at > SENT_MS then
            lastSent[name] = nil
        end
    end
    local heat = lastSent.heat and lastSent.heat.value or state.heat_native
    local cool = lastSent.cool and lastSent.cool.value or state.cool_native
    return heat, cool
end

-- The setpoint commands for a request of heat and/or cool (°C), in send order, or nil and a
-- failure. Nothing is sent here: prepare and execute both use it.
--
-- One setpoint alone moves the other when needed to keep the deadband, so one rule serves PATCH,
-- scene steps and 1.0.0 clients that only send target_temperature. Both together must already be
-- that far apart.
local function plan(device, heat, cool)
    local capabilities = device.capabilities
    local scale = capabilities.scale
    if heat == nil and cool == nil then
        return nil, { code = "INVALID_TEMPERATURE", message = "Send heat_setpoint, cool_setpoint or both" }
    end
    if heat ~= nil and not capabilities.has_heat then
        return nil, unsupported("This thermostat has no heat setpoint")
    end
    if cool ~= nil and not capabilities.has_cool then
        return nil, unsupported("This thermostat has no cool setpoint")
    end
    for _, requested in ipairs({ { "heat_setpoint", heat }, { "cool_setpoint", cool } }) do
        local field, value = requested[1], requested[2]
        if value ~= nil and (type(value) ~= "number" or value < SETPOINT_MIN_C or value > SETPOINT_MAX_C) then
            return nil, invalid(field, field .. " must be a number from " .. SETPOINT_MIN_C .. " to " .. SETPOINT_MAX_C)
        end
    end

    local low, high = Units.toNative(SETPOINT_MIN_C, scale), Units.toNative(SETPOINT_MAX_C, scale)
    -- Without a reported deadband cool still stays above heat, by one native step (1 °F or
    -- 0.1 °C), as scene steps and the app require: a push never leaves both at the same value.
    local reported = capabilities.deadband_native
    local deadband = math.max(reported or 0, 1)
    local gap = (reported and reported > 0) and ("at least " .. degrees(capabilities.deadband_c) .. "° ") or ""
    local currentHeat, currentCool = currentSetpoints(device)
    -- A setpoint the thermostat does not use (no such mode) is never pushed.
    local h = heat and Units.toNative(heat, scale) or (capabilities.has_heat and currentHeat or nil)
    local c = cool and Units.toNative(cool, scale) or (capabilities.has_cool and currentCool or nil)
    local pushed

    if heat and cool then
        if c - h < deadband then
            return nil, invalid("cool_setpoint", "cool_setpoint must be " .. gap .. "above heat_setpoint")
        end
    elseif heat and c and c - h < deadband then
        c, pushed = h + deadband, "cool"
        if c > high then
            return nil, invalid("heat_setpoint", "heat_setpoint leaves no room above it for the cool setpoint, which stays " .. gap .. "higher")
        end
    elseif cool and h and c - h < deadband then
        h, pushed = c - deadband, "heat"
        if h < low then
            return nil, invalid("cool_setpoint", "cool_setpoint leaves no room below it for the heat setpoint, which stays " .. gap .. "lower")
        end
    end

    local heatStep = (heat ~= nil or pushed == "heat")
        and { field = "heat_setpoint", setpoint = "heat", native = h, command = "SET_SETPOINT_HEAT", params = Units.param(h, scale) } or nil
    local coolStep = (cool ~= nil or pushed == "cool")
        and { field = "cool_setpoint", setpoint = "cool", native = c, command = "SET_SETPOINT_COOL", params = Units.param(c, scale) } or nil

    -- Cool first when the cool setpoint rises (or is unknown), else heat first. From one valid pair
    -- to another, the pair in between then never breaks the deadband either: raising cool first
    -- only widens the gap, and when cool falls, heat falls at least as far below it. "Rises" is
    -- judged against currentSetpoints, the last setpoint sent until the thermostat reports it.
    local first, second = heatStep, coolStep
    if currentCool == nil or (c ~= nil and c > currentCool) then
        first, second = coolStep, heatStep
    end
    local steps = {}
    if first then
        steps[#steps + 1] = first
    end
    if second then
        steps[#steps + 1] = second
    end
    return steps
end

-- set_temperature on a dual thermostat sets the setpoint of the mode: the one in the same request
-- or scene step (the mode variable changes only later), else the current one.
local function setpointsForTarget(device, params)
    local mode = lower(params.mode or device.state.hvac_mode)
    if mode == "heat" then
        return params.value, nil
    elseif mode == "cool" then
        return nil, params.value
    end
    return nil, nil, unsupported("In auto and off this thermostat has a heat and a cool setpoint; send heat_setpoint and cool_setpoint")
end

-- The setpoint commands for set_temperature or set_setpoints, or nil and a failure.
local function setpointPlan(device, action, params)
    if action == "set_setpoints" then
        return plan(device, params.heat, params.cool)
    end
    local heat, cool, failure = setpointsForTarget(device, params)
    if failure then
        return nil, failure
    end
    local steps, planFailure = plan(device, heat, cool)
    if planFailure and planFailure.code == "INVALID_TEMPERATURE" then
        -- The request named target_temperature, not a setpoint.
        planFailure.field = "target_temperature"
    end
    return steps, planFailure
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
        local _, failure = setpointPlan(device, action, params)
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
        local steps, failure = setpointPlan(device, action, params)
        if not steps then
            return false, failure
        end

        local requested = {}
        if action == "set_setpoints" then
            requested.heat_c, requested.cool_c = params.heat, params.cool
        else
            requested.heat_c, requested.cool_c = setpointsForTarget(device, params)
        end
        local sent, applied = {}, {}
        for _, step in ipairs(steps) do
            local ok, err = send(device.id, step.command, step.params)
            if not ok then
                Log.error("climate_command", "Control4 command failed", {
                    device_id = device.id,
                    command = step.command,
                    error = err,
                    applied = applied,
                })
                return false, { code = "COMMAND_FAILED", message = err, field = step.field, applied = applied }
            end
            sent[#sent + 1] = { command = step.command, params = step.params }
            applied[#applied + 1] = step.field
            info.lastSent[step.setpoint] = { value = step.native, at = Clock.millis() }
        end

        local result = { device_id = device.id, action = action, requested = requested, sent = sent }
        Log.info("climate_command", "Control4 command dispatched", result)
        return true, result
    end

    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Unsupported thermostat action: " .. tostring(action),
    }
end

return ThermostatProxy
