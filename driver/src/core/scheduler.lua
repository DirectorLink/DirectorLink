-- Runs the schedules (src/core/schedules.lua, docs/SCHEDULES.md) on the controller, once a minute,
-- in the controller's local time.
-- - Time and sun schedules run at their minute on their days (up to 5 minutes late, e.g. after a
--   restart), once; an "only if" is checked then, with the latest weather.
-- - Weather schedules run when the weather turns: hotter than the threshold, wind stronger than it,
--   or rain starting; on their days, within their hours, and (by default) at most once a day. They
--   run again only after it has cooled 2° below the threshold, the wind has dropped 10 km/h below
--   it, or it has been dry for an hour.
-- A scheduled scene runs like one from a member's key: doors and gates in it are skipped.
-- The installer can pause them all in Composer (the Schedules property); each run is shown in the
-- Last Automation property (src/core/installer_view.lua).

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Schedules = require("src.core.schedules")
local Sun = require("src.core.sun")
local Weather = require("src.core.weather")

local Scheduler = {}

Scheduler.GRACE_MINUTES = 5
Scheduler.HEAT_REARM = 2
Scheduler.WIND_REARM = 10
Scheduler.DRY_SECONDS = 3600
Scheduler.RAIN_EXPECTED_CHANCE = 50

local state = { services = nil, timer = nil }

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

-- The minute a time or sun schedule runs on the local date of `info`, or nil (no sunset that
-- day, no location, or an offset that crosses midnight).
function Scheduler.targetMinute(schedule, info)
    local trigger = schedule.trigger
    if trigger.type == "time" then
        return Schedules.minutes(trigger.at)
    end
    if trigger.type ~= "sun" then
        return nil
    end
    local sunrise, sunset = Scheduler.sunTimes(info)
    local base = trigger.event == "sunrise" and sunrise or sunset
    if not base then
        return nil
    end
    local minute = base + (trigger.offset or 0)
    if minute < 0 or minute >= 1440 then
        return nil
    end
    return minute
end

-- Shabbat triggers and "only on Shabbat and holidays" wait for the Jewish calendar (ADR-037): until
-- it works out holy times (1.2.0), no moment counts as holy, as while it is off, so they never run.
local function waitsForCalendar(schedule)
    return schedule.trigger.type == "shabbat" or schedule.during_shabbat == "only"
end

-- When a time or sun schedule runs next (seconds from 1970), or nil.
function Scheduler.nextRun(schedule, now)
    if schedule.enabled == false or schedule.trigger.type == "weather" or waitsForCalendar(schedule) then
        return nil
    end
    local today = Scheduler.localTime(now)
    for add = 0, 7 do
        -- By calendar date, at noon, so a daylight saving change never skips or repeats a day.
        local info = Scheduler.localTime(os.time({ year = today.year, month = today.month, day = today.day + add, hour = 12, min = 0, sec = 0 }))
        if hasDay(schedule, info.weekday) then
            local minute = Scheduler.targetMinute(schedule, info)
            local at = minute and epochAt(info, minute)
            if at and at > now then
                return at
            end
        end
    end
    return nil
end

-- True or false for a time or sun schedule's "only if" with this weather, or nil when it needs
-- weather and there is none.
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
    if onlyIf.hotter_than and not (weather.temperature > onlyIf.hotter_than) then
        return false
    end
    if onlyIf.wind_below and not (weather.wind_speed and weather.wind_speed < onlyIf.wind_below) then
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
    if state.services.onRun then
        pcall(state.services.onRun, { at = now, scene_id = schedule.scene_id, schedule = schedule, weather = weather, result = result, error = lastRun.error })
    end
    Log.info("schedules", "schedule ran", {
        schedule = schedule.id,
        scene = schedule.scene_id,
        note = note or Json.null,
        ran = lastRun.ran or 0,
        skipped = lastRun.skipped or 0,
        failed = lastRun.failed or 0,
        error = lastRun.error or Json.null,
    })
end

-- Sets `runtime.armed` from the reading: false while the weather still is past its threshold
-- after running, true again once it has turned back.
local function rearm(trigger, runtime, weather, now)
    if trigger.kind == "heat" then
        if weather.temperature < trigger.above - Scheduler.HEAT_REARM then
            runtime.armed = true
        end
    elseif trigger.kind == "wind" then
        if weather.wind_speed and weather.wind_speed < trigger.above - Scheduler.WIND_REARM then
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

-- A time or sun schedule due at `now`: its run today, or yesterday's just before midnight, when
-- `now` is at most GRACE_MINUTES after it. Returns the key of that run and its moment.
local function dueRun(schedule, info, now)
    for _, day in ipairs({ info, dayBefore(info) }) do
        if hasDay(schedule, day.weekday) then
            local minute = Scheduler.targetMinute(schedule, day)
            -- On the day clocks go forward, a time that does not exist runs when it would have.
            local at = minute and epochAt(day, minute)
            if at and now >= at and now < at + Scheduler.GRACE_MINUTES * 60 then
                return day.date .. "@" .. minute, at
            end
        end
    end
    return nil
end

-- One pass over the schedules for the minute of `now`. Returns how many ran. While paused in
-- Composer nothing runs and nothing is remembered as done.
function Scheduler.tick(now)
    now = now or Clock.now()
    if state.services and state.services.onTick then
        pcall(state.services.onTick, now)
    end
    if state.services and state.services.paused and state.services.paused() then
        return 0
    end
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
    local ran, changed = 0, false
    for _, schedule in ipairs(records) do
        local runtime = Schedules.runtime(schedule.id)
        local trigger = schedule.trigger
        if schedule.enabled == false or waitsForCalendar(schedule) then
            -- Nothing.
        elseif trigger.type == "weather" then
            if weather then
                local armedBefore, drySince = runtime.armed, runtime.dry_since
                if runtime.armed == nil then
                    runtime.armed = true
                end
                rearm(trigger, runtime, weather, now)
                -- Hours across midnight (22:00 to 06:00) belong to the day they started.
                local day = info
                if trigger.from and Schedules.minutes(trigger.from) > Schedules.minutes(trigger.to) and info.minute < Schedules.minutes(trigger.to) then
                    day = dayBefore(info)
                end
                local onceDone = trigger.once_a_day ~= false and runtime.fired_day == day.date
                if runtime.armed and weatherActive(trigger, weather) and hasDay(schedule, day.weekday) and inHours(trigger, info.minute) and not onceDone then
                    runtime.armed = false
                    runtime.dry_since = nil
                    runtime.fired_day = day.date
                    run(schedule, now, trigger.kind, weather)
                    ran = ran + 1
                end
                changed = changed or runtime.armed ~= armedBefore or runtime.dry_since ~= drySince
            end
        else
            local key, at = dueRun(schedule, info, now)
            local waitForWeather = key and weatherComing and next(schedule.only_if or {}) ~= nil and now < at + (Scheduler.GRACE_MINUTES - 1) * 60
            if key and runtime.last_fired ~= key and not waitForWeather then
                runtime.last_fired = key
                changed = true
                -- Changed after its time: it starts with the next one.
                if (schedule.updated_epoch or 0) <= at then
                    local met = Scheduler.conditionsMet(schedule, weather)
                    if met == nil then
                        met = schedule.if_no_weather ~= "skip"
                        if met then
                            run(schedule, now, "no_weather")
                            ran = ran + 1
                        else
                            runtime.last_run = { at = Clock.iso(now), skipped_by = "no_weather" }
                        end
                    elseif met then
                        run(schedule, now, nil)
                        ran = ran + 1
                    else
                        runtime.last_run = { at = Clock.iso(now), skipped_by = "only_if" }
                        Log.info("schedules", "schedule skipped: its conditions were not met", { schedule = schedule.id })
                    end
                end
            end
        end
    end
    if ran > 0 or changed then
        Schedules.saveRuntime()
    end
    return ran
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

-- `services.runScene(sceneId, caller)` runs a saved scene and returns its result.
function Scheduler.start(services)
    state.services = services
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
