-- The Jewish calendar (ADR-037, docs/SCHEDULES.md "Shabbat and holidays"): Shabbat and holiday
-- times for the home, the Hebrew date and the week's reading, worked out on the controller from the
-- project's location; nothing goes to the network. It needs DirectorLink's Composer property
-- Jewish Calendar = On (Off by default): while it is off nothing is worked out. Admins choose the
-- candle-lighting and havdalah minutes and Israel or abroad in the app; the settings are kept on
-- the controller.
--
-- The engine (hebrew_date, holidays, parasha, sun and holy_times; docs/CALENDAR.md) is pure and
-- knows no time zone: it counts days as R.D. numbers and times as UTC epochs. This service adds the
-- settings, the location and the controller's local time (os.date, os.time), and keeps the holy
-- periods from a few days ago to a year ahead worked out, again at most once a day.

local Clock = require("src.core.clock")
local Log = require("src.core.log")
local Store = require("src.core.store")

local JewishCalendar = {}

local STORE_KEY = "directorlink_calendar"
-- The engine's day number (R.D. 1 is Monday 1 January of year 1) of 1970-01-01.
local UNIX_RD = 719163

-- What admins may set (PATCH /v1/calendar/settings), and the defaults.
JewishCalendar.LIMITS = {
    candle_lighting_minutes = { 0, 90 }, -- before sunset
    havdalah_minutes = { 20, 90 }, -- after sunset
}
JewishCalendar.HOLIDAYS = { auto = true, israel = true, abroad = true }
JewishCalendar.DEFAULTS = { holidays = "auto", candle_lighting_minutes = 20, havdalah_minutes = 42 }
-- The holy periods kept worked out: from this many days before today to this many after.
JewishCalendar.DAYS_BEFORE = 3
JewishCalendar.DAYS_AFTER = 400

-- Israel's holidays and readings are used automatically ("auto") for a home whose location is in
-- this box (it also takes in parts of Jordan, Lebanon and Sinai: admins there set "abroad") and
-- whose project has no other country code; without a location, for Israel's country code or time
-- zone, and when neither is known.
local ISRAEL_BOX = { south = 29.45, north = 33.35, west = 34.2, east = 35.95 }
local ISRAEL_ZONES = { ["Asia/Jerusalem"] = true, ["Asia/Tel_Aviv"] = true, Israel = true }

-- The engine, loaded the first time the calendar works something out: a home with the calendar
-- off never loads it.
local ENGINE_MODULES = {
    HebrewDate = "src.core.hebrew_date",
    Holidays = "src.core.holidays",
    Parasha = "src.core.parasha",
    Sun = "src.core.sun",
    HolyTimes = "src.core.holy_times",
}

local state = {
    -- configure(): the Composer switch, the project's location and its country and time zone, and
    -- for tests what works out the holy periods (HolyTimes.periods otherwise).
    enabled = nil,
    location = nil,
    region = nil,
    periods = nil,
    -- The engine's modules, once loaded.
    engine = nil,
    settings = nil,
    -- False after the stored settings could not be read: saving would overwrite them.
    complete = true,
    -- The holy periods worked out: { key, periods, spans, failed }.
    window = nil,
}

local function isWhole(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function defaults()
    local settings = { revision = 1 }
    for field, value in pairs(JewishCalendar.DEFAULTS) do
        settings[field] = value
    end
    return settings
end

local function engine()
    if not state.engine then
        local modules = {}
        for name, path in pairs(ENGINE_MODULES) do
            local ok, module = pcall(require, path)
            if not ok then
                error("the calendar engine could not be loaded (" .. path .. "): " .. tostring(module), 0)
            end
            modules[name] = module
        end
        state.engine = modules
    end
    return state.engine
end

-- `options`: enabled (function: the Jewish Calendar property is On), location (function: the
-- project's latitude and longitude, or nil), region (function: { country_code, timezone }), and
-- for tests periods (in place of HolyTimes.periods). Only the ones given change.
function JewishCalendar.configure(options)
    for _, name in ipairs({ "enabled", "location", "region", "periods" }) do
        if options[name] ~= nil then
            state[name] = options[name]
        end
    end
    JewishCalendar.invalidate()
end

-- Forgets what was worked out: after a change of the settings, the location or the Composer switch.
function JewishCalendar.invalidate()
    state.window = nil
end

-- ---- Days and local time ------------------------------------------------------------------
-- The same day numbers as HebrewDate's, without loading the engine.

-- The engine's day number of a civil date (no time zone involved).
function JewishCalendar.fixedDay(year, month, day)
    if month <= 2 then
        year, month = year - 1, month + 12
    end
    return 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400) + math.floor((153 * (month - 3) + 2) / 5) + day - 719469 + UNIX_RD
end

-- The civil date of a day number: year, month, day.
function JewishCalendar.civilDate(rd)
    local fields = os.date("!*t", (rd - UNIX_RD) * 86400)
    return fields.year, fields.month, fields.day
end

-- "2026-10-03" for a day number.
function JewishCalendar.dateKey(rd)
    return os.date("!%Y-%m-%d", (rd - UNIX_RD) * 86400)
end

-- The day number of the local date of `epoch`.
function JewishCalendar.localDay(epoch)
    local fields = os.date("*t", epoch)
    return JewishCalendar.fixedDay(fields.year, fields.month, fields.day)
end

-- Local midnight at the start of a day number.
function JewishCalendar.localMidnight(rd)
    local year, month, day = JewishCalendar.civilDate(rd)
    return os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
end

-- ---- The switch, the location and the settings -------------------------------------------

local function call(fn, ...)
    if not fn then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

local function location()
    local latitude, longitude = call(state.location)
    latitude, longitude = tonumber(latitude), tonumber(longitude)
    if not latitude or not longitude then
        return nil
    end
    return latitude, longitude
end

-- Israel (true) or abroad (false), and why: "from the location", "from the country", "from the
-- time zone", "by default" (nothing known) or "set in the app".
local function reckoning()
    local settings = state.settings or defaults()
    if settings.holidays == "israel" then
        return true, "set in the app"
    elseif settings.holidays == "abroad" then
        return false, "set in the app"
    end
    local region = call(state.region) or {}
    local country = string.upper(tostring(region.country_code or ""))
    local zone = tostring(region.timezone or "")
    local latitude, longitude = location()
    if latitude then
        local inBox = latitude >= ISRAEL_BOX.south and latitude <= ISRAEL_BOX.north and longitude >= ISRAEL_BOX.west and longitude <= ISRAEL_BOX.east
        return inBox and (country == "" or country == "IL"), "from the location"
    end
    if country == "IL" then
        return true, "from the country"
    elseif ISRAEL_ZONES[zone] then
        return true, "from the time zone"
    elseif country == "" and zone == "" then
        return true, "by default"
    end
    return false, country ~= "" and "from the country" or "from the time zone"
end

-- The settings stored on the controller (defaults until an admin changes them). Returns them and
-- how the store answered (as Store.read).
function JewishCalendar.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    local settings = defaults()
    local saved = type(data) == "table" and data.settings or nil
    if type(saved) == "table" then
        if JewishCalendar.HOLIDAYS[saved.holidays] then
            settings.holidays = saved.holidays
        end
        for field, limits in pairs(JewishCalendar.LIMITS) do
            if isWhole(saved[field], limits[1], limits[2]) then
                settings[field] = saved[field]
            end
        end
        if isWhole(saved.revision, 1, math.huge) then
            settings.revision = saved.revision
        end
        if type(saved.updated_at) == "string" then
            settings.updated_at = saved.updated_at
        end
    end
    state.settings = settings
    JewishCalendar.invalidate()
    if not state.complete then
        Log.error("calendar", "the calendar settings could not be read; they cannot be changed until the driver restarts")
    end
    return settings, form
end

-- "off" (the Composer switch), "no_location" (no latitude and longitude in the project) or "ok".
-- With the switch off nothing is worked out.
function JewishCalendar.status()
    if call(state.enabled) ~= true then
        return "off"
    end
    if not location() then
        return "no_location"
    end
    return "ok"
end

-- As the API shows them: holidays, israel (in use), the minutes and version.
function JewishCalendar.settings()
    local settings = state.settings or defaults()
    return {
        holidays = settings.holidays,
        israel = (reckoning()),
        candle_lighting_minutes = settings.candle_lighting_minutes,
        havdalah_minutes = settings.havdalah_minutes,
        version = settings.revision,
    }
end

-- `changes`: holidays, candle_lighting_minutes and havdalah_minutes, checked by the caller;
-- `expected`: the version the caller saw, or nil not to check. Returns the settings, or nil and
-- "VERSION_CONFLICT", "STORE_UNREADABLE" or "PERSIST_FAILED".
function JewishCalendar.updateSettings(changes, expected)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    local current = state.settings or defaults()
    if expected ~= nil and expected ~= current.revision then
        return nil, "VERSION_CONFLICT"
    end
    local updated = { revision = current.revision + 1, updated_at = Clock.iso() }
    for field in pairs(JewishCalendar.DEFAULTS) do
        updated[field] = current[field]
        if changes[field] ~= nil then
            updated[field] = changes[field]
        end
    end
    if not Store.write(STORE_KEY, { version = 1, settings = updated }, false) then
        return nil, "PERSIST_FAILED"
    end
    state.settings = updated
    JewishCalendar.invalidate()
    return JewishCalendar.settings()
end

-- ---- Holy periods ------------------------------------------------------------------------

-- When a period's holy time begins and ends: from candle lighting to havdalah, or, for a period
-- whose sunsets do not happen at this latitude (`approximate`), its civil days, from local 00:00 on
-- the first to 24:00 on the last.
local function span(period)
    local from, to
    if period.starts_at and period.ends_at then
        from, to = period.starts_at, period.ends_at
    end
    if period.approximate or not from then
        local civilFrom, civilTo = JewishCalendar.localMidnight(period.first), JewishCalendar.localMidnight(period.last + 1)
        from = from and math.min(from, civilFrom) or civilFrom
        to = to and math.max(to, civilTo) or civilTo
    end
    return { from = from, to = to }
end

-- The periods from a few days ago to a year ahead, worked out again when a day starts or the
-- settings or the location change. nil without a location. A failure in the engine is logged once
-- and leaves no periods: Shabbat automation then waits, and the other schedules run as usual.
local function window()
    local latitude, longitude = location()
    if not latitude then
        return nil
    end
    local settings = state.settings or defaults()
    local israel = reckoning()
    local today = JewishCalendar.localDay(Clock.now())
    local key = table.concat({ settings.revision, latitude, longitude, tostring(israel), today }, "|")
    if state.window and state.window.key == key then
        return state.window
    end
    local from, to = today - JewishCalendar.DAYS_BEFORE, today + JewishCalendar.DAYS_AFTER
    local started = Clock.millis()
    local ok, periods = pcall(function()
        local periods = state.periods or engine().HolyTimes.periods
        return periods(from, to, {
            latitude = latitude,
            longitude = longitude,
            israel = israel,
            candle_lighting_minutes = settings.candle_lighting_minutes,
            havdalah_minutes = settings.havdalah_minutes,
        })
    end)
    local spans = {}
    if ok and type(periods) == "table" then
        for index, period in ipairs(periods) do
            spans[index] = span(period)
        end
        Log.debug("calendar", "calendar computed", {
            milliseconds = Clock.millis() - started,
            periods = #periods,
            from = JewishCalendar.dateKey(from),
            to = JewishCalendar.dateKey(to),
            israel = israel,
        })
        state.window = { key = key, periods = periods, spans = spans }
    else
        Log.error("calendar", "the Shabbat and holiday times could not be worked out", { error = tostring(periods) })
        state.window = { key = key, periods = {}, spans = spans, failed = true }
    end
    return state.window
end

-- The periods whose holy time overlaps fromEpoch..toEpoch, in order (within the periods worked
-- out: from 3 days before today to 400 after). Empty unless the status is "ok".
function JewishCalendar.periodsBetween(fromEpoch, toEpoch)
    local periods = {}
    local worked = JewishCalendar.status() == "ok" and window() or nil
    if worked then
        for index, period in ipairs(worked.periods) do
            local holy = worked.spans[index]
            if holy.from <= toEpoch and holy.to > fromEpoch then
                periods[#periods + 1] = period
            end
        end
    end
    return periods
end

-- The period holy at `epoch` (its start counts, its end does not), or nil.
function JewishCalendar.periodAt(epoch)
    local worked = JewishCalendar.status() == "ok" and window() or nil
    if worked then
        for index, period in ipairs(worked.periods) do
            local holy = worked.spans[index]
            if epoch >= holy.from and epoch < holy.to then
                return period
            end
        end
    end
    return nil
end

-- The first period whose holy time begins after `epoch`, or nil.
function JewishCalendar.nextPeriod(epoch)
    local worked = JewishCalendar.status() == "ok" and window() or nil
    if worked then
        for index, period in ipairs(worked.periods) do
            if worked.spans[index].from > epoch then
                return period
            end
        end
    end
    return nil
end

-- Whether `epoch` is in Shabbat or a holiday: true or false, or nil unless the status is "ok" (no
-- moment counts as holy while the calendar is off or has no location).
function JewishCalendar.holyAt(epoch)
    if JewishCalendar.status() ~= "ok" then
        return nil
    end
    return JewishCalendar.periodAt(epoch) ~= nil
end

-- ---- Today and this week -----------------------------------------------------------------

-- The Hebrew day now: { rd (the civil date whose daytime it is), date, hebrew = { year, month,
-- day, key, leap_year }, after_sunset, holidays }. The Hebrew day starts at sunset, so after
-- today's sunset it is tomorrow's; without a location the civil date's.
function JewishCalendar.today(now)
    now = now or Clock.now()
    local modules = engine()
    local fields = os.date("*t", now)
    local rd = JewishCalendar.fixedDay(fields.year, fields.month, fields.day)
    local afterSunset = false
    local latitude, longitude = location()
    if latitude then
        local sunset = modules.Sun.sunsetEpoch(fields.year, fields.month, fields.day, latitude, longitude)
        afterSunset = sunset ~= nil and now >= sunset
    end
    if afterSunset then
        rd = rd + 1
    end
    local year, month, day = modules.HebrewDate.fromFixed(rd)
    return {
        rd = rd,
        date = JewishCalendar.dateKey(rd),
        hebrew = { year = year, month = month, day = day, key = modules.HebrewDate.monthKey(year, month), leap_year = modules.HebrewDate.isLeapYear(year) == true },
        after_sunset = afterSunset,
        holidays = modules.Holidays.onDate(rd, (reckoning())) or {},
    }
end

-- This week's Shabbat, the first Saturday on or after today's Hebrew day: { rd, date, parasha
-- (ids, or nil when a holiday reading replaces it), holidays }.
function JewishCalendar.week(now)
    local modules = engine()
    local israel = reckoning()
    local today = JewishCalendar.today(now)
    local saturday = today.rd + (6 - today.rd % 7) % 7
    return {
        rd = saturday,
        date = JewishCalendar.dateKey(saturday),
        parasha = modules.Parasha.forShabbat(saturday, israel),
        holidays = modules.Holidays.onDate(saturday, israel) or {},
    }
end

-- English names, for Composer, the log and the API's `name` fields ("Rosh Chodesh Cheshvan").
function JewishCalendar.holidayName(entry)
    return engine().Holidays.name(entry) or entry.key
end

function JewishCalendar.parashaName(ids)
    return engine().Parasha.name(ids)
end

-- ---- The Calendar Status property (Composer, English) -------------------------------------

-- "Shabbat, Shmini Atzeret, Simchat Torah": Shabbat for a Saturday, then each day's holy days in
-- order, each once.
local function periodNames(period)
    local names, seen = {}, {}
    local function add(name)
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for _, day in ipairs(period.days or {}) do
        if day.shabbat then
            add("Shabbat")
        end
        for _, entry in ipairs(day.holidays or {}) do
            if entry.yom_tov then
                add(JewishCalendar.holidayName(entry))
            end
        end
    end
    return table.concat(names, ", ")
end

local function clock(epoch)
    return os.date("%a %d %b %H:%M", epoch)
end

local function dayText(rd)
    return os.date("!%a %d %b", (rd - UNIX_RD) * 86400)
end

local NO_SUNSET = "no sunset at this latitude, no times"

-- "Israel (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 02
-- Oct 18:04 to Sat 03 Oct 19:05 Shabbat, Shmini Atzeret, Simchat Torah", or during a period "Now
-- Shabbat until Sat 03 Oct 19:05 · Israel · candles 20, havdalah 42".
function JewishCalendar.statusText(now)
    now = now or Clock.now()
    local status = JewishCalendar.status()
    if status == "off" then
        return "Off"
    elseif status == "no_location" then
        return "No location - set latitude and longitude in the project properties"
    end
    local worked = window()
    if not worked or worked.failed then
        return "Error: the times could not be worked out - see the log (calendar)"
    end
    local settings = state.settings or defaults()
    local israel, source = reckoning()
    local place = israel and "Israel" or "Abroad"
    local current = JewishCalendar.periodAt(now)
    if current then
        local ending = current.ends_at and clock(current.ends_at) or (dayText(current.last) .. " 24:00 (" .. NO_SUNSET .. ")")
        return string.format("Now %s until %s · %s · candles %d, havdalah %d", periodNames(current), ending, place, settings.candle_lighting_minutes, settings.havdalah_minutes)
    end
    local parts = {
        string.format("%s (%s)", place, source),
        string.format("candles %d min before sunset, havdalah %d min after", settings.candle_lighting_minutes, settings.havdalah_minutes),
    }
    local upcoming = JewishCalendar.nextPeriod(now)
    if upcoming and upcoming.starts_at and upcoming.ends_at then
        parts[#parts + 1] = string.format("next %s to %s %s", clock(upcoming.starts_at), clock(upcoming.ends_at), periodNames(upcoming))
    elseif upcoming then
        parts[#parts + 1] = string.format("next %s: %s", dayText(upcoming.first - 1), NO_SUNSET)
    end
    return table.concat(parts, " · ")
end

return JewishCalendar
