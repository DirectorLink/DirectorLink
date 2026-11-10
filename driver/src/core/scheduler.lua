-- Runs the schedules (src/core/schedules.lua, docs/SCHEDULES.md) on the controller, once a minute,
-- in the controller's local time.
-- - Time and sun schedules run at their minute on their days (up to 5 minutes late, e.g. after a
--   restart), once; an "only if" is checked then, with the latest weather.
-- - Weather schedules run when the weather turns: the threshold or hotter, the threshold or a
--   stronger wind, or rain starting; on their days, within their hours, and (by default) at most
--   once a day. They run again only after it has cooled to 2° below the threshold or less, the wind
--   has dropped to 10 km/h below it or less, or it has been dry for an hour. The threshold itself
--   always counts, in rules and "only if" alike (1.10.1, ADR-074). The weather is the saved
--   forecast's hour for now (1.10.0, ADR-071, src/core/weather.lua), with or without the
--   internet. In a minute when other schedules run too, they run after them (1.10.0).
-- - Shabbat schedules (the Jewish calendar, ADR-037) run when a holy period begins (candle
--   lighting) or ends (havdalah), plus their offset, once per period. "during_shabbat" keeps a
--   time, sun or weather schedule away from holy time ("skip") or to it ("only"). While the
--   calendar is off or has no location no moment counts as holy: Shabbat schedules and "only" do
--   not run, and "skip" runs as usual.
-- - After a restart, the first minute also runs Shabbat schedules and "only" schedules whose moment
--   passed in the last 6 hours and did not run, late (a family keeping Shabbat cannot make up for
--   them by hand); the others keep their 5 minutes. What was due while the schedules were paused,
--   or while the calendar was off or had no location, is not caught up, not even by a later
--   restart; nor is anything when what the schedules ran could not be read.
-- - Since 1.14.0: a time or sun schedule with `run_late` is caught up like them (6 hours); a person
--   can skip a schedule's next run (Scheduler.skipNext); sun schedules run at dawn or dusk too, and
--   within their earliest and latest times; `on_holidays` keeps a time, sun or weather schedule away
--   from the home's own holidays ("skip") or to them ("only", src/core/home_holidays.lua); and
--   Scheduler.week says what runs on each of the next days, and why not.
-- A scheduled scene runs like one from a member's key: doors and gates in it are skipped.
-- The installer can pause them all in Composer (the Schedules property); each run is shown in the
-- Last Automation property (src/core/installer_view.lua). Each run, and each skip with its reason,
-- also goes into the history (ADR-046, src/core/activity.lua).

local Activity = require("src.core.activity")
local Clock = require("src.core.clock")
local HomeHolidays = require("src.core.home_holidays")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Scenes = require("src.core.scenes")
local Schedules = require("src.core.schedules")
local Sun = require("src.core.sun")
local Weather = require("src.core.weather")

local Scheduler = {}

Scheduler.GRACE_MINUTES = 5
Scheduler.CATCH_UP_SECONDS = 6 * 3600
Scheduler.HEAT_REARM = 2
Scheduler.WIND_REARM = 10
Scheduler.DRY_SECONDS = 3600
Scheduler.RAIN_EXPECTED_CHANCE = 50

-- `firstTick`: the first minute after start, which catches up (CATCH_UP_SECONDS). `stopped`: Shabbat
-- automation could not run when last looked at (Scheduler.switchesChanged). `pausedSkips`: schedule id
-- -> the run the history says was skipped while paused (once a pause, until the schedules run again).
local state = { services = nil, timer = nil, firstTick = false, stopped = false, pausedSkips = {} }

-- The history: a schedule ran (`fields.counts`, `note`), failed or was skipped (`reason`), with its
-- scene by the name it has now, and its time and days as they are now.
local function remember(schedule, fields)
    local scene = Scenes.find(schedule.scene_id)
    fields.who = { type = "schedule", schedule_id = schedule.id, trigger = schedule.trigger, days = schedule.days }
    fields.what = scene and scene.name or nil
    fields.ids = { schedule_id = schedule.id, scene_id = schedule.scene_id }
    Activity.record("schedule", "run", fields)
end

-- The Jewish calendar service (src/core/jewish_calendar.lua), or nil.
local function calendarService()
    return state.services and state.services.calendar or nil
end

-- Whether Shabbat automation can run: the schedules are not paused, and the calendar is on and has
-- a location.
local function canRun()
    local services = state.services
    if not services or (services.paused and services.paused()) then
        return false
    end
    local calendar = calendarService()
    return calendar ~= nil and calendar.status() == "ok"
end

-- After a change of a Composer switch or of the location (main.lua), and every minute: once Shabbat
-- automation can run again after it could not (the schedules resumed, the calendar turned on or
-- given a location), what was due meanwhile stays missed, also after a restart.
function Scheduler.switchesChanged(now)
    local running = canRun()
    if running and state.stopped then
        Schedules.setCatchUpAfter(now or Clock.now())
    end
    state.stopped = not running
end

-- Seconds from 1970 for a date and time read as UTC (no time zone involved).
local function asUtc(fields)
    local year, month = fields.year, fields.month
    if month <= 2 then
        year, month = year - 1, month + 12
    end
    local days = 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400) + math.floor((153 * (month - 3) + 2) / 5) + fields.day - 719469
    return days * 86400 + (fields.hour or 0) * 3600 + (fields.min or 0) * 60 + (fields.sec or 0)
end

-- The local date of `now`: weekday 0 (Sunday) to 6, minute of the day, and the offset from UTC.
function Scheduler.localTime(now)
    local fields = os.date("*t", now)
    return {
        year = fields.year,
        month = fields.month,
        day = fields.day,
        date = string.format("%04d-%02d-%02d", fields.year, fields.month, fields.day),
        weekday = fields.wday - 1,
        minute = fields.hour * 60 + fields.min,
        offset = math.floor((asUtc(fields) - now) / 60 + 0.5),
    }
end

-- The moment of `minute` on the local date of `info`.
local function epochAt(info, minute)
    return os.time({ year = info.year, month = info.month, day = info.day, hour = math.floor(minute / 60), min = minute % 60, sec = 0 })
end

local function hasDay(schedule, weekday)
    for _, day in ipairs(schedule.days) do
        if day == weekday then
            return true
        end
    end
    return false
end

-- Sunrise and sunset on the local date of `info` (minutes after midnight), or nil.
function Scheduler.sunTimes(info)
    local latitude, longitude = Weather.location()
    if not latitude then
        return nil
    end
    return Sun.times(info.year, info.month, info.day, latitude, longitude, info.offset)
end

-- Dawn and dusk (civil twilight, 1.14.0) on the local date of `info` (minutes after midnight), or
-- nil: no location, or the sun does not go 6° below the horizon that day (the white nights).
function Scheduler.twilight(info)
    local latitude, longitude = Weather.location()
    if not latitude then
        return nil
    end
    return Sun.twilight(info.year, info.month, info.day, latitude, longitude, info.offset)
end

-- The minute of a sun event (sunrise, sunset, dawn or dusk) on the local date of `info`, or nil.
local function sunEvent(event, info)
    if event == "dawn" or event == "dusk" then
        local dawn, dusk = Scheduler.twilight(info)
        if event == "dawn" then
            return dawn
        end
        return dusk
    end
    local sunrise, sunset = Scheduler.sunTimes(info)
    if event == "sunrise" then
        return sunrise
    end
    return sunset
end

-- The minute a time or sun schedule runs on the local date of `info`, or nil (no sunset that
-- day, no location, or an offset that crosses midnight). A sun schedule's earliest and latest times
-- (1.14.0) hold it within them: "at sunset, but not before 17:30" runs at 17:30 while the sun sets
-- earlier, and an offset that would cross midnight runs at the limit before it.
function Scheduler.targetMinute(schedule, info)
    local trigger = schedule.trigger
    if trigger.type == "time" then
        return Schedules.minutes(trigger.at)
    end
    if trigger.type ~= "sun" then
        return nil
    end
    local base = sunEvent(trigger.event, info)
    if not base then
        return nil
    end
    local minute = base + (trigger.offset or 0)
    local earliest, latest = Schedules.minutes(trigger.earliest), Schedules.minutes(trigger.latest)
    if earliest and minute < earliest then
        minute = earliest
    end
    if latest and minute > latest then
        minute = latest
    end
    if minute < 0 or minute >= 1440 then
        return nil
    end
    return minute
end

-- Whether a schedule may run on the local date of `info` as far as the home's own holidays go
-- (1.14.0), why not, and the holiday: "holiday" (skipped: it is one) or "not_holiday" (only on
-- them, and it is not).
local function holidayAllows(schedule, info)
    local mode = schedule.on_holidays or "run"
    if mode == "run" then
        return true
    end
    local holiday = HomeHolidays.on(info.year, info.month, info.day)
    if mode == "skip" then
        return holiday == nil, "holiday", holiday
    end
    return holiday ~= nil, "not_holiday", holiday
end

-- The key a time or sun schedule's run on a local date is remembered by (`last_fired`).
local function runKey(info, minute)
    return info.date .. "@" .. minute
end

-- Whether a skipped run (`skipKey`) is the run `key`: a time or sun schedule's run of the same
-- local date (its minute may have moved since, with the sun or the location), a Shabbat schedule's
-- of the same period, or a weather rule's next.
local function sameRun(skipKey, key)
    if skipKey == key then
        return true
    end
    local skipDate, date = skipKey:match("^(.-)@"), key:match("^(.-)@")
    return skipDate ~= nil and skipDate == date
end

-- Whether a schedule may run at `at` as far as Shabbat and holidays go (holy time is from candle
-- lighting to havdalah), and why not: "shabbat" (skipped: holy time), "not_shabbat" (only then,
-- and it is not) or "calendar" (off, or no location: no moment counts as holy).
local function shabbatAllows(schedule, calendar, at)
    local mode = schedule.during_shabbat or "run"
    if mode == "run" then
        return true
    end
    local holy = calendar and calendar.holyAt(at)
    if holy == nil then
        return mode == "skip", "calendar"
    end
    if mode == "skip" then
        return not holy, "shabbat"
    end
    return holy, "not_shabbat"
end

-- The local date of a day number of the calendar, at noon.
local function localDate(calendar, rd)
    local year, month, day = calendar.civilDate(rd)
    return Scheduler.localTime(os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 }))
end

-- A Shabbat schedule's moment in a period: its begin (candle lighting) or end (havdalah) plus the
-- offset, and the key it runs under, once per period. nil in a period that lacks a sunset
-- (`approximate`), even when this one time happens: a begin whose end never comes would leave the
-- home in Shabbat mode until the sun sets again, weeks later.
local function shabbatMoment(schedule, calendar, period)
    local trigger = schedule.trigger
    local base = trigger.event == "candle_lighting" and period.starts_at or period.ends_at
    if not base or period.approximate then
        return nil
    end
    return base + (trigger.offset or 0) * 60, "shabbat:" .. calendar.dateKey(period.first) .. ":" .. trigger.event
end

-- When a schedule runs next (seconds from 1970) and the key of that run, or nil: a time or sun
-- schedule by its minute (not in holy time with "skip", only then with "only"; not on the home's
-- holidays with on_holidays "skip", only on them with "only"), a Shabbat schedule by the holy
-- periods. The run a person skipped is passed over, unless `ignoreSkip`.
function Scheduler.upcoming(schedule, now, ignoreSkip)
    if schedule.enabled == false or schedule.trigger.type == "weather" then
        return nil
    end
    local skip = not ignoreSkip and Schedules.runtime(schedule.id).skip or nil
    local function wanted(key)
        return skip == nil or not sameRun(skip.key, key)
    end
    local calendar = calendarService()
    local mode = schedule.during_shabbat or "run"
    local holidays = schedule.on_holidays or "run"
    if holidays == "only" and HomeHolidays.count() == 0 then
        return nil
    end
    if schedule.trigger.type == "shabbat" or mode == "only" then
        if not calendar or calendar.status() ~= "ok" then
            return nil
        end
        local lastFired = Schedules.runtime(schedule.id).last_fired
        for _, period in ipairs(calendar.periodsBetween(now - 86400, now + 400 * 86400)) do
            if schedule.trigger.type == "shabbat" then
                local at, key = shabbatMoment(schedule, calendar, period)
                if at and at > now and key ~= lastFired and hasDay(schedule, os.date("*t", at).wday - 1) and wanted(key) then
                    return at, key
                end
            else
                -- Each civil day of the period, the evening before it, and the night after it (far
                -- north in summer, havdalah may come after midnight), at the schedule's minute.
                for rd = period.first - 1, period.last + 1 do
                    local info = localDate(calendar, rd)
                    if hasDay(schedule, info.weekday) and holidayAllows(schedule, info) then
                        local minute = Scheduler.targetMinute(schedule, info)
                        local at = minute and epochAt(info, minute)
                        if at and at > now and calendar.holyAt(at) and wanted(runKey(info, minute)) then
                            return at, runKey(info, minute)
                        end
                    end
                end
            end
        end
        return nil
    end
    local today = Scheduler.localTime(now)
    -- Three weeks for one that skips holy time: a weekly one may fall on holidays two weeks running.
    -- With the home's holidays, up to a year and a bit: a holiday may last a year, and one that runs
    -- only on them waits for the next. A skipped run adds a week.
    local horizon = mode == "skip" and 20 or 7
    if holidays ~= "run" then
        horizon = 400
    elseif skip then
        horizon = horizon + 7
    end
    for add = 0, horizon do
        -- By calendar date, at noon, so a daylight saving change never skips or repeats a day.
        local info = Scheduler.localTime(os.time({ year = today.year, month = today.month, day = today.day + add, hour = 12, min = 0, sec = 0 }))
        if hasDay(schedule, info.weekday) and holidayAllows(schedule, info) then
            local minute = Scheduler.targetMinute(schedule, info)
            local at = minute and epochAt(info, minute)
            if at and at > now and shabbatAllows(schedule, calendar, at) and wanted(runKey(info, minute)) then
                return at, runKey(info, minute)
            end
        end
    end
    return nil
end

-- When a schedule runs next (seconds from 1970), or nil (Scheduler.upcoming).
function Scheduler.nextRun(schedule, now)
    return (Scheduler.upcoming(schedule, now))
end

-- Skips a schedule's next run (1.14.0): the one Scheduler.nextRun says now, or a weather rule's next
-- time. Once that run comes due it does not run, and the history says a person skipped it. One at a
-- time: asked again, the same run stays skipped. Returns the skip ({ key, at }), or nil and why:
-- "OFF" (switched off) or "NO_NEXT_RUN".
function Scheduler.skipNext(schedule, now)
    if schedule.enabled == false then
        return nil, "OFF"
    end
    local runtime = Schedules.runtime(schedule.id)
    if runtime.skip then
        return runtime.skip
    end
    local skip
    if schedule.trigger.type == "weather" then
        skip = { key = "weather" }
    else
        local at, key = Scheduler.upcoming(schedule, now, true)
        if not at then
            return nil, "NO_NEXT_RUN"
        end
        skip = { key = key, at = at }
    end
    runtime.skip = skip
    Schedules.saveRuntime()
    return skip
end

-- Runs the skipped run after all. Returns whether there was one.
function Scheduler.cancelSkip(schedule)
    local runtime = Schedules.runtime(schedule.id)
    if not runtime.skip then
        return false
    end
    runtime.skip = nil
    Schedules.saveRuntime()
    return true
end

-- True or false for a time or sun schedule's "only if" with this weather, or nil when it needs
-- weather and there is none. The threshold itself counts (1.10.1, ADR-074): "hotter_than 23" is 23°
-- or warmer, "wind_below 20" 20 km/h or less.
function Scheduler.conditionsMet(schedule, weather)
    local onlyIf = schedule.only_if or {}
    if next(onlyIf) == nil then
        return true
    end
    if not weather then
        return nil
    end
    if onlyIf.not_raining and weather.raining then
        return false
    end
    if onlyIf.hotter_than and not (weather.temperature >= onlyIf.hotter_than) then
        return false
    end
    if onlyIf.wind_below and not (weather.wind_speed and weather.wind_speed <= onlyIf.wind_below) then
        return false
    end
    if onlyIf.rain_expected and not ((weather.today.rain_chance or 0) >= Scheduler.RAIN_EXPECTED_CHANCE) then
        return false
    end
    return true
end

local function inHours(trigger, minute)
    if not trigger.from then
        return true
    end
    local from, to = Schedules.minutes(trigger.from), Schedules.minutes(trigger.to)
    if from < to then
        return minute >= from and minute < to
    end
    -- Across midnight, e.g. 22:00 to 06:00.
    return minute >= from or minute < to
end

-- Whether a run left an AC off because its last mode is not known yet (On, as it was: ADR-070).
local function leftOff(result)
    for _, problem in ipairs(type(result) == "table" and type(result.problems) == "table" and result.problems or {}) do
        if type(problem) == "table" and problem.code == "NO_LAST_MODE" then
            return true
        end
    end
    return false
end

local function run(schedule, now, note, weather)
    local runtime = Schedules.runtime(schedule.id)
    local ok, result, failure = pcall(state.services.runScene, schedule.scene_id, { id = "schedule:" .. schedule.id, role = "member" })
    if not ok then
        result, failure = nil, "FAILED: " .. tostring(result)
    end
    local lastRun = { at = Clock.iso(now), note = note }
    if result then
        lastRun.ran, lastRun.skipped, lastRun.failed = result.ran, result.skipped, result.failed
    else
        lastRun.error = failure or "FAILED"
    end
    runtime.last_run = lastRun
    remember(schedule, {
        outcome = lastRun.error and "failed" or nil,
        reason = lastRun.error and (lastRun.error == "SCENE_NOT_FOUND" and "scene_gone" or "error") or nil,
        note = note,
        counts = result,
    })
    if state.services.onRun then
        pcall(state.services.onRun, { at = now, scene_id = schedule.scene_id, schedule = schedule, weather = weather, note = note, result = result, error = lastRun.error })
    end
    Log.info("schedules", "schedule ran", {
        schedule = schedule.id,
        scene = schedule.scene_id,
        note = note or Json.null,
        -- The weather that decided it: the forecast read then (ADR-071).
        forecast_from = weather and weather.saved_at and Clock.iso(weather.saved_at) or Json.null,
        ran = lastRun.ran or 0,
        skipped = lastRun.skipped or 0,
        failed = lastRun.failed or 0,
        error = lastRun.error or Json.null,
    })
    -- A device refused, the scene could not run, or it left an AC off whose last mode is not known
    -- yet (1.10.0, ADR-070): the home's admins are alerted, once a run (ADR-047), with the scene's
    -- name sealed to them (ADR-050).
    if state.services.onFailed and (lastRun.error or (lastRun.failed or 0) > 0 or leftOff(result)) then
        local scene = Scenes.find(schedule.scene_id)
        pcall(state.services.onFailed, now, { what = scene and scene.name or nil })
    end
end

-- Sets `runtime.armed` from the reading: false while the weather still is past its threshold
-- after running, true again once it has turned back: to 2° below a heat rule's threshold or cooler,
-- 10 km/h below a wind rule's or calmer (the threshold counts, 1.10.1).
local function rearm(trigger, runtime, weather, now)
    if trigger.kind == "heat" then
        if weather.temperature <= trigger.above - Scheduler.HEAT_REARM then
            runtime.armed = true
        end
    elseif trigger.kind == "wind" then
        if weather.wind_speed and weather.wind_speed <= trigger.above - Scheduler.WIND_REARM then
            runtime.armed = true
        end
    else
        if weather.raining then
            runtime.dry_since = nil
        else
            runtime.dry_since = runtime.dry_since or now
            if now - runtime.dry_since >= Scheduler.DRY_SECONDS then
                runtime.armed = true
            end
        end
    end
end

-- `above` or hotter, `above` km/h or a stronger wind (as since 0.14.0), or raining.
local function weatherActive(trigger, weather)
    if trigger.kind == "heat" then
        return weather.temperature >= trigger.above
    elseif trigger.kind == "wind" then
        return weather.wind_speed ~= nil and weather.wind_speed >= trigger.above
    end
    return weather.raining == true
end

-- The day before `info` (its noon), for times just before midnight and night-time hours.
local function dayBefore(info)
    return Scheduler.localTime(os.time({ year = info.year, month = info.month, day = info.day - 1, hour = 12, min = 0, sec = 0 }))
end

-- Whether a run whose moment is `at` is due at `now`, and whether it is late: at most GRACE_MINUTES
-- after it, or, in the first minute after a restart, CATCH_UP_SECONDS for a moment not before
-- `catchUp` (Schedules.catchUpAfter; nil: no catch-up now).
local function dueAt(at, now, catchUp)
    if now < at then
        return false, false
    end
    if now < at + Scheduler.GRACE_MINUTES * 60 then
        return true, false
    end
    return catchUp ~= nil and at >= catchUp and now < at + Scheduler.CATCH_UP_SECONDS, true
end

-- A time or sun schedule due at `now`: its run today, or yesterday's just before midnight (dueAt).
-- Returns the key of that run, its moment, whether it is late (past the grace time), and its day.
local function dueRun(schedule, info, now, catchUp)
    for _, day in ipairs({ info, dayBefore(info) }) do
        if hasDay(schedule, day.weekday) then
            local minute = Scheduler.targetMinute(schedule, day)
            -- On the day clocks go forward, a time that does not exist runs when it would have.
            local at = minute and epochAt(day, minute)
            if at then
                local due, late = dueAt(at, now, catchUp)
                if due then
                    return runKey(day, minute), at, late, day
                end
            end
        end
    end
    return nil
end

-- A Shabbat schedule due at `now` (dueAt): when a holy period began or ended, plus the offset, on
-- one of its days (the local weekday of that moment). Returns the key of that run (the period's
-- first holy date and the event, so it runs once per period whatever changes), its moment, and
-- whether it is late.
local function dueShabbat(schedule, calendar, now, catchUp)
    if not calendar or calendar.status() ~= "ok" then
        return nil
    end
    for _, period in ipairs(calendar.periodsBetween(now - 2 * 86400, now + 86400)) do
        local at, key = shabbatMoment(schedule, calendar, period)
        if at and hasDay(schedule, os.date("*t", at).wday - 1) then
            local due, late = dueAt(at, now, catchUp)
            if due then
                return key, at, late
            end
        end
    end
    return nil
end

-- While the schedules are paused in Composer: the history says which time, sun and Shabbat schedules
-- did not run because of it, once a schedule for the pause, when its first run comes due (and not one
-- that would not have run anyway, on Shabbat). The pause itself is an entry too (a Composer setting),
-- and two weeks away with many daily schedules would otherwise push everything else out of the
-- history (ADR-046). Nothing is remembered as done: resumed within its 5 minutes, it still runs.
local function notePaused(now)
    local calendar = calendarService()
    local info = Scheduler.localTime(now)
    for _, schedule in ipairs(Schedules.records()) do
        if schedule.enabled ~= false and schedule.trigger.type ~= "weather" then
            local key, at, day
            if schedule.trigger.type == "shabbat" then
                key, at = dueShabbat(schedule, calendar, now, nil)
            else
                key, at, _, day = dueRun(schedule, info, now, nil)
            end
            if key and key ~= Schedules.runtime(schedule.id).last_fired and state.pausedSkips[schedule.id] == nil
                and (schedule.updated_epoch or 0) <= at and shabbatAllows(schedule, calendar, at) and (day == nil or holidayAllows(schedule, day)) then
                state.pausedSkips[schedule.id] = key
                remember(schedule, { outcome = "skipped", reason = "paused" })
            end
        end
    end
end

-- One pass over the schedules for the minute of `now`. Returns how many ran. While paused in
-- Composer nothing runs and nothing is remembered as done.
function Scheduler.tick(now)
    now = now or Clock.now()
    local firstTick = state.firstTick
    state.firstTick = false
    if state.services and state.services.onTick then
        pcall(state.services.onTick, now)
    end
    Scheduler.switchesChanged(now)
    -- Only the first minute after start catches up, also when it finds the schedules paused, and
    -- only what came due after they could last run: what was due while paused, or while the
    -- calendar was off or had no location, never runs afterwards.
    local catchUp = firstTick and (Schedules.catchUpAfter() or 0) or nil
    if state.services and state.services.paused and state.services.paused() then
        notePaused(now)
        return 0
    end
    -- Running again: the next pause is listed again.
    if next(state.pausedSkips) then
        state.pausedSkips = {}
    end
    local calendar = calendarService()
    local info = Scheduler.localTime(now)
    local records = Schedules.records()
    local needsWeather = false
    for _, schedule in ipairs(records) do
        if schedule.enabled ~= false and Schedules.usesWeather(schedule) then
            needsWeather = true
        end
    end
    Weather.tick(needsWeather, now)
    local weather = Weather.current(now)
    -- A reading on its way (just after a restart): conditions wait for it, within the grace time.
    local weatherComing = not weather and Weather.pending()
    local ran, changed, due = 0, false, {}
    for _, schedule in ipairs(records) do
        local runtime = Schedules.runtime(schedule.id)
        local trigger = schedule.trigger
        if schedule.enabled == false then
            -- Nothing.
        elseif trigger.type == "weather" then
            if weather then
                local armedBefore, drySince, windowBefore = runtime.armed, runtime.dry_since, runtime.window_day
                if runtime.armed == nil then
                    runtime.armed = true
                end
                rearm(trigger, runtime, weather, now)
                -- Hours across midnight (22:00 to 06:00) belong to the day they started.
                local day = info
                if trigger.from and Schedules.minutes(trigger.from) > Schedules.minutes(trigger.to) and info.minute < Schedules.minutes(trigger.to) then
                    day = dayBefore(info)
                end
                -- A rule with hours is ready again when its hours begin each day (1.10.0): "08:00 to
                -- 23:00, hotter than 23°" runs each day from 08:00 once it is that hot, whatever the
                -- night was like. A rule that already ran today before 1.10.0 kept no such day: it
                -- is not made ready again the same day.
                if trigger.from and inHours(trigger, info.minute) and runtime.window_day ~= day.date then
                    if not (runtime.window_day == nil and runtime.fired_day == day.date) then
                        runtime.armed = true
                    end
                    runtime.window_day = day.date
                end
                local onceDone = trigger.once_a_day ~= false and runtime.fired_day == day.date
                -- Held back in holy time ("skip"), a rule stays armed: it runs after havdalah if
                -- the weather still passes. So on the home's holidays (1.14.0), by the day its hours
                -- belong to.
                if runtime.armed and weatherActive(trigger, weather) and hasDay(schedule, day.weekday) and inHours(trigger, info.minute) and not onceDone and shabbatAllows(schedule, calendar, now) and holidayAllows(schedule, day) then
                    runtime.armed = false
                    runtime.dry_since = nil
                    runtime.fired_day = day.date
                    if runtime.skip and runtime.skip.key == "weather" then
                        -- A person skipped its next run (1.14.0): this is it, as if it had run.
                        runtime.skip = nil
                        runtime.last_run = { at = Clock.iso(now), skipped_by = "skip" }
                        Log.info("schedules", "schedule skipped: its next run was skipped", { schedule = schedule.id })
                        remember(schedule, { outcome = "skipped", reason = "skip" })
                        changed = true
                    else
                        -- Runs with the minute's others, after them (below).
                        due[#due + 1] = { schedule = schedule, at = now, note = trigger.kind, weather = weather, reacts = true }
                    end
                end
                changed = changed or runtime.armed ~= armedBefore or runtime.dry_since ~= drySince or runtime.window_day ~= windowBefore
            end
        else
            local key, at, late, day
            if trigger.type == "shabbat" then
                key, at, late = dueShabbat(schedule, calendar, now, catchUp)
            else
                -- Caught up after a restart: those only on Shabbat and holidays, and since 1.14.0
                -- those set to run late.
                local catchesUp = schedule.during_shabbat == "only" or schedule.run_late == true
                key, at, late, day = dueRun(schedule, info, now, catchesUp and catchUp or nil)
            end
            local waitForWeather = key and weatherComing and next(schedule.only_if or {}) ~= nil and now < at + (Scheduler.GRACE_MINUTES - 1) * 60
            if key and runtime.last_fired ~= key and not waitForWeather then
                runtime.last_fired = key
                changed = true
                -- Changed after its time: it starts with the next one.
                if (schedule.updated_epoch or 0) <= at then
                    -- Holy time at the schedule's moment, not now: 17:59 checked at 18:01 is 17:59.
                    local allowed, why = shabbatAllows(schedule, calendar, at)
                    -- The home's holidays by the run's own day (1.14.0).
                    local onHoliday, holidayWhy, holiday = true, nil, nil
                    if day then
                        onHoliday, holidayWhy, holiday = holidayAllows(schedule, day)
                    end
                    local skipped = allowed and onHoliday and runtime.skip ~= nil and sameRun(runtime.skip.key, key)
                    local met = allowed and onHoliday and not skipped and Scheduler.conditionsMet(schedule, weather)
                    if skipped then
                        -- A person skipped this run (1.14.0).
                        runtime.skip = nil
                        runtime.last_run = { at = Clock.iso(now), skipped_by = "skip" }
                        Log.info("schedules", "schedule skipped: its next run was skipped", { schedule = schedule.id })
                        remember(schedule, { outcome = "skipped", reason = "skip" })
                    elseif allowed and not onHoliday then
                        -- Not on the home's holidays, and it is one: skipped, and said. Only on them,
                        -- and it is not one: like a day not in its days, nothing to say.
                        if holidayWhy == "holiday" then
                            runtime.last_run = { at = Clock.iso(now), skipped_by = "holiday" }
                            Log.info("schedules", "schedule skipped: a holiday", { schedule = schedule.id })
                            remember(schedule, { outcome = "skipped", reason = "holiday", note = holiday and holiday.name or nil })
                        end
                    elseif not allowed then
                        -- "only" outside holy time, or without the calendar, is like a day not in
                        -- its days: nothing to say.
                        if why == "shabbat" then
                            runtime.last_run = { at = Clock.iso(now), skipped_by = "shabbat" }
                            Log.info("schedules", "schedule skipped: Shabbat or a holiday", { schedule = schedule.id })
                            remember(schedule, { outcome = "skipped", reason = "shabbat" })
                        elseif why == "calendar" then
                            -- Only on Shabbat, and the calendar is off or has no location: the
                            -- history says so (the schedule cannot run while it is).
                            remember(schedule, { outcome = "skipped", reason = "calendar_off" })
                        end
                    elseif met == nil then
                        if schedule.if_no_weather ~= "skip" then
                            due[#due + 1] = { schedule = schedule, at = at, note = late and "late" or "no_weather" }
                        else
                            runtime.last_run = { at = Clock.iso(now), skipped_by = "no_weather" }
                            remember(schedule, { outcome = "skipped", reason = "no_weather" })
                        end
                    elseif met then
                        local decided = next(schedule.only_if or {}) ~= nil and weather or nil
                        due[#due + 1] = { schedule = schedule, at = at, note = late and "late" or nil, weather = decided }
                    else
                        runtime.last_run = { at = Clock.iso(now), skipped_by = "only_if" }
                        Log.info("schedules", "schedule skipped: its conditions were not met", { schedule = schedule.id, forecast_from = Clock.iso(weather.saved_at or now) })
                        remember(schedule, { outcome = "skipped", reason = "only_if" })
                    end
                end
            end
        end
        -- A skipped run that never came due (switched off, paused, or changed meanwhile) is
        -- forgotten once it could no longer be caught up.
        if runtime.skip and runtime.skip.at and now >= runtime.skip.at + Scheduler.CATCH_UP_SECONDS then
            runtime.skip = nil
            changed = true
        end
    end
    -- In the order they were due: after a restart, what is caught up runs oldest first. Weather
    -- rules run last (1.10.0): they react to the weather now, so a time, sun or Shabbat schedule of
    -- the same minute (a morning scene at 08:30, when a rule's hours begin) cannot undo what they did.
    table.sort(due, function(a, b)
        if (a.reacts == true) ~= (b.reacts == true) then
            return b.reacts == true
        end
        if a.at ~= b.at then
            return a.at < b.at
        end
        return a.schedule.id < b.schedule.id
    end)
    for _, item in ipairs(due) do
        if item.note == "late" then
            Log.info("schedules", "schedule caught up after a restart", { schedule = item.schedule.id, due_at = Clock.iso(item.at) })
        end
        run(item.schedule, now, item.note, item.weather)
        ran = ran + 1
    end
    if ran > 0 or changed then
        Schedules.saveRuntime()
    end
    return ran
end

-- ---- The next days (1.14.0, GET /v1/schedules/week) ---------------------------------------

-- What a run at `at` (seconds from 1970) is in the next days: "skipped" and why ("off", "paused",
-- "skip"), "past" (its time has passed) or "planned". A run judged by the holidays or Shabbat is
-- given its reason by the caller.
local function runStatus(schedule, runtime, key, at, now, paused)
    if schedule.enabled == false then
        return "skipped", "off"
    end
    if at <= now then
        return "past"
    end
    if paused then
        return "skipped", "paused"
    end
    if runtime.skip and sameRun(runtime.skip.key, key) then
        return "skipped", "skip"
    end
    return "planned"
end

-- The next `count` local days from today: for each, its local date (`info`), the holiday of the
-- home that day, and each schedule's runs that day (`runs`: { schedule, at, status, reason }), or
-- why one of its days has none. A weather rule's day has no time (`status` "weather"), and is
-- listed only while its weather may come in its hours, as far as the saved forecast reaches
-- (1.14.1, weatherMayCome). A schedule with "only if" is planned, and runs if the weather then
-- allows.
-- Days a schedule does not run on at all (not in its days; only on Shabbat or the home's holidays,
-- and it is not) have nothing for it.
-- A weather rule's Shabbat setting over a day's hours (the whole day without hours; hours across
-- midnight end the next day), as the tick holds it to the moment the weather turns: "run" when it
-- may run in some of them; "shabbat" when it keeps away from Shabbat and holidays and all of them
-- are holy; nil when it runs only then and none of them is (nor while the calendar is off, as
-- shabbatAllows).
local function weatherShabbat(schedule, calendar, info)
    local mode = schedule.during_shabbat or "run"
    if mode == "run" then
        return "run"
    end
    if not calendar or calendar.status() ~= "ok" then
        return mode == "skip" and "run" or nil
    end
    local trigger = schedule.trigger
    local from, to = 0, 24 * 60
    if trigger.from then
        from, to = Schedules.minutes(trigger.from), Schedules.minutes(trigger.to)
        if from >= to then
            to = to + 24 * 60
        end
    end
    local first = os.time({ year = info.year, month = info.month, day = info.day, hour = 0, min = from, sec = 0 })
    local last = os.time({ year = info.year, month = info.month, day = info.day, hour = 0, min = to, sec = 0 }) - 1
    local periods = calendar.periodsBetween(first, last)
    if mode == "only" then
        return #periods > 0 and "run" or nil
    end
    -- One period over all of them: two would leave a gap between them.
    if #periods == 1 and calendar.holyAt(first) and calendar.holyAt(last) then
        return "shabbat"
    end
    return "run"
end

-- A quarter of an hour: every time zone's whole hours fall on it.
local QUARTER = 15 * 60

-- Whether a weather rule's weather may still come in its hours on `info` (the whole day without
-- hours; hours across midnight end the next day), as the tick reacts to it: past its threshold
-- (weatherActive) at a moment its Shabbat setting allows (shabbatAllows). False only when the
-- saved forecast holds every moment of them still to come that it may run at and none passes, or
-- none is to come and it has not run that day; true when one may pass, when the forecast does not
-- reach them (the weather is not known yet), and on a day it ran (1.14.1). The forecast's
-- temperature and wind are straight lines between its hours, and its rain and code change at them,
-- so these moments decide: the hours' first and last minute, every whole hour between (on a
-- quarter-hour grid, which holds them in every time zone), and the minute before each edge of holy
-- time and the edge itself.
local function weatherMayCome(schedule, runtime, calendar, info, now)
    if runtime.fired_day == info.date then
        return true
    end
    local trigger = schedule.trigger
    local from, to = 0, 24 * 60
    if trigger.from then
        from, to = Schedules.minutes(trigger.from), Schedules.minutes(trigger.to)
        if from >= to then
            to = to + 24 * 60
        end
    end
    local first = math.max(epochAt(info, from), now)
    local last = epochAt(info, to) - 60
    if first > last then
        return false
    end
    local moments = { first, last }
    for moment = first - first % QUARTER + QUARTER, last, QUARTER do
        moments[#moments + 1] = moment
    end
    if (schedule.during_shabbat or "run") ~= "run" and calendar and calendar.status() == "ok" then
        for _, period in ipairs(calendar.periodsBetween(first, last)) do
            for _, edge in ipairs({ period.starts_at or first, period.ends_at or last }) do
                for _, moment in ipairs({ edge - 60, edge }) do
                    if moment >= first and moment <= last then
                        moments[#moments + 1] = moment
                    end
                end
            end
        end
    end
    -- Only the moments it may run at count, so a day is decided as soon as the forecast reaches them.
    local known = true
    for _, moment in ipairs(moments) do
        if shabbatAllows(schedule, calendar, moment) then
            local weather = Weather.current(moment)
            if not weather then
                known = false
            elseif weatherActive(trigger, weather) then
                return true
            end
        end
    end
    return not known
end

function Scheduler.week(now, count)
    local calendar = calendarService()
    local paused = state.services ~= nil and state.services.paused ~= nil and state.services.paused() == true
    local today = Scheduler.localTime(now)
    local days, byDate = {}, {}
    for add = 0, count - 1 do
        local info = Scheduler.localTime(os.time({ year = today.year, month = today.month, day = today.day + add, hour = 12, min = 0, sec = 0 }))
        local day = { info = info, runs = {}, holiday = HomeHolidays.on(info.year, info.month, info.day) }
        days[#days + 1] = day
        byDate[info.date] = day
    end
    local from = os.time({ year = today.year, month = today.month, day = today.day, hour = 0, min = 0, sec = 0 })
    local to = os.time({ year = today.year, month = today.month, day = today.day + count, hour = 0, min = 0, sec = 0 })
    for _, schedule in ipairs(Schedules.records()) do
        local runtime = Schedules.runtime(schedule.id)
        local trigger = schedule.trigger
        if trigger.type == "shabbat" then
            -- While the calendar is off or has no location there are no moments (calendar_status).
            if calendar and calendar.status() == "ok" then
                for _, period in ipairs(calendar.periodsBetween(from - 2 * 86400, to + 86400)) do
                    local at, key = shabbatMoment(schedule, calendar, period)
                    local day = at and at >= from and at < to and byDate[Scheduler.localTime(at).date]
                    if day and hasDay(schedule, os.date("*t", at).wday - 1) then
                        local status, reason = runStatus(schedule, runtime, key, at, now, paused)
                        day.runs[#day.runs + 1] = { schedule = schedule, at = at, status = status, reason = reason }
                    end
                end
            end
        else
            for _, day in ipairs(days) do
                local info = day.info
                if hasDay(schedule, info.weekday) then
                    local onHoliday, holidayWhy = holidayAllows(schedule, info)
                    local entry
                    if trigger.type == "weather" then
                        local shabbat = onHoliday and weatherShabbat(schedule, calendar, info) or nil
                        if shabbat == "shabbat" then
                            entry = { schedule = schedule, status = "skipped", reason = "shabbat" }
                        elseif shabbat then
                            local status, reason = "weather", nil
                            if schedule.enabled == false then
                                status, reason = "skipped", "off"
                            elseif paused then
                                status, reason = "skipped", "paused"
                            end
                            -- Not listed on a day the forecast says its weather will not come
                            -- (1.14.1).
                            if status ~= "weather" or weatherMayCome(schedule, runtime, calendar, info, now) then
                                entry = { schedule = schedule, status = status, reason = reason }
                            end
                        elseif not onHoliday and holidayWhy == "holiday" then
                            entry = { schedule = schedule, status = "skipped", reason = "holiday" }
                        end
                    else
                        local minute = Scheduler.targetMinute(schedule, info)
                        if not minute then
                            -- No sunrise or sunset (or no dawn or dusk) that day, no location, or an
                            -- offset across midnight.
                            if onHoliday then
                                entry = { schedule = schedule, status = "skipped", reason = "no_sun" }
                            end
                        else
                            local at = epochAt(info, minute)
                            local allowed, why = shabbatAllows(schedule, calendar, at)
                            if not onHoliday then
                                if holidayWhy == "holiday" then
                                    entry = { schedule = schedule, at = at, status = "skipped", reason = "holiday" }
                                end
                            elseif not allowed then
                                if why == "shabbat" then
                                    entry = { schedule = schedule, at = at, status = "skipped", reason = "shabbat" }
                                end
                            else
                                local status, reason = runStatus(schedule, runtime, runKey(info, minute), at, now, paused)
                                entry = { schedule = schedule, at = at, status = status, reason = reason }
                            end
                        end
                    end
                    if entry then
                        day.runs[#day.runs + 1] = entry
                    end
                end
            end
        end
    end
    -- By time; a day's weather rules, and runs without a time, after them.
    for _, day in ipairs(days) do
        table.sort(day.runs, function(a, b)
            if (a.at ~= nil) ~= (b.at ~= nil) then
                return a.at ~= nil
            end
            if a.at and a.at ~= b.at then
                return a.at < b.at
            end
            return a.schedule.id < b.schedule.id
        end)
    end
    return days
end

-- Shabbat and holidays on a local day (`info`), with the Jewish calendar on: { starts_at, ends_at }
-- for the holy time that begins or ends that day (each nil when it does not), or nil when none of
-- the day is holy.
function Scheduler.holyOn(info)
    local calendar = calendarService()
    if not calendar or calendar.status() ~= "ok" then
        return nil
    end
    local dayStart = os.time({ year = info.year, month = info.month, day = info.day, hour = 0, min = 0, sec = 0 })
    local dayEnd = os.time({ year = info.year, month = info.month, day = info.day + 1, hour = 0, min = 0, sec = 0 })
    local holy = nil
    for _, period in ipairs(calendar.periodsBetween(dayStart, dayEnd - 1)) do
        holy = holy or {}
        if period.starts_at and period.starts_at >= dayStart and period.starts_at < dayEnd then
            holy.starts_at = period.starts_at
        end
        if period.ends_at and period.ends_at >= dayStart and period.ends_at < dayEnd then
            holy.ends_at = period.ends_at
        end
    end
    return holy
end

local function scheduleNext()
    local now = Clock.now()
    -- A second after the next minute starts.
    local delay = (60 - now % 60 + 1) * 1000
    local ok, timer = pcall(function()
        return C4:SetTimer(delay, function()
            state.timer = nil
            local ran, err = pcall(Scheduler.tick)
            if not ran then
                Log.error("schedules", "the scheduler failed", { error = tostring(err) })
            end
            scheduleNext()
        end)
    end)
    state.timer = ok and timer or nil
end

-- `services.runScene(sceneId, caller)` runs a saved scene and returns its result;
-- `services.calendar` is the Jewish calendar (src/core/jewish_calendar.lua);
-- `services.onFailed(at, { what })`, if any, is told of each run that failed (a device refused, or
-- an error) or left an AC off with no last mode known, with its scene's name.
function Scheduler.start(services)
    state.services = services
    state.firstTick = true
    -- As the Composer switches are now (not the location, in case it is read a moment late): only
    -- a change from here on stops the catch-up.
    local calendar = calendarService()
    state.stopped = (services.paused ~= nil and services.paused()) or calendar == nil or calendar.status() == "off"
    Scheduler.stop()
    local now = Clock.now()
    local info = Scheduler.localTime(now)
    local ok, zone = pcall(function()
        return C4:GetTimeZone()
    end)
    Log.info("schedules", "scheduler started", {
        local_time = os.date("%Y-%m-%d %H:%M", now),
        utc_offset_minutes = info.offset,
        timezone = ok and zone or Json.null,
        schedules = #Schedules.records(),
    })
    scheduleNext()
end

function Scheduler.stop()
    if state.timer then
        pcall(function()
            state.timer:Cancel()
        end)
        state.timer = nil
    end
end

return Scheduler
