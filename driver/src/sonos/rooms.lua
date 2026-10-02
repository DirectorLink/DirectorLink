-- Which Control4 room each Sonos room is in (docs/SONOS.md). A Sonos room appears in the Control4
-- room of the same name, matched without regard to case or spaces (with the room's names in other
-- languages too, from Settings → Rooms); an admin picks the room for the others, and that choice
-- wins. The choices are kept in the driver's persistent data: { [player id] = { room_id, name } }.

local Log = require("src.core.log")
local Store = require("src.core.store")

local Rooms = {}

local STORE_KEY = "directorlink_sonos_rooms"
Rooms.MAX_CHOICES = 100

local state = { choices = {}, complete = true }

-- "Living Room", "living room" and "LivingRoom" are one name.
function Rooms.normalize(name)
    return (string.lower(tostring(name or "")):gsub("%s+", ""))
end

local function save()
    local rooms = {}
    for playerId, choice in pairs(state.choices) do
        rooms[playerId] = { room_id = choice.room_id, name = choice.name }
    end
    if not Store.write(STORE_KEY, { version = 1, rooms = rooms }, false) then
        Log.error("sonos", "could not save the Sonos rooms")
        return false
    end
    return true
end

-- The choices of a stored record ({ version, rooms }), player id -> { room_id, name }.
function Rooms.read(data)
    local choices, count = {}, 0
    for playerId, choice in pairs(type(data) == "table" and type(data.rooms) == "table" and data.rooms or {}) do
        local roomId = type(choice) == "table" and tonumber(choice.room_id) or nil
        if type(playerId) == "string" and playerId:match("^RINCON_%x+$") and roomId and roomId >= 1 and count < Rooms.MAX_CHOICES then
            choices[playerId] = { room_id = roomId, name = type(choice.name) == "string" and choice.name or nil }
            count = count + 1
        end
    end
    return choices
end

function Rooms.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    state.choices = Rooms.read(data)
    if not state.complete then
        Log.warn("sonos", "the stored Sonos rooms are unreadable")
    end
end

-- The admin's choice for a player: a room id, or nil.
function Rooms.choice(playerId)
    local choice = state.choices[playerId]
    return choice and choice.room_id or nil
end

-- Puts a player in a room (`roomId`), or back to its name (nil). False when it was not saved.
function Rooms.choose(playerId, roomId, name)
    if not state.complete then
        return false, "STORE_UNREADABLE"
    end
    local before = state.choices[playerId]
    if roomId then
        local count = 0
        for _ in pairs(state.choices) do
            count = count + 1
        end
        if not before and count >= Rooms.MAX_CHOICES then
            return false, "LIMIT_REACHED"
        end
        state.choices[playerId] = { room_id = roomId, name = name }
    else
        state.choices[playerId] = nil
    end
    if not save() then
        state.choices[playerId] = before
        return false, "PERSIST_FAILED"
    end
    return true
end

-- The Control4 room whose name (or one of its names) is `name`; nil when none is, or more than
-- one. `rooms`: the project's rooms ({ id, name }); `names(roomId)`: language -> name.
function Rooms.match(name, rooms, names)
    local wanted = Rooms.normalize(name)
    if wanted == "" then
        return nil
    end
    local found = nil
    for _, room in pairs(rooms or {}) do
        local same = Rooms.normalize(room.name) == wanted
        if not same and names then
            for _, other in pairs(names(room.id) or {}) do
                if Rooms.normalize(other) == wanted then
                    same = true
                end
            end
        end
        if same then
            if found and found ~= room.id then
                return nil
            end
            found = room.id
        end
    end
    return found
end

-- The room a player is shown in, and how: "admin" (picked), "name" (matched) or nil.
function Rooms.place(player, rooms, names)
    local chosen = Rooms.choice(player.id)
    if chosen and rooms and rooms[chosen] then
        return chosen, "admin"
    end
    local matched = Rooms.match(player.name, rooms, names)
    if matched then
        return matched, "name"
    end
    return nil, nil
end

function Rooms.reset()
    state.choices, state.complete = {}, true
end

-- For tests and the log: how many choices there are.
function Rooms.count()
    local count = 0
    for _ in pairs(state.choices) do
        count = count + 1
    end
    return count
end

return Rooms
