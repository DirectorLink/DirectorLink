-- Wall-clock and duration helpers.

local Clock = {}

function Clock.now()
    return os.time()
end

-- ISO 8601 UTC timestamp for a Unix time in seconds (defaults to now).
function Clock.iso(seconds)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", seconds or os.time())
end

-- The Unix time (seconds) of an ISO 8601 time with its zone: "2026-10-05T18:14:03Z", with a
-- fraction of a second ("…:03.250Z") or an offset ("+03:00", "+0300", "-05"); nil for anything else
-- (no zone, no seconds, out of range). Worked out by arithmetic, whatever the controller's zone.
function Clock.parseIso(text)
    if type(text) ~= "string" or #text > 40 then
        return nil
    end
    local year, month, day, hour, minute, second, zone =
        text:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.-)%s*$")
    if not year then
        return nil
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60 then
        return nil
    end
    zone = zone:gsub("^%.%d+", "")
    local offset
    if zone == "Z" or zone == "z" then
        offset = 0
    else
        local sign, hours, minutes = zone:match("^([%+%-])(%d%d):?(%d%d)$")
        if not sign then
            sign, hours = zone:match("^([%+%-])(%d%d)$")
            minutes = "00"
        end
        if not sign then
            return nil
        end
        offset = (tonumber(hours) * 60 + tonumber(minutes)) * 60 * (sign == "-" and -1 or 1)
    end
    -- Days since 1970-01-01 of a date in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
    local y = month <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local yearOfEra = y - era * 400
    local dayOfYear = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
    local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
    local days = era * 146097 + dayOfEra - 719468
    return days * 86400 + hour * 3600 + minute * 60 + second - offset
end

-- Milliseconds for measuring durations. C4:GetTime is only used for differences,
-- so it does not matter whether it counts from boot or from the epoch.
function Clock.millis()
    local ok, value = pcall(function()
        return C4:GetTime()
    end)
    if ok and type(value) == "number" then
        return value
    end
    return os.time() * 1000
end

return Clock
