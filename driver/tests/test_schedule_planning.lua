-- Planning schedules (1.14.0, ADR-090, docs/SCHEDULES.md): a schedule's next run skipped
-- (POST/DELETE /v1/schedules/{id}/skip), dawn and dusk, a sun schedule's earliest and latest times,
-- run_late after a restart, the home's own holidays (/v1/holidays, on_holidays), and the next seven
-- days (GET /v1/schedules/week). With a controlled clock, as test_schedules.lua.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Helpers = require("calendar_helpers")
local WeatherFake = require("weather_fake")

local tests = {}

local EVERY = { 0, 1, 2, 3, 4, 5, 6 }
-- The mock project's location (driver/tests/c4mock.lua): Tel Aviv.
local LATITUDE, LONGITUDE = 32.08, 34.78

local function controlled(now)
    local clock = { now = now }
    function clock.set(value)
        clock.now = value
    end
    return clock, function()
        require("src.core.clock").now = function()
            return clock.now
        end
    end
end

-- Starts the driver with the clock at `now` (changed later with clock.set); `properties` are set in
-- Composer before it starts.
local function start(now, properties)
    local clock, useClock = controlled(now)
    local mock = Mock.startDriver(nil, nil, nil, function()
        for name, value in pairs(properties or {}) do
            Properties[name] = value
        end
        useClock()
    end)
    local admin = T.pair(mock, "Chrome on Windows")
    return mock, admin, clock, require("src.core.scheduler")
end

-- The driver started again (a restart, or an update in Composer) with the clock at `now`; its data
-- is kept.
local function restart(previous, now)
    local clock, useClock = controlled(now)
    local mock = Mock.updateDriver(previous, previous.project, useClock)
    return mock, clock, require("src.core.scheduler")
end

-- Local hh:mm on the day `days` after today.
local function at(days, hh, mm)
    local today = os.date("*t")
    return os.time({ year = today.year, month = today.month, day = today.day + days, hour = hh, min = mm, sec = 0 })
end

local function iso(time)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", time)
end

local function date(time)
    return os.date("%Y-%m-%d", time)
end

local function weekday(time)
    return os.date("*t", time).wday - 1
end

local function clockText(minute)
    return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end

local function scene(mock, admin)
    local created = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Evening", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } })
    T.eq(created.status, 201, created.body)
    return created.json.id
end

local function schedule(mock, admin, body)
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
    T.eq(created.status, 201, created.body)
    return created.json
end

local function get(mock, admin, id)
    return T.http(mock, "GET", "/v1/schedules/" .. id, { key = admin }).json
end

local function patch(mock, admin, id, body)
    local answer = T.http(mock, "PATCH", "/v1/schedules/" .. id, { key = admin, body = body })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function skip(mock, admin, id, method)
    return T.http(mock, method or "POST", "/v1/schedules/" .. id .. "/skip", { key = admin })
end

local function post(mock, admin, body)
    return T.http(mock, "POST", "/v1/schedules", { key = admin, body = body }).json
end

local function holidays(mock, admin, body)
    return T.http(mock, "PUT", "/v1/holidays", { key = admin, body = body })
end

-- The newest history entry of a schedule, or nil.
local function entryOf(mock, admin, id)
    for _, item in ipairs(T.http(mock, "GET", "/v1/activity?kind=schedule&limit=200", { key = admin }).json.items) do
        if item.ids and item.ids.schedule_id == id then
            return item
        end
    end
    return nil
end

local function member(mock, admin)
    return T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Guest", role = "viewer" } }).json.key
end

-- ---- Skip the next run -------------------------------------------------------------------------

function tests.skipping_the_next_run_skips_that_run_only_and_survives_a_restart()
    local first, second = at(1, 6, 45), at(2, 6, 45)
    local mock, admin, clock, Scheduler = start(at(0, 12, 0))
    local id = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "time", at = "06:45" }, days = EVERY }).id
    T.eq(get(mock, admin, id).skip, Json.null)
    local skipped = skip(mock, admin, id)
    T.eq(skipped.status, 200, skipped.body)
    T.eq(skipped.json.skip.at, iso(first), "tomorrow's 06:45 is skipped")
    T.eq(skipped.json.next_run, iso(second), "and the next is the day after")
    T.eq(skip(mock, admin, id).json.skip.at, iso(first), "asked again: the same run stays skipped")
    patch(mock, admin, id, { enabled = false })
    T.eq(patch(mock, admin, id, { enabled = true }).skip.at, iso(first), "switching it off and on keeps the skip")
    patch(mock, admin, id, { scene_id = scene(mock, admin) })
    T.eq(get(mock, admin, id).skip.at, iso(first), "so does another scene")

    local updated, later, Again = restart(mock, first - 600)
    T.eq(get(updated, admin, id).skip.at, iso(first), "kept across a restart")
    later.set(first + 10)
    T.eq(Again.tick(), 0, "skipped")
    local item = get(updated, admin, id)
    T.eq(item.last_run.skipped_by, "skip")
    T.eq(item.skip, Json.null, "done with")
    T.eq(item.next_run, iso(second))
    local entry = entryOf(updated, admin, id)
    T.eq(entry.outcome, "skipped")
    T.eq(entry.reason, "skip")
    later.set(second + 10)
    T.eq(Again.tick(), 1, "the next day it runs")
end

function tests.a_skip_is_taken_back_or_ends_with_a_new_time()
    local first = at(1, 6, 45)
    local mock, admin, clock, Scheduler = start(at(0, 12, 0))
    local id = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "time", at = "06:45" }, days = EVERY }).id
    T.eq(skip(mock, admin, id).status, 200)
    local back = skip(mock, admin, id, "DELETE")
    T.eq(back.status, 200, back.body)
    T.eq(back.json.skip, Json.null)
    T.eq(back.json.next_run, iso(first), "runs tomorrow after all")
    T.eq(skip(mock, admin, id, "DELETE").status, 200, "nothing to take back is fine")

    skip(mock, admin, id)
    local moved = patch(mock, admin, id, { trigger = { type = "time", at = "07:00" } })
    T.eq(moved.skip, Json.null, "another time: the skipped run is no longer that one")
    T.eq(moved.next_run, iso(at(1, 7, 0)))
    skip(mock, admin, id)
    T.eq(patch(mock, admin, id, { days = { 0, 1, 2 } }).skip, Json.null, "other days too")

    -- Switched off over its run: forgotten once it could no longer be caught up (6 hours).
    patch(mock, admin, id, { days = EVERY })
    T.eq(skip(mock, admin, id).json.skip.at, iso(at(1, 7, 0)))
    patch(mock, admin, id, { enabled = false })
    clock.set(at(1, 7, 0) + 5 * 3600)
    Scheduler.tick()
    T.truthy(get(mock, admin, id).skip ~= Json.null, "kept for 6 hours")
    clock.set(at(1, 7, 0) + 6 * 3600 + 30)
    Scheduler.tick()
    T.eq(patch(mock, admin, id, { enabled = true }).skip, Json.null, "then forgotten")

    local refused = skip(mock, admin, (patch(mock, admin, id, { enabled = false })).id)
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "SCHEDULE_OFF")
    T.eq(skip(mock, admin, "deadbeef").status, 404)
    T.eq(skip(mock, admin, "week").status, 400)
    local guest = member(mock, admin)
    T.eq(T.http(mock, "POST", "/v1/schedules/" .. id .. "/skip", { key = guest }).status, 403, "the admins' (ADR-054)")
end

function tests.a_weather_rules_next_run_can_be_skipped()
    local noon = at(0, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local id = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "weather", kind = "heat", above = 30, once_a_day = false }, days = EVERY }).id
    local skipped = skip(mock, admin, id)
    T.eq(skipped.status, 200, skipped.body)
    T.eq(skipped.json.skip.at, Json.null, "its next time is the weather's")
    -- Until 13:00 27°, 14:00 hot, 15:00 cooled, 16:00 hot again.
    local temperatures = { 27, 31, 27, 31 }
    mock.weather = WeatherFake.forecast(function(time)
        return temperatures[math.max(1, math.min(math.floor((time - noon) / 3600), #temperatures))]
    end)
    clock.set(noon + 60)
    T.eq(Scheduler.tick(), 0, "not hot yet")
    clock.set(noon + 2 * 3600 + 30)
    T.eq(Scheduler.tick(), 0, "hot, but skipped")
    T.eq(get(mock, admin, id).last_run.skipped_by, "skip")
    T.eq(get(mock, admin, id).skip, Json.null)
    T.eq(entryOf(mock, admin, id).reason, "skip")
    clock.set(noon + 3 * 3600 + 30)
    T.eq(Scheduler.tick(), 0, "cooled")
    clock.set(noon + 4 * 3600 + 30)
    T.eq(Scheduler.tick(), 1, "hot again: it runs")
end

-- ---- Dawn, dusk, and the earliest and latest times -----------------------------------------------

function tests.sun_schedules_run_at_dawn_and_dusk_and_within_their_limits()
    local noon = at(0, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local Sun = require("src.core.sun")
    local today = Scheduler.localTime(noon)
    local dawn, dusk = Sun.twilight(today.year, today.month, today.day, LATITUDE, LONGITUDE, today.offset)
    local sunrise, sunset = Sun.times(today.year, today.month, today.day, LATITUDE, LONGITUDE, today.offset)
    -- Tel Aviv: civil twilight lasts about 22 to 28 minutes around sunrise and sunset.
    T.truthy(sunrise - dawn >= 20 and sunrise - dawn <= 30, "dawn before sunrise: " .. (sunrise - dawn))
    T.truthy(dusk - sunset >= 20 and dusk - sunset <= 30, "dusk after sunset: " .. (dusk - sunset))
    local sceneId = scene(mock, admin)
    local atDusk = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "dusk" }, days = EVERY })
    T.eq(atDusk.trigger.event, "dusk")
    T.eq(atDusk.next_run, iso(at(0, math.floor(dusk / 60), dusk % 60)), "today at dusk")
    -- Sunset less an hour, but not before an hour and a half after sunset (long after dusk).
    local floor = sunset + 90
    local early = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "sunset", offset = -60, earliest = clockText(floor) }, days = EVERY })
    T.eq(early.trigger.earliest, clockText(floor))
    T.eq(early.next_run, iso(at(0, math.floor(floor / 60), floor % 60)), "held to its earliest time")
    -- At dawn, but not after 15 minutes before today's dawn: tomorrow at that time.
    local cap = dawn - 15
    local capped = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "dawn", latest = clockText(cap) }, days = EVERY })
    T.eq(capped.next_run, iso(at(1, math.floor(cap / 60), cap % 60)), "held to its latest time")
    clock.set(at(0, math.floor(floor / 60), floor % 60) + 10)
    T.eq(Scheduler.tick(), 1, "the earliest time runs it")
    T.eq(get(mock, admin, early.id).last_run.ran, 1)

    local base = { scene_id = sceneId, days = EVERY }
    local function refused(trigger, field)
        base.trigger = trigger
        local answer = post(mock, admin, base)
        T.eq(answer.code, "INVALID_FIELD", field)
        T.eq(answer.errors and answer.errors[1].field or answer.field, field)
    end
    refused({ type = "sun", event = "dusk", earliest = "7:00" }, "trigger.earliest")
    refused({ type = "sun", event = "dusk", latest = "24:00" }, "trigger.latest")
    refused({ type = "sun", event = "dusk", earliest = "20:00", latest = "19:00" }, "trigger.latest")
    refused({ type = "sun", event = "dusk", earliest = "20:00", latest = "20:00" }, "trigger.latest")
    refused({ type = "sun", event = "noon" }, "trigger.event")
    refused({ type = "time", at = "06:00", earliest = "05:00" }, "trigger.earliest")

    local weather = T.http(mock, "GET", "/v1/weather", { key = admin }).json
    T.eq(weather.today.dawn, clockText(dawn), "the weather says dawn and dusk too")
    T.eq(weather.today.dusk, clockText(dusk))
    T.truthy(weather.tomorrow.dawn:match("^%d%d:%d%d$"))
end

-- ---- Run late after a restart --------------------------------------------------------------------

function tests.a_schedule_set_to_run_late_is_caught_up_after_a_restart()
    local eight = at(1, 8, 0)
    local mock, admin, clock, Scheduler = start(at(0, 12, 0))
    local sceneId = scene(mock, admin)
    local late = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = { weekday(eight) }, run_late = true })
    local plain = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = { weekday(eight) } })
    T.eq(late.run_late, true)
    T.eq(plain.run_late, false)
    T.eq(Scheduler.tick(), 0)
    -- Off from now until 09:40 tomorrow.
    local restarted, later, Again = restart(mock, eight + 100 * 60)
    T.eq(Again.tick(), 1, "the one set to run late runs, late")
    T.eq(get(restarted, admin, late.id).last_run.note, "late")
    T.eq(get(restarted, admin, plain.id).last_run, Json.null, "the other keeps its 5 minutes")
    later.set(eight + 101 * 60)
    T.eq(Again.tick(), 0, "once")
    -- More than 6 hours late: not caught up.
    local third, _, Third = restart(restarted, at(8, 8, 0) + 6 * 3600 + 60)
    T.eq(Third.tick(), 0)
    T.eq(get(third, admin, late.id).last_run.at, iso(eight + 100 * 60), "the last run is still yesterday's")

    local sunLate = schedule(third, admin, { scene_id = sceneId, trigger = { type = "sun", event = "sunrise" }, days = EVERY, run_late = true })
    T.eq(sunLate.run_late, true, "sun schedules too")
    local answer = post(third, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain" }, days = EVERY, run_late = true })
    T.eq(answer.code, "INVALID_FIELD", "a weather rule reacts to the weather now")
    answer = post(third, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = EVERY, run_late = "yes" })
    T.eq(answer.code, "INVALID_FIELD")
end

-- ---- The home's holidays -------------------------------------------------------------------------

function tests.the_homes_holidays_are_checked_and_kept()
    local mock, admin = start(at(0, 12, 0))
    local empty = T.http(mock, "GET", "/v1/holidays", { key = admin })
    T.eq(empty.status, 200, empty.body)
    T.eq(#empty.json.items, 0)
    T.eq(empty.json.version, 0)
    T.contains(empty.body, '"items":[]')
    local function refused(items, field)
        local answer = holidays(mock, admin, { items = items })
        T.eq(answer.status, 400, answer.body)
        T.eq(answer.json.code, "INVALID_FIELD", field)
        T.contains(answer.body, '"' .. field .. '"', field)
    end
    refused({ { name = "", from = "2026-12-25" } }, "items[0].name")
    refused({ { name = string.rep("x", 61), from = "2026-12-25" } }, "items[0].name")
    refused({ { name = "Trip", from = "2026-02-30" } }, "items[0].from")
    refused({ { name = "Trip", from = "26-12-25" } }, "items[0].from")
    refused({ { name = "Trip", from = "2026-12-25", to = "2026-12-24" } }, "items[0].to")
    refused({ { name = "Year off", from = "2026-01-01", to = "2027-01-02" } }, "items[0].to")
    refused({ { name = "Always", from = "2026-01-01", to = "2026-12-31", yearly = true }, { name = "Too long", from = "2026-01-01", to = "2027-01-01", yearly = true } }, "items[1].to")
    refused({ { name = "Trip", from = "2026-12-25", colour = "red" } }, "items[0].colour")
    refused({ { name = "Trip", from = "2026-12-25", yearly = "yes" } }, "items[0].yearly")
    local many = {}
    for index = 1, 101 do
        many[index] = { name = "Day " .. index, from = "2026-12-25" }
    end
    refused(many, "items")
    T.eq(holidays(mock, admin, { items = "Christmas" }).json.code, "INVALID_FIELD")
    T.eq(holidays(mock, admin, { items = {}, colour = "red" }).json.code, "INVALID_FIELD")

    local saved = holidays(mock, admin, {
        items = {
            { name = "Winter break", from = "2026-12-20", to = "2027-01-03" },
            { name = "  Independence Day ", from = "2026-04-22", yearly = true },
            { name = "New Year", from = "2026-12-31", to = "2027-01-01", yearly = true },
        },
        version = 0,
    })
    T.eq(saved.status, 200, saved.body)
    T.eq(saved.json.version, 1)
    T.eq(saved.json.items[2].name, "Independence Day", "trimmed")
    T.eq(saved.json.items[2].to, "2026-04-22", "one day when to is left out")
    T.eq(saved.json.items[1].yearly, false)
    local conflict = holidays(mock, admin, { items = {}, version = 0 })
    T.eq(conflict.status, 409)
    T.eq(conflict.json.code, "VERSION_CONFLICT")

    local Holidays = require("src.core.home_holidays")
    T.eq(Holidays.on(2026, 12, 20).name, "Winter break")
    T.eq(Holidays.on(2027, 1, 3).name, "Winter break")
    T.eq(Holidays.on(2027, 1, 4), nil)
    T.eq(Holidays.on(2027, 12, 20), nil, "once")
    T.eq(Holidays.on(2031, 4, 22).name, "Independence Day", "every year")
    T.eq(Holidays.on(2030, 12, 31).name, "New Year", "across New Year")
    T.eq(Holidays.on(2031, 1, 1).name, "New Year")
    T.eq(Holidays.on(2031, 1, 2), nil)

    local updated = Mock.updateDriver(mock)
    local kept = T.http(updated, "GET", "/v1/holidays", { key = admin }).json
    T.eq(#kept.items, 3, "kept across an update")
    T.eq(kept.version, 1)
    local guest = member(updated, admin)
    T.eq(T.http(updated, "GET", "/v1/holidays", { key = guest }).status, 403, "the admins' (ADR-054)")
    T.eq(T.http(updated, "PUT", "/v1/holidays", { key = guest, body = { items = {} } }).status, 403)
end

function tests.schedules_skip_the_homes_holidays_or_run_only_on_them()
    local trip = at(1, 7, 0)
    local mock, admin, clock, Scheduler = start(at(0, 12, 0))
    T.eq(holidays(mock, admin, { items = { { name = "Trip", from = date(trip) } } }).status, 200)
    local sceneId = scene(mock, admin)
    local usual = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = EVERY, on_holidays = "skip" })
    local only = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = EVERY, on_holidays = "only" })
    local always = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = EVERY })
    T.eq(usual.on_holidays, "skip")
    T.eq(always.on_holidays, "run")
    T.eq(usual.next_run, iso(at(2, 7, 0)), "not on the trip")
    T.eq(only.next_run, iso(trip), "only on it")
    clock.set(trip + 10)
    T.eq(Scheduler.tick(), 2, "the holiday's and the one that always runs")
    T.eq(get(mock, admin, usual.id).last_run.skipped_by, "holiday")
    local entry = entryOf(mock, admin, usual.id)
    T.eq(entry.reason, "holiday")
    T.eq(entry.note, "Trip", "with the holiday's name")
    T.eq(get(mock, admin, only.id).last_run.ran, 1)
    T.eq(get(mock, admin, only.id).next_run, Json.null, "no holiday ahead")
    clock.set(at(2, 7, 0) + 10)
    T.eq(Scheduler.tick(), 2, "the day after: not the holiday's")
    T.eq(get(mock, admin, only.id).last_run.at, iso(trip + 10))

    -- A weather rule keeps away from them too, by the day.
    T.eq(holidays(mock, admin, { items = { { name = "Trip", from = date(at(3, 12, 0)) } } }).status, 200)
    local hot = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = EVERY, on_holidays = "skip" })
    mock.weather = WeatherFake.steady(32)
    clock.set(at(3, 12, 0))
    T.eq(Scheduler.tick(), 0, "hot, on a holiday")
    clock.set(at(4, 12, 0))
    T.eq(Scheduler.tick(), 1, "hot, the day after")
    T.eq(get(mock, admin, hot.id).last_run.ran, 1)

    T.eq(post(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = EVERY, on_holidays = "maybe" }).code, "INVALID_FIELD")
    local shabbat = post(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "havdalah" }, days = EVERY, on_holidays = "skip" })
    T.eq(shabbat.code, "INVALID_FIELD", "a Shabbat schedule runs at Shabbat times")
end

-- A request as it runs once opened from a sealed one (backups are read and restored sealed, as
-- tests/test_camera_order.lua's `sealedAs`).
local function sealedAs(mock, key, method, path, body)
    local keyId = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json.id
    local status, _, text = require("src.api.server").handleRequest({
        method = method,
        path = path,
        query = {},
        headers = body and { ["content-type"] = "application/json" } or {},
        body = body and Json.encode(body) or "",
        principal = { id = keyId, name = "Owner's iPhone", role = "admin", sealed = true },
    }, { ip = "192.168.1.50", port = "0" })
    return { status = status, json = Json.decode(text), body = text }
end

-- Checks the backup `document`, then restores it; returns the check's preview.
local function restoreInto(mock, key, document)
    local part = sealedAs(mock, key, "POST", "/v1/restore/parts", { index = 0, count = 1, text = Json.encode(document) })
    T.eq(part.status, 200, part.body)
    local check = sealedAs(mock, key, "POST", "/v1/restore", { upload = part.json.upload })
    T.eq(check.status, 200, check.body)
    local done = sealedAs(mock, key, "POST", "/v1/restore", { upload = part.json.upload, dry_run = false })
    T.eq(done.status, 200, done.body)
    return check.json.restore
end

function tests.the_holidays_go_into_backups_and_come_back()
    local mock, admin = start(at(0, 12, 0))
    T.eq(holidays(mock, admin, { items = { { name = "Trip", from = "2027-02-01", to = "2027-02-07" } } }).status, 200)
    local document = sealedAs(mock, admin, "GET", "/v1/backup").json
    T.eq(document.sections.holidays.version, 1)
    T.eq(document.sections.holidays.items[1].name, "Trip")
    T.eq(document.sections.holidays.items[1].to, "2027-02-07")

    local fresh, freshKey = start(at(0, 12, 0))
    T.eq(holidays(fresh, freshKey, { items = { { name = "Here", from = "2027-03-01" } } }).status, 200)
    local preview = restoreInto(fresh, freshKey, document)
    T.eq(preview.counts.holidays, 1)
    local restored = T.http(fresh, "GET", "/v1/holidays", { key = freshKey }).json
    T.eq(#restored.items, 1)
    T.eq(restored.items[1].name, "Trip")

    -- A backup made before 1.14.0 has no holidays: the ones here stay.
    T.eq(holidays(fresh, freshKey, { items = { { name = "Here", from = "2027-03-01" } } }).status, 200)
    document.sections.holidays = nil
    document.driver_version = "1.13.2"
    preview = restoreInto(fresh, freshKey, document)
    T.eq(preview.counts.holidays, Json.null)
    T.eq(T.http(fresh, "GET", "/v1/holidays", { key = freshKey }).json.items[1].name, "Here", "not written")
end

-- ---- The next seven days -------------------------------------------------------------------------

local function runOf(day, id)
    for _, run in ipairs(day.runs) do
        if run.schedule_id == id then
            return run
        end
    end
    return nil
end

function tests.the_week_says_what_runs_each_day_and_why_not()
    local noon = at(0, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local sceneId = scene(mock, admin)
    T.eq(holidays(mock, admin, { items = { { name = "Trip", from = date(at(2, 12, 0)) } } }).status, 200)
    local morning = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "07:00" }, days = EVERY, on_holidays = "skip" }).id
    local evening = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "20:00" }, days = EVERY, only_if = { not_raining = true } }).id
    local off = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "21:00" }, days = { weekday(at(1, 12, 0)) }, enabled = false }).id
    local rain = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain", from = "08:00", to = "18:00" }, days = EVERY }).id
    local tripOnly = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "09:00" }, days = EVERY, on_holidays = "only" }).id
    T.eq(skip(mock, admin, evening).json.skip.at, iso(at(0, 20, 0)))

    local answer = T.http(mock, "GET", "/v1/schedules/week", { key = admin })
    T.eq(answer.status, 200, answer.body)
    local days = answer.json.days
    T.eq(#days, 7)
    T.eq(answer.json.paused, false)
    T.eq(days[1].date, date(noon), "today first")
    T.eq(days[1].weekday, weekday(noon))
    T.eq(days[7].date, date(at(6, 12, 0)))
    for _, event in ipairs({ "dawn", "sunrise", "sunset", "dusk" }) do
        T.truthy(days[1].sun[event]:match("^%d%d:%d%d$"), event)
    end
    T.eq(days[1].holiday, Json.null)
    T.eq(days[1].holy, Json.null, "the Jewish calendar is off")

    -- Today at noon: the morning has passed, the evening is skipped, the rain rule has its hours.
    T.eq(runOf(days[1], morning).status, "past")
    T.eq(runOf(days[1], morning).at, iso(at(0, 7, 0)))
    T.eq(runOf(days[1], evening).status, "skipped")
    T.eq(runOf(days[1], evening).reason, "skip")
    T.eq(runOf(days[1], evening).conditions, true, "it has an only if")
    T.eq(runOf(days[1], rain).status, "weather")
    T.eq(runOf(days[1], rain).at, Json.null)
    T.eq(runOf(days[1], rain).from, "08:00")
    T.eq(runOf(days[1], rain).to, "18:00")
    T.eq(runOf(days[1], off), nil, "not one of its days")
    T.eq(runOf(days[1], tripOnly), nil, "only on holidays: nothing on other days")
    -- Tomorrow: in time order, the rule last; the one switched off says so.
    local order = {}
    for _, run in ipairs(days[2].runs) do
        order[#order + 1] = run.schedule_id
    end
    T.same(order, { morning, evening, off, rain })
    T.eq(runOf(days[2], morning).status, "planned")
    T.eq(runOf(days[2], morning).conditions, false)
    T.eq(runOf(days[2], evening).status, "planned")
    T.eq(runOf(days[2], off).status, "skipped")
    T.eq(runOf(days[2], off).reason, "off")
    -- The day after: the trip.
    T.eq(days[3].holiday.name, "Trip")
    T.eq(runOf(days[3], morning).status, "skipped")
    T.eq(runOf(days[3], morning).reason, "holiday")
    T.eq(runOf(days[3], tripOnly).status, "planned")
    T.eq(runOf(days[3], tripOnly).at, iso(at(2, 9, 0)))

    Properties["Schedules"] = "Paused"
    OnPropertyChanged("Schedules")
    local paused = T.http(mock, "GET", "/v1/schedules/week", { key = admin }).json
    T.eq(paused.paused, true)
    T.eq(runOf(paused.days[2], morning).reason, "paused")
    T.eq(runOf(paused.days[1], morning).status, "past", "what has passed is past")
    T.eq(T.http(mock, "GET", "/v1/schedules/week", { key = member(mock, admin) }).status, 403, "the admins' (ADR-054)")
end

-- Shabbat on 2-3 October 2026 in Tel Aviv: candle lighting 15:04 UTC on Friday, havdalah 16:05 UTC
-- on Saturday (test_schedules.lua).
local CANDLES = Helpers.epoch("2026-10-02T15:04:00Z")
local HAVDALAH = Helpers.epoch("2026-10-03T16:05:00Z")
local FRIDAY = 739891

function tests.the_week_shows_shabbat_and_what_keeps_away_from_it()
    local mock, admin, clock, Scheduler = start(Helpers.localAt(FRIDAY, 12, 0), { ["Jewish Calendar"] = "On" })
    local sceneId = scene(mock, admin)
    local boiler = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = EVERY, during_shabbat = "skip" }).id
    local lights = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "candle_lighting", offset = -30 }, days = EVERY }).id
    local days = T.http(mock, "GET", "/v1/schedules/week", { key = admin }).json.days
    T.eq(days[1].holy.starts_at, iso(CANDLES), "Shabbat begins on Friday")
    T.eq(days[1].holy.ends_at, Json.null)
    T.eq(days[2].holy.starts_at, Json.null)
    T.eq(days[2].holy.ends_at, iso(HAVDALAH), "and ends on Saturday")
    T.eq(days[3].holy, Json.null)
    T.eq(runOf(days[1], lights).at, iso(CANDLES - 30 * 60))
    T.eq(runOf(days[1], lights).status, "planned")
    T.eq(runOf(days[2], boiler).status, "skipped")
    T.eq(runOf(days[2], boiler).reason, "shabbat")
    T.eq(runOf(days[3], boiler).status, "planned")
end

-- A weather rule is held to its Shabbat setting when the weather turns, so the week judges its
-- hours of each day: only on Shabbat, it shows on the days they touch holy time; keeping away from
-- Shabbat, it is skipped on a day they are all holy. (Its hours from the local clock: the suite
-- also runs in UTC.)
function tests.the_week_holds_weather_rules_to_shabbat()
    local mock, admin = start(Helpers.localAt(FRIDAY, 12, 0), { ["Jewish Calendar"] = "On" })
    local sceneId = scene(mock, admin)
    local onlyShabbat = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = EVERY, during_shabbat = "only" }).id
    -- Saturday, from three hours to one hour before havdalah.
    local holyHours = { type = "weather", kind = "rain", from = os.date("%H:%M", HAVDALAH - 3 * 3600), to = os.date("%H:%M", HAVDALAH - 3600) }
    local notShabbat = schedule(mock, admin, { scene_id = sceneId, trigger = holyHours, days = EVERY, during_shabbat = "skip" }).id
    local allDay = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain" }, days = EVERY, during_shabbat = "skip" }).id
    local days = T.http(mock, "GET", "/v1/schedules/week", { key = admin }).json.days
    T.eq(runOf(days[1], onlyShabbat).status, "weather", "Friday's hours reach candle lighting")
    T.eq(runOf(days[2], onlyShabbat).status, "weather")
    for index = 3, 7 do
        T.eq(runOf(days[index], onlyShabbat), nil, "no holy time on " .. days[index].date)
    end
    T.eq(runOf(days[2], notShabbat).status, "skipped", "its hours are all in Shabbat")
    T.eq(runOf(days[2], notShabbat).reason, "shabbat")
    T.eq(runOf(days[3], notShabbat).status, "weather")
    T.eq(runOf(days[2], allDay).status, "weather", "it may run after havdalah")
end

-- The saved forecast decides a weather rule's days (1.14.1): a day is listed while its weather may
-- come in its hours, as far as the forecast reaches, and a day it ran on stays. (The owner's
-- "hotter than 23°" was listed on a Saturday forecast to reach 20°.)
function tests.the_week_lists_a_weather_rule_only_on_days_its_weather_may_come()
    local noon = at(0, 12, 0)
    local mock, admin, clock, Scheduler = start(noon)
    local sceneId = scene(mock, admin)
    local hot = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30, from = "08:00", to = "20:00" }, days = EVERY }).id
    local mornings = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30, from = "08:00", to = "11:00" }, days = EVERY }).id
    local rain = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain" }, days = EVERY }).id
    -- 25° and dry, but 32° tomorrow at 15:00 (after the mornings' hours), and rain the day after
    -- from 03:00 to 04:00.
    local hotAt, wetAt = at(1, 15, 0), at(2, 3, 0)
    mock.weather = WeatherFake.forecast(function(time)
        return { temperature = time == hotAt and 32 or 25, rain = time == wetAt and 1 or 0 }
    end)
    T.eq(Scheduler.tick(), 0, "the forecast is read")

    local days = T.http(mock, "GET", "/v1/schedules/week", { key = admin }).json.days
    T.eq(runOf(days[1], hot), nil, "25° for the rest of today")
    T.eq(runOf(days[2], hot).status, "weather", "32° tomorrow at 15:00")
    T.eq(runOf(days[2], mornings), nil, "not in its hours")
    T.eq(runOf(days[1], mornings), nil, "its hours are over today, and it did not run")
    T.eq(runOf(days[3], rain).status, "weather", "rain the day after tomorrow")
    T.eq(runOf(days[2], rain), nil)
    for index = 3, 5 do
        T.eq(runOf(days[index], hot), nil, "25° on " .. days[index].date)
    end
    -- The forecast is used for 5 days after it was read: after that the weather is not known yet.
    T.eq(runOf(days[6], hot).status, "weather", "the forecast runs out at noon")
    T.eq(runOf(days[7], hot).status, "weather")
    T.eq(runOf(days[7], mornings).status, "weather")

    -- Tomorrow it runs at 15:00; at 18:00 the heat is gone, but today it ran.
    clock.set(hotAt + 30)
    T.eq(Scheduler.tick(), 1, "hot: it runs")
    clock.set(at(1, 18, 0))
    days = T.http(mock, "GET", "/v1/schedules/week", { key = admin }).json.days
    T.eq(runOf(days[1], hot).status, "weather", "it ran today")
    T.eq(runOf(days[1], mornings), nil)
end

-- With Shabbat, the weather counts only at moments the rule may run: only on Shabbat, heat before
-- candle lighting does not; keeping away from Shabbat, heat within it does not.
function tests.the_week_judges_the_forecast_by_the_shabbat_setting()
    local mock, admin, clock, Scheduler = start(Helpers.localAt(FRIDAY, 12, 0), { ["Jewish Calendar"] = "On" })
    local sceneId = scene(mock, admin)
    local onlyShabbat = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = EVERY, during_shabbat = "only" }).id
    local notShabbat = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, days = EVERY, during_shabbat = "skip" }).id
    local wetShabbat = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "rain" }, days = EVERY, during_shabbat = "only" }).id
    -- 32° at 13:00 on Friday (before candle lighting) and at 10:00 on Saturday (in Shabbat), and
    -- rain on Saturday from 10:00 to 11:00; 25° and dry otherwise.
    local fridayHot, saturdayHot = Helpers.localAt(FRIDAY, 13, 0), Helpers.localAt(FRIDAY + 1, 10, 0)
    T.truthy(fridayHot < CANDLES and saturdayHot > CANDLES and saturdayHot < HAVDALAH)
    mock.weather = WeatherFake.forecast(function(time)
        local hotNow = time == fridayHot or time == saturdayHot
        return { temperature = hotNow and 32 or 25, rain = time == saturdayHot and 1 or 0 }
    end)
    Scheduler.tick()

    local days = T.http(mock, "GET", "/v1/schedules/week", { key = admin }).json.days
    T.eq(runOf(days[1], onlyShabbat), nil, "hot on Friday before candle lighting only")
    T.eq(runOf(days[2], onlyShabbat).status, "weather", "hot on Saturday morning")
    T.eq(runOf(days[1], notShabbat).status, "weather", "hot on Friday afternoon")
    T.eq(runOf(days[2], notShabbat), nil, "hot on Saturday only in Shabbat")
    T.eq(runOf(days[2], wetShabbat).status, "weather")
    T.eq(runOf(days[1], wetShabbat), nil, "dry on Friday evening")
end

-- ---- Composer -------------------------------------------------------------------------------------

function tests.composer_prints_the_new_choices()
    local mock, admin = start(at(0, 12, 0))
    T.eq(holidays(mock, admin, { items = { { name = "Trip", from = "2027-02-01", to = "2027-02-07" } } }).status, 200)
    local sceneId = scene(mock, admin)
    schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "dusk", offset = 30, earliest = "18:00", latest = "22:00" }, days = EVERY, on_holidays = "skip", run_late = true })
    local id = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "06:45" }, days = EVERY }).id
    skip(mock, admin, id)
    local lines = {}
    local realPrint = print
    _G.print = function(line)
        lines[#lines + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    local text = table.concat(lines, " | ")
    T.contains(text, "Home's holidays: Trip 2027-02-01-2027-02-07")
    T.contains(text, "[on] every day 30 min after dusk, 18:00-22:00 -> Evening · not on the home's holidays, runs late after a restart (up to 6 h)")
    T.contains(text, "[on] every day 06:45 -> Evening · skipping tomorrow 06:45 · next " .. os.date("%a %d %b ", at(2, 6, 45)) .. "06:45")
end

return tests
