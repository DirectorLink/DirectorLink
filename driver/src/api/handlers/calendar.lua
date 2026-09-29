-- The Jewish calendar (ADR-037, src/core/jewish_calendar.lua): Shabbat and holiday times, the
-- Hebrew date and the week's reading, worked out on the controller from the project's location,
-- behind the Composer property Jewish Calendar (Off by default). Everyone may read it; admins
-- change how the times are worked out. The answers carry stable keys and ids, and English names
-- for scripts; apps show their own names.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local JewishCalendar = require("src.core.jewish_calendar")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")

local Calendar = {}

-- What admins may set (PATCH /v1/calendar/settings).
Calendar.LIMITS = JewishCalendar.LIMITS
Calendar.HOLIDAYS = JewishCalendar.HOLIDAYS

local FIELDS = { holidays = true, candle_lighting_minutes = true, havdalah_minutes = true, version = true }

local function isWhole(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function iso(epoch)
    return epoch and Clock.iso(epoch) or Json.null
end

-- The answer to a request that needs the calendar while it is off (schedules use it too).
function Calendar.offProblem()
    return Problem.new(409, "JEWISH_CALENDAR_OFF", "The Jewish calendar is off: an installer turns it on with DirectorLink's Jewish Calendar property in Composer")
end

local function settingsView(settings)
    return {
        holidays = settings.holidays,
        israel = settings.israel,
        candle_lighting_minutes = settings.candle_lighting_minutes,
        havdalah_minutes = settings.havdalah_minutes,
        version = settings.version,
    }
end

local function holidaysView(calendar, entries)
    local items = Json.array()
    for _, entry in ipairs(entries or {}) do
        items[#items + 1] = {
            key = entry.key,
            day = entry.day or Json.null,
            month = entry.month or Json.null,
            yom_tov = entry.yom_tov == true,
            name = calendar.holidayName(entry),
        }
    end
    return items
end

local function periodView(calendar, period)
    if not period then
        return Json.null
    end
    local days = Json.array()
    for _, day in ipairs(period.days or {}) do
        days[#days + 1] = {
            date = calendar.dateKey(day.rd),
            shabbat = day.shabbat == true,
            candle_lighting = iso(day.candle_lighting),
            holidays = holidaysView(calendar, day.holidays),
        }
    end
    return { starts_at = iso(period.starts_at), ends_at = iso(period.ends_at), approximate = period.approximate == true, days = days }
end

-- GET /v1/calendar: the settings, today's Hebrew date, this week's Shabbat, and the holy period now
-- and next. With the calendar off, nothing but that; without a location, no times.
function Calendar.get(ctx)
    local calendar = ctx.services.calendar
    local status = calendar and calendar.status() or "off"
    if status == "off" then
        return 200, {
            enabled = false,
            status = "off",
            settings = Json.null,
            today = Json.null,
            week = Json.null,
            current = Json.null,
            next = Json.null,
        }
    end
    local now = Clock.now()
    local today, week = calendar.today(now), calendar.week(now)
    local parasha = Json.null
    if week.parasha then
        parasha = { ids = Json.array(week.parasha), name = calendar.parashaName(week.parasha) }
    end
    return 200, {
        enabled = true,
        status = status,
        settings = settingsView(calendar.settings()),
        today = {
            date = today.date,
            hebrew = { year = today.hebrew.year, month = today.hebrew.key, day = today.hebrew.day, leap_year = today.hebrew.leap_year },
            after_sunset = today.after_sunset,
            holidays = holidaysView(calendar, today.holidays),
        },
        week = { date = week.date, parasha = parasha, holidays = holidaysView(calendar, week.holidays) },
        current = status == "ok" and periodView(calendar, calendar.periodAt(now)) or Json.null,
        next = status == "ok" and periodView(calendar, calendar.nextPeriod(now)) or Json.null,
    }
end

-- A settings change: nil, or the Problem with it.
local function checkSettings(body)
    local problem = Validate.body(body, FIELDS, true)
    if problem then
        return problem
    end
    if body.holidays == nil and body.candle_lighting_minutes == nil and body.havdalah_minutes == nil then
        return Problem.invalidRequest("Send at least one setting to change")
    end
    if body.holidays ~= nil and not Calendar.HOLIDAYS[body.holidays] then
        return Problem.invalidField("holidays", 'holidays must be "auto", "israel" or "abroad"')
    end
    for _, field in ipairs({ "candle_lighting_minutes", "havdalah_minutes" }) do
        local limits = Calendar.LIMITS[field]
        if body[field] ~= nil and not isWhole(body[field], limits[1], limits[2]) then
            return Problem.invalidField(field, string.format("%s must be whole minutes from %d to %d", field, limits[1], limits[2]))
        end
    end
    if body.version ~= nil and not isWhole(body.version, 1, math.huge) then
        return Problem.invalidField("version", "version must be the settings' version, a whole number")
    end
    return nil
end

-- PATCH /v1/calendar/settings: the fields sent replace the settings; with `version`, only if
-- nobody changed them since. The body is checked first, then refused while the calendar is off.
function Calendar.update_settings(ctx)
    local body = ctx.body
    local problem = checkSettings(body)
    if problem then
        return problem
    end
    local calendar = ctx.services.calendar
    if not (calendar and ctx.services.calendarEnabled and ctx.services.calendarEnabled()) then
        return Calendar.offProblem()
    end
    local settings, failure = calendar.updateSettings({
        holidays = body.holidays,
        candle_lighting_minutes = body.candle_lighting_minutes,
        havdalah_minutes = body.havdalah_minutes,
    }, body.version)
    if not settings then
        if failure == "VERSION_CONFLICT" then
            return Problem.new(409, failure, "The settings were changed on another device; read them again", { version = calendar.settings().version })
        elseif failure == "STORE_UNREADABLE" then
            return Problem.new(503, "UNAVAILABLE", "The saved calendar settings could not be read when DirectorLink started; restart the driver and try again")
        end
        return Problem.new(503, "UNAVAILABLE", "The calendar settings could not be saved; try again")
    end
    ctx.services.log.info("calendar", "calendar settings changed", {
        holidays = settings.holidays,
        israel = settings.israel,
        candle_lighting_minutes = settings.candle_lighting_minutes,
        havdalah_minutes = settings.havdalah_minutes,
        version = settings.version,
        by = ctx.apiKey.id,
    })
    if ctx.services.onCalendarChanged then
        ctx.services.onCalendarChanged()
    end
    return 200, settingsView(settings)
end

return Calendar
