local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Blinds = {}

local function findBlind(ctx)
    local id, problem = Validate.id(ctx.params.blindId, "blindId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "blind" or device.supported ~= true then
        return nil, Problem.notFound("Blind", id)
    end
    return device
end

function Blinds.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.blindList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.blind(registry, device)
        end
    end
    return 200, { items = items }
end

function Blinds.get(ctx)
    local device, problem = findBlind(ctx)
    if not device then
        return problem
    end
    return 200, Views.blind(ctx.services.registry, device)
end

function Blinds.update(ctx)
    local device, problem = findBlind(ctx)
    if not device then
        return problem
    end

    local body = ctx.body
    problem = Validate.body(body, { position = true }, true)
    if problem then
        return problem
    end
    local position = body.position
    if type(position) ~= "number" or position ~= math.floor(position) or position < 0 or position > 100 then
        return Problem.invalidField("position", "position must be a whole number from 0 (closed) to 100 (open)")
    end

    local ok, failure = ctx.services.adapters.execute(device.id, "set_position", { position = position })
    if not ok then
        return Problem.fromAdapter(failure)
    end
    return 202, Views.blind(ctx.services.registry, device)
end

function Blinds.stop(ctx)
    local device, problem = findBlind(ctx)
    if not device then
        return problem
    end
    local ok, failure = ctx.services.adapters.execute(device.id, "stop")
    if not ok then
        return Problem.fromAdapter(failure)
    end
    return 202, Views.blind(ctx.services.registry, device)
end

return Blinds
