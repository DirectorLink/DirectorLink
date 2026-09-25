local Diagnostics = {}

local MAX_ENTRIES = 250
local entries = {}

local function now()
    local ok, value = pcall(function()
        if C4.GetTime then
            return C4:GetTime()
        end
        return os.time() * 1000
    end)
    if ok then
        return value
    end
    return os.time() * 1000
end

local function safeJson(value)
    local ok, encoded = pcall(function()
        return C4:JsonEncode(value, false, true)
    end)
    if ok and encoded then
        return encoded
    end
    return tostring(value)
end

function Diagnostics.log(level, category, message, data)
    local entry = {
        ts = now(),
        level = tostring(level or "INFO"),
        category = tostring(category or "general"),
        message = tostring(message or ""),
        data = data,
    }

    table.insert(entries, entry)
    if #entries > MAX_ENTRIES then
        table.remove(entries, 1)
    end

    pcall(function()
        local suffix = data ~= nil and (" " .. safeJson(data)) or ""
        C4:DebugLog(
            "[C4Bridge][" .. entry.level .. "][" .. entry.category .. "] " ..
            entry.message .. suffix
        )
    end)

    return entry
end

function Diagnostics.info(category, message, data)
    return Diagnostics.log("INFO", category, message, data)
end

function Diagnostics.warn(category, message, data)
    return Diagnostics.log("WARN", category, message, data)
end

function Diagnostics.error(category, message, data)
    return Diagnostics.log("ERROR", category, message, data)
end

function Diagnostics.list()
    local copy = {}
    for i, entry in ipairs(entries) do
        copy[i] = entry
    end
    return copy
end

function Diagnostics.clear()
    entries = {}
end

return Diagnostics
