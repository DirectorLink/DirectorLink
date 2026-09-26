-- Wall-clock and duration helpers.

local Clock = {}

function Clock.now()
    return os.time()
end

-- ISO 8601 UTC timestamp for a Unix time in seconds (defaults to now).
function Clock.iso(seconds)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", seconds or os.time())
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
