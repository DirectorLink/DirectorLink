local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local RoomNames = require("src.core.room_names")
local RoomLayout = require("src.core.room_layout")
local Access = require("src.auth.access")
local People = require("src.auth.people")
local Activity = require("src.core.activity")

local Rooms = {}

-- The devices in each room that the caller sees.
local function deviceCounts(ctx)
    local counts = {}
    for _, device in pairs(ctx.services.registry.devices or {}) do
        local roomId = tonumber(device.room_id)
        if roomId and Access.canSee(ctx.apiKey, device) then
            counts[roomId] = (counts[roomId] or 0) + 1
        end
    end
    return counts
end

-- A room as the caller sees it: whether it is hidden from members (ADR-054; only admins see one).
local function view(ctx, room, counts)
    local result = Views.room(ctx.services.registry, room, counts)
    result.hidden_from_members = People.hiddenRooms()[tonumber(room.id)] == true
    return result
end

-- In the home's order (PUT /v1/rooms/order): the rooms the caller sees (ADR-054: a member, theirs,
-- never one hidden from members). Which rooms a person hides from their own lists is in their
-- profile.
function Rooms.list(ctx)
    local registry = ctx.services.registry
    local counts = deviceCounts(ctx)
    local items = Json.array()
    for _, room in ipairs(RoomLayout.sort(registry.roomList())) do
        if Access.seesRoom(ctx.apiKey, room.id) then
            items[#items + 1] = view(ctx, room, counts)
        end
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
    -- A room the caller does not see is, for them, one that does not exist (ADR-054).
    if not room or not Access.seesRoom(ctx.apiKey, id) then
        return Problem.notFound("Room", id)
    end
    return 200, view(ctx, room, deviceCounts(ctx))
end

-- PATCH {"names": {"en": "Living room", "he": ""}, "hidden_from_members": true}: sets the room's
-- name per language (an empty string removes that language; the Control4 name itself is never
-- changed), and whether every member is kept from seeing it (ADR-054), whatever rooms they were
-- given. Admins still see it.
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
    problem = Validate.body(body, { names = true, hidden_from_members = true }, true)
    if problem then
        return problem
    end
    local hidden = body.hidden_from_members
    if hidden ~= nil and type(hidden) ~= "boolean" then
        return Problem.invalidField("hidden_from_members", "hidden_from_members must be true or false")
    end
    if body.names == nil and hidden == nil then
        return Problem.invalidRequest("Send names, hidden_from_members or both")
    end
    local names = body.names or {}
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

    if hidden ~= nil and hidden ~= (People.hiddenRooms()[id] == true) then
        local ok, failure = People.setRoomHidden(id, hidden)
        if not ok then
            if failure == "UNAVAILABLE" then
                return Problem.new(503, "UNAVAILABLE", "The people's permissions could not be read when DirectorLink started; restart the driver and try again")
            end
            return Problem.internal("The room could not be saved")
        end
        ctx.services.log.info("rooms", hidden and "room hidden from members" or "room shown to members", { room_id = id, by = ctx.apiKey.id })
        Activity.record("access", hidden and "room_hidden" or "room_shown", { by = ctx.apiKey, what = room.name, ids = { room_id = id } })
        -- What members may see changed: the keys-changed path drops what they may no longer use.
        if ctx.services.onKeysChanged then
            ctx.services.onKeysChanged()
        end
    end
    if next(changes) then
        RoomNames.update(id, changes)
        ctx.services.log.info("rooms", "room names changed", { room_id = id })
    end
    return 200, view(ctx, room, deviceCounts(ctx))
end

return Rooms
