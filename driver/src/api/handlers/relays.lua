local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Relays = {}

local STATES = { open = "open", closed = "close" }

local function findRelay(ctx)
    local id, problem = Validate.id(ctx.params.relayId, "relayId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "relay" or device.supported ~= true then
        return nil, Problem.notFound("Relay", id)
    end
    return device
end

local function run(ctx, device, action)
    if not ctx.services.doorControlEnabled() then
        return Problem.new(403, "DOOR_CONTROL_DISABLED",
            "Door control is off; turn on the Door Control property of C4Bridge in Composer")
    end
    local ok, failure = ctx.services.adapters.execute(device.id, action)
    if not ok then
        return Problem.fromAdapter(failure)
    end
    ctx.services.log.info("relay_command", "relay " .. action .. " requested", {
        device_id = device.id,
        key_id = ctx.apiKey and ctx.apiKey.id or Json.null,
        client = ctx.client and ctx.client.ip or Json.null,
    })
    return 202, Views.relay(ctx.services.registry, device)
end

function Relays.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.relayList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.relay(registry, device)
        end
    end
    return 200, { items = items }
end

function Relays.get(ctx)
    local device, problem = findRelay(ctx)
    if not device then
        return problem
    end
    return 200, Views.relay(ctx.services.registry, device)
end

function Relays.update(ctx)
    local device, problem = findRelay(ctx)
    if not device then
        return problem
    end
    local body = ctx.body
    problem = Validate.body(body, { state = true }, true)
    if problem then
        return problem
    end
    local action = STATES[body.state]
    if not action then
        return Problem.invalidField("state", 'state must be "open" or "closed"')
    end
    return run(ctx, device, action)
end

function Relays.pulse(ctx)
    local device, problem = findRelay(ctx)
    if not device then
        return problem
    end
    return run(ctx, device, "pulse")
end

return Relays
