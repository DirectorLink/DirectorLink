-- The Jewish calendar (ADR-037, src/core/jewish_calendar.lua, /v1/calendar): Shabbat and holiday
-- times behind the Composer property Jewish Calendar, Off by default, and the schedules that use
-- them (src/core/scheduler.lua). With the real engine and a controlled clock, on dates whose times
-- are known (they agree with Hebcal and with api-examples.json), in whatever time zone the process
-- has; the daylight saving ones only in the time zone they are about (CI runs them with
-- TZ=Asia/Jerusalem and TZ=America/New_York).

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Helpers = require("calendar_helpers")

local tests = {}

local EVERY_DAY = { 0, 1, 2, 3, 4, 5, 6 }
local EXAMPLES = Helpers.examples()

-- Shabbat and Shmini Atzeret 5787 in Tel Aviv (Israel): candle lighting on Friday 2 October 2026 at
-- 18:04 and havdalah on Saturday at 19:05, Israel time.
local CANDLES = Helpers.epoch("2026-10-02T15:04:00Z")
local HAVDALAH = Helpers.epoch("2026-10-03T16:05:00Z")
local FRIDAY, SATURDAY = 739891, 739892

-- Projects elsewhere than Mock.project()'s Tel Aviv.
local NO_LOCATION = { CityName = "Tel Aviv", CountryCode = "IL", CountryName = "Israel" }
local TROMSO = { CityName = "Tromso", CountryCode = "NO", CountryName = "Norway", Latitude = "69.6496", Longitude = "18.956" }
local NEW_YORK = { CityName = "New York", CountryCode = "US", CountryName = "United States", Latitude = "40.71427", Longitude = "-74.00597" }
local REYKJAVIK = { CityName = "Reykjavik", CountryCode = "IS", CountryName = "Iceland", Latitude = "64.13548", Longitude = "-21.89541" }

local function isNull(value)
    return value == Json.null
end

local function iso(epoch)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function hhmm(epoch)
    return os.date("%H:%M", epoch)
end

local function weekday(epoch)
    return os.date("*t", epoch).wday - 1
end

-- "Fri 02 Oct 18:04", in the process's local time, as Composer shows it.
local function shown(epoch)
    return os.date("%a %d %b %H:%M", epoch)
end

local localAt = Helpers.localAt

-- An answer of api-examples.json as the driver gives it in this process's time zone: without a
-- location, and in the midnight sun, the Hebrew date changes at local midnight (today.changes_at),
-- which the example has in its own time zone.
local AT_MIDNIGHT = { no_location = true, approximate = true }

local function example(name)
    local item = EXAMPLES.Calendar[name]
    if not AT_MIDNIGHT[name] or Helpers.zone() == item.timezone then
        return item.value
    end
    local value = Json.decode(Json.encode(item.value))
    local today = os.date("*t", Helpers.epoch(item.now))
    value.today.changes_at = iso(os.time({ year = today.year, month = today.month, day = today.day + 1, hour = 0, min = 0, sec = 0 }))
    return value
end

local function project(properties)
    local fresh = Mock.project()
    fresh.projectProperties = properties
    return fresh
end

-- Starts the driver with the clock at `now` (clock.set changes it), counting what the engine is
-- asked (Helpers.calls). options: project, zone (what C4:GetTimeZone answers), calendar (true:
-- Jewish Calendar = On from the start), previous (the driver before: an update in Composer, which
-- keeps the stored data), prepare (more to do before it starts).
local function start(now, options)
    options = options or {}
    local previous = options.previous
    local clock = { now = now }
    function clock.set(value)
        clock.now = value
    end
    local mock = Mock.startDriver(options.project or (previous and previous.project), nil, previous and "DIT_UPDATING" or nil, function(fresh)
        if previous then
            fresh.uuidCount = previous.uuidCount
            for name, value in pairs(previous.persist) do
                fresh.persist[name] = value
                fresh.persistEncrypted[name] = previous.persistEncrypted[name]
            end
        end
        if options.calendar then
            Properties["Jewish Calendar"] = "On"
        end
        if options.zone then
            C4.GetTimeZone = function()
                return options.zone
            end
        end
        require("src.core.clock").now = function()
            return clock.now
        end
        Helpers.watch()
        if options.prepare then
            options.prepare(fresh)
        end
    end)
    return mock, clock, require("src.core.scheduler")
end

local function setCalendar(value)
    Properties["Jewish Calendar"] = value
    OnPropertyChanged("Jewish Calendar")
end

local function scene(mock, admin, name, device)
    local created = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = name or "Shabbat lights", steps = { { type = "lights", device_ids = { device or 20 }, set = { on = true } } } } })
    T.eq(created.status, 201, created.body)
    return created.json.id
end

local function schedule(mock, admin, body)
    body.days = body.days or EVERY_DAY
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
    T.eq(created.status, 201, created.body)
    return created.json
end

local function get(mock, admin, id)
    return T.http(mock, "GET", "/v1/schedules/" .. id, { key = admin }).json
end

local function calendarAnswer(mock, admin)
    local answer = T.http(mock, "GET", "/v1/calendar", { key = admin })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function patchSettings(mock, apiKey, body)
    return T.http(mock, "PATCH", "/v1/calendar/settings", { key = apiKey, body = body })
end

local function key(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role, role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key
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

-- The devices commands went to after `from`, in order.
local function devicesSince(mock, from)
    local devices = {}
    for index = from + 1, #mock.commands do
        devices[#devices + 1] = mock.commands[index].device
    end
    return devices
end

local function logged(mock, admin, message)
    for _, entry in ipairs(T.http(mock, "GET", "/v1/logs?category=calendar&level=debug&limit=500", { key = admin }).json.items) do
        if entry.message == message then
            return entry
        end
    end
    local schedules = T.http(mock, "GET", "/v1/logs?category=schedules&level=debug&limit=500", { key = admin }).json.items
    for _, entry in ipairs(schedules) do
        if entry.message == message then
            return entry
        end
    end
    return nil
end

local function printout()
    local lines = {}
    local realPrint = print
    _G.print = function(line)
        lines[#lines + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    return lines
end

-- 1 -----------------------------------------------------------------------------------------

function tests.the_calendar_is_off_by_default_and_says_so()
    local mock, _, Scheduler = start(CANDLES - 3600)
    local admin = T.pair(mock, "Chrome on Windows")
    T.eq(mock.properties["Calendar Status"], "Off")
    T.same(calendarAnswer(mock, admin), EXAMPLES.Calendar.off.value)
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.jewish_calendar, false)

    local settings = patchSettings(mock, admin, { candle_lighting_minutes = 30, version = 1 })
    T.eq(settings.status, 409, settings.body)
    T.same(settings.json, EXAMPLES.Problem.calendar_off.value)

    local sceneId = scene(mock, admin)
    for _, body in ipairs({
        { trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } },
        { trigger = { type = "time", at = "07:30" }, during_shabbat = "skip" },
        { trigger = { type = "sun", event = "sunset" }, during_shabbat = "only" },
    }) do
        body.scene_id, body.days = sceneId, EVERY_DAY
        local refused = T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
        T.eq(refused.status, 409, refused.body)
        T.eq(refused.json.code, "JEWISH_CALENDAR_OFF")
    end
    T.eq(#T.http(mock, "GET", "/v1/schedules", { key = admin }).json.items, 0, "none of them was kept")

    -- An ordinary schedule, and one that says "run as usual" in full.
    for _, body in ipairs({ { trigger = { type = "time", at = "07:30" } }, { trigger = { type = "time", at = "07:45" }, during_shabbat = "run" } }) do
        body.scene_id = sceneId
        local created = schedule(mock, admin, body)
        T.eq(created.during_shabbat, "run")
        T.truthy(isNull(created.calendar_status), "an ordinary schedule has no calendar status")
    end
    -- Nothing was worked out, and the engine was never loaded.
    Scheduler.tick()
    T.http(mock, "GET", "/v1/schedules", { key = admin })
    T.eq(Helpers.calls, 0)
    T.eq(package.loaded["src.core.holy_times"], nil)
end

function tests.everyone_reads_the_calendar_and_only_admins_change_its_settings()
    local mock = start(CANDLES - 3600)
    local admin = T.pair(mock, "Chrome on Windows")
    local viewer, member = key(mock, admin, "viewer"), key(mock, admin, "member")
    T.eq(calendarAnswer(mock, viewer).status, "off")
    T.eq(T.http(mock, "GET", "/v1/calendar").status, 401)
    setCalendar("On")
    T.eq(calendarAnswer(mock, viewer).status, "ok", "viewers read it all, as they read sunrise and sunset")
    for _, apiKey in ipairs({ viewer, member }) do
        local refused = patchSettings(mock, apiKey, { havdalah_minutes = 50 })
        T.eq(refused.status, 403, refused.body)
        T.eq(refused.json.code, "FORBIDDEN")
        T.eq(refused.json.required_role, "admin")
    end
end

function tests.a_settings_change_is_checked_before_it_is_refused()
    local mock = start(CANDLES - 3600)
    local admin = T.pair(mock, "Chrome on Windows")
    local patch = function(body)
        return patchSettings(mock, admin, body)
    end
    T.eq(patch("[1]").json.code, "INVALID_REQUEST", "an array")
    T.eq(patch({}).json.code, "INVALID_REQUEST", "nothing to change")
    T.eq(patch({ version = 1 }).json.code, "INVALID_REQUEST", "only the version")
    for _, body in ipairs({
        { colour = "blue" },
        { holidays = "mars" },
        { holidays = Json.null },
        { candle_lighting_minutes = -1 },
        { candle_lighting_minutes = 91 },
        { candle_lighting_minutes = 2.5 },
        { candle_lighting_minutes = "20" },
        { havdalah_minutes = 19 },
        { havdalah_minutes = 91 },
        { havdalah_minutes = 42, version = 0 },
        { havdalah_minutes = 42, version = "1" },
    }) do
        local refused = patch(body)
        T.eq(refused.status, 400, Json.encode(body))
        T.eq(refused.json.code, "INVALID_FIELD", Json.encode(body))
    end
    for _, body in ipairs({
        { holidays = "abroad" },
        { candle_lighting_minutes = 0 },
        { candle_lighting_minutes = 90 },
        { havdalah_minutes = 20 },
        { havdalah_minutes = 90 },
        { holidays = "auto", candle_lighting_minutes = 18, havdalah_minutes = 72, version = 3 },
    }) do
        T.eq(patch(body).json.code, "JEWISH_CALENDAR_OFF", Json.encode(body))
    end
end

function tests.the_system_feature_follows_the_composer_property()
    local mock = start(CANDLES - 3600)
    local admin = T.pair(mock, "Chrome on Windows")
    setCalendar("On")
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.jewish_calendar, true)
    local created = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } })
    T.same(created.trigger, { event = "candle_lighting", offset = -30, type = "shabbat" })
    T.eq(created.during_shabbat, "run")
    T.eq(created.calendar_status, "ok")
    setCalendar("Off")
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.jewish_calendar, false)
end

-- 2 -----------------------------------------------------------------------------------------

function tests.turned_on_it_gives_the_times_of_tel_aviv_as_in_israel()
    local now = Helpers.epoch(EXAMPLES.Calendar.ok.now)
    local mock = start(now)
    local admin = T.pair(mock, "Chrome on Windows")
    T.eq(T.http(mock, "PATCH", "/v1/logs/settings", { key = admin, body = { level = "debug" } }).status, 200)
    setCalendar("On")
    local answer = calendarAnswer(mock, admin)
    -- Israel automatically: the location is in Israel and the project's country is IL.
    T.same(answer.settings, { candle_lighting_minutes = 20, havdalah_minutes = 42, holidays = "auto", israel = true, version = 1 })
    -- The times are the engine's, for the week's period.
    local period = require("src.core.holy_times").periods(SATURDAY, SATURDAY, { latitude = 32.08, longitude = 34.78, israel = true, candle_lighting_minutes = 20, havdalah_minutes = 42 })[1]
    T.eq(answer.next.starts_at, iso(period.starts_at))
    T.eq(answer.next.ends_at, iso(period.ends_at))
    T.eq(answer.next.starts_at, iso(CANDLES))
    T.truthy(isNull(answer.current))
    -- The whole answer is the contract's example (Tuesday of Chol HaMoed Sukkot 5787).
    T.same(answer, EXAMPLES.Calendar.ok.value)
    T.eq(mock.properties["Calendar Status"], "Israel (from the location) · candles 20 min before sunset, havdalah 42 min after · next "
        .. shown(CANDLES) .. " to " .. shown(HAVDALAH) .. " Shabbat, Shmini Atzeret, Simchat Torah")
    T.truthy(logged(mock, admin, "jewish calendar on in Composer"), "the switch is logged")
    local computed = logged(mock, admin, "calendar computed")
    T.truthy(computed, "worked out, at debug level")
    T.eq(computed.data.from, "2026-09-26")
    T.eq(computed.data.to, "2027-11-03")
    T.truthy(type(computed.data.milliseconds) == "number")
end

-- The driver's answers are the contract's examples, worked out from the location and the date
-- alone: Tel Aviv during Sukkot and on the second day of Rosh Hashana 5785, a home without a
-- location, and Tromso in the midnight sun.
function tests.the_answers_are_the_api_examples()
    for _, case in ipairs({
        { name = "ok" },
        { name = "three_day_period" },
        { name = "no_location", properties = NO_LOCATION },
        { name = "approximate", properties = TROMSO, zone = "Europe/Oslo" },
    }) do
        local mock = start(Helpers.epoch(EXAMPLES.Calendar[case.name].now), { calendar = true, zone = case.zone, project = case.properties and project(case.properties) })
        T.same(calendarAnswer(mock, T.pair(mock)), example(case.name), case.name)
    end
    -- And a Shabbat schedule runs at that time: 30 minutes before candle lighting on Friday
    -- 2 October 2026 is 14:34 UTC (api-examples.json, ScheduleList.calendar_on).
    local mock, clock, Scheduler = start(CANDLES - 3 * 3600, { calendar = true })
    local admin = T.pair(mock)
    local created = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } })
    T.eq(created.next_run, "2026-10-02T14:34:00Z")
    clock.set(Helpers.epoch("2026-10-02T14:34:20Z"))
    T.eq(Scheduler.tick(), 1)
end

-- Automatically Israel by the location, and without one by the project's country or time zone.
function tests.israel_or_abroad_comes_from_the_location_else_the_country_or_time_zone()
    for _, case in ipairs({
        { properties = { Latitude = "31.77", Longitude = "35.21", CountryCode = "" }, zone = "UTC", israel = true },
        { properties = { Latitude = "31.95", Longitude = "35.93", CountryCode = "JO" }, zone = "Asia/Amman", israel = false },
        { properties = { Latitude = "40.71427", Longitude = "-74.00597", CountryCode = "IL" }, zone = "Asia/Jerusalem", israel = false },
        { properties = { CountryCode = "il" }, zone = "America/New_York", israel = true },
        { properties = { CountryCode = "US" }, zone = "Asia/Jerusalem", israel = true },
        { properties = { CountryCode = "US" }, zone = "America/New_York", israel = false },
        { properties = { CountryCode = "" }, zone = "Europe/London", israel = false },
        { properties = {}, zone = "", israel = true },
    }) do
        local mock = start(Helpers.epoch("2026-10-05T07:00:00Z"), { calendar = true, zone = case.zone, project = project(case.properties) })
        T.eq(calendarAnswer(mock, T.pair(mock)).settings.israel, case.israel, Json.encode(case))
    end
end

-- The service counts days as the engine does, without loading it.
function tests.the_calendar_counts_days_as_the_engine_does()
    start(CANDLES)
    local Calendar, HebrewDate = require("src.core.jewish_calendar"), require("src.core.hebrew_date")
    for rd = HebrewDate.fixedFromGregorian(1970, 1, 1), HebrewDate.fixedFromGregorian(2100, 12, 31), 97 do
        local year, month, day = HebrewDate.gregorianFromFixed(rd)
        T.eq(Calendar.fixedDay(year, month, day), rd)
        T.eq(Calendar.dateKey(rd), HebrewDate.dateKey(rd))
        local y, m, d = Calendar.civilDate(rd)
        T.eq(y * 10000 + m * 100 + d, year * 10000 + month * 100 + day)
    end
end

-- 3 -----------------------------------------------------------------------------------------

function tests.admins_change_the_minutes_the_times_move_and_it_survives_an_update()
    local now = Helpers.epoch(EXAMPLES.Calendar.ok.now)
    local mock = start(now, { calendar = true })
    local admin = T.pair(mock, "Chrome on Windows")
    for _, body in ipairs({ { candle_lighting_minutes = 91 }, { havdalah_minutes = 19 }, { holidays = "mars" }, { colour = "blue" } }) do
        T.eq(patchSettings(mock, admin, body).json.code, "INVALID_FIELD", Json.encode(body))
    end
    T.eq(patchSettings(mock, admin, { version = 1 }).json.code, "INVALID_REQUEST")
    T.eq(patchSettings(mock, key(mock, admin, "viewer"), { havdalah_minutes = 50 }).status, 403)

    local changed = patchSettings(mock, admin, EXAMPLES.CalendarSettingsUpdate.minutes.value)
    T.eq(changed.status, 200, changed.body)
    T.same(changed.json, EXAMPLES.CalendarSettings.after_minutes.value)
    local conflict = patchSettings(mock, admin, { holidays = "abroad", version = 1 })
    T.eq(conflict.status, 409, conflict.body)
    T.same(conflict.json, EXAMPLES.Problem.settings_version_conflict.value)

    -- Candles 10 minutes earlier, havdalah 8 later; Composer says so at once.
    local upcoming = calendarAnswer(mock, admin).next
    T.eq(upcoming.starts_at, iso(CANDLES - 10 * 60))
    T.eq(upcoming.ends_at, iso(HAVDALAH + 8 * 60))
    T.contains(mock.properties["Calendar Status"], "candles 30 min before sunset, havdalah 50 min after")
    local entry = logged(mock, admin, "calendar settings changed")
    T.truthy(entry, "the change is logged")
    T.eq(entry.data.by, T.http(mock, "GET", "/v1/api-keys/current", { key = admin }).json.id)
    T.eq(entry.data.candle_lighting_minutes, 30)

    -- A driver update keeps them.
    local updated = start(now, { previous = mock, calendar = true })
    T.same(calendarAnswer(updated, admin).settings, EXAMPLES.CalendarSettings.after_minutes.value)
    T.contains(updated.properties["Calendar Status"], "candles 30 min before sunset")

    -- Abroad, whatever the location says: Simchat Torah is a second holy day, lit after nightfall.
    local abroad = patchSettings(updated, admin, { holidays = "abroad", candle_lighting_minutes = 20, havdalah_minutes = 42, version = 2 })
    T.eq(abroad.status, 200, abroad.body)
    T.same(abroad.json, { candle_lighting_minutes = 20, havdalah_minutes = 42, holidays = "abroad", israel = false, version = 3 })
    upcoming = calendarAnswer(updated, admin).next
    T.eq(upcoming.starts_at, iso(CANDLES))
    T.eq(upcoming.ends_at, "2026-10-04T16:04:00Z")
    T.eq(#upcoming.days, 2)
    T.eq(upcoming.days[2].candle_lighting, "2026-10-03T16:05:00Z")
    T.eq(upcoming.days[2].holidays[1].key, "simchat_torah")
    T.contains(updated.properties["Calendar Status"], "Abroad (set in the app)")
end

function tests.settings_that_could_not_be_read_are_not_overwritten()
    local mock = start(CANDLES - 3600, {
        calendar = true,
        prepare = function(fresh)
            fresh.persist["directorlink_calendar"] = "json:{not json"
        end,
    })
    local admin = T.pair(mock, "Chrome on Windows")
    local refused = patchSettings(mock, admin, { havdalah_minutes = 50 })
    T.eq(refused.status, 503, refused.body)
    T.eq(refused.json.code, "UNAVAILABLE")
    T.eq(mock.persist["directorlink_calendar"], "json:{not json", "left as it was")
    T.eq(calendarAnswer(mock, admin).settings.havdalah_minutes, 42, "the defaults, meanwhile")
end

-- 4 -----------------------------------------------------------------------------------------

function tests.three_holy_days_begin_once_and_end_once()
    -- Rosh Hashana 5785 and Shabbat in Tel Aviv: Thursday to Saturday, 3-5 October 2024.
    local begins, ends = Helpers.epoch("2024-10-02T15:04:00Z"), Helpers.epoch("2024-10-05T16:02:00Z")
    local mock, clock, Scheduler = start(begins - 3 * 3600, { calendar = true })
    local admin = T.pair(mock)
    local candles = schedule(mock, admin, { scene_id = scene(mock, admin, "Candles", 20), trigger = { type = "shabbat", event = "candle_lighting" } })
    local havdalah = schedule(mock, admin, { scene_id = scene(mock, admin, "Havdalah", 21), trigger = { type = "shabbat", event = "havdalah" } })
    T.eq(candles.next_run, iso(begins))
    T.eq(havdalah.next_run, iso(ends))

    -- Every hour through the three days, and at the second and third evenings' candle lighting.
    local moments = { Helpers.epoch("2024-10-03T16:05:30Z"), Helpers.epoch("2024-10-04T15:01:30Z"), begins + 30, ends + 30 }
    for moment = begins - 2 * 3600, ends + 3 * 3600, 3600 do
        moments[#moments + 1] = moment
    end
    table.sort(moments)
    local ran, before = 0, #mock.commands
    for _, moment in ipairs(moments) do
        clock.set(moment)
        ran = ran + Scheduler.tick()
    end
    T.eq(ran, 2, "one begin and one end")
    T.eq(commandsTo(mock, 20, before), 1)
    T.eq(commandsTo(mock, 21, before), 1)
    T.eq(get(mock, admin, candles.id).last_run.at, iso(begins))
    T.eq(get(mock, admin, havdalah.id).last_run.at, iso(ends + 30))
    T.eq(get(mock, admin, candles.id).next_run, "2024-10-11T14:52:00Z", "next: Yom Kippur")
end

-- 5 -----------------------------------------------------------------------------------------

function tests.a_restart_runs_nothing_twice_and_catches_up_six_hours_late_in_order()
    local mock, clock, Scheduler = start(CANDLES - 3 * 3600, { calendar = true })
    local admin = T.pair(mock)
    local early = schedule(mock, admin, { scene_id = scene(mock, admin, "Early", 20), trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } })
    local candles = schedule(mock, admin, { scene_id = scene(mock, admin, "Candles", 21), trigger = { type = "shabbat", event = "candle_lighting" } })
    -- An hour after candle lighting, only on Shabbat and holidays.
    local evening = CANDLES + 3600
    local only = schedule(mock, admin, { scene_id = scene(mock, admin, "Evening", 22), trigger = { type = "time", at = hhmm(evening) }, days = { weekday(evening) }, during_shabbat = "only" })
    T.eq(Scheduler.tick(), 0)
    clock.set(CANDLES - 30 * 60 + 20)
    T.eq(Scheduler.tick(), 1, "30 minutes before candle lighting")

    -- The controller is off from then until 2 h 26 min after candle lighting.
    local restarted, later, Again = start(CANDLES + 2 * 3600 + 26 * 60, { previous = mock, calendar = true })
    local before = #restarted.commands
    T.eq(Again.tick(), 2, "candle lighting and the evening, late")
    T.same(devicesSince(restarted, before), { 21, 22 }, "in the order they were due, and not the early one again")
    for _, id in ipairs({ candles.id, only.id }) do
        T.eq(get(restarted, admin, id).last_run.note, "late")
    end
    T.truthy(isNull(get(restarted, admin, early.id).last_run.note), "the early one ran on time")
    T.contains(restarted.properties["Last Automation"], ", late after a restart")
    T.truthy(logged(restarted, admin, "schedule caught up after a restart"))
    later.set(later.now + 60)
    T.eq(Again.tick(), 0)
    -- Another restart catches nothing up again.
    local third, _, Third = start(later.now + 120, { previous = restarted, calendar = true })
    T.eq(Third.tick(), 0)

    -- Havdalah, and an hour after it. The controller is off from Saturday afternoon until 6 hours
    -- and a minute after havdalah: the hour after is caught up, havdalah itself is not.
    local havdalah = schedule(third, admin, { scene_id = scene(third, admin, "Havdalah", 20), trigger = { type = "shabbat", event = "havdalah" } })
    local after = schedule(third, admin, { scene_id = scene(third, admin, "After", 21), trigger = { type = "shabbat", event = "havdalah", offset = 60 } })
    local fourth, _, Fourth = start(HAVDALAH + 6 * 3600 + 60, { previous = third, calendar = true })
    before = #fourth.commands
    T.eq(Fourth.tick(), 1)
    T.same(devicesSince(fourth, before), { 21 })
    T.eq(get(fourth, admin, after.id).last_run.note, "late")
    T.truthy(isNull(get(fourth, admin, havdalah.id).last_run), "more than 6 hours late: not run")
    T.eq(get(fourth, admin, havdalah.id).next_run, "2026-10-10T15:57:00Z", "next week's")
end

-- 6 -----------------------------------------------------------------------------------------

function tests.an_offset_past_midnight_runs_the_next_day_with_its_days()
    local at = HAVDALAH + 300 * 60 -- 21:05 UTC: 00:05 on Sunday in Israel
    local mock, clock, Scheduler = start(HAVDALAH - 3600, { calendar = true })
    local admin = T.pair(mock)
    local night = schedule(mock, admin, { scene_id = scene(mock, admin, "Night", 20), trigger = { type = "shabbat", event = "havdalah", offset = 300 }, days = { weekday(at) } })
    local other = schedule(mock, admin, { scene_id = scene(mock, admin, "Other", 21), trigger = { type = "shabbat", event = "havdalah", offset = 300 }, days = { (weekday(at) + 6) % 7 } })
    T.eq(night.next_run, iso(at))
    T.truthy(other.next_run ~= iso(at), "not on its days")
    local before = #mock.commands
    clock.set(HAVDALAH + 30)
    T.eq(Scheduler.tick(), 0, "not at havdalah")
    clock.set(at + 30)
    T.eq(Scheduler.tick(), 1, "five hours after it")
    T.eq(commandsTo(mock, 20, before), 1)
    T.eq(commandsTo(mock, 21, before), 0)
    if Helpers.zone() == "Asia/Jerusalem" then
        T.eq(weekday(at), 0, "Sunday in Israel")
        T.eq(hhmm(at), "00:05")
    end
end

-- 7 -----------------------------------------------------------------------------------------

function tests.skip_and_only_follow_holy_time_and_next_run_knows_it()
    local now = localAt(FRIDAY, 7, 0)
    local mock, clock, Scheduler = start(now, { calendar = true })
    local admin = T.pair(mock)
    local Calendar = require("src.core.jewish_calendar")
    -- Friday 18:30 counts as holy and Saturday 20:00 does not (Israel time); the start counts and
    -- the end does not.
    local fridayEvening, saturdayNight = CANDLES + 26 * 60, HAVDALAH + 55 * 60
    T.eq(Calendar.holyAt(fridayEvening), true)
    T.eq(Calendar.holyAt(saturdayNight), false)
    T.eq(Calendar.holyAt(CANDLES), true)
    T.eq(Calendar.holyAt(CANDLES - 1), false)
    T.eq(Calendar.holyAt(HAVDALAH), false)

    local sceneId = scene(mock, admin)
    local skipMorning = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, during_shabbat = "skip" })
    local onlyMorning = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, during_shabbat = "only" })
    local skipSunset = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "sunset" }, during_shabbat = "skip" })
    local onlySunset = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "sun", event = "sunset" }, during_shabbat = "only" })
    local skipEvening = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = hhmm(fridayEvening) }, days = { weekday(fridayEvening) }, during_shabbat = "skip" })
    local skipNight = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = hhmm(saturdayNight) }, days = { weekday(saturdayNight) }, during_shabbat = "skip" })
    for _, item in ipairs({ skipMorning, onlyMorning, skipSunset, onlySunset }) do
        T.eq(item.calendar_status, "ok")
    end
    -- Friday morning is not holy; Saturday morning is; both sunsets are.
    T.eq(skipMorning.next_run, iso(localAt(FRIDAY, 8, 0)))
    T.eq(onlyMorning.next_run, iso(localAt(SATURDAY, 8, 0)))
    local fridaySunset = Helpers.epoch(onlySunset.next_run)
    T.eq(os.date("*t", fridaySunset).day, 2, "Friday's sunset")
    T.truthy(fridaySunset > CANDLES and fridaySunset < CANDLES + 3600)
    local sundaySunset = Helpers.epoch(skipSunset.next_run)
    T.truthy(sundaySunset > HAVDALAH + 12 * 3600, "not before Sunday's")
    T.truthy(isNull(skipEvening.next_run) or Helpers.epoch(skipEvening.next_run) > HAVDALAH, "Friday 18:30 is skipped")
    T.eq(skipNight.next_run, iso(saturdayNight), "Saturday 20:00 runs")

    local function at(moment)
        clock.set(moment + 30)
        return Scheduler.tick()
    end
    T.eq(at(localAt(FRIDAY, 8, 0)), 1, "skip on Friday morning")
    T.eq(at(fridaySunset), 1, "only at Friday's sunset")
    T.eq(get(mock, admin, skipSunset.id).last_run.skipped_by, "shabbat")
    T.eq(at(fridayEvening), 0)
    T.eq(get(mock, admin, skipEvening.id).last_run.skipped_by, "shabbat")
    T.eq(at(localAt(SATURDAY, 8, 0)), 1, "only on Saturday morning")
    T.eq(get(mock, admin, skipMorning.id).last_run.skipped_by, "shabbat")
    T.eq(get(mock, admin, onlyMorning.id).last_run.ran, 1)
    T.eq(at(saturdayNight), 1, "skip after havdalah")
    -- After havdalah: only waits for the next holy time, skip is back to every day.
    T.eq(get(mock, admin, onlyMorning.id).next_run, iso(localAt(739899, 8, 0)), "next Shabbat")
    T.eq(get(mock, admin, skipMorning.id).next_run, iso(localAt(739893, 8, 0)), "Sunday")
end

-- 8 -----------------------------------------------------------------------------------------

function tests.a_heat_rule_that_skips_holy_time_waits_for_havdalah()
    local mock, clock, Scheduler = start(CANDLES + 3600, { calendar = true })
    local admin = T.pair(mock)
    local sceneId = scene(mock, admin, "Cool", 20)
    local skip = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "weather", kind = "heat", above = 30 }, during_shabbat = "skip" })
    local only = schedule(mock, admin, { scene_id = scene(mock, admin, "Shabbat cool", 21), trigger = { type = "weather", kind = "heat", above = 30 }, during_shabbat = "only" })
    mock.weather = {
        current = { temperature_2m = 33, precipitation = 0, weather_code = 0, wind_speed_10m = 5, wind_gusts_10m = 8 },
        daily = { temperature_2m_max = Json.array({ 34 }), temperature_2m_min = Json.array({ 24 }), precipitation_probability_max = Json.array({ 0 }) },
    }
    local before = #mock.commands
    T.eq(Scheduler.tick(), 1, "hot on Friday evening: only the Shabbat rule")
    T.eq(commandsTo(mock, 21, before), 1)
    for _, moment in ipairs({ CANDLES + 2 * 3600, HAVDALAH - 20 * 60, HAVDALAH - 60 }) do
        clock.set(moment)
        T.eq(Scheduler.tick(), 0, "held back: still hot, still waiting")
    end
    clock.set(HAVDALAH + 60)
    T.eq(Scheduler.tick(), 1, "after havdalah, still hot")
    T.eq(commandsTo(mock, 20, before), 1)
    T.eq(get(mock, admin, skip.id).last_run.note, "heat")
    T.eq(get(mock, admin, only.id).last_run.note, "heat")
end

-- 9 -----------------------------------------------------------------------------------------

function tests.calendar_schedules_are_kept_but_do_not_run_while_the_calendar_is_off()
    local eight = localAt(739894, 8, 0) -- Monday 5 October 2026, no holiday
    local mock, clock, Scheduler = start(eight - 3600, { calendar = true })
    local admin = T.pair(mock)
    local sceneId = scene(mock, admin)
    local function create(body)
        body.scene_id = sceneId
        return schedule(mock, admin, body).id
    end
    local candles = create({ trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } })
    local only = create({ trigger = { type = "time", at = "08:00" }, during_shabbat = "only" })
    local skip = create({ trigger = { type = "time", at = "08:00" }, during_shabbat = "skip" })
    local plain = create({ trigger = { type = "time", at = "08:00" } })
    T.contains(mock.properties["Schedule Status"], "· 2 Shabbat schedules")
    T.notContains(mock.properties["Schedule Status"], "not running")
    setCalendar("Off")
    T.contains(mock.properties["Schedule Status"], "· 2 Shabbat schedules not running (Jewish Calendar is Off)")
    T.eq(mock.properties["Calendar Status"], "Off")

    for _, id in ipairs({ candles, only, skip }) do
        T.eq(get(mock, admin, id).calendar_status, "off", "it says why")
    end
    T.truthy(isNull(get(mock, admin, plain).calendar_status))
    T.truthy(isNull(get(mock, admin, candles).next_run), "a Shabbat trigger has no next run")
    T.truthy(isNull(get(mock, admin, only).next_run), "nothing counts as Shabbat, so no next run")
    T.eq(get(mock, admin, skip).next_run, iso(eight), "skip runs as usual")
    T.eq(get(mock, admin, plain).next_run, iso(eight))

    local before = #mock.commands
    clock.set(eight + 30)
    T.eq(Scheduler.tick(), 2, "the skip and the ordinary schedule")
    T.truthy(#mock.commands > before)
    T.eq(get(mock, admin, skip).last_run.ran, 1)
    T.truthy(isNull(get(mock, admin, only).last_run), "only on Shabbat: not run")
    T.truthy(isNull(get(mock, admin, candles).last_run))

    -- They stay the admin's to switch off and on, move to other days, clear or delete.
    local patch = function(id, body)
        return T.http(mock, "PATCH", "/v1/schedules/" .. id, { key = admin, body = body })
    end
    T.eq(patch(candles, { enabled = false }).status, 200)
    T.eq(patch(candles, { enabled = true }).status, 200)
    T.eq(patch(candles, { days = { 5 } }).status, 200)
    T.eq(patch(skip, { during_shabbat = "only" }).json.code, "JEWISH_CALENDAR_OFF")
    T.eq(patch(plain, { trigger = { type = "shabbat", event = "havdalah", offset = 0 } }).json.code, "JEWISH_CALENDAR_OFF")
    local cleared = patch(only, { during_shabbat = "run" })
    T.eq(cleared.status, 200, cleared.body)
    T.truthy(isNull(cleared.json.calendar_status), "an ordinary schedule again")
    T.eq(cleared.json.next_run, iso(localAt(739895, 8, 0)))
    T.eq(get(mock, admin, skip).during_shabbat, "skip", "a refused change leaves it as it was")

    -- And they survive an update of the driver.
    local updated = start(eight + 60, { previous = mock })
    local items = T.http(updated, "GET", "/v1/schedules", { key = admin }).json.items
    T.eq(#items, 4)
    local kept = {}
    for _, item in ipairs(items) do
        kept[item.id] = item
    end
    T.eq(kept[candles].trigger.type, "shabbat")
    T.same(kept[candles].days, { 5 })
    T.eq(kept[skip].during_shabbat, "skip")
    T.eq(T.http(updated, "DELETE", "/v1/schedules/" .. candles, { key = admin }).status, 204)
end

function tests.turned_on_again_the_calendar_catches_nothing_up()
    local mock, clock, Scheduler = start(CANDLES - 2 * 3600, { calendar = true })
    local admin = T.pair(mock)
    local candles = schedule(mock, admin, { scene_id = scene(mock, admin, "Candles", 20), trigger = { type = "shabbat", event = "candle_lighting" } })
    local evening = CANDLES + 3600
    schedule(mock, admin, { scene_id = scene(mock, admin, "Evening", 21), trigger = { type = "time", at = hhmm(evening) }, days = { weekday(evening) }, during_shabbat = "only" })
    schedule(mock, admin, { scene_id = scene(mock, admin, "Havdalah", 22), trigger = { type = "shabbat", event = "havdalah" } })
    T.eq(Scheduler.tick(), 0)
    clock.set(CANDLES - 10 * 60)
    setCalendar("Off")
    local before = #mock.commands
    clock.set(CANDLES + 30)
    T.eq(Scheduler.tick(), 0, "off at candle lighting")
    clock.set(CANDLES + 20 * 60)
    setCalendar("On")
    T.eq(Scheduler.tick(), 0, "on again: candle lighting is not caught up")
    clock.set(evening + 30)
    T.eq(Scheduler.tick(), 1, "the next moment runs")
    clock.set(HAVDALAH + 30)
    T.eq(Scheduler.tick(), 1)
    T.same(devicesSince(mock, before), { 21, 22 })
    T.eq(get(mock, admin, candles.id).next_run, "2026-10-09T14:55:00Z")
end

-- From before candle lighting until after an "only" schedule's evening the schedules are paused,
-- the calendar is off, or the project has no location; then all is back, the controller is off for
-- a while, and an hour later the driver restarts, within the 6 hours of both moments: neither is
-- caught up, then or later; what came due while the controller was off is.
function tests.what_was_due_while_paused_off_or_without_a_location_is_never_caught_up()
    local modes = {
        { "paused", function(on)
            Properties["Schedules"] = on and "On" or "Paused"
            OnPropertyChanged("Schedules")
        end },
        { "calendar off", function(on)
            setCalendar(on and "On" or "Off")
        end },
        { "no location", function(on, mock)
            mock.project.projectProperties = on and Mock.project().projectProperties or NO_LOCATION
            ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
        end },
    }
    for _, mode in ipairs(modes) do
        local label, switch = mode[1], mode[2]
        local mock, clock, Scheduler = start(CANDLES - 3 * 3600, { calendar = true })
        local admin = T.pair(mock)
        local candles = schedule(mock, admin, { scene_id = scene(mock, admin, "Candles", 20), trigger = { type = "shabbat", event = "candle_lighting" } })
        local evening = CANDLES + 3600
        local only = schedule(mock, admin, { scene_id = scene(mock, admin, "Evening", 21), trigger = { type = "time", at = hhmm(evening) }, days = { weekday(evening) }, during_shabbat = "only" })
        local night = evening + 50 * 60
        local offline = schedule(mock, admin, { scene_id = scene(mock, admin, "Night", 22), trigger = { type = "time", at = hhmm(night) }, days = { weekday(night) }, during_shabbat = "only" })
        T.eq(Scheduler.tick(), 0)
        clock.set(CANDLES - 10 * 60)
        switch(false, mock)
        for moment = CANDLES + 30, evening + 5 * 60, 60 do
            clock.set(moment)
            T.eq(Scheduler.tick(), 0, label)
        end
        clock.set(evening + 20 * 60)
        switch(true, mock)
        clock.set(evening + 21 * 60 + 1)
        T.eq(Scheduler.tick(), 0, label .. ": back, nothing is caught up")
        -- The controller is off from then until an hour later, over the night schedule's minute.
        local restarted, _, Again = start(evening + 80 * 60, { previous = mock, calendar = true })
        local before = #restarted.commands
        T.eq(Again.tick(), 1, label .. ": after the restart, only what came due while the controller was off")
        T.same(devicesSince(restarted, before), { 22 }, label)
        T.eq(get(restarted, admin, offline.id).last_run.note, "late", label)
        for _, id in ipairs({ candles.id, only.id }) do
            T.truthy(isNull(get(restarted, admin, id).last_run), label)
        end
    end
end

-- Director or Composer saying again what the switches already are (a refresh, the same value)
-- does not keep a real restart from catching up.
function tests.switches_said_again_leave_the_catch_up_after_a_restart()
    local mock, _, Scheduler = start(CANDLES - 3600, { calendar = true })
    local admin = T.pair(mock)
    schedule(mock, admin, { scene_id = scene(mock, admin, "Candles", 20), trigger = { type = "shabbat", event = "candle_lighting" } })
    T.eq(Scheduler.tick(), 0)
    -- The controller is off from before candle lighting until two hours after it.
    local restarted, _, Again = start(CANDLES + 2 * 3600, { previous = mock, calendar = true })
    OnPropertyChanged("Schedules")
    OnPropertyChanged("Jewish Calendar")
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    local before = #restarted.commands
    T.eq(Again.tick(), 1, "candle lighting, late")
    T.eq(commandsTo(restarted, 20, before), 1)
end

-- What the schedules ran cannot be read after a restart: nothing is caught up, which could run a
-- Shabbat schedule a second time (1.1.x could repeat one only within its 5 minutes). A save that
-- fails is logged.
function tests.when_what_ran_cannot_be_read_nothing_is_caught_up()
    local mock, clock, Scheduler = start(CANDLES - 3600, { calendar = true })
    local admin = T.pair(mock)
    schedule(mock, admin, { scene_id = scene(mock, admin, "Candles", 20), trigger = { type = "shabbat", event = "candle_lighting" } })
    T.eq(Scheduler.tick(), 0)
    clock.set(CANDLES + 20)
    T.eq(Scheduler.tick(), 1, "at candle lighting")
    mock.persist["directorlink_schedule_state"] = "json:{not json"
    local restarted, later, Again = start(CANDLES + 2 * 3600, { previous = mock, calendar = true })
    local before = #restarted.commands
    T.eq(Again.tick(), 0, "not again two hours later")
    T.eq(commandsTo(restarted, 20, before), 0)
    local warned = logged(restarted, admin, "what the schedules ran could not be read; nothing is caught up after this start")
    T.truthy(warned and warned.level == "warn", "logged")

    local plain = schedule(restarted, admin, { scene_id = scene(restarted, admin, "Plain", 21), trigger = { type = "time", at = hhmm(later.now + 120) }, days = { weekday(later.now + 120) } })
    local realSet = C4.PersistSetValue
    C4.PersistSetValue = function(self, name, value, encrypted)
        if name == "directorlink_schedule_state" then
            error("the disk is full")
        end
        return realSet(self, name, value, encrypted)
    end
    later.set(Helpers.epoch(plain.next_run) + 20)
    local ok, ran = pcall(Again.tick)
    C4.PersistSetValue = realSet
    T.truthy(ok, ran)
    T.eq(ran, 1)
    local failed = logged(restarted, admin, "could not save what the schedules ran")
    T.truthy(failed and failed.level == "error", "a failed save is logged")
end

-- 10 ----------------------------------------------------------------------------------------

function tests.without_a_location_there_are_dates_and_the_reading_but_no_times()
    local now = Helpers.epoch(EXAMPLES.Calendar.no_location.now)
    local mock, clock, Scheduler = start(now, { calendar = true, project = project(NO_LOCATION) })
    local admin = T.pair(mock)
    T.same(calendarAnswer(mock, admin), example("no_location"))
    T.eq(mock.properties["Calendar Status"], "No location - set latitude and longitude in the project properties")
    local sceneId = scene(mock, admin)
    -- The next 08:00, local time.
    local eight = localAt(739894, 8, 0)
    if eight <= now then
        eight = localAt(739895, 8, 0)
    end
    local candles = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "havdalah", offset = 20 } })
    local only = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, during_shabbat = "only" })
    local skip = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, during_shabbat = "skip" })
    for _, item in ipairs({ candles, only, skip }) do
        T.eq(item.calendar_status, "no_location")
    end
    T.truthy(isNull(candles.next_run))
    T.truthy(isNull(only.next_run))
    T.eq(skip.next_run, iso(eight))
    T.contains(mock.properties["Schedule Status"], "· 2 Shabbat schedules not running (no location)")
    clock.set(eight + 30)
    T.eq(Scheduler.tick(), 1, "skip runs as usual")
    T.eq(get(mock, admin, skip.id).last_run.ran, 1)
    T.eq(Helpers.calls, 0, "no times worked out")
end

function tests.a_new_location_in_composer_is_used_at_once()
    local mock = start(CANDLES - 3600, { calendar = true })
    local admin = T.pair(mock)
    T.contains(mock.properties["Calendar Status"], "Israel (from the location)")
    mock.project.projectProperties = NO_LOCATION
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(mock.properties["Calendar Status"], "No location - set latitude and longitude in the project properties")
    T.eq(calendarAnswer(mock, admin).status, "no_location")
    mock.project.projectProperties = NEW_YORK
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    -- Abroad, Shmini Atzeret and Simchat Torah are two holy days, at New York's times.
    local abroad = require("src.core.holy_times").periods(SATURDAY, SATURDAY, { latitude = 40.71427, longitude = -74.00597, israel = false })[1]
    T.eq(abroad.last, SATURDAY + 1)
    T.contains(mock.properties["Calendar Status"], "Abroad (from the location)")
    T.contains(mock.properties["Calendar Status"], "next " .. shown(abroad.starts_at) .. " to " .. shown(abroad.ends_at) .. " Shabbat, Shmini Atzeret, Simchat Torah")
    T.eq(calendarAnswer(mock, admin).next.ends_at, iso(abroad.ends_at))
end

-- The engine never stops the rest: if it fails, Shabbat automation waits and says why in
-- Composer, and every other schedule runs as usual.
function tests.a_failure_in_the_engine_leaves_the_other_schedules_running()
    local mock, clock, Scheduler = start(CANDLES - 3600, { calendar = true })
    local admin = T.pair(mock)
    require("src.core.jewish_calendar").configure({
        periods = function()
            error("no sunset table")
        end,
    })
    local sceneId = scene(mock, admin)
    local later = CANDLES + 3600
    local plain = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = hhmm(later) }, days = { weekday(later) } })
    local skip = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = hhmm(later) }, days = { weekday(later) }, during_shabbat = "skip" })
    local candles = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "candle_lighting" } })
    T.truthy(isNull(candles.next_run))
    T.eq(skip.next_run, iso(later))
    clock.set(later + 30)
    T.eq(Scheduler.tick(), 2, "the ordinary and the skip schedule")
    T.eq(mock.properties["Calendar Status"], "Error: the times could not be worked out - see the log (calendar)")
    local entry = logged(mock, admin, "the Shabbat and holiday times could not be worked out")
    T.truthy(entry and entry.level == "error")
    T.contains(entry.data.error, "no sunset table")
    T.eq(get(mock, admin, plain.id).last_run.ran, 1)
end

-- 11 ----------------------------------------------------------------------------------------

function tests.in_the_midnight_sun_triggers_idle_and_the_condition_takes_the_civil_days()
    local now = Helpers.epoch(EXAMPLES.Calendar.approximate.now)
    local mock, clock, Scheduler = start(now, { calendar = true, zone = "Europe/Oslo", project = project(TROMSO) })
    local admin = T.pair(mock)
    T.same(calendarAnswer(mock, admin), example("approximate"))
    T.eq(mock.properties["Calendar Status"], "Abroad (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 26 Jun: no sunset at this latitude, no times")
    -- From Thursday 11:00 (local time), every half hour until Sunday noon.
    local thursday, saturday = 739792, 739794
    clock.set(localAt(thursday, 11, 0))
    local sceneId = scene(mock, admin)
    local candles = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "candle_lighting" } })
    local havdalah = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "havdalah" } })
    local only = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "10:00" }, during_shabbat = "only" })
    local skip = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "10:00" }, during_shabbat = "skip" })
    -- No times until the sun sets again, for Shabbat on 1 August.
    T.eq(candles.next_run, "2026-07-31T21:00:00Z")
    T.eq(havdalah.next_run, "2026-08-01T21:55:00Z")
    T.eq(only.next_run, iso(localAt(saturday, 10, 0)))
    T.eq(skip.next_run, iso(localAt(thursday + 1, 10, 0)))
    -- Holy from 00:00 on Saturday to 24:00, local time.
    local Calendar = require("src.core.jewish_calendar")
    T.eq(Calendar.holyAt(localAt(saturday, 0, 0) - 1), false)
    T.eq(Calendar.holyAt(localAt(saturday, 0, 0)), true)
    T.eq(Calendar.holyAt(localAt(saturday + 1, 0, 0) - 1), true)
    T.eq(Calendar.holyAt(localAt(saturday + 1, 0, 0)), false)
    local function runUntil(finish)
        local ran = 0
        while clock.now < finish do
            clock.set(clock.now + 30 * 60)
            ran = ran + Scheduler.tick()
        end
        return ran
    end
    T.eq(runUntil(localAt(saturday, 23, 30)), 2, "skip on Friday, only on Saturday; the triggers never")
    T.eq(get(mock, admin, skip.id).last_run.skipped_by, "shabbat")
    T.eq(get(mock, admin, only.id).last_run.ran, 1)
    T.eq(runUntil(localAt(saturday + 1, 12, 0)), 1, "skip again on Sunday")
    T.eq(get(mock, admin, skip.id).last_run.ran, 1)
    T.truthy(isNull(get(mock, admin, candles.id).last_run) and isNull(get(mock, admin, havdalah.id).last_run))
end

-- As the polar night starts (Tromsø, Shabbat 28 November 2026) Friday's sun still sets, so candle
-- lighting is at 10:22 UTC, but Saturday's does not: no havdalah. Neither trigger runs that
-- weekend (a begin whose end never comes would keep the home in Shabbat mode for seven weeks), and
-- holy time starts at candle lighting.
function tests.at_the_start_of_the_polar_night_neither_trigger_runs_and_holy_time_starts_at_candle_lighting()
    local candlesAt = Helpers.epoch("2026-11-27T10:22:00Z")
    local mock, clock, Scheduler = start(Helpers.epoch("2026-11-26T09:00:00Z"), { calendar = true, zone = "Europe/Oslo", project = project(TROMSO) })
    local admin = T.pair(mock)
    local period = calendarAnswer(mock, admin).next
    T.eq(period.starts_at, iso(candlesAt))
    T.truthy(isNull(period.ends_at), "no havdalah")
    T.eq(period.approximate, true)
    local on = schedule(mock, admin, { scene_id = scene(mock, admin, "Shabbat on", 20), trigger = { type = "shabbat", event = "candle_lighting" } })
    local off = schedule(mock, admin, { scene_id = scene(mock, admin, "Shabbat off", 21), trigger = { type = "shabbat", event = "havdalah" } })
    local afterCandles = candlesAt + 3600
    local only = schedule(mock, admin, { scene_id = scene(mock, admin, "Afternoon", 22), trigger = { type = "time", at = hhmm(afterCandles) }, days = { weekday(afterCandles) }, during_shabbat = "only" })
    T.eq(on.next_run, "2027-01-15T10:52:00Z", "the first Shabbat whose sun sets on both evenings")
    T.eq(off.next_run, "2027-01-16T12:14:00Z")
    T.eq(only.next_run, iso(afterCandles))
    local Calendar = require("src.core.jewish_calendar")
    T.eq(Calendar.holyAt(candlesAt - 1), false)
    T.eq(Calendar.holyAt(candlesAt), true)
    local before = #mock.commands
    for moment = candlesAt - 3600 + 20, Helpers.epoch("2026-11-29T12:00:20Z"), 600 do
        clock.set(moment)
        Scheduler.tick()
    end
    T.eq(commandsTo(mock, 20, before), 0, "not at candle lighting")
    T.eq(commandsTo(mock, 21, before), 0)
    T.eq(commandsTo(mock, 22, before), 1, "only on Shabbat: an hour after candle lighting is holy")
end

-- Far north in summer havdalah may come after midnight (Reykjavik, Shabbat 19 to 21 June 2026, from
-- 23:43 on Friday to 00:45 on Sunday, UTC): a schedule only on Shabbat between midnight and
-- havdalah says when it runs, and runs then.
function tests.an_only_schedule_between_midnight_and_havdalah_knows_its_next_run()
    local sunday = Helpers.epoch("2026-06-21T00:30:00Z")
    local mock, clock, Scheduler = start(Helpers.epoch("2026-06-20T01:00:00Z"), { calendar = true, zone = "Atlantic/Reykjavik", project = project(REYKJAVIK) })
    local admin = T.pair(mock)
    local current = calendarAnswer(mock, admin).current
    T.eq(current.starts_at, "2026-06-19T23:43:00Z")
    T.eq(current.ends_at, "2026-06-21T00:45:00Z")
    local only = schedule(mock, admin, { scene_id = scene(mock, admin), trigger = { type = "time", at = hhmm(sunday) }, days = { weekday(sunday) }, during_shabbat = "only" })
    T.eq(only.next_run, iso(sunday))
    clock.set(sunday + 20)
    T.eq(Scheduler.tick(), 1)
end

-- 12 ----------------------------------------------------------------------------------------

function tests.the_hebrew_date_changes_at_sunset_and_the_week_after_shabbat()
    local mock, clock = start(Helpers.epoch("2026-10-02T09:00:00Z"), { calendar = true })
    local admin = T.pair(mock)
    local friday = calendarAnswer(mock, admin)
    T.eq(friday.today.date, "2026-10-02")
    T.same(friday.today.hebrew, { day = 21, leap_year = true, month = "tishrei", year = 5787 })
    T.eq(friday.today.after_sunset, false)
    T.eq(friday.today.holidays[1].key, "hoshana_rabba")
    T.eq(friday.week.date, "2026-10-03", "a holiday Shabbat")
    T.truthy(isNull(friday.week.parasha), "a holiday reading")
    T.eq(#friday.week.holidays, 2)

    -- Friday after sunset (18:24 in Tel Aviv) is already Shabbat's Hebrew day.
    clock.set(Helpers.epoch("2026-10-02T15:30:00Z"))
    local evening = calendarAnswer(mock, admin)
    T.eq(evening.today.date, "2026-10-03")
    T.eq(evening.today.hebrew.day, 22)
    T.eq(evening.today.after_sunset, true)
    T.eq(evening.today.holidays[1].key, "shmini_atzeret")
    T.eq(evening.week.date, "2026-10-03")
    T.eq(evening.current.starts_at, iso(CANDLES), "in the period")
    T.eq(evening.next.starts_at, "2026-10-09T14:55:00Z")

    -- Saturday after sunset: Sunday's Hebrew day, and the week of Bereshit.
    clock.set(Helpers.epoch("2026-10-03T16:30:00Z"))
    local night = calendarAnswer(mock, admin)
    T.eq(night.today.date, "2026-10-04")
    T.eq(night.today.hebrew.day, 23)
    T.eq(#night.today.holidays, 0, "Simchat Torah is abroad's second day")
    T.eq(night.week.date, "2026-10-10")
    T.same(night.week.parasha, { ids = { 1 }, name = "Bereshit" })
    T.truthy(isNull(night.current), "after havdalah")
end

-- today.changes_at is when the Hebrew date changes next, at a sunset (to the second) or at a local
-- midnight (no location, no sunset, or far north a sunset after midnight): the second before, it is
-- still the same day; from then on, the next. Apps read the calendar again then.
function tests.today_says_when_the_hebrew_date_changes_next()
    for _, place in ipairs({
        { "Tel Aviv", nil, { "2026-10-02T09:00:00Z", "2026-10-02T15:30:00Z", "2026-10-03T21:30:00Z" } },
        { "no location", NO_LOCATION, { "2026-10-05T07:00:00Z", "2026-10-05T22:30:00Z" } },
        { "the midnight sun", TROMSO, { "2026-06-25T10:00:00Z" } },
        { "Reykjavik in June", REYKJAVIK, { "2026-06-19T22:00:00Z", "2026-06-19T23:59:30Z", "2026-06-20T00:10:00Z" } },
    }) do
        local mock, clock = start(Helpers.epoch(place[3][1]), { calendar = true, project = place[2] and project(place[2]) })
        local admin = T.pair(mock)
        local function today(at)
            clock.set(at)
            return calendarAnswer(mock, admin).today
        end
        for _, when in ipairs(place[3]) do
            local label = place[1] .. " at " .. when
            local now = Helpers.epoch(when)
            local seen = today(now)
            local changes = Helpers.epoch(seen.changes_at)
            T.truthy(changes > now and changes - now <= 2 * 86400, label)
            T.eq(today(changes - 1).date, seen.date, label .. ": the second before")
            T.truthy(today(changes).date ~= seen.date, label .. ": from then")
        end
    end
end

-- 13 ----------------------------------------------------------------------------------------

function tests.composer_shows_shabbat_schedules_and_the_calendar()
    local mock, clock, Scheduler = start(CANDLES - 5 * 3600, { calendar = true })
    local admin = T.pair(mock)
    local lights = scene(mock, admin, "Shabbat lights", 20)
    local candles = schedule(mock, admin, { scene_id = lights, trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } })
    schedule(mock, admin, { scene_id = lights, trigger = { type = "shabbat", event = "havdalah" }, days = { 6 } })
    local after = schedule(mock, admin, { scene_id = lights, trigger = { type = "shabbat", event = "havdalah", offset = 20 } })
    schedule(mock, admin, { scene_id = lights, trigger = { type = "time", at = "07:30" }, during_shabbat = "skip" })
    local evening = CANDLES + 3600 -- Friday evening, local time
    schedule(mock, admin, { scene_id = lights, trigger = { type = "time", at = hhmm(evening) }, days = { 5 }, only_if = { not_raining = true }, during_shabbat = "only" })
    T.eq(candles.next_run, iso(CANDLES - 30 * 60))
    T.contains(mock.properties["Schedule Status"], "5 on · next ")
    T.contains(mock.properties["Schedule Status"], " Shabbat lights · 4 Shabbat schedules")

    local text = table.concat(printout(), " | ")
    T.contains(text, "Jewish calendar: Israel (from the location) · candles 20 min before sunset")
    T.contains(text, "[on] 30 min before candle lighting -> Shabbat lights · next ")
    T.contains(text, "[on] Sat: at havdalah -> Shabbat lights")
    T.contains(text, "[on] 20 min after havdalah -> Shabbat lights")
    T.contains(text, "[on] every day 07:30 -> Shabbat lights · not on Shabbat and holidays")
    T.contains(text, "[on] Fri " .. hhmm(evening) .. " -> Shabbat lights · only if not raining, only on Shabbat and holidays")
    T.notContains(text, "rain starts", "a Shabbat trigger is not a rain rule")

    clock.set(CANDLES - 30 * 60 + 20)
    T.eq(Scheduler.tick(), 1)
    T.eq(mock.properties["Last Automation"], os.date("%d %b %H:%M", CANDLES - 30 * 60 + 20) .. " Shabbat lights · schedule 30 min before candle lighting · 1 device")
    -- The controller is off until 40 minutes after havdalah: both havdalah schedules run late.
    local restarted = start(HAVDALAH + 40 * 60, { previous = mock, calendar = true })
    T.eq(require("src.core.scheduler").tick(), 2)
    T.eq(get(restarted, admin, after.id).last_run.note, "late")
    T.eq(restarted.properties["Last Automation"], os.date("%d %b %H:%M", HAVDALAH + 40 * 60) .. " Shabbat lights · schedule 20 min after havdalah, late after a restart · 1 device")
    text = table.concat(printout(), " | ")
    T.contains(text, "(1 ran, 0 skipped, 0 failed, late after a restart)")
end

-- 14 ----------------------------------------------------------------------------------------

-- Israel's clocks go forward on a Friday (27 March 2026) and back on a Sunday (25 October 2026):
-- Shabbat times are moments, never minutes of the day, so neither moves them.
function tests.israels_clock_changes_move_no_shabbat_time()
    if Helpers.zone() ~= "Asia/Jerusalem" then
        T.skip("for TZ=Asia/Jerusalem")
    end
    local mock, clock, Scheduler = start(Helpers.epoch("2026-03-26T08:00:00Z"), { calendar = true })
    local admin = T.pair(mock)
    local sceneId = scene(mock, admin)
    local candles = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "candle_lighting" } })
    local evening = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "19:00" }, days = { 5 }, during_shabbat = "only" })
    local before = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "18:00" }, days = { 5 }, during_shabbat = "skip" })
    T.eq(candles.next_run, "2026-03-27T15:37:00Z", "18:37 summer time")
    T.eq(evening.next_run, "2026-03-27T16:00:00Z")
    T.eq(before.next_run, "2026-03-27T15:00:00Z")
    T.eq(mock.properties["Calendar Status"], "Israel (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 27 Mar 18:37 to Sat 28 Mar 19:40 Shabbat")
    local ran = 0
    for _, moment in ipairs({ "2026-03-27T15:00:20Z", "2026-03-27T15:37:20Z", "2026-03-27T16:00:20Z" }) do
        clock.set(Helpers.epoch(moment))
        ran = ran + Scheduler.tick()
    end
    T.eq(ran, 3)
    T.contains(mock.properties["Last Automation"], "27 Mar 19:00")

    -- The last Friday of summer time and the first of winter time.
    local autumn, later, Autumn = start(Helpers.epoch("2026-10-22T08:00:00Z"), { previous = mock, calendar = true })
    T.eq(autumn.properties["Calendar Status"], "Israel (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 23 Oct 17:39 to Sat 24 Oct 18:41 Shabbat")
    local fridays = schedule(autumn, admin, { scene_id = sceneId, trigger = { type = "time", at = "17:30" }, days = { 5 }, during_shabbat = "skip" })
    local night = schedule(autumn, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "havdalah", offset = 360 }, days = { 0 } })
    T.eq(fridays.next_run, "2026-10-23T14:30:00Z", "17:30 summer time: before candle lighting (17:39)")
    T.eq(night.next_run, "2026-10-24T21:41:00Z", "00:41 on Sunday, before the clocks go back")
    later.set(Helpers.epoch("2026-10-23T14:30:20Z"))
    T.eq(Autumn.tick(), 1)
    T.truthy(isNull(get(autumn, admin, fridays.id).next_run), "in winter time 17:30 on a Friday is after candle lighting (30 October 16:32)")
    later.set(Helpers.epoch("2026-10-29T08:00:00Z"))
    Autumn.tick()
    T.eq(autumn.properties["Calendar Status"], "Israel (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 30 Oct 16:32 to Sat 31 Oct 17:34 Shabbat")
    later.set(Helpers.epoch("2026-10-30T15:30:20Z"))
    T.eq(Autumn.tick(), 0)
    T.eq(get(autumn, admin, fridays.id).last_run.skipped_by, "shabbat")
end

-- The United States' clocks go forward on 8 March and back on 1 November 2026, on Sundays.
function tests.new_yorks_clock_changes_move_no_shabbat_time()
    if Helpers.zone() ~= "America/New_York" then
        T.skip("for TZ=America/New_York")
    end
    local mock, clock, Scheduler = start(Helpers.epoch("2026-03-05T15:00:00Z"), { calendar = true, zone = "America/New_York", project = project(NEW_YORK) })
    local admin = T.pair(mock)
    local sceneId = scene(mock, admin)
    T.eq(mock.properties["Calendar Status"], "Abroad (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 06 Mar 17:32 to Sat 07 Mar 18:36 Shabbat")
    local fridays = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "time", at = "18:00" }, days = { 5 }, during_shabbat = "skip" })
    local night = schedule(mock, admin, { scene_id = sceneId, trigger = { type = "shabbat", event = "havdalah", offset = 360 }, days = { 0 } })
    T.eq(fridays.next_run, "2026-03-13T22:00:00Z", "6 March 18:00 is after candle lighting (17:32); 13 March 18:00 summer time is before it (18:40)")
    T.eq(night.next_run, "2026-03-08T05:36:00Z", "00:36 on Sunday, before the clocks go forward")
    clock.set(Helpers.epoch("2026-03-06T23:00:20Z"))
    T.eq(Scheduler.tick(), 0)
    T.eq(get(mock, admin, fridays.id).last_run.skipped_by, "shabbat")
    clock.set(Helpers.epoch("2026-03-08T05:36:20Z"))
    T.eq(Scheduler.tick(), 1)
    clock.set(Helpers.epoch("2026-03-12T15:00:00Z"))
    Scheduler.tick()
    T.eq(mock.properties["Calendar Status"], "Abroad (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 13 Mar 18:40 to Sat 14 Mar 19:44 Shabbat")
    clock.set(Helpers.epoch("2026-03-13T22:00:20Z"))
    T.eq(Scheduler.tick(), 1)

    clock.set(Helpers.epoch("2026-10-29T15:00:00Z"))
    Scheduler.tick()
    T.eq(mock.properties["Calendar Status"], "Abroad (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 30 Oct 17:34 to Sat 31 Oct 18:35 Shabbat")
    T.eq(get(mock, admin, night.id).next_run, "2026-11-01T04:35:00Z", "00:35 on Sunday, before the clocks go back")
    clock.set(Helpers.epoch("2026-11-05T15:00:00Z"))
    Scheduler.tick()
    T.eq(mock.properties["Calendar Status"], "Abroad (from the location) · candles 20 min before sunset, havdalah 42 min after · next Fri 06 Nov 16:26 to Sat 07 Nov 17:27 Shabbat")
end

return tests
