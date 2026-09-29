local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Thermostats = {}

local MODES = { off = true, heat = true, cool = true, auto = true }
local FAN_SPEEDS = { low = true, medium = true, high = true, auto = true, on = true, circulate = true }
local SETPOINTS = { "heat_setpoint", "cool_setpoint" }

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function findThermostat(ctx)
    local id, problem = Validate.id(ctx.params.thermostatId, "thermostatId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "climate" or device.supported ~= true then
        return nil, Problem.notFound("Thermostat", id)
    end
    return device
end

function Thermostats.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.climateList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.thermostat(registry, device)
        end
    end
    return 200, { items = items }
end

function Thermostats.get(ctx)
    local device, problem = findThermostat(ctx)
    if not device then
        return problem
    end
    return 200, Views.thermostat(ctx.services.registry, device)
end

function Thermostats.update(ctx)
    local device, problem = findThermostat(ctx)
    if not device then
        return problem
    end

    local body = ctx.body
    problem = Validate.body(body, {
        mode = true,
        target_temperature = true,
        fan_speed = true,
        heat_setpoint = true,
        cool_setpoint = true,
    }, true)
    if problem then
        return problem
    end

    local options = Views.thermostatOptions(device)
    local commands = {}

    if body.mode ~= nil then
        if type(body.mode) ~= "string" or not MODES[body.mode] then
            return Problem.invalidField("mode", "mode must be one of off, heat, cool, auto")
        end
        if not contains(options.modes, body.mode) then
            return Problem.new(409, "MODE_NOT_SUPPORTED", "This thermostat does not support mode " .. body.mode)
        end
        commands[#commands + 1] = { field = "mode", action = "set_hvac_mode", params = { value = body.mode } }
    end

    if body.fan_speed ~= nil then
        if type(body.fan_speed) ~= "string" or not FAN_SPEEDS[body.fan_speed] then
            return Problem.invalidField("fan_speed", "fan_speed must be one of low, medium, high, auto, on, circulate")
        end
        if #options.fan_speeds == 0 then
            return Problem.new(409, "NOT_SUPPORTED", "This thermostat has no fan control")
        end
        if not contains(options.fan_speeds, body.fan_speed) then
            return Problem.new(409, "NOT_SUPPORTED", "This thermostat does not support fan speed " .. body.fan_speed)
        end
        commands[#commands + 1] = { field = "fan_speed", action = "set_fan_mode", params = { value = body.fan_speed } }
    end

    local heat, cool = body.heat_setpoint, body.cool_setpoint
    local setpoints = heat ~= nil or cool ~= nil
    if body.target_temperature ~= nil and setpoints then
        return Problem.invalidRequest("Send either target_temperature or heat_setpoint/cool_setpoint")
    end

    if body.target_temperature ~= nil then
        local target = body.target_temperature
        if type(target) ~= "number" or target < options.min or target > options.max then
            return Problem.invalidField("target_temperature",
                "target_temperature must be a number from " .. options.min .. " to " .. options.max)
        end
        -- The mode sent with it says which setpoint a dual-setpoint thermostat sets: its mode
        -- variable changes only after the mode command. Thermostat V2 reads only the value.
        commands[#commands + 1] = {
            field = "target_temperature",
            action = "set_temperature",
            params = { value = target, mode = body.mode },
        }
    end

    if setpoints then
        if not Views.isDual(device) then
            return Problem.new(409, "NOT_SUPPORTED", "This thermostat has one target temperature; send target_temperature")
        end
        for _, field in ipairs(SETPOINTS) do
            local value = body[field]
            if value ~= nil and (type(value) ~= "number" or value < options.min or value > options.max) then
                return Problem.invalidField(field, field .. " must be a number from " .. options.min .. " to " .. options.max)
            end
        end
        -- One command for both: the adapter moves the other setpoint when needed to keep the
        -- deadband, and picks the order that never breaks it in between.
        commands[#commands + 1] = {
            field = heat ~= nil and "heat_setpoint" or "cool_setpoint",
            action = "set_setpoints",
            params = { heat = heat, cool = cool },
        }
    end

    -- Everything is checked before anything is sent, so a setpoint the thermostat refuses (too
    -- close to the other one, or none in this mode) does not leave the mode already changed.
    for _, command in ipairs(commands) do
        local ok, failure = ctx.services.adapters.prepare(device.id, command.action, command.params)
        if not ok then
            failure = failure or {}
            if failure.field then
                return Problem.invalidField(failure.field, failure.message)
            end
            return Problem.fromAdapter(failure)
        end
    end

    local applied = Json.array()
    for _, command in ipairs(commands) do
        local ok, failure = ctx.services.adapters.execute(device.id, command.action, command.params)
        if not ok then
            failure = failure or {}
            local failed = Problem.fromAdapter(failure)
            -- A setpoint command sends up to two; the adapter says which failed and which went out.
            failed.failed_field = failure.field or command.field
            for _, field in ipairs(failure.applied or {}) do
                applied[#applied + 1] = field
            end
            failed.applied = applied
            return failed
        end
        applied[#applied + 1] = command.field
    end

    return 202, Views.thermostat(ctx.services.registry, device)
end

return Thermostats
