-- C4Bridge log: a leveled, in-memory ring buffer that the API serves at /v1/logs.
-- Every recorded entry is also written to the Director driver log via C4:DebugLog.

local Json = require("src.core.json")
local Clock = require("src.core.clock")

local Log = {}

Log.MAX_ENTRIES = 500

local LEVELS = {
    debug = 10,
    info = 20,
    warn = 30,
    error = 40,
}

-- Field names whose values never reach the log.
local REDACTED = {
    api_key = true,
    authorization = true,
    key = true,
    pairing_code = true,
    password = true,
    secret = true,
    token = true,
}

local state = {
    level = "info",
    seq = 0,
    entries = {},
}

-- Accepts debug/info/warn/error (and Composer's "Warning"); returns nil otherwise.
function Log.normalizeLevel(value)
    local name = string.lower(tostring(value or ""))
    if name == "warning" then
        name = "warn"
    end
    if LEVELS[name] then
        return name
    end
    return nil
end

function Log.isLevel(value)
    return type(value) == "string" and LEVELS[value] ~= nil
end

function Log.setLevel(value)
    local name = Log.normalizeLevel(value)
    if not name then
        return false
    end
    state.level = name
    return true
end

function Log.getLevel()
    return state.level
end

local function sanitize(value, depth)
    if type(value) ~= "table" or value == Json.null then
        return value
    end
    if depth > 5 then
        return "[nested]"
    end
    local copy = {}
    for key, item in pairs(value) do
        if type(key) == "string" and REDACTED[string.lower(key)] then
            copy[key] = "[redacted]"
        else
            copy[key] = sanitize(item, depth + 1)
        end
    end
    return setmetatable(copy, getmetatable(value))
end

function Log.write(level, category, message, data)
    if not LEVELS[level] or LEVELS[level] < LEVELS[state.level] then
        return nil
    end

    state.seq = state.seq + 1
    local entry = {
        seq = state.seq,
        time = Clock.iso(),
        level = level,
        category = tostring(category or "general"),
        message = tostring(message or ""),
        data = Json.null,
    }
    if data ~= nil then
        entry.data = sanitize(data, 0)
    end

    table.insert(state.entries, entry)
    if #state.entries > Log.MAX_ENTRIES then
        table.remove(state.entries, 1)
    end

    pcall(function()
        local suffix = ""
        if entry.data ~= Json.null then
            local ok, encoded = pcall(Json.encode, entry.data)
            suffix = " " .. (ok and encoded or tostring(entry.data))
        end
        C4:DebugLog(
            "[C4Bridge][" .. string.upper(level) .. "][" .. entry.category .. "] " ..
            entry.message .. suffix
        )
    end)

    return entry
end

function Log.debug(category, message, data)
    return Log.write("debug", category, message, data)
end

function Log.info(category, message, data)
    return Log.write("info", category, message, data)
end

function Log.warn(category, message, data)
    return Log.write("warn", category, message, data)
end

function Log.error(category, message, data)
    return Log.write("error", category, message, data)
end

-- Returns matching entries (oldest first, at most `limit` of the newest) and the last seq.
function Log.query(options)
    options = options or {}
    local minimum = LEVELS[options.level or "debug"] or LEVELS.debug
    local after = tonumber(options.after) or 0
    local limit = tonumber(options.limit) or 200
    local category = options.category

    local matched = {}
    for _, entry in ipairs(state.entries) do
        if entry.seq > after
            and LEVELS[entry.level] >= minimum
            and (category == nil or entry.category == category) then
            matched[#matched + 1] = entry
        end
    end

    local items = Json.array()
    for index = math.max(1, #matched - limit + 1), #matched do
        items[#items + 1] = matched[index]
    end
    return items, state.seq
end

-- Clears entries and restores defaults (used by tests).
function Log.reset()
    state.level = "info"
    state.seq = 0
    state.entries = {}
end

return Log
