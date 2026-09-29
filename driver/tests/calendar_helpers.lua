-- Helpers for the Jewish calendar's driver tests (test_calendar.lua, test_schedules.lua): dates and
-- times, the process's time zone, the contract's example answers, and a count of how often the
-- engine (src/core/holy_times.lua) is asked to work out holy periods.

local Helpers = {}

-- The driver folder (this file is driver/tests/calendar_helpers.lua).
local DRIVER_ROOT = debug.getinfo(1, "S").source:match("^@(.-)[/\\]tests[/\\][^/\\]+$") or "./driver"

-- The R.D. number of a civil date (as the engine counts days; kept here so the tests do not work
-- out what they expect with the code they test).
function Helpers.fixedDay(year, month, day)
    if month <= 2 then
        year, month = year - 1, month + 12
    end
    return 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400) + math.floor((153 * (month - 3) + 2) / 5) + day - 306
end

-- "2026-10-02T15:04:00Z" -> seconds from 1970.
function Helpers.epoch(text)
    local year, month, day, hour, minute, second = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
    local rd = Helpers.fixedDay(tonumber(year), tonumber(month), tonumber(day))
    return (rd - 719163) * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

-- Local hh:mm on a day number, in the process's time zone.
function Helpers.localAt(rd, hour, minute)
    local fields = os.date("!*t", (rd - 719163) * 86400)
    return os.time({ year = fields.year, month = fields.month, day = fields.day, hour = hour, min = minute or 0, sec = 0 })
end

-- Minutes the process's local time is ahead of UTC at `epoch`.
function Helpers.offset(epoch)
    local fields = os.date("*t", epoch)
    local rd = Helpers.fixedDay(fields.year, fields.month, fields.day)
    return ((rd - 719163) * 86400 + fields.hour * 3600 + fields.min * 60 + fields.sec - epoch) / 60
end

-- The process's time zone, told by its 2026 clock changes: "Asia/Jerusalem" (Friday 27 March and
-- Sunday 25 October), "America/New_York" (8 March and 1 November), or nil.
function Helpers.zone()
    local function changes(before, after, from, to)
        return Helpers.offset(Helpers.epoch(before)) == from and Helpers.offset(Helpers.epoch(after)) == to
    end
    if changes("2026-03-26T23:59:00Z", "2026-03-27T00:01:00Z", 120, 180) and changes("2026-10-24T22:59:00Z", "2026-10-24T23:01:00Z", 180, 120) then
        return "Asia/Jerusalem"
    elseif changes("2026-03-08T06:59:00Z", "2026-03-08T07:01:00Z", -300, -240) and changes("2026-11-01T05:59:00Z", "2026-11-01T06:01:00Z", -240, -300) then
        return "America/New_York"
    end
    return nil
end

-- tests/vectors/calendar/api-examples.json: the contract's example answers.
function Helpers.examples()
    local file = assert(io.open(DRIVER_ROOT .. "/../tests/vectors/calendar/api-examples.json", "rb"))
    local text = file:read("*a")
    file:close()
    return require("src.core.json").decode(text)
end

-- Counts in Helpers.calls how often the driver just started (Mock.startDriver) asks the engine
-- for holy periods; `periods`, if given, answers instead of it (e.g. a failing engine).
Helpers.calls = 0

function Helpers.watch(periods)
    Helpers.calls = 0
    require("src.core.jewish_calendar").configure({
        periods = function(...)
            Helpers.calls = Helpers.calls + 1
            return (periods or require("src.core.holy_times").periods)(...)
        end,
    })
end

return Helpers
