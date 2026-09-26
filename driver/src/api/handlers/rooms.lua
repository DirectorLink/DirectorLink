local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Rooms = {}

local function deviceCounts(registry)
    local counts = {}
    for _, device in pairs(registry.devices or {}) do
        local roomId = tonumber(device.room_id)
        if roomId then
            counts[roomId] = (counts[roomId] or 0) + 1
        end
    end
    return counts
end

function Rooms.list(ctx)
    local registry = ctx.services.registry
    local counts = deviceCounts(registry)
    local items = Json.array()
    for _, room in ipairs(registry.roomList()) do
        items[#items + 1] = Views.room(registry, room, counts)
    end
    return 200, { items = items }
end

function Rooms.get(ctx)
    local id, problem = Validate.id(ctx.params.roomId, "roomId")
    if not id then
        return problem
    end
    local registry = ctx.services.registry
    local room = (registry.rooms or {})[id]
    if not room then
        return Problem.notFound("Room", id)
    end
    return 200, Views.room(registry, room, deviceCounts(registry))
end

return Rooms
