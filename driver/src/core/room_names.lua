-- Room names in other languages, kept by C4Bridge (Control4 has one name per room).
-- Stored in the driver's persistent data as { [roomId] = { [language] = name } }.

local Json = require("src.core.json")
local Log = require("src.core.log")

local RoomNames = {}

local STORE_KEY = "C4BRIDGE_ROOM_NAMES"
-- Language tags: "en", "he", "pt-BR".
local LANGUAGE_PATTERN = "^%l%l%l?$"
local REGION_PATTERN = "^%l%l%l?%-%u%u$"
RoomNames.MAX_LANGUAGES = 10

local names = {}

function RoomNames.validLanguage(tag)
    return type(tag) == "string" and (tag:match(LANGUAGE_PATTERN) ~= nil or tag:match(REGION_PATTERN) ~= nil)
end

local function save()
    local stored = {}
    for roomId, byLanguage in pairs(names) do
        if next(byLanguage) then
            stored[tostring(roomId)] = byLanguage
        end
    end
    local ok, err = pcall(function()
        C4:PersistSetValue(STORE_KEY, Json.encode({ version = 1, rooms = stored }), false)
    end)
    if not ok then
        Log.error("rooms", "could not save room names", { error = tostring(err) })
    end
end

function RoomNames.load()
    names = {}
    local ok, raw = pcall(function()
        return C4:PersistGetValue(STORE_KEY, false)
    end)
    if not ok or type(raw) ~= "string" or raw == "" then
        return
    end
    local data = Json.decode(raw)
    if type(data) ~= "table" or type(data.rooms) ~= "table" then
        Log.warn("rooms", "stored room names are unreadable; starting empty")
        return
    end
    for roomId, byLanguage in pairs(data.rooms) do
        local id = tonumber(roomId)
        if id and type(byLanguage) == "table" then
            names[id] = {}
            for language, name in pairs(byLanguage) do
                if RoomNames.validLanguage(language) and type(name) == "string" then
                    names[id][language] = name
                end
            end
        end
    end
end

-- The names of one room, language → name (a copy).
function RoomNames.get(roomId)
    local result = {}
    for language, name in pairs(names[tonumber(roomId)] or {}) do
        result[language] = name
    end
    return result
end

-- Applies changes (language → name; "" removes that language) and saves.
function RoomNames.update(roomId, changes)
    roomId = tonumber(roomId)
    local current = names[roomId] or {}
    for language, name in pairs(changes) do
        if name == "" then
            current[language] = nil
        else
            current[language] = name
        end
    end
    names[roomId] = current
    save()
    return RoomNames.get(roomId)
end

function RoomNames.count(roomId)
    local count = 0
    for _ in pairs(names[tonumber(roomId)] or {}) do
        count = count + 1
    end
    return count
end

return RoomNames
