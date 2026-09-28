-- The home's room order (docs/PREFERENCES.md), one for everyone, set by an admin. Control4 has its
-- own order; this is DirectorLink's. Rooms not in the order keep Control4's order, after the
-- ordered ones. Hiding a room is personal: each profile's `hidden_rooms` (profiles.lua).

local Log = require("src.core.log")
local Store = require("src.core.store")
local Json = require("src.core.json")

local RoomLayout = {}

local STORE_KEY = "directorlink_room_layout"
RoomLayout.MAX_ROOMS = 1000

local state = { order = {} }

local function save()
    local order = Json.array()
    for _, id in ipairs(state.order) do
        order[#order + 1] = id
    end
    if not Store.write(STORE_KEY, { version = 1, order = order }, false) then
        Log.error("rooms", "could not save the room order")
        return false
    end
    return true
end

function RoomLayout.load()
    state.order = {}
    local data = Store.read(STORE_KEY, false)
    if type(data) ~= "table" then
        return
    end
    local seen = {}
    for _, id in ipairs(Store.items(data.order)) do
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            state.order[#state.order + 1] = id
        end
    end
end

-- `rooms` (a list with `id`) in the home's order: the ordered ones first, then the rest as given.
function RoomLayout.sort(rooms)
    local rank = {}
    for index, id in ipairs(state.order) do
        rank[id] = index
    end
    local indexed = {}
    for index, room in ipairs(rooms) do
        indexed[#indexed + 1] = { room = room, rank = rank[tonumber(room.id)], index = index }
    end
    table.sort(indexed, function(a, b)
        if a.rank and b.rank then
            return a.rank < b.rank
        end
        if a.rank or b.rank then
            return a.rank ~= nil
        end
        return a.index < b.index
    end)
    local sorted = {}
    for _, item in ipairs(indexed) do
        sorted[#sorted + 1] = item.room
    end
    return sorted
end

-- The new order (room ids, already checked by the API).
function RoomLayout.setOrder(ids)
    state.order = {}
    for _, id in ipairs(ids) do
        state.order[#state.order + 1] = id
    end
    return save()
end

return RoomLayout
