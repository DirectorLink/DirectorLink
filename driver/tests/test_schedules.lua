-- Schedules (src/core/schedules.lua, src/core/scheduler.lua, /v1/schedules) and the weather they
-- use (src/core/weather.lua, /v1/weather), with a controlled clock and a fake Open-Meteo
-- (driver/tests/weather_fake.lua): since 1.10.0 (ADR-071) the weather is its saved forecast's hour.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Helpers = require("calendar_helpers")
local WeatherFake = require("weather_fake")

local tests = {}

-- Starts the driver with the clock at `now` (changed later with clock.set).
local function start(now)
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Chrome on Windows")
    local clock = { now = now }
    local Clock = require("src.core.clock")
    Clock.now = function()
        return clock.now
    end
    function clock.set(value)
        clock.now = value
    end
    return mock, admin, clock, require("src.core.scheduler")
end

-- Local time `hh:mm` on the day `days` after today.
local function at(days, hh, mm)
    local fields = os.date("*t", os.time() + days * 86400)
    fields.hour, fields.min, fields.sec = hh, mm, 0
    return os.time(fields)
end

local function weekday(time)
    return os.date("*t", time).wday - 1
end

-- The fake Open-Meteo's forecast with the same weather every hour (`options`: wind, rain, chance).
local function weather(temperature, options)
    return WeatherFake.steady(temperature, options)
end

-- How many times the controller asked Open-Meteo.
local function weatherRequests(mock)
    local count = 0
    for _, request in ipairs(mock.urlRequests) do
        if request.url:match("open%-meteo") then
            count = count + 1
        end
    end
    return count
end

local function scene(mock, admin, steps)
    local created = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Evening", steps = steps or { { type = "lights", device_ids = { 20 }, set = { on = true } } } } })
    T.eq(created.status, 201, created.body)
    return created.json.id
end

local function schedule(mock, admin, body)
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
    T.eq(created.status, 201, created.body)
    return created.json
end

local function commandsTo(mock, device, from)
    local count = 0
    for index = (from or 0) + 1, #mock.commands do
        if mock.commands[index].device == device then
            count = count + 1
        end
    end
    return count
end

function tests.a_time_schedule_runs_its_scene_at_its_minute_once()
    local runAt = at(1, 6, 45)
    local mock, admin, clock, Scheduler = start(os.time())
    local sceneId = scene(mock, admin)
    local created = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "06:45" }, days = { weekday(runAt) } })
    T.eq(created.enabled, true)
    T.eq(created.next_run, os.date("!%Y-%m-%dT%H:%M:%SZ", runAt), "next: tomorrow 06:45")
    T.contains(T.http(mock, "GET", "/v1/schedules", { key = admin }).body, '"only_if":{}')

    local before = #mock.commands
    clock.set(runAt - 60)
    T.eq(Scheduler.tick(), 0, "not yet")
    clock.set(runAt + 1)
    T.eq(Scheduler.tick(), 1, "at 06:45")
    T.eq(commandsTo(mock, 20, before), 1)
    clock.set(runAt + 61)
    T.eq(Scheduler.tick(), 0, "once")
    local item = T.http(mock, "GET", "/v1/schedules/" .. created.id, { key = admin }).json
    T.eq(item.last_run.ran, 1)
    local week = os.date("*t", runAt)
    week.day = week.day + 7
    T.eq(item.next_run, os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(week)), "next: the same weekday next week")

    -- A restart in the same minute does not run it again.
    local updated = Mock.updateDriver(mock)
    require("src.core.clock").now = function()
        return runAt + 90
    end
    T.eq(require("src.core.scheduler").tick(), 0, "remembered across a restart")
    T.eq(#T.http(updated, "GET", "/v1/schedules", { key = admin }).json.items, 1)
end

function tests.a_schedule_changed_after_its_time_starts_the_next_day_and_can_be_switched_off()
    local runAt = at(1, 7, 0)
    local mock, admin, clock, Scheduler = start(runAt + 120)
    local sceneId = scene(mock, admin)
    local created = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    T.eq(Scheduler.tick(), 0, "made at 07:02: not today")
    clock.set(runAt + 86400 + 30)
    T.eq(Scheduler.tick(), 1, "tomorrow it runs")
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. created.id, { key = admin, body = { enabled = false } }).status, 200)
    clock.set(runAt + 2 * 86400 + 30)
    T.eq(Scheduler.tick(), 0, "switched off")
    T.truthy(T.http(mock, "GET", "/v1/schedules/" .. created.id, { key = admin }).json.next_run == Json.null)
end

function tests.only_if_uses_the_weather_and_what_to_do_without_it()
    local runAt = at(1, 6, 45)
    local mock, admin, clock, Scheduler = start(runAt - 600)
    local sceneId = scene(mock, admin)
    local day = { weekday(runAt) }
    local dry = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "06:45" }, days = day, only_if = { not_raining = true } })
    local hot = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "06:45" }, days = day, only_if = { hotter_than = 28 }, if_no_weather = "skip" })
    mock.weather = weather(25, { rain = 0.4 })
    clock.set(runAt + 5)
    T.eq(Scheduler.tick(), 0, "raining, and not hot")
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. dry.id, { key = admin }).json.last_run.skipped_by, "only_if")

    -- Tomorrow Open-Meteo cannot be reached: the first runs anyway, the second is skipped.
    mock.weather = nil
    local nextDay = runAt + 7 * 86400
    clock.set(nextDay + 5)
    T.eq(Scheduler.tick(), 1)
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. dry.id, { key = admin }).json.last_run.note, "no_weather")
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. hot.id, { key = admin }).json.last_run.skipped_by, "no_weather")
end

function tests.a_heat_rule_runs_once_until_it_has_cooled()
    local noon = at(1, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30, once_a_day = false }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    -- The forecast for 13:00, 14:00, ... 18:00 and after.
    local temperatures = { 29, 31, 31, 29, 27.5, 30.5 }
    mock.weather = WeatherFake.forecast(function(time)
        return temperatures[math.max(1, math.min(math.floor((time - noon) / 3600), #temperatures))]
    end)
    local function reading(hours)
        clock.set(noon + hours * 3600)
        return Scheduler.tick()
    end
    T.eq(reading(1), 0)
    T.eq(reading(2), 1, "hotter than 30")
    T.eq(reading(3), 0, "still hot: not again")
    T.eq(reading(4), 0, "29 is not 2° below")
    T.eq(reading(5), 0, "cooled: armed again")
    T.eq(reading(6), 1, "hot again")
    T.eq(weatherRequests(mock), 1, "one forecast for all of it")
end

-- The owner's Shabbat AC (1.10.0): "08:00 to 23:00, hotter than 23°" runs on Friday evening, an
-- evening scene turns the AC off at 23:20, and on Saturday it runs again from 08:00 once it is that
-- hot, even after a night that never cooled 2° below.
function tests.a_rule_with_hours_is_ready_again_when_its_hours_begin_each_day()
    local evening = at(1, 18, 0)
    local mock, admin, clock, Scheduler = start(evening)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 23, from = "08:00", to = "23:00", once_a_day = false }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    -- 26° until the morning of the third day, 22° from 06:00 then, 24° from 10:00.
    mock.weather = WeatherFake.forecast(WeatherFake.steps({ { 0, 26 }, { at(3, 6, 0), 22 }, { at(3, 10, 0), 24 } }))
    local function reading(time)
        clock.set(time)
        return Scheduler.tick()
    end
    T.eq(reading(evening), 1, "hotter than 23 in the evening")
    T.eq(reading(evening + 3600), 0, "still hot: not again")
    T.eq(reading(at(1, 23, 30)), 0, "after 23:00: outside its hours")
    T.eq(reading(at(2, 3, 0)), 0, "a warm night, never below 21")
    T.eq(reading(at(2, 7, 59)), 0, "before 08:00")
    T.eq(reading(at(2, 8, 1)), 1, "08:01 the next day: ready again, and hot")
    T.eq(reading(at(2, 9, 0)), 0, "then not again while it stays hot")
    T.eq(reading(at(3, 8, 1)), 0, "the day after, not hot at 08:00")
    T.eq(reading(at(3, 11, 0)), 1, "it runs once it gets hot")
end

-- A rule that ran today under 1.9.0 (no window day kept) is not made ready again the same day.
function tests.a_rule_that_ran_today_before_the_update_does_not_run_again_today()
    local evening = at(1, 18, 0)
    local mock, admin, clock, Scheduler = start(evening)
    local sceneId = scene(mock, admin)
    local created = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 23, from = "08:00", to = "23:00", once_a_day = false }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    mock.weather = weather(26)
    clock.set(evening)
    T.eq(Scheduler.tick(), 1)
    -- As 1.9.0 left it: ran today, disarmed, no window day.
    require("src.core.schedules").runtime(created.id).window_day = nil
    clock.set(evening + 3600)
    T.eq(Scheduler.tick(), 0, "not again the same day")
end

function tests.weather_rules_keep_to_their_days_hours_and_once_a_day()
    local morning = at(1, 9, 0)
    local mock, admin, clock, Scheduler = start(morning)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "wind", above = 40, from = "12:00", to = "20:00" }, days = { weekday(morning) } })
    -- Windy, calm from 13:00 to 14:00, then windy again.
    mock.weather = WeatherFake.forecast(WeatherFake.steps({
        { 0, { temperature = 22, wind = 55 } },
        { morning + 4 * 3600, { temperature = 22, wind = 10 } },
        { morning + 5 * 3600, { temperature = 22, wind = 60 } },
    }))
    T.eq(Scheduler.tick(), 0, "windy, but before 12:00")
    clock.set(morning + 3 * 3600 + 60)
    T.eq(Scheduler.tick(), 1, "12:01, still windy")
    clock.set(morning + 4 * 3600)
    Scheduler.tick()
    clock.set(morning + 5 * 3600)
    T.eq(Scheduler.tick(), 0, "at most once a day")
    clock.set(morning + 86400 + 4 * 3600)
    T.eq(Scheduler.tick(), 0, "not on other days")
end

-- Rain is the forecast's precipitation in the hour now (ADR-071); a dry hour is the forecast's too.
function tests.a_rain_rule_runs_when_rain_starts_and_again_after_a_dry_hour()
    local start0 = at(1, 10, 0)
    local mock, admin, clock, Scheduler = start(start0)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain", once_a_day = false }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    -- Rain from 11:00 to 12:00, dry for an hour, rain from 13:00 to 14:00, dry until 17:00, rain.
    local wet = { [1] = 1, [3] = 0.2, [7] = 1 }
    mock.weather = WeatherFake.forecast(function(time)
        return { temperature = 18, rain = wet[math.floor((time - start0) / 3600)] }
    end)
    local runs = {}
    for minute = 0, 8 * 60, 5 do
        clock.set(start0 + minute * 60)
        if Scheduler.tick() > 0 then
            runs[#runs + 1] = minute
        end
    end
    -- Not at 13:00: the hour between the two rains is not more than an hour dry.
    T.same(runs, { 60, 420 }, "rain started at 11:00, and new rain at 17:00 after hours dry")
end

function tests.a_scheduled_scene_leaves_doors_and_gates_alone()
    local runAt = at(1, 8, 0)
    local mock, admin, clock, Scheduler = start(os.time())
    Properties["Door Control"] = "Enabled"
    local sceneId = scene(mock, admin, { { type = "relays", device_ids = { 70 }, set = { action = "pulse" } }, { type = "lights", device_ids = { 21 }, set = { on = false } } })
    local created = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = { weekday(runAt) } })
    local before = #mock.commands
    clock.set(runAt + 10)
    T.eq(Scheduler.tick(), 1)
    T.eq(commandsTo(mock, 70, before), 0, "no door opened by a schedule")
    T.eq(commandsTo(mock, 21, before), 1)
    local lastRun = T.http(mock, "GET", "/v1/schedules/" .. created.id, { key = admin }).json.last_run
    T.eq(lastRun.skipped, 1)
    T.eq(lastRun.ran, 1)
end

function tests.sun_schedules_and_the_weather_view()
    local mock, admin, clock, Scheduler = start(os.time())
    local sceneId = scene(mock, admin)
    local created = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "sunset", offset = -30 }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    T.truthy(created.next_run ~= Json.null, "a next run half an hour before sunset")

    local view = T.http(mock, "GET", "/v1/weather", { key = admin })
    T.eq(view.status, 200, view.body)
    T.eq(view.json.status, "unreachable", "no Open-Meteo in this test yet")
    T.truthy(view.json.today.sunrise:match("^%d%d:%d%d$"), "sunrise without the internet")
    T.truthy(view.json.today.sunset:match("^%d%d:%d%d$"))
    T.eq(view.json.location.latitude, 32.08)
    mock.weather = weather(24, { wind = 12 })
    -- Tried again 30 minutes after the failure.
    clock.set(os.time() + 31 * 60)
    view = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(view.status, "ok")
    T.eq(view.current.temperature, 24)
    T.eq(view.current.raining, false)
    T.eq(view.today.max_temperature, 26)
    local request = mock.urlRequests[#mock.urlRequests].url
    T.contains(request, "latitude=32.08&longitude=34.78", "the location, rounded")
end

function tests.schedule_input_and_roles_are_checked()
    local mock, admin = start(os.time())
    local sceneId = scene(mock, admin)
    local post = function(body)
        return T.http(mock, "POST", "/v1/schedules", { key = admin, body = body }).json
    end
    local base = function(changes)
        local body = { scene_id = sceneId, trigger = { type = "time", at = "06:45" }, days = { 0 } }
        for key, value in pairs(changes) do
            body[key] = value
        end
        return body
    end
    T.eq(post(base({ scene_id = "deadbeef" })).code, "INVALID_FIELD", "unknown scene")
    T.eq(post(base({ trigger = { type = "time", at = "25:00" } })).code, "INVALID_FIELD")
    T.eq(post(base({ trigger = { type = "sun", event = "noon" } })).code, "INVALID_FIELD")
    T.eq(post(base({ trigger = { type = "sun", event = "sunset", offset = 400 } })).code, "INVALID_FIELD")
    T.eq(post(base({ trigger = { type = "weather", kind = "heat", above = 80 } })).code, "INVALID_FIELD")
    T.eq(post(base({ trigger = { type = "weather", kind = "rain", above = 3 } })).code, "INVALID_FIELD")
    T.eq(post(base({ trigger = { type = "weather", kind = "heat", above = 30 }, only_if = { not_raining = true } })).code, "INVALID_FIELD")
    T.eq(post(base({ days = {} })).code, "INVALID_FIELD")
    T.eq(post(base({ days = { 7 } })).code, "INVALID_FIELD")
    T.eq(post(base({ only_if = { sunny = true } })).code, "INVALID_FIELD")
    T.eq(post(base({ if_no_weather = "maybe" })).code, "INVALID_FIELD")
    T.eq(post(base({ colour = "red" })).code, "INVALID_FIELD")

    local created = schedule(mock, admin, base({}))
    local viewer = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Guest", role = "viewer" } }).json.key
    T.eq(T.http(mock, "GET", "/v1/schedules", { key = viewer }).status, 403, "schedules are the admins' (ADR-054)")
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. created.id, { key = viewer }).status, 403)
    T.eq(T.http(mock, "GET", "/v1/weather", { key = viewer }).status, 200, "the weather is everyone's")
    T.eq(T.http(mock, "POST", "/v1/schedules", { key = viewer, body = base({}) }).status, 403)
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. created.id, { key = viewer, body = { enabled = false } }).status, 403)
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. created.id, { key = admin, body = { days = { 1 }, version = 5 } }).json.code, "VERSION_CONFLICT")
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. created.id, { key = admin, body = { version = 1 } }).status, 400, "nothing to change")

    local inUse = T.http(mock, "DELETE", "/v1/scenes/" .. sceneId, { key = admin })
    T.eq(inUse.status, 409)
    T.eq(inUse.json.code, "SCENE_IN_USE")
    T.eq(T.http(mock, "DELETE", "/v1/schedules/" .. created.id, { key = admin }).status, 204)
    T.eq(T.http(mock, "DELETE", "/v1/scenes/" .. sceneId, { key = admin }).status, 204, "free once no schedule runs it")
end

function tests.shabbat_triggers_and_during_shabbat_are_checked()
    local mock, admin = start(os.time())
    local sceneId = scene(mock, admin)
    Properties["Jewish Calendar"] = "On"
    OnPropertyChanged("Jewish Calendar")
    local post = function(changes)
        local body = { scene_id = sceneId, trigger = { type = "shabbat", event = "candle_lighting", offset = -30 }, days = { 0, 1, 2, 3, 4, 5, 6 } }
        for key, value in pairs(changes) do
            body[key] = value
        end
        return T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
    end
    local refused = function(changes, field)
        local answer = post(changes)
        T.eq(answer.status, 400, answer.body)
        T.eq(answer.json.code, "INVALID_FIELD")
        T.eq(answer.json.errors[1].field, field, answer.body)
        return answer.json.detail
    end
    T.contains(refused({ trigger = { type = "holiday" } }, "trigger.type"), "time, sun, weather or shabbat")
    refused({ trigger = { type = "shabbat" } }, "trigger.event")
    refused({ trigger = { type = "shabbat", event = "sunset" } }, "trigger.event")
    refused({ trigger = { type = "sun", event = "candle_lighting" } }, "trigger.event")
    refused({ trigger = { type = "shabbat", event = "havdalah", offset = 361 } }, "trigger.offset")
    refused({ trigger = { type = "shabbat", event = "havdalah", offset = -361 } }, "trigger.offset")
    refused({ trigger = { type = "shabbat", event = "havdalah", offset = 2.5 } }, "trigger.offset")
    refused({ trigger = { type = "shabbat", event = "havdalah", offset = "30" } }, "trigger.offset")
    refused({ trigger = { type = "shabbat", event = "havdalah", at = "18:00" } }, "trigger.at")
    refused({ trigger = { type = "sun", event = "sunset", offset = 200 } }, "trigger.offset")
    T.contains(refused({ during_shabbat = "only" }, "during_shabbat"), "does not apply")
    refused({ during_shabbat = "skip" }, "during_shabbat")
    refused({ trigger = { type = "time", at = "07:00" }, during_shabbat = "sometimes" }, "during_shabbat")
    refused({ trigger = { type = "time", at = "07:00" }, during_shabbat = true }, "during_shabbat")

    -- What is kept: the offset defaults to 0, and a Shabbat trigger may say "only if" like a time.
    local havdalah = post({ trigger = { type = "shabbat", event = "havdalah" }, only_if = { not_raining = true } })
    T.eq(havdalah.status, 201, havdalah.body)
    T.same(havdalah.json.trigger, { event = "havdalah", offset = 0, type = "shabbat" })
    T.eq(havdalah.json.during_shabbat, "run")
    T.eq(havdalah.json.only_if.not_raining, true)
    for _, offset in ipairs({ -360, 360 }) do
        T.eq(post({ trigger = { type = "shabbat", event = "candle_lighting", offset = offset } }).status, 201)
    end
    for _, trigger in ipairs({ { type = "time", at = "07:00" }, { type = "sun", event = "sunrise", offset = 15 }, { type = "weather", kind = "heat", above = 30 } }) do
        for _, during in ipairs({ "skip", "only" }) do
            local created = post({ trigger = trigger, during_shabbat = during })
            T.eq(created.status, 201, created.body)
            T.eq(created.json.during_shabbat, during)
        end
    end
    -- A change that does not mention it keeps it; a Shabbat trigger over it must clear it.
    local only = post({ trigger = { type = "time", at = "07:00" }, during_shabbat = "only" }).json
    local patch = function(body)
        return T.http(mock, "PATCH", "/v1/schedules/" .. only.id, { key = admin, body = body })
    end
    T.eq(patch({ enabled = false }).json.during_shabbat, "only")
    T.eq(patch({ trigger = { type = "shabbat", event = "havdalah" } }).json.code, "INVALID_FIELD")
    local changed = patch({ trigger = { type = "shabbat", event = "havdalah" }, during_shabbat = "run" })
    T.eq(changed.status, 200, changed.body)
    T.eq(changed.json.trigger.type, "shabbat")
    T.eq(changed.json.during_shabbat, "run")
end

function tests.a_schedule_stored_before_1_2_0_runs_as_usual_on_shabbat()
    local mock = Mock.startDriver(nil, nil, nil, function(fresh)
        fresh.persist["directorlink_schedules"] = "json:" .. Json.encode({ version = 1, schedules = {
            { id = "0a1b2c3d", enabled = true, scene_id = "deadbeef", trigger = { type = "time", at = "06:45" }, days = { 0, 1 }, only_if = {}, if_no_weather = "run",
                version = 3, created_at = "2026-09-01T08:00:00Z", updated_at = "2026-09-02T08:00:00Z", updated_epoch = 0 },
        } })
    end)
    local admin = T.pair(mock)
    local item = T.http(mock, "GET", "/v1/schedules/0a1b2c3d", { key = admin }).json
    T.eq(item.during_shabbat, "run")
    T.eq(item.calendar_status, Json.null)
    T.eq(item.version, 3)
    T.eq(T.http(mock, "PATCH", "/v1/schedules/0a1b2c3d", { key = admin, body = { days = { 0, 1, 2 } } }).status, 200)
    T.contains(mock.persist["directorlink_schedules"], '"during_shabbat":"run"', "and it is stored in full")
end

-- 1.10.0 (ADR-071): a forecast every 6 hours, 4 requests a day, whoever asks; a failed one is tried
-- again every 30 minutes.
function tests.the_forecast_is_read_every_six_hours_and_a_failure_retried_every_thirty_minutes()
    local noon = at(1, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    for minute = 0, 61 do
        clock.set(noon + minute * 60)
        Scheduler.tick()
        T.http(mock, "GET", "/v1/weather", { key = admin })
    end
    T.eq(weatherRequests(mock), 3, "at 12:00, 12:30 and 13:00")
    mock.weather = weather(31)
    clock.set(noon + 90 * 60)
    T.eq(Scheduler.tick(), 1, "read at 13:30: it runs")
    -- A day of schedules every minute, with an app open on Schedules all day.
    for minute = 91, 90 + 24 * 60 - 1 do
        clock.set(noon + minute * 60)
        Scheduler.tick()
        if minute % 5 == 0 then
            T.http(mock, "GET", "/v1/weather", { key = admin })
        end
    end
    T.eq(weatherRequests(mock) - 3, 4, "13:30, 19:30, 01:30 and 07:30: 4 in a day")
end

local function iso(time)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", time)
end

-- The weather now is the saved forecast's hour (ADR-071): the temperature and the wind between the
-- two hours around now, the rain of the hour now, and the day's high, low and chance of rain. The
-- API says it is the forecast, when it was read and until when it holds; "only if" uses it; and
-- the request carries the rounded location and what is asked, nothing else.
function tests.the_weather_now_is_the_forecasts_hour_and_the_api_says_so()
    local ten = at(1, 10, 0)
    local mock, admin, clock, Scheduler = start(ten)
    local sceneId = scene(mock, admin)
    local day = { weekday(ten) }
    local warm = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "10:30" }, days = day, only_if = { hotter_than = 22 }, if_no_weather = "skip" })
    local hot = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "10:30" }, days = day, only_if = { hotter_than = 24 } })
    -- 20° at 10:00 and 26° at 11:00, the wind 10 and 30 km/h, rain from 10:00 to 11:00 only.
    mock.weather = WeatherFake.forecast(WeatherFake.steps({
        { 0, { temperature = 20, wind = 10 } },
        { ten, { temperature = 20, wind = 10, rain = 0.4 } },
        { ten + 3600, { temperature = 26, wind = 30 } },
    }))
    T.eq(Scheduler.tick(), 0, "read at 10:00")
    T.eq(mock.urlRequests[#mock.urlRequests].url, "https://api.open-meteo.com/v1/forecast?latitude=32.08&longitude=34.78"
        .. "&hourly=temperature_2m,precipitation,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max"
        .. "&timezone=auto&timeformat=unixtime&forecast_days=6")
    local halfPast = ten + 30 * 60 + 1
    clock.set(halfPast)
    T.eq(Scheduler.tick(), 1, "23° at 10:30, halfway from 20 to 26: hotter than 22, not than 24")
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. warm.id, { key = admin }).json.last_run.ran, 1)
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. hot.id, { key = admin }).json.last_run.skipped_by, "only_if")
    -- The log says which forecast decided.
    local logs = T.http(mock, "GET", "/v1/logs?category=schedules&limit=50", { key = admin }).body
    T.contains(logs, '"forecast_from":"' .. iso(ten) .. '"')
    local view = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(view.status, "ok")
    T.eq(view.source, "forecast")
    T.eq(view.fetched_at, iso(ten), "when the forecast was read")
    T.eq(view.forecast_for, iso(halfPast))
    T.eq(view.forecast_until, iso(ten + 5 * 86400), "5 days after it was read")
    T.eq(view.detail, Json.null)
    T.eq(view.current.temperature, 23)
    T.eq(view.current.wind_speed, 20)
    T.eq(view.current.wind_gusts, Json.null)
    T.eq(view.current.precipitation, 0.4)
    T.eq(view.current.raining, true, "rain forecast from 10:00 to 11:00")
    T.eq(view.today.max_temperature, 26)
    T.eq(view.today.min_temperature, 20)
    T.eq(view.today.rain_chance, 80)
    clock.set(ten + 90 * 60)
    view = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(view.current.temperature, 26)
    T.eq(view.current.raining, false, "dry from 11:00")
    T.eq(weatherRequests(mock), 1)
end

-- Without the internet the saved forecast is the weather, after a restart too, for 5 days after it
-- was read; then there is none (if_no_weather) until Open-Meteo answers again. Read for another
-- location it is not used.
function tests.without_the_internet_the_saved_forecast_holds_for_five_days()
    local saved = at(1, 8, 0)
    local mock, admin, clock, Scheduler = start(saved)
    local sceneId = scene(mock, admin)
    local every = { 0, 1, 2, 3, 4, 5, 6 }
    local rule = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30, from = "09:00", to = "10:00" }, days = every })
    local morning = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = every, only_if = { hotter_than = 25 }, if_no_weather = "skip" })
    -- Every day 32° from 09:00 to 10:00 (and 27° at 10:00), 27° otherwise.
    local function forecast()
        return WeatherFake.forecast(function(time)
            return os.date("*t", time).hour == 9 and 32 or 27
        end)
    end
    mock.weather = forecast()
    T.eq(Scheduler.tick(), 0, "read at 08:00")
    mock.weather = nil
    local function day(days, hh, mm)
        local fields = os.date("*t", saved)
        return os.time({ year = fields.year, month = fields.month, day = fields.day + days, hour = hh, min = mm, sec = 1 })
    end
    local Clock = require("src.core.clock")
    for days = 0, 4 do
        if days == 2 then
            -- Restarted while offline: the forecast is kept.
            mock = Mock.updateDriver(mock)
            Clock = require("src.core.clock")
            Clock.now = function()
                return clock.now
            end
            Scheduler = require("src.core.scheduler")
        end
        if days > 0 then
            clock.set(day(days, 7, 0))
            T.eq(Scheduler.tick(), 1, "07:00, 27° in the forecast, day " .. days)
            T.eq(T.http(mock, "GET", "/v1/schedules/" .. morning.id, { key = admin }).json.last_run.note, Json.null)
        end
        clock.set(day(days, 9, 0))
        T.eq(Scheduler.tick(), 1, "09:00, 32° in the forecast, day " .. days)
    end
    local view = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(view.status, "ok")
    T.eq(view.source, "forecast")
    T.eq(view.fetched_at, iso(saved), "read before the internet went")
    T.eq(view.detail, "Couldn't resolve host", "why it was not read again")
    T.truthy(#mock.urlRequests > 0, "tried again meanwhile")
    -- The fifth day after: the forecast holds until 08:00.
    clock.set(day(5, 7, 0))
    T.eq(Scheduler.tick(), 1, "07:00 on the fifth day: still the forecast")
    clock.set(day(5, 9, 0))
    T.eq(Scheduler.tick(), 0, "09:00 on the fifth day: run out, no weather")
    view = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(view.status, "unreachable")
    T.eq(view.source, Json.null)
    T.eq(view.current, Json.null)
    clock.set(day(6, 7, 0))
    T.eq(Scheduler.tick(), 0)
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. morning.id, { key = admin }).json.last_run.skipped_by, "no_weather")
    -- The internet is back: read within 30 minutes, and used at once.
    mock.weather = forecast()
    clock.set(day(6, 8, 59))
    Scheduler.tick()
    clock.set(day(6, 9, 0))
    T.eq(Scheduler.tick(), 1, "09:00 with a new forecast")
    T.eq(T.http(mock, "GET", "/v1/weather", { key = admin }).json.fetched_at, iso(day(6, 8, 59)))
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. rule.id, { key = admin }).json.last_run.note, "heat")
    -- The project moved: a forecast for the old location is not the weather there.
    mock.weather = nil
    mock.project.projectProperties.Latitude, mock.project.projectProperties.Longitude = "32.79", "34.99"
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    clock.set(day(6, 9, 40))
    T.eq(T.http(mock, "GET", "/v1/weather", { key = admin }).json.status, "unreachable")
    mock.weather = forecast()
    clock.set(day(6, 10, 15))
    T.eq(T.http(mock, "GET", "/v1/weather", { key = admin }).json.status, "ok")
    T.contains(mock.urlRequests[#mock.urlRequests].url, "latitude=32.79&longitude=34.99")
end

-- What is kept (ADR-071): the forecast, about 3 KB, under 1.9.0's key with version 2 and no
-- reading, so a 1.9.0 driver after a downgrade finds none and reads the weather anew; 1.9.0's
-- reading is no forecast, and 1.10.0 reads one at once.
function tests.the_saved_forecast_is_small_and_a_1_9_0_reading_is_not_one()
    local noon = at(1, 12, 0)
    local mock = Mock.startDriver(nil, nil, nil, function(fresh)
        fresh.persist["directorlink_weather"] = "json:" .. Json.encode({ version = 1, fetched_at = noon - 600, data = { temperature = 24, raining = false, today = {} } })
        require("src.core.clock").now = function()
            return noon
        end
    end)
    local admin = T.pair(mock)
    T.eq(T.http(mock, "GET", "/v1/weather", { key = admin }).json.status, "unreachable", "1.9.0's reading is not used")
    mock.weather = weather(24)
    require("src.core.clock").now = function()
        return noon + 31 * 60
    end
    T.eq(T.http(mock, "GET", "/v1/weather", { key = admin }).json.status, "ok")
    local raw = mock.persist["directorlink_weather"]
    T.truthy(#raw < 4000, "small: " .. #raw .. " bytes")
    local kept = Json.decode(raw:sub(#"json:" + 1))
    T.eq(kept.version, 2)
    T.eq(kept.data, nil, "no reading for 1.9.0")
    T.eq(kept.fetched_at, nil)
    T.eq(kept.saved_at, noon + 31 * 60)
    T.eq(#kept.temperature, 122, "from 12:00 to 13:00 five days later")
    T.eq(kept.temperature[1], 24)
    T.eq(#kept.days, 6)
end

function tests.switching_a_weather_rule_off_and_on_does_not_run_it_twice_a_day()
    local noon = at(1, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local sceneId = scene(mock, admin)
    local rule = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    mock.weather = weather(33)
    T.eq(Scheduler.tick(), 1)
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. rule.id, { key = admin, body = { enabled = false } }).status, 200)
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. rule.id, { key = admin, body = { enabled = true } }).status, 200)
    clock.set(noon + 16 * 60)
    T.eq(Scheduler.tick(), 0, "still once a day")
    -- The last reading survives a driver update.
    local updated = Mock.updateDriver(mock)
    require("src.core.clock").now = function()
        return noon + 20 * 60
    end
    updated.weather = nil
    T.eq(T.http(updated, "GET", "/v1/weather", { key = admin }).json.status, "ok", "the saved forecast, 20 minutes old")
end

function tests.a_run_just_before_midnight_is_not_lost_to_a_restart()
    local late = at(1, 23, 58)
    local mock, admin, clock, Scheduler = start(late - 3600)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "23:58" }, days = { weekday(late) } })
    clock.set(late + 3 * 60)
    T.eq(Scheduler.tick(), 1, "00:01 the next day, within the 5 minutes")
    clock.set(late + 4 * 60)
    T.eq(Scheduler.tick(), 0)
end

function tests.night_hours_belong_to_the_day_they_start()
    local friday = at(1, 12, 0)
    while weekday(friday) ~= 5 do
        friday = friday + 86400
    end
    local fields = os.date("*t", friday)
    fields.hour, fields.min = 0, 30
    local earlyFriday = os.time(fields)
    local mock, admin, clock, Scheduler = start(earlyFriday - 3600)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain", from = "22:00", to = "06:00" }, days = { 5 } })
    mock.weather = weather(15, { rain = 1 })
    clock.set(earlyFriday)
    T.eq(Scheduler.tick(), 0, "00:30 on Friday is Thursday night")
    fields.day, fields.hour = fields.day + 1, 0
    clock.set(os.time(fields))
    T.eq(Scheduler.tick(), 1, "00:30 on Saturday is Friday night")
end

function tests.enabled_null_and_unknown_trigger_fields_are_refused()
    local mock, admin = start(os.time())
    local sceneId = scene(mock, admin)
    local post = function(body)
        return T.http(mock, "POST", "/v1/schedules", { key = admin, body = body }).json
    end
    T.eq(post({ scene_id = sceneId, trigger = { type = "time", at = "06:00", bogus = 1 }, days = { 0 } }).code, "INVALID_FIELD")
    T.eq(post({ scene_id = sceneId, trigger = { type = "sun", event = "sunset", at = "06:00" }, days = { 0 } }).code, "INVALID_FIELD")
    local created = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "06:00" }, days = { 0 }, enabled = false })
    T.eq(T.http(mock, "PATCH", "/v1/schedules/" .. created.id, { key = admin, body = { enabled = Json.null } }).json.code, "INVALID_FIELD")
end

function tests.composer_shows_the_schedules_and_the_last_run()
    local runAt = at(1, 6, 45)
    local mock, admin, clock, Scheduler = start(runAt - 3600)
    local sceneId = scene(mock, admin)
    T.eq(mock.properties["Schedule Status"], "None")
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "06:45" }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    T.contains(mock.properties["Schedule Status"], "1 on · next today 06:45 Evening")
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    T.contains(mock.properties["Schedule Status"], "2 on")
    T.contains(mock.properties["Schedule Status"], "1 weather rule")

    clock.set(runAt + 5)
    T.eq(Scheduler.tick(), 1)
    T.contains(mock.properties["Last Automation"], "Evening · schedule every day 06:45 · 1 device")
    T.contains(mock.properties["Schedule Status"], "1 weather rule · no weather forecast yet")
    mock.weather = weather(31.5)
    clock.set(runAt + 20 * 60)
    T.eq(Scheduler.tick(), 0, "Open-Meteo could not be reached: tried again 30 minutes later")
    T.contains(mock.properties["Schedule Status"], "1 weather rule · no weather forecast (Open-Meteo unreachable)")
    clock.set(runAt + 35 * 60)
    T.eq(Scheduler.tick(), 1)
    T.contains(mock.properties["Last Automation"], "Evening · heat rule, 31.5C forecast · 1 device")
    clock.set(runAt + 36 * 60)
    Scheduler.tick()
    T.contains(mock.properties["Schedule Status"], "1 weather rule · weather forecast from today " .. os.date("%H:%M", runAt + 35 * 60))
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. sceneId .. "/run", { key = admin }).status, 202)
    T.contains(mock.properties["Last Automation"], "Evening · run from Chrome on Windows · 1 device")
    T.contains(Mock.updateDriver(mock).properties["Last Automation"], "run from Chrome on Windows", "kept across an update")
end

function tests.the_installer_pauses_all_schedules_in_composer()
    local runAt = at(1, 7, 30)
    local mock, admin, clock, Scheduler = start(runAt - 3600)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:30" }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    Properties["Schedules"] = "Paused"
    OnPropertyChanged("Schedules")
    T.contains(mock.properties["Schedule Status"], "Paused in Composer - 1 schedule is not running")
    T.eq(T.http(mock, "GET", "/v1/schedules", { key = admin }).json.paused, true)
    clock.set(runAt + 5)
    T.eq(Scheduler.tick(), 0, "paused")
    Properties["Schedules"] = "On"
    OnPropertyChanged("Schedules")
    T.eq(T.http(mock, "GET", "/v1/schedules", { key = admin }).json.paused, false)
    clock.set(runAt + 65)
    T.eq(Scheduler.tick(), 1, "resumed within its 5 minutes: it runs")
end

function tests.the_composer_action_prints_every_schedule_and_scene()
    local mock, admin = start(os.time())
    local sceneId = scene(mock, admin, {
        { type = "lights", device_ids = { 20 }, set = { brightness = 40 } },
        { type = "climate", room_id = 11, set = { mode = "cool", target_temperature = 24 } },
        { type = "relays", device_ids = { 70 }, set = { action = "pulse" } },
    })
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "sunset", offset = -30 }, days = { 0, 1, 2, 3, 4 }, only_if = { not_raining = true } })
    local lines = {}
    local realPrint = print
    _G.print = function(line)
        lines[#lines + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    local text = table.concat(lines, " | ")
    T.contains(text, "DirectorLink schedules: 1")
    T.contains(text, "[on] Sun-Thu 30 min before sunset -> Evening · only if not raining")
    T.contains(text, "Kitchen Island (20) -> 40%")
    T.contains(text, "all climate in Living Room (11) -> cool 24C")
    T.contains(text, "Main Door (70) -> pulse (skipped when a schedule runs it)")
    T.contains(text, "made in the DirectorLink app")
end

-- ---- Shabbat and holidays (the Jewish calendar, ADR-037) --------------------------------------
-- Shabbat and Shmini Atzeret 5787 in Tel Aviv (Mock.project), from candle lighting on Friday
-- 2 October 2026 at 15:04 UTC to havdalah on Saturday at 16:05 UTC.

local CANDLES = Helpers.epoch("2026-10-02T15:04:00Z")
local HAVDALAH = Helpers.epoch("2026-10-03T16:05:00Z")
local FRIDAY, SATURDAY = 739891, 739892
local localAt = Helpers.localAt

-- Starts (or updates, with `previous`) the driver with the calendar on from the start and the
-- clock at `now`; `properties` are set in Composer before it starts.
local function startCalendar(now, previous, properties)
    local clock = { now = now }
    function clock.set(value)
        clock.now = value
    end
    local mock = Mock.startDriver(previous and previous.project, nil, previous and "DIT_UPDATING" or nil, function(fresh)
        if previous then
            fresh.uuidCount = previous.uuidCount
            for name, value in pairs(previous.persist) do
                fresh.persist[name] = value
            end
        end
        Properties["Jewish Calendar"] = "On"
        for name, value in pairs(properties or {}) do
            Properties[name] = value
        end
        require("src.core.clock").now = function()
            return clock.now
        end
    end)
    return mock, clock, require("src.core.scheduler")
end

local function get(mock, admin, id)
    return T.http(mock, "GET", "/v1/schedules/" .. id, { key = admin }).json
end

function tests.a_shabbat_schedule_runs_once_a_period_whatever_is_changed()
    local mock, clock, Scheduler = startCalendar(CANDLES - 3600)
    local admin = T.pair(mock)
    local created = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "shabbat", event = "candle_lighting", offset = -30 }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    clock.set(CANDLES - 30 * 60 + 10)
    T.eq(Scheduler.tick(), 1)
    local function patch(path, body)
        local answer = T.http(mock, "PATCH", path, { key = admin, body = body })
        T.eq(answer.status, 200, answer.body)
        return answer.json
    end
    -- A later offset, off and on again, other minutes: this period's moment has passed.
    local later = patch("/v1/schedules/" .. created.id, { trigger = { type = "shabbat", event = "candle_lighting", offset = -10 } })
    T.eq(later.next_run, "2026-10-09T14:45:00Z", "next week's, 10 minutes before 14:55")
    patch("/v1/schedules/" .. created.id, { enabled = false })
    patch("/v1/schedules/" .. created.id, { enabled = true })
    patch("/v1/calendar/settings", { candle_lighting_minutes = 30, havdalah_minutes = 50 })
    local ran = 0
    for moment = CANDLES - 25 * 60, CANDLES + 3600, 60 do
        clock.set(moment)
        ran = ran + Scheduler.tick()
    end
    T.eq(ran, 0, "once a period")
    T.eq(get(mock, admin, created.id).next_run, "2026-10-09T14:35:00Z", "candles at 14:45 with 30 minutes, less 10")
    clock.set(Helpers.epoch("2026-10-09T14:35:10Z"))
    T.eq(Scheduler.tick(), 1, "next week")
end

function tests.holy_time_is_judged_when_a_schedule_is_due_not_when_it_is_checked()
    -- Due 2 minutes before candle lighting and 2 minutes before havdalah; each checked 3 minutes
    -- later (within its 5 minutes), when holy time has begun or ended.
    local beforeCandles, beforeHavdalah = CANDLES - 2 * 60, HAVDALAH - 2 * 60
    local mock, clock, Scheduler = startCalendar(beforeCandles - 3600)
    local admin = T.pair(mock)
    local sceneId = scene(mock, admin)
    local function add(due, mode)
        return schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = os.date("%H:%M", due) }, days = { os.date("*t", due).wday - 1 }, during_shabbat = mode }).id
    end
    local skipBefore, onlyBefore = add(beforeCandles, "skip"), add(beforeCandles, "only")
    local skipInside, onlyInside = add(beforeHavdalah, "skip"), add(beforeHavdalah, "only")
    clock.set(beforeCandles + 3 * 60)
    T.eq(Scheduler.tick(), 1, "not yet holy at its time: skip runs")
    T.eq(get(mock, admin, skipBefore).last_run.ran, 1)
    T.truthy(get(mock, admin, onlyBefore).last_run == Json.null, "only: nothing to say, as on a day not in its days")
    clock.set(beforeHavdalah + 3 * 60)
    T.eq(Scheduler.tick(), 1, "still holy at its time: only runs")
    T.eq(get(mock, admin, onlyInside).last_run.ran, 1)
    T.eq(get(mock, admin, skipInside).last_run.skipped_by, "shabbat")
end

function tests.after_a_restart_only_shabbat_automation_is_caught_up()
    local mock, clock, Scheduler = startCalendar(localAt(FRIDAY, 12, 0))
    local admin = T.pair(mock)
    local sceneId = scene(mock, admin)
    local plain = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = { 6 } })
    local only = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = { 6 }, during_shabbat = "only" })
    local paused = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "10:00" }, days = { 6 }, during_shabbat = "only" })
    T.eq(Scheduler.tick(), 0)
    -- Off from Friday until 09:40 on Saturday (local time): the Shabbat-only one runs, late.
    local restarted, _, Again = startCalendar(localAt(SATURDAY, 9, 40), mock)
    T.eq(Again.tick(), 1)
    T.eq(get(restarted, admin, only.id).last_run.note, "late")
    T.truthy(get(restarted, admin, plain.id).last_run == Json.null, "an ordinary schedule keeps its 5 minutes")
    -- Started again at 10:40 with the schedules paused: that first minute catches up nothing, and
    -- resuming does not either.
    local third, later, Third = startCalendar(localAt(SATURDAY, 10, 40), restarted, { Schedules = "Paused" })
    T.eq(Third.tick(), 0)
    Properties["Schedules"] = "On"
    OnPropertyChanged("Schedules")
    later.set(later.now + 60)
    T.eq(Third.tick(), 0)
    T.truthy(get(third, admin, paused.id).last_run == Json.null)
end

function tests.a_shabbat_schedule_leaves_doors_alone_and_keeps_to_only_if()
    local mock, clock, Scheduler = startCalendar(HAVDALAH - 3600, nil, { ["Door Control"] = "Enabled" })
    local admin = T.pair(mock)
    local doors = scene(mock, admin, { { type = "relays", device_ids = { 70 }, set = { action = "pulse" } }, { type = "lights", device_ids = { 21 }, set = { on = false } } })
    local every = { 0, 1, 2, 3, 4, 5, 6 }
    local open = schedule(mock, admin, { scene_id = doors, trigger = { type = "shabbat", event = "havdalah" }, days = every })
    local dry = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "shabbat", event = "havdalah" }, days = every, only_if = { not_raining = true } })
    mock.weather = weather(18, { rain = 1.2 })
    local before = #mock.commands
    clock.set(HAVDALAH + 30)
    T.eq(Scheduler.tick(), 1)
    T.eq(commandsTo(mock, 70, before), 0, "no door opened by a schedule")
    T.eq(commandsTo(mock, 21, before), 1)
    T.eq(get(mock, admin, open.id).last_run.skipped, 1)
    T.eq(get(mock, admin, dry.id).last_run.skipped_by, "only_if")
end

-- The owner's Shabbat AC (ADR-071): "hotter than 23°, 08:30 to 23:00, only on Shabbat and holidays"
-- turns the main ACs on, and nobody can fix anything on Shabbat. The forecast: 26° on Friday, 23°
-- from the hour before candle lighting, 18° from 22:00, and on Saturday from 18° at 08:00 to 25° at
-- 09:00 (23° at 08:43). It runs at candle lighting and at 08:43, with the internet or without it
-- from Friday 13:00 (and a restart at 21:00).
local function shabbatAc(offline)
    local lighting = os.date("*t", CANDLES)
    if lighting.hour < 9 or lighting.hour >= 23 then
        T.skip("candle lighting is not between 08:30 and 23:00 in this time zone")
    end
    local mock, clock, Scheduler = startCalendar(localAt(FRIDAY, 12, 0))
    local admin = T.pair(mock)
    schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "weather", kind = "heat", above = 23, from = "08:30", to = "23:00" }, days = { 0, 1, 2, 3, 4, 5, 6 }, during_shabbat = "only" })
    mock.weather = WeatherFake.forecast(WeatherFake.steps({
        { 0, 26 },
        { CANDLES - CANDLES % 3600 - 3600, 23 },
        { localAt(FRIDAY, 22, 0), 18 },
        { localAt(SATURDAY, 9, 0), 25 },
    }))
    local runs, cut, restarted = {}, false, false
    local moment = localAt(FRIDAY, 12, 0) + 1
    local morning = localAt(SATURDAY, 8, 20)
    while moment < localAt(SATURDAY, 11, 0) do
        if offline and not cut and moment >= localAt(FRIDAY, 13, 0) then
            mock.weather, cut = nil, true
        elseif offline and not restarted and moment >= localAt(FRIDAY, 21, 0) then
            mock, clock, Scheduler = startCalendar(moment, mock)
            restarted = true
        end
        clock.set(moment)
        if Scheduler.tick() > 0 then
            runs[#runs + 1] = os.date("%a %H:%M", moment)
        end
        -- Every minute around candle lighting and on Saturday morning, every 5 minutes otherwise.
        local close = math.abs(moment - CANDLES) < 20 * 60 or (moment >= morning and moment < morning + 3600)
        moment = moment + (close and 60 or 300)
    end
    T.same(runs, { os.date("%a %H:%M", CANDLES), os.date("%a %H:%M", localAt(SATURDAY, 8, 43)) })
    local view = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(view.source, "forecast")
    return view
end

function tests.the_owners_shabbat_ac_runs_from_the_forecast()
    local fetched = require("src.core.clock").parseIso(shabbatAc(false).fetched_at)
    T.truthy(fetched > localAt(SATURDAY, 11, 0) - 6 * 3600, "read every 6 hours")
end

function tests.the_owners_shabbat_ac_runs_from_the_saved_forecast_without_the_internet()
    local view = shabbatAc(true)
    T.eq(view.fetched_at, os.date("!%Y-%m-%dT%H:%M:%SZ", localAt(FRIDAY, 12, 0) + 1), "the forecast read on Friday at noon")
    T.eq(view.detail, "Couldn't resolve host")
end

function tests.the_printout_shows_heat_and_cool_setpoints()
    local mock, admin = start(os.time())
    scene(mock, admin, {
        { type = "climate", room_id = 10, set = { mode = "auto", heat_setpoint = 20, cool_setpoint = 24 } },
        { type = "climate", room_id = 11, set = { cool_setpoint = 23.5, fan_speed = "circulate" } },
    })
    local lines = {}
    local realPrint = print
    _G.print = function(line)
        lines[#lines + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    local text = table.concat(lines, " | ")
    T.contains(text, "all climate in Kitchen (10) -> auto heat 20C cool 24C")
    T.contains(text, "all climate in Living Room (11) -> cool 23.5C fan circulate")
end

return tests
