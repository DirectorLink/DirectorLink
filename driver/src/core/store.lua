-- The driver's persistent data (C4:PersistSetValue). Director hands a stored string that is JSON
-- back as a decoded Lua table (seen on OS 3.4.3; its own typed values look like
-- {":boolean:":true}), so a JSON string never comes back as it was written. Values are stored as
-- "json:" plus JSON, which Director returns unchanged; tables Director already decoded (data written
-- by 0.9.1 and older) are accepted as they are.

local Json = require("src.core.json")

local Store = {}

local PREFIX = "json:"

-- Returns the stored table, or nil, plus how it came back ("json", "table", "missing" or
-- "unreadable") for the log.
function Store.read(name, encrypted)
    local ok, raw = pcall(function()
        return C4:PersistGetValue(name, encrypted == true)
    end)
    if not ok then
        return nil, "unreadable"
    end
    if type(raw) == "table" then
        return raw, "table"
    end
    if raw == nil or raw == "" then
        return nil, "missing"
    end
    if type(raw) ~= "string" then
        return nil, "unreadable"
    end
    if raw:sub(1, #PREFIX) == PREFIX then
        raw = raw:sub(#PREFIX + 1)
    end
    local value = Json.decode(raw)
    if type(value) == "table" then
        return value, "json"
    end
    return nil, "unreadable"
end

-- Returns true when Director took the value.
function Store.write(name, value, encrypted)
    return (pcall(function()
        C4:PersistSetValue(name, PREFIX .. Json.encode(value), encrypted == true)
    end))
end

-- The items of a stored array in order, whatever index Director's decoding starts it at.
function Store.items(array)
    if type(array) ~= "table" then
        return {}
    end
    local indexes = {}
    for index in pairs(array) do
        if type(index) == "number" then
            indexes[#indexes + 1] = index
        end
    end
    table.sort(indexes)
    local items = {}
    for _, index in ipairs(indexes) do
        items[#items + 1] = array[index]
    end
    return items
end

return Store
