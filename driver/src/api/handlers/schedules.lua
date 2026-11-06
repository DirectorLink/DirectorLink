-- Schedules (docs/SCHEDULES.md, src/core/schedules.lua, src/core/scheduler.lua) and the weather
-- they use (GET /v1/weather). Only admins see them (ADR-054), and make, change and delete them; the
-- weather is everyone's. Since 1.14.0 admins also skip a schedule's next run, see the next seven
-- days (GET /v1/schedules/week), and keep the home's own holidays (/v1/holidays,
-- src/core/home_holidays.lua).

local Clock = require("src.core.clock")
local HomeHolidays = require("src.core.home_holidays")
local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Calendar = require("src.api.handlers.calendar")
local Scenes = require("src.core.scenes")
local Scheduler = require("src.core.scheduler")
local Schedules = require("src.core.schedules")
local Weather = require("src.core.weather")
local Access = require("src.auth.access")

local Handlers = {}

local FIELDS = { enabled = true, scene_id = true, trigger = true, days = true, only_if = true, if_no_weather = true, during_shabbat = true, on_holidays = true, run_late = true }

-- The days GET /v1/schedules/week answers for: today and the six after it.
local WEEK_DAYS = 7

local function nullable(value)
    if value == nil then
        return Json.null
    end
    return value
end

-- For a schedule that uses the Jewish calendar, the calendar's status: "ok", "off" or
-- "no_location" (src/core/jewish_calendar.lua); with "off" or "no_location" it does not run as it
-- would (Shabbat triggers and "only" wait, "skip" runs as usual).
local function calendarStatus(services, schedule)
    if not Schedules.usesCalendar(schedule) then
        return Json.null
    end
    local calendar = services and services.calendar
    return calendar and calendar.status() or "off"
end

-- A skipped next run (1.14.0): when it was due ({ at }; null for a weather rule's next time), or
-- null.
local function skipView(runtime)
    local skip = runtime.skip
    if type(skip) ~= "table" then
        return Json.null
    end
    return { at = skip.at and Clock.iso(skip.at) or Json.null }
end

local function view(schedule, now, services)
    local runtime = Schedules.runtime(schedule.id)
    local lastRun = runtime.last_run
    local nextRun = Scheduler.nextRun(schedule, now)
    return {
        id = schedule.id,
        enabled = schedule.enabled ~= false,
        scene_id = schedule.scene_id,
        trigger = schedule.trigger,
        days = Json.array(schedule.days),
        only_if = schedule.only_if or {},
        if_no_weather = schedule.if_no_weather or "run",
        during_shabbat = schedule.during_shabbat or "run",
        on_holidays = schedule.on_holidays or "run",
        run_late = schedule.run_late == true,
        calendar_status = calendarStatus(services, schedule),
        next_run = nextRun and Clock.iso(nextRun) or Json.null,
        skip = skipView(runtime),
        last_run = type(lastRun) == "table" and {
            at = lastRun.at,
            ran = nullable(lastRun.ran),
            skipped = nullable(lastRun.skipped),
            failed = nullable(lastRun.failed),
            -- no_weather: ran without weather data; only_if / no_weather under skipped_by: did not
            -- run; since 1.14.0 also skip (a person skipped it) and holiday (the home's).
            note = nullable(lastRun.note),
            skipped_by = nullable(lastRun.skipped_by),
            error = nullable(lastRun.error),
        } or Json.null,
        version = schedule.version,
        created_at = schedule.created_at,
        updated_at = schedule.updated_at,
    }
end

local function findSchedule(ctx)
    local id = tostring(ctx.params.scheduleId or "")
    if #id ~= 8 or not id:match("^[%da-f]+$") then
        return nil, Problem.invalidParameter("scheduleId", "scheduleId is 8 hex characters")
    end
    local schedule = Schedules.find(id)
    if not schedule then
        return nil, Problem.notFound("Schedule", id)
    end
    return schedule
end

local function storeProblem(failure, what)
    if failure == "STORE_UNREADABLE" then
        return Problem.new(503, "UNAVAILABLE", "The saved schedules could not be read when DirectorLink started; restart the driver and try again")
    end
    return Problem.internal("The schedule could not be " .. what)
end

-- Checks the merged fields; a scene given in the request must exist (switching off a schedule
-- whose scene is gone still works).
local function checked(input, sceneGiven)
    local record, field, message = Schedules.check(input)
    if not record then
        return nil, Problem.invalidField(field, message)
    end
    if sceneGiven and not Scenes.find(record.scene_id) then
        return nil, Problem.invalidField("scene_id", "Unknown scene: " .. record.scene_id)
    end
    return record
end

-- Setting a Jewish calendar feature (a Shabbat trigger, or "during_shabbat" other than "run")
-- needs the calendar on in Composer. A schedule that has one can still be switched on or off,
-- change its days or scene, or be deleted while it is off; it does not run meanwhile.
local function calendarOff(ctx, body)
    local trigger, during = body.trigger, body.during_shabbat
    local sets = type(trigger) == "table" and trigger.type == "shabbat" or type(during) == "string" and during ~= "run"
    if sets and not (ctx.services.calendarEnabled and ctx.services.calendarEnabled()) then
        return Calendar.offProblem()
    end
    return nil
end

function Handlers.list(ctx)
    local now = Clock.now()
    local items = Json.array()
    for _, schedule in ipairs(Schedules.list()) do
        items[#items + 1] = view(schedule, now, ctx.services)
    end
    -- Paused by the installer in Composer (the Schedules property): nothing runs.
    local paused = ctx.services.schedulesPaused and ctx.services.schedulesPaused() or false
    return 200, { items = items, paused = paused }
end

function Handlers.get(ctx)
    local schedule, problem = findSchedule(ctx)
    if not schedule then
        return problem
    end
    return 200, view(schedule, Clock.now(), ctx.services)
end

function Handlers.create(ctx)
    local body = ctx.body
    local problem = Validate.body(body, FIELDS, true)
    if problem then
        return problem
    end
    local record
    record, problem = checked(body, true)
    if not record then
        return problem
    end
    problem = calendarOff(ctx, body)
    if problem then
        return problem
    end
    local created, failure = Schedules.create(record)
    if not created then
        if failure == "SCHEDULE_LIMIT_REACHED" then
            return Problem.new(409, failure, "This home has " .. Schedules.MAX_SCHEDULES .. " schedules, as many as it allows")
        end
        return storeProblem(failure, "saved")
    end
    if ctx.services.onSchedulesChanged then
        ctx.services.onSchedulesChanged()
    end
    ctx.services.log.info("schedules", "schedule created", { schedule = created.id, scene = created.scene_id, trigger = created.trigger.type, by = ctx.apiKey.id })
    return 201, view(created, Clock.now(), ctx.services)
end

-- PATCH: the fields sent replace the schedule's (a whole `trigger` or `only_if`); with `version`,
-- only if nobody changed it since (409 VERSION_CONFLICT). {"enabled": false} switches it off.
function Handlers.update(ctx)
    local schedule, problem = findSchedule(ctx)
    if not schedule then
        return problem
    end
    local body = ctx.body
    local allowed = { version = true }
    for field in pairs(FIELDS) do
        allowed[field] = true
    end
    problem = Validate.body(body, allowed, true)
    if problem then
        return problem
    end
    if body.version ~= nil and (type(body.version) ~= "number" or body.version < 1 or body.version ~= math.floor(body.version)) then
        return Problem.invalidField("version", "version must be the schedule's version, a whole number")
    end
    local merged, count = {}, 0
    for field in pairs(FIELDS) do
        merged[field] = schedule[field]
        if body[field] ~= nil then
            merged[field] = body[field]
            count = count + 1
        end
    end
    if count == 0 then
        return Problem.invalidRequest("Send at least one field to change")
    end
    local record
    record, problem = checked(merged, body.scene_id ~= nil)
    if not record then
        return problem
    end
    problem = calendarOff(ctx, body)
    if problem then
        return problem
    end
    local updated, failure = Schedules.replace(schedule.id, record, body.version)
    if not updated then
        if failure == "VERSION_CONFLICT" then
            return Problem.new(409, failure, "The schedule was changed on another device; read it again", { version = schedule.version })
        elseif failure == "NOT_FOUND" then
            return Problem.notFound("Schedule", schedule.id)
        end
        return storeProblem(failure, "saved")
    end
    if ctx.services.onSchedulesChanged then
        ctx.services.onSchedulesChanged()
    end
    ctx.services.log.info("schedules", "schedule changed", { schedule = schedule.id, enabled = updated.enabled, by = ctx.apiKey.id })
    return 200, view(updated, Clock.now(), ctx.services)
end

-- POST /v1/schedules/{id}/skip (1.14.0): the schedule's next run does not run; asked again, the
-- same run stays skipped. DELETE runs it after all.
function Handlers.skip(ctx)
    local schedule, problem = findSchedule(ctx)
    if not schedule then
        return problem
    end
    local skip, failure = Scheduler.skipNext(schedule, Clock.now())
    if not skip then
        if failure == "OFF" then
            return Problem.new(409, "SCHEDULE_OFF", "This schedule is switched off: it has no next run to skip")
        end
        return Problem.new(409, "NO_NEXT_RUN", "This schedule has no next run to skip")
    end
    if ctx.services.onSchedulesChanged then
        ctx.services.onSchedulesChanged()
    end
    ctx.services.log.info("schedules", "next run skipped", { schedule = schedule.id, due_at = skip.at and Clock.iso(skip.at) or Json.null, by = ctx.apiKey.id })
    return 200, view(Schedules.find(schedule.id), Clock.now(), ctx.services)
end

function Handlers.unskip(ctx)
    local schedule, problem = findSchedule(ctx)
    if not schedule then
        return problem
    end
    if Scheduler.cancelSkip(schedule) then
        if ctx.services.onSchedulesChanged then
            ctx.services.onSchedulesChanged()
        end
        ctx.services.log.info("schedules", "skipped run back on", { schedule = schedule.id, by = ctx.apiKey.id })
    end
    return 200, view(Schedules.find(schedule.id), Clock.now(), ctx.services)
end

function Handlers.delete(ctx)
    local schedule, problem = findSchedule(ctx)
    if not schedule then
        return problem
    end
    local deleted, failure = Schedules.delete(schedule.id)
    if not deleted then
        if failure == "NOT_FOUND" then
            return Problem.notFound("Schedule", schedule.id)
        end
        return storeProblem(failure, "deleted")
    end
    if ctx.services.onSchedulesChanged then
        ctx.services.onSchedulesChanged()
    end
    ctx.services.log.info("schedules", "schedule deleted", { schedule = schedule.id, by = ctx.apiKey.id })
    return 204
end

local function clock(minute)
    return minute and string.format("%02d:%02d", math.floor(minute / 60), minute % 60) or Json.null
end

-- GET /v1/schedules/week (1.14.0): today and the next six days in the home's time zone, each with
-- its sun times, the home's holiday, Shabbat and holidays (with the Jewish calendar on), and every
-- run of every schedule that day, or why one of its days has none (Scheduler.week).
function Handlers.week(ctx)
    local now = Clock.now()
    local days = Json.array()
    for _, day in ipairs(Scheduler.week(now, WEEK_DAYS)) do
        local info = day.info
        local sunrise, sunset = Scheduler.sunTimes(info)
        local dawn, dusk = Scheduler.twilight(info)
        local holy = Scheduler.holyOn(info)
        local runs = Json.array()
        for _, run in ipairs(day.runs) do
            local trigger = run.schedule.trigger
            runs[#runs + 1] = {
                schedule_id = run.schedule.id,
                scene_id = run.schedule.scene_id,
                at = run.at and Clock.iso(run.at) or Json.null,
                status = run.status,
                reason = nullable(run.reason),
                -- Runs only if the weather then holds ("only if"), which is not known yet.
                conditions = next(run.schedule.only_if or {}) ~= nil,
                from = trigger.type == "weather" and nullable(trigger.from) or Json.null,
                to = trigger.type == "weather" and nullable(trigger.to) or Json.null,
            }
        end
        days[#days + 1] = {
            date = info.date,
            weekday = info.weekday,
            sun = { dawn = clock(dawn), sunrise = clock(sunrise), sunset = clock(sunset), dusk = clock(dusk) },
            holiday = day.holiday and { name = day.holiday.name } or Json.null,
            holy = holy and { starts_at = holy.starts_at and Clock.iso(holy.starts_at) or Json.null, ends_at = holy.ends_at and Clock.iso(holy.ends_at) or Json.null } or Json.null,
            runs = runs,
        }
    end
    local paused = ctx.services.schedulesPaused and ctx.services.schedulesPaused() or false
    return 200, { days = days, paused = paused }
end

-- GET /v1/holidays (1.14.0): the home's own holidays, for schedules that skip them or run only on
-- them.
function Handlers.holidays(ctx)
    return 200, HomeHolidays.view()
end

-- PUT /v1/holidays: replaces the whole list; with `version`, only if nobody changed it since (409
-- VERSION_CONFLICT).
function Handlers.set_holidays(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { items = true, version = true }, false)
    if problem then
        return problem
    end
    if type(body.items) ~= "table" or body.items == Json.null or (not Json.isArray(body.items) and next(body.items) ~= nil) then
        return Problem.invalidField("items", "items is the list of holidays")
    end
    if #body.items > HomeHolidays.MAX_ITEMS then
        return Problem.invalidField("items", "At most " .. HomeHolidays.MAX_ITEMS .. " holidays")
    end
    if body.version ~= nil and (type(body.version) ~= "number" or body.version < 0 or body.version ~= math.floor(body.version)) then
        return Problem.invalidField("version", "version must be the list's version, a whole number")
    end
    local items = {}
    for index, input in ipairs(body.items) do
        local item, field, message = HomeHolidays.check(input)
        if not item then
            return Problem.invalidField("items[" .. (index - 1) .. "]" .. (field ~= "" and ("." .. field) or ""), message)
        end
        items[#items + 1] = item
    end
    local updated, failure = HomeHolidays.replace(items, body.version)
    if not updated then
        if failure == "VERSION_CONFLICT" then
            return Problem.new(409, failure, "The holidays were changed on another device; read them again", { version = HomeHolidays.view().version })
        elseif failure == "STORE_UNREADABLE" then
            return Problem.new(503, "UNAVAILABLE", "The saved holidays could not be read when DirectorLink started; restart the driver and try again")
        end
        return Problem.internal("The holidays could not be saved")
    end
    if ctx.services.onSchedulesChanged then
        ctx.services.onSchedulesChanged()
    end
    ctx.services.log.info("schedules", "holidays changed", { holidays = #items, by = ctx.apiKey.id })
    return 200, updated
end

local function rounded(value)
    return value and math.floor(value * 100 + 0.5) / 100 or Json.null
end

-- A day's high, low and chance of rain from the forecast (null without weather), and its sunrise and
-- sunset on the controller's local date `info`; since 1.14.0 its dawn and dusk (civil twilight).
local function dayView(values, info)
    local sunrise, sunset = Scheduler.sunTimes(info)
    local dawn, dusk = Scheduler.twilight(info)
    values = values or {}
    return {
        max_temperature = nullable(values.max_temperature),
        min_temperature = nullable(values.min_temperature),
        rain_chance = nullable(values.rain_chance),
        sunrise = clock(sunrise),
        sunset = clock(sunset),
        dawn = clock(dawn),
        dusk = clock(dusk),
    }
end

-- GET /v1/weather: the weather now and today's sunrise and sunset (worked out on the controller,
-- so they are there without the internet too). Since 1.10.0 (ADR-071) the weather now is the saved
-- forecast's hour for now (`source`), read at `fetched_at`; `detail` says why the last read failed,
-- also while the saved forecast is used. Reading it keeps the forecast fresh for an hour. Since
-- 1.12.1 (ADR-084) `tomorrow` too, as `today`: the app's line on Home shows it from 15:00, and
-- tomorrow's sunrise after sunset.
function Handlers.weather(ctx)
    local now = Clock.now()
    Weather.wanted(now)
    local data, fetchedAt, reason, detail = Weather.current(now)
    local today = Scheduler.localTime(now)
    -- By calendar date, at noon, as the scheduler counts days (a daylight saving change skips none).
    local tomorrow = Scheduler.localTime(os.time({ year = today.year, month = today.month, day = today.day + 1, hour = 12, min = 0, sec = 0 }))
    local latitude, longitude = Weather.location()
    local result = {
        status = data and "ok" or string.lower(reason or "waiting"),
        detail = nullable(detail),
        -- Where the home is: for admins only (rounded).
        location = latitude and Access.isAdmin(ctx.apiKey) and { latitude = rounded(latitude), longitude = rounded(longitude) } or Json.null,
        fetched_at = fetchedAt and Clock.iso(fetchedAt) or Json.null,
        source = data and data.source or Json.null,
        forecast_for = data and Clock.iso(now) or Json.null,
        forecast_until = data and data.forecast_until and Clock.iso(data.forecast_until) or Json.null,
        current = data and {
            temperature = data.temperature,
            wind_speed = nullable(data.wind_speed),
            wind_gusts = nullable(data.wind_gusts),
            precipitation = data.precipitation,
            raining = data.raining,
            weather_code = nullable(data.weather_code),
        } or Json.null,
        today = dayView(data and data.today, today),
        tomorrow = dayView(data and data.tomorrow, tomorrow),
        attribution = "Weather data by Open-Meteo.com",
    }
    return 200, result
end

return Handlers
