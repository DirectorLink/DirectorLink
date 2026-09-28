local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local RoomNames = require("src.core.room_names")
local RoomLayout = require("src.core.room_layout")

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

-- In the home's order (PUT /v1/rooms/order). Which rooms a person hides is in their profile.
function Rooms.list(ctx)
    local registry = ctx.services.registry
    local counts = deviceCounts(registry)
    local items = Json.array()
    for _, room in ipairs(RoomLayout.sort(registry.roomList())) do
        items[#items + 1] = Views.room(registry, room, counts)
    end
    return 200, { items = items }
end

-- PUT {"room_ids": [12, 10, 11]}: the home's room order, for everyone (admins). Rooms left out
-- follow, in Control4's order.
function Rooms.order(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { room_ids = true }, true)
    if problem then
        return problem
    end
    local ids = body.room_ids
    if type(ids) ~= "table" or ids == Json.null or (not Json.isArray(ids) and next(ids) ~= nil) or #ids > RoomLayout.MAX_ROOMS then
        return Problem.invalidField("room_ids", "room_ids must be a list of room ids")
    end
    local rooms = ctx.services.registry.rooms or {}
    local seen, order = {}, {}
    for _, id in ipairs(ids) do
        if type(id) ~= "number" or id ~= math.floor(id) or not rooms[id] then
            return Problem.invalidField("room_ids", "Unknown room: " .. tostring(id))
        end
        if seen[id] then
            return Problem.invalidField("room_ids", "Room " .. id .. " is listed twice")
        end
        seen[id] = true
        order[#order + 1] = id
    end
    if not RoomLayout.setOrder(order) then
        return Problem.internal("The room order could not be saved")
    end
    ctx.services.log.info("rooms", "room order changed", { rooms = #order, by = ctx.apiKey.id })
    return Rooms.list(ctx)
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
