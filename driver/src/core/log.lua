-- DirectorLink log: a leveled, in-memory ring buffer that the API serves at /v1/logs.
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
    home_secret = true,
    key = true,
    pairing_code = true,
    password = true,
    secret = true,
    token = true,
}

-- Values that never reach the log, whatever field or message they are in (Log.hide): the pairing
-- code, which pairs an admin key.
local MAX_HIDDEN = 8

local state = {
    level = "info",
    seq = 0,
    entries = {},
    quiet = 0, -- Log.quietly calls running: their info entries are written at debug level
    hidden = {},
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

-- `value` with every hidden value in it replaced.
local function scrub(value)
    if type(value) ~= "string" then
        return value
    end
    for _, hidden in ipairs(state.hidden) do
        local start = value:find(hidden, 1, true)
        while start do
            value = value:sub(1, start - 1) .. "[redacted]" .. value:sub(start + #hidden)
            start = value:find(hidden, start + #"[redacted]", true)
        end
    end
    return value
end

-- Keeps `value` out of every entry from now on, in any field and in the message (the newest few).
function Log.hide(value)
    value = tostring(value or "")
    if #value < 4 then
        return
    end
    for index, hidden in ipairs(state.hidden) do
        if hidden == value then
            table.remove(state.hidden, index)
            break
        end
    end
    table.insert(state.hidden, 1, value)
    state.hidden[MAX_HIDDEN + 1] = nil
end

local function sanitize(value, depth)
    if type(value) ~= "table" or value == Json.null then
        return scrub(value)
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

local function record(level, category, message, data, always)
    if level == "info" and state.quiet > 0 and not always then
        level = "debug"
    end
    if not LEVELS[level] or (LEVELS[level] < LEVELS[state.level] and not always) then
        return nil
    end

    state.seq = state.seq + 1
    local entry = {
        seq = state.seq,
        time = Clock.iso(),
        level = level,
        category = tostring(category or "general"),
        message = scrub(tostring(message or "")),
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
            "[DirectorLink][" .. string.upper(level) .. "][" .. entry.category .. "] " ..
            entry.message .. suffix
        )
    end)

    return entry
end

function Log.write(level, category, message, data)
    return record(level, category, message, data, false)
end

-- An info entry written whatever the log level (who changed a setting, ADR-043): never left out.
function Log.always(category, message, data)
    return record("info", category, message, data, true)
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

local function quietDone(ok, ...)
    state.quiet = state.quiet - 1
    if not ok then
        error((...), 0)
    end
    return ...
end

-- Runs fn(...) and returns what it returns, with the info entries it writes recorded at debug level
-- (warnings and errors stay as they are). A project refresh initializes every device again, and
-- what the adapters log about each one would only repeat the first discovery and push older
-- entries (door openings among them) out of the log.
function Log.quietly(fn, ...)
    state.quiet = state.quiet + 1
    return quietDone(pcall(fn, ...))
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
    state.quiet = 0
    state.hidden = {}
end

return Log
