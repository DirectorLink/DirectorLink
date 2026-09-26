-- Input validation helpers. Each returns the parsed value, or nil plus a Problem.

local Json = require("src.core.json")
local Problem = require("src.api.problem")

local Validate = {}

function Validate.id(value, name)
    local text = tostring(value or "")
    if text:match("^%d+$") and tonumber(text) >= 1 then
        return tonumber(text)
    end
    return nil, Problem.invalidParameter(name, name .. " must be a positive integer")
end

function Validate.optionalInteger(value, name, minimum, maximum)
    if value == nil or value == "" then
        return nil
    end
    local text = tostring(value)
    local number = text:match("^%-?%d+$") and tonumber(text)
    if not number or (minimum and number < minimum) or (maximum and number > maximum) then
        local range = ""
        if minimum and maximum then
            range = " from " .. minimum .. " to " .. maximum
        elseif minimum then
            range = " of at least " .. minimum
        end
        return nil, Problem.invalidParameter(name, name .. " must be an integer" .. range)
    end
    return number
end

function Validate.optionalBoolean(value, name)
    if value == nil or value == "" then
        return nil
    end
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    return nil, Problem.invalidParameter(name, name .. " must be true or false")
end

-- Checks that the body is a JSON object with only `allowed` fields
-- and, when `requireOne` is set, at least one of them.
function Validate.body(body, allowed, requireOne)
    if type(body) ~= "table" or body == Json.null or Json.isArray(body) then
        return Problem.invalidRequest("The request body must be a JSON object")
    end
    local count = 0
    for key in pairs(body) do
        if not allowed[key] then
            return Problem.invalidField(tostring(key), "Unknown field: " .. tostring(key))
        end
        count = count + 1
    end
    if requireOne and count == 0 then
        return Problem.invalidRequest("The request body must contain at least one field")
    end
    return nil
end

function Validate.name(value, field, default)
    if value == nil then
        return default
    end
    if type(value) ~= "string" then
        return nil, Problem.invalidField(field, field .. " must be a string")
    end
    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    -- Count UTF-8 characters (bytes that are not continuation bytes), not bytes.
    local _, characters = trimmed:gsub("[^\128-\191]", "")
    if characters == 0 or characters > 64 then
        return nil, Problem.invalidField(field, field .. " must be 1 to 64 characters")
    end
    return trimmed
end

return Validate
