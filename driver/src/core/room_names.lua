-- Room names in other languages, kept by DirectorLink (Control4 has one name per room).
-- Stored in the driver's persistent data as { [roomId] = { [language] = name } }.

local Log = require("src.core.log")
local Store = require("src.core.store")

local RoomNames = {}

local STORE_KEY = "DIRECTORLINK_ROOM_NAMES"
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
    local ok, err = Store.write(STORE_KEY, { version = 1, rooms = stored }, false)
    if not ok then
        Log.error("rooms", "could not save room names", { error = tostring(err) })
    end
end

function RoomNames.load()
    names = {}
    local data, form = Store.read(STORE_KEY, false)
    if form == "missing" then
        return
    end
    if type(data) ~= "table" or type(data.rooms) ~= "table" then
        Log.warn("rooms", "stored room names are unreadable; starting empty", { stored_as = form })
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
    -- Written by 0.9.1 and older as plain JSON, which Director hands back decoded.
    if form == "table" then
        save()
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
