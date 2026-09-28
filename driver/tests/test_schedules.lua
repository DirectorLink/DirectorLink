-- Schedules (src/core/schedules.lua, src/core/scheduler.lua, /v1/schedules) and the weather they
-- use (src/core/weather.lua, /v1/weather), with a controlled clock and a fake Open-Meteo.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

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

local function weather(temperature, options)
    options = options or {}
    return {
        current = {
            temperature_2m = temperature,
            precipitation = options.rain or 0,
            weather_code = options.code or 0,
            wind_speed_10m = options.wind or 5,
            wind_gusts_10m = (options.wind or 5) * 1.5,
        },
        daily = {
            temperature_2m_max = Json.array({ temperature + 2 }),
            temperature_2m_min = Json.array({ temperature - 8 }),
            precipitation_probability_max = Json.array({ options.chance or 10 }),
        },
    }
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
    local step = 0
    local function reading(temperature)
        step = step + 1
        mock.weather = weather(temperature)
        clock.set(noon + step * 16 * 60)
        return Scheduler.tick()
    end
    T.eq(reading(29), 0)
    T.eq(reading(31), 1, "hotter than 30")
    T.eq(reading(31), 0, "still hot: not again")
    T.eq(reading(29), 0, "29 is not 2° below")
    T.eq(reading(27.5), 0, "cooled: armed again")
    T.eq(reading(30.5), 1, "hot again")
end

function tests.weather_rules_keep_to_their_days_hours_and_once_a_day()
    local morning = at(1, 9, 0)
    local mock, admin, clock, Scheduler = start(morning)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "wind", above = 40, from = "12:00", to = "20:00" }, days = { weekday(morning) } })
    mock.weather = weather(22, { wind = 55 })
    T.eq(Scheduler.tick(), 0, "windy, but before 12:00")
    clock.set(morning + 3 * 3600 + 60)
    T.eq(Scheduler.tick(), 1, "12:01, still windy")
    mock.weather = weather(22, { wind = 10 })
    clock.set(morning + 4 * 3600)
    Scheduler.tick()
    mock.weather = weather(22, { wind = 60 })
    clock.set(morning + 5 * 3600)
    T.eq(Scheduler.tick(), 0, "at most once a day")
    clock.set(morning + 86400 + 4 * 3600)
    T.eq(Scheduler.tick(), 0, "not on other days")
end

function tests.a_rain_rule_runs_when_rain_starts_and_again_after_a_dry_hour()
    local start0 = at(1, 10, 0)
    local mock, admin, clock, Scheduler = start(start0)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain", once_a_day = false }, days = { 0, 1, 2, 3, 4, 5, 6 } })
    local minutes = 0
    local function after(step, reading)
        minutes = minutes + step
        mock.weather = reading
        clock.set(start0 + minutes * 60)
        return Scheduler.tick()
    end
    T.eq(after(0, weather(20)), 0)
    T.eq(after(16, weather(18, { code = 61 })), 1, "rain started")
    T.eq(after(16, weather(18)), 0, "dry for a moment")
    T.eq(after(16, weather(18, { rain = 0.2 })), 0, "rain again within the hour: the same rain")
    T.eq(after(16, weather(18)), 0)
    T.eq(after(61, weather(18)), 0, "an hour dry: armed")
    T.eq(after(16, weather(18, { rain = 1 })), 1, "new rain")
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
    clock.set(os.time() + 16 * 60)
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
    T.eq(T.http(mock, "GET", "/v1/schedules", { key = viewer }).status, 200)
    T.eq(T.http(mock, "GET", "/v1/weather", { key = viewer }).status, 200)
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

return tests
