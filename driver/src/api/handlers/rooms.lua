local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local RoomNames = require("src.core.room_names")

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

-- PATCH {"names": {"en": "Living room", "he": ""}}: sets the room's name per language; an empty
-- string removes that language. The Control4 name itself is never changed.
function Rooms.update(ctx)
    local id, problem = Validate.id(ctx.params.roomId, "roomId")
    if not id then
        return problem
    end
    local registry = ctx.services.registry
    local room = (registry.rooms or {})[id]
    if not room then
        return Problem.notFound("Room", id)
    end

    local body = ctx.body
    problem = Validate.body(body, { names = true }, true)
    if problem then
        return problem
    end
    local names = body.names
    if type(names) ~= "table" or names == Json.null or Json.isArray(names) then
        return Problem.invalidField("names", "names must be an object of language to name")
    end

    local changes, added = {}, 0
    local existing = RoomNames.get(id)
    for language, name in pairs(names) do
        if not RoomNames.validLanguage(language) then
            return Problem.invalidField("names", "Unknown language tag " .. tostring(language) .. ' (use e.g. "en", "he", "pt-BR")')
        end
        if name == "" then
            changes[language] = ""
        else
            local trimmed, nameProblem = Validate.name(name, "names." .. language)
            if nameProblem then
                return nameProblem
            end
            changes[language] = trimmed
            if existing[language] == nil then
                added = added + 1
            end
        end
    end
    if RoomNames.count(id) + added > RoomNames.MAX_LANGUAGES then
        return Problem.invalidField("names", "A room can have names in at most " .. RoomNames.MAX_LANGUAGES .. " languages")
    end

    RoomNames.update(id, changes)
    ctx.services.log.info("rooms", "room names changed", { room_id = id })
    return 200, Views.room(registry, room, deviceCounts(registry))
end

return Rooms
