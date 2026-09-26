-- JSON encoder/decoder for C4Bridge (Lua 5.1).
-- Owning this instead of using C4:JsonEncode keeps output deterministic (sorted keys,
-- explicit empty arrays, explicit null) and lets the API layer run in plain Lua for tests.

local Json = {}

-- Sentinel for JSON null: nil cannot be stored in Lua tables.
Json.null = setmetatable({}, {
    __tostring = function()
        return "null"
    end,
})

local ARRAY_MT = { __json = "array" }

-- Marks a table as a JSON array so an empty list encodes as [] rather than {}.
function Json.array(values)
    return setmetatable(values or {}, ARRAY_MT)
end

function Json.isArray(value)
    return type(value) == "table" and getmetatable(value) == ARRAY_MT
end

-- Keys listed here come first in objects; the rest are sorted alphabetically.
local KEY_PRIORITY = {
    id = 1,
    name = 2,
    type = 3,
    title = 4,
    status = 5,
}

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function encodeString(value)
    local escaped = value:gsub('[%c"\\]', function(char)
        return ESCAPES[char] or string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
end

local function encodeNumber(value)
    if value ~= value or value == math.huge or value == -math.huge then
        return "null"
    end
    if value == math.floor(value) and value >= -2 ^ 53 and value <= 2 ^ 53 then
        -- "%.0f" rather than "%d": Lua 5.1 formats %d through a C long, which is 32 bits on some builds.
        return string.format("%.0f", value)
    end
    return string.format("%.14g", value)
end

local function isSequence(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then
            return false
        end
    end
    return count > 0
end

local function keyOrder(a, b)
    local pa = KEY_PRIORITY[a.name] or 100
    local pb = KEY_PRIORITY[b.name] or 100
    if pa ~= pb then
        return pa < pb
    end
    return a.name < b.name
end

local encodeValue

local function encodeTable(value, seen)
    if seen[value] then
        error("cannot encode a circular reference", 0)
    end
    seen[value] = true

    local encoded
    if Json.isArray(value) or isSequence(value) then
        local parts = {}
        for index = 1, #value do
            parts[index] = encodeValue(value[index], seen)
        end
        encoded = "[" .. table.concat(parts, ",") .. "]"
    else
        local entries = {}
        for key, item in pairs(value) do
            entries[#entries + 1] = { name = tostring(key), value = item }
        end
        table.sort(entries, keyOrder)
        local parts = {}
        for index, entry in ipairs(entries) do
            parts[index] = encodeString(entry.name) .. ":" .. encodeValue(entry.value, seen)
        end
        encoded = "{" .. table.concat(parts, ",") .. "}"
    end

    seen[value] = nil
    return encoded
end

encodeValue = function(value, seen)
    local kind = type(value)
    if value == nil or value == Json.null then
        return "null"
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind == "number" then
        return encodeNumber(value)
    elseif kind == "string" then
        return encodeString(value)
    elseif kind == "table" then
        return encodeTable(value, seen)
    end
    error("cannot encode a value of type " .. kind, 0)
end

-- Returns the JSON text; raises an error for values JSON cannot represent.
function Json.encode(value)
    return encodeValue(value, {})
end

-- Decoding ---------------------------------------------------------------

local MAX_DEPTH = 32

local function fail(position, message)
    error({ json = true, message = message .. " at position " .. tostring(position) }, 0)
end

local function skipWhitespace(text, position)
    local _, finish = text:find("^[ \n\r\t]*", position)
    return finish + 1
end

local function utf8Char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40
        )
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40
    )
end

local SIMPLE_ESCAPES = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
}

local function decodeString(text, position)
    local parts = {}
    local index = position + 1
    while true do
        local char = text:sub(index, index)
        if char == "" then
            fail(position, "unterminated string")
        elseif char == '"' then
            return table.concat(parts), index + 1
        elseif char == "\\" then
            local escape = text:sub(index + 1, index + 1)
            if escape == "u" then
                local hex = text:sub(index + 2, index + 5)
                if not hex:match("^%x%x%x%x$") then
                    fail(index, "invalid unicode escape")
                end
                local code = tonumber(hex, 16)
                local advance = 6
                if code >= 0xD800 and code <= 0xDBFF then
                    local low = text:sub(index + 6, index + 11)
                    if low:match("^\\u%x%x%x%x$") then
                        local lowCode = tonumber(low:sub(3), 16)
                        if lowCode >= 0xDC00 and lowCode <= 0xDFFF then
                            code = 0x10000 + (code - 0xD800) * 0x400 + (lowCode - 0xDC00)
                            advance = 12
                        end
                    end
                end
                parts[#parts + 1] = utf8Char(code)
                index = index + advance
            else
                local replacement = SIMPLE_ESCAPES[escape]
                if not replacement then
                    fail(index, "invalid escape sequence")
                end
                parts[#parts + 1] = replacement
                index = index + 2
            end
        else
            local stop = text:find('["\\]', index)
            if not stop then
                fail(position, "unterminated string")
            end
            local chunk = text:sub(index, stop - 1)
            if chunk:find("[%z\1-\31]") then
                fail(index, "control character in string")
            end
            parts[#parts + 1] = chunk
            index = stop
        end
    end
end

local function decodeNumber(text, position)
    if text:find("^-?0%d", position) then
        fail(position, "invalid number")
    end
    local _, finish = text:find("^-?%d+", position)
    if not finish then
        fail(position, "invalid number")
    end
    local _, fraction = text:find("^%.%d+", finish + 1)
    if fraction then
        finish = fraction
    end
    local _, exponent = text:find("^[eE][-+]?%d+", finish + 1)
    if exponent then
        finish = exponent
    end
    return tonumber(text:sub(position, finish)), finish + 1
end

local decodeValue

local function decodeArray(text, position, depth)
    local result = Json.array()
    local index = skipWhitespace(text, position + 1)
    if text:sub(index, index) == "]" then
        return result, index + 1
    end
    while true do
        local value
        value, index = decodeValue(text, index, depth + 1)
        result[#result + 1] = value
        index = skipWhitespace(text, index)
        local char = text:sub(index, index)
        if char == "]" then
            return result, index + 1
        elseif char ~= "," then
            fail(index, "expected ',' or ']'")
        end
        index = skipWhitespace(text, index + 1)
    end
end

local function decodeObject(text, position, depth)
    local result = {}
    local index = skipWhitespace(text, position + 1)
    if text:sub(index, index) == "}" then
        return result, index + 1
    end
    while true do
        if text:sub(index, index) ~= '"' then
            fail(index, "expected a string key")
        end
        local key
        key, index = decodeString(text, index)
        index = skipWhitespace(text, index)
        if text:sub(index, index) ~= ":" then
            fail(index, "expected ':'")
        end
        index = skipWhitespace(text, index + 1)
        local value
        value, index = decodeValue(text, index, depth + 1)
        result[key] = value
        index = skipWhitespace(text, index)
        local char = text:sub(index, index)
        if char == "}" then
            return result, index + 1
        elseif char ~= "," then
            fail(index, "expected ',' or '}'")
        end
        index = skipWhitespace(text, index + 1)
    end
end

decodeValue = function(text, position, depth)
    if depth > MAX_DEPTH then
        fail(position, "nested too deeply")
    end
    local char = text:sub(position, position)
    if char == "{" then
        return decodeObject(text, position, depth)
    elseif char == "[" then
        return decodeArray(text, position, depth)
    elseif char == '"' then
        return decodeString(text, position)
    elseif char == "-" or char:match("%d") then
        return decodeNumber(text, position)
    elseif text:sub(position, position + 3) == "true" then
        return true, position + 4
    elseif text:sub(position, position + 4) == "false" then
        return false, position + 5
    elseif text:sub(position, position + 3) == "null" then
        return Json.null, position + 4
    end
    fail(position, "unexpected character")
end

-- Returns the decoded value (JSON null becomes Json.null), or nil plus an error message.
function Json.decode(text)
    if type(text) ~= "string" then
        return nil, "expected a string"
    end
    local ok, result = pcall(function()
        local value, position = decodeValue(text, skipWhitespace(text, 1), 0)
        position = skipWhitespace(text, position)
        if position <= #text then
            fail(position, "unexpected trailing characters")
        end
        return value
    end)
    if ok then
        return result
    end
    if type(result) == "table" and result.json then
        return nil, result.message
    end
    return nil, tostring(result)
end

return Json
