-- Schedules (docs/SCHEDULES.md, src/core/schedules.lua, src/core/scheduler.lua) and the weather
-- they use (GET /v1/weather). Everyone sees them; admins make, change and delete them.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Calendar = require("src.api.handlers.calendar")
local Scenes = require("src.core.scenes")
local Scheduler = require("src.core.scheduler")
local Schedules = require("src.core.schedules")
local Weather = require("src.core.weather")

local Handlers = {}

local FIELDS = { enabled = true, scene_id = true, trigger = true, days = true, only_if = true, if_no_weather = true, during_shabbat = true }

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
        calendar_status = calendarStatus(services, schedule),
        next_run = nextRun and Clock.iso(nextRun) or Json.null,
        last_run = type(lastRun) == "table" and {
            at = lastRun.at,
            ran = nullable(lastRun.ran),
            skipped = nullable(lastRun.skipped),
            failed = nullable(lastRun.failed),
            -- no_weather: ran without weather data; only_if / no_weather under skipped_by: did not run.
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

local function rounded(value)
    return value and math.floor(value * 100 + 0.5) / 100 or Json.null
end

-- GET /v1/weather: the latest reading and today's sunrise and sunset (worked out on the controller,
-- so they are there without the internet too). Reading it keeps the weather fresh for an hour.
function Handlers.weather(ctx)
    local now = Clock.now()
    Weather.wanted(now)
    local data, fetchedAt, reason, detail = Weather.current(now)
    local sunrise, sunset = Scheduler.sunTimes(Scheduler.localTime(now))
    local latitude, longitude = Weather.location()
    local result = {
        status = data and "ok" or string.lower(reason or "waiting"),
        detail = nullable(detail),
        -- Where the home is: for admins only (rounded).
        location = latitude and ctx.apiKey and ctx.apiKey.role == "admin" and { latitude = rounded(latitude), longitude = rounded(longitude) } or Json.null,
        fetched_at = fetchedAt and Clock.iso(fetchedAt) or Json.null,
        current = data and {
            temperature = data.temperature,
            wind_speed = nullable(data.wind_speed),
            wind_gusts = nullable(data.wind_gusts),
            precipitation = data.precipitation,
            raining = data.raining,
            weather_code = nullable(data.weather_code),
        } or Json.null,
        today = {
            max_temperature = nullable(data and data.today.max_temperature),
            min_temperature = nullable(data and data.today.min_temperature),
            rain_chance = nullable(data and data.today.rain_chance),
            sunrise = clock(sunrise),
            sunset = clock(sunset),
        },
        attribution = "Weather data by Open-Meteo.com",
    }
    return 200, result
end

return Handlers
