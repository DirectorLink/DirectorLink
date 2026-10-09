local Clock = require("src.core.clock")
local Log = require("src.core.log")
local Units = require("src.adapters.thermostat_units")

-- Separate heat and cool setpoints: the Control4 thermostat proxy (thermostat_proxy.lua, 1.1.0), and
-- since 1.10.2 a Thermostat V2 thermostat that reports them instead of a single setpoint, as a Nest
-- does (thermostat_v2.lua, ADR-076). Moved here from thermostat_proxy.lua unchanged, so both
-- follow one rule.
--
-- What it reads of a device: capabilities.scale ("F" | "C"), has_heat, has_cool, deadband_native,
-- deadband_c, and state.heat_native, cool_native, hvac_mode. `lastSent`: the adapter's record of the
-- setpoints sent and not yet reported, { heat = { value, at }, cool = ... }.
local Setpoints = {}

-- Sanity bounds for both setpoints, in °C. The proxy does not report limits of its own (that we
-- know of); the thermostat still applies its own on top of these.
Setpoints.MIN_C = 5
Setpoints.MAX_C = 35

-- A setpoint DirectorLink sent counts until the thermostat reports that value, or this long.
local SENT_MS = 10000

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function degrees(value)
    if value == math.floor(value) then
        return string.format("%d", value)
    end
    return string.format("%.1f", value)
end

local function invalid(field, message)
    return { code = "INVALID_TEMPERATURE", field = field, message = message }
end

local function unsupported(message)
    return { code = "ACTION_NOT_SUPPORTED", message = message }
end

-- A setpoint sent is no longer pending once the thermostat reports that value.
function Setpoints.reported(lastSent, heatNative, coolNative)
    if lastSent.heat and lastSent.heat.value == heatNative then
        lastSent.heat = nil
    end
    if lastSent.cool and lastSent.cool.value == coolNative then
        lastSent.cool = nil
    end
end

-- The heat and cool setpoints the thermostat has as far as DirectorLink knows, in native units.
-- Director reports a setpoint only some time after the command, so a request that comes before
-- then starts from what was last sent: judged against the old report, it could skip a push it
-- needs or send its setpoints in an order that breaks the deadband in between.
local function currentSetpoints(device, lastSent)
    local state = device.state
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
local function plan(device, lastSent, heat, cool)
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
        if value ~= nil and (type(value) ~= "number" or value < Setpoints.MIN_C or value > Setpoints.MAX_C) then
            return nil, invalid(field, field .. " must be a number from " .. Setpoints.MIN_C .. " to " .. Setpoints.MAX_C)
        end
    end

    local low, high = Units.toNative(Setpoints.MIN_C, scale), Units.toNative(Setpoints.MAX_C, scale)
    -- Without a reported deadband cool still stays above heat, by one native step (1 °F or
    -- 0.1 °C), as scene steps and the app require: a push never leaves both at the same value.
    local reportedDeadband = capabilities.deadband_native
    local deadband = math.max(reportedDeadband or 0, 1)
    local gap = (reportedDeadband and reportedDeadband > 0) and ("at least " .. degrees(capabilities.deadband_c) .. "° ") or ""
    local currentHeat, currentCool = currentSetpoints(device, lastSent)
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
function Setpoints.forTarget(device, params)
    local mode = lower(params.mode or device.state.hvac_mode)
    if mode == "heat" then
        return params.value, nil
    elseif mode == "cool" then
        return nil, params.value
    end
    return nil, nil, unsupported("In auto and off this thermostat has a heat and a cool setpoint; send heat_setpoint and cool_setpoint")
end

-- The setpoint commands for set_temperature or set_setpoints, or nil and a failure.
function Setpoints.plan(device, lastSent, action, params)
    if action == "set_setpoints" then
        return plan(device, lastSent, params.heat, params.cool)
    end
    local heat, cool, failure = Setpoints.forTarget(device, params)
    if failure then
        return nil, failure
    end
    local steps, planFailure = plan(device, lastSent, heat, cool)
    if planFailure and planFailure.code == "INVALID_TEMPERATURE" then
        -- The request named target_temperature, not a setpoint.
        planFailure.field = "target_temperature"
    end
    return steps, planFailure
end

-- Sends the setpoint commands of set_temperature or set_setpoints. `send(deviceId, command,
-- params)` returns true, or false and an error. Returns true and the result, or false and a failure.
function Setpoints.execute(device, lastSent, action, params, send)
    local steps, failure = Setpoints.plan(device, lastSent, action, params)
    if not steps then
        return false, failure
    end

    local requested = {}
    if action == "set_setpoints" then
        requested.heat_c, requested.cool_c = params.heat, params.cool
    else
        requested.heat_c, requested.cool_c = Setpoints.forTarget(device, params)
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
        lastSent[step.setpoint] = { value = step.native, at = Clock.millis() }
    end

    local result = { device_id = device.id, action = action, requested = requested, sent = sent }
    Log.info("climate_command", "Control4 command dispatched", result)
    return true, result
end

return Setpoints
