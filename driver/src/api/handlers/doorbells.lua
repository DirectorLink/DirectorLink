local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Doorbells = {}

local function findDoorbell(ctx)
    local id, problem = Validate.id(ctx.params.doorbellId, "doorbellId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "doorbell" or device.supported ~= true then
        return nil, Problem.notFound("Doorbell", id)
    end
    return device
end

function Doorbells.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.doorbellList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.doorbell(registry, device)
        end
    end
    return 200, { items = items }
end

function Doorbells.get(ctx)
    local device, problem = findDoorbell(ctx)
    if not device then
        return problem
    end
    return 200, Views.doorbell(ctx.services.registry, device)
end

-- Opens the gate or door wired to the DoorBird, like its button in the Control4 app.
function Doorbells.open(ctx)
    local device, problem = findDoorbell(ctx)
    if not device then
        return problem
    end
    if not ctx.services.doorControlEnabled() then
        return Problem.new(403, "DOOR_CONTROL_DISABLED",
            "Door control is off; turn on the Door Control property of DirectorLink in Composer")
    end
    local ok, failure = ctx.services.adapters.execute(device.id, "open")
    if not ok then
        return Problem.fromAdapter(failure)
    end
    ctx.services.log.info("doorbell_command", "open requested", {
        device_id = device.id,
        key_id = ctx.apiKey and ctx.apiKey.id or Json.null,
        client = ctx.client and ctx.client.ip or Json.null,
    })
    return 202, Views.doorbell(ctx.services.registry, device)
end

return Doorbells
