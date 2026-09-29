-- Reads the Jewish calendar's reference data, tests/vectors/calendar/*.json (from Hebcal.com,
-- CC BY 4.0; scripts/make_calendar_vectors.mjs made them), for the calendar suites.

local Json = require("src.core.json")
local HebrewDate = require("src.core.hebrew_date")

local Vectors = {}

Vectors.CITIES = { "tel-aviv", "new-york", "buenos-aires", "reykjavik", "tromso" }

local cache = {}

function Vectors.read(name)
    if not cache[name] then
        local file = assert(io.open("tests/vectors/calendar/" .. name, "rb"))
        local text = file:read("*a")
        file:close()
        cache[name] = Json.decode(text)
    end
    return cache[name]
end

-- "2026-10-03" -> rd
function Vectors.rd(date)
    return assert(HebrewDate.parseDateKey(date), "not a date: " .. tostring(date))
end

-- Hebcal's local time, "2026-01-02T16:28:00+02:00" -> seconds from 1970.
function Vectors.epoch(text)
    local date, hour, minute, second, sign, offsetHours, offsetMinutes = text:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d):(%d%d):(%d%d)([%+%-])(%d%d):(%d%d)$")
    assert(date, "not a local time: " .. tostring(text))
    local offset = (tonumber(offsetHours) * 60 + tonumber(offsetMinutes)) * (sign == "-" and -1 or 1)
    return (Vectors.rd(date) - HebrewDate.UNIX_EPOCH) * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second) - offset * 60, offset
end

function Vectors.isNull(value)
    return value == nil or value == Json.null
end

-- "2024-10-02T15:04:00Z"
function Vectors.iso(epoch)
    return epoch and os.date("!%Y-%m-%dT%H:%M:%SZ", epoch) or "none"
end

return Vectors
