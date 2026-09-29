-- The Jewish calendar (ADR-037): Shabbat and holiday times behind the Composer property Jewish
-- Calendar, Off by default. With it off the API says so (/v1/calendar, /v1/system), refuses to
-- set calendar features (409 JEWISH_CALENDAR_OFF), and Shabbat triggers and "only" schedules are
-- kept but do not run, while "skip" schedules run as usual.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local EVERY_DAY = { 0, 1, 2, 3, 4, 5, 6 }

local function isNull(value)
    return value == Json.null
end

-- Starts the driver with the clock at `now` (changed later with clock.set).
local function start(now)
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Chrome on Windows")
    local clock = { now = now or os.time() }
    require("src.core.clock").now = function()
        return clock.now
    end
    function clock.set(value)
        clock.now = value
    end
    return mock, admin, clock, require("src.core.scheduler")
end

local function setCalendar(value)
    Properties["Jewish Calendar"] = value
    OnPropertyChanged("Jewish Calendar")
end

local function scene(mock, admin)
    local created = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Shabbat lights", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } })
    T.eq(created.status, 201, created.body)
    return created.json.id
end

local function key(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role, role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key
end

-- Local time `hh:mm` on the day `days` after today.
local function at(days, hh, mm)
    local fields = os.date("*t", os.time() + days * 86400)
    fields.hour, fields.min, fields.sec = hh, mm, 0
    return os.time(fields)
end

function tests.the_calendar_is_off_by_default_and_says_so()
    local mock, admin = start()
    local calendar = T.http(mock, "GET", "/v1/calendar", { key = admin })
    T.eq(calendar.status, 200, calendar.body)
    T.eq(calendar.json.enabled, false)
    T.eq(calendar.json.status, "off")
    for _, field in ipairs({ "settings", "today", "week", "current", "next" }) do
        T.contains(calendar.body, '"' .. field .. '":null', field .. " is there, and null")
    end
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.jewish_calendar, false)

    local settings = T.http(mock, "PATCH", "/v1/calendar/settings", { key = admin, body = { candle_lighting_minutes = 30, version = 1 } })
    T.eq(settings.status, 409, settings.body)
    T.eq(settings.json.code, "JEWISH_CALENDAR_OFF")
    T.contains(settings.json.detail, "Jewish Calendar property in Composer")

    local sceneId = scene(mock, admin)
    local post = function(body)
        body.scene_id, body.days = sceneId, body.days or EVERY_DAY
        return T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
    end
    for _, body in ipairs({
        { trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } },
        { trigger = { type = "time", at = "07:30" }, during_shabbat = "skip" },
        { trigger = { type = "sun", event = "sunset" }, during_shabbat = "only" },
    }) do
        local refused = post(body)
        T.eq(refused.status, 409, refused.body)
        T.eq(refused.json.code, "JEWISH_CALENDAR_OFF")
    end
    T.eq(#T.http(mock, "GET", "/v1/schedules", { key = admin }).json.items, 0, "none of them was kept")

    -- An ordinary schedule, and one that says "run as usual" in full.
    for _, body in ipairs({ { trigger = { type = "time", at = "07:30" } }, { trigger = { type = "time", at = "07:45" }, during_shabbat = "run" } }) do
        local created = post(body)
        T.eq(created.status, 201, created.body)
        T.eq(created.json.during_shabbat, "run")
        T.truthy(isNull(created.json.calendar_status), "an ordinary schedule has no calendar status")
    end
end

function tests.everyone_reads_the_calendar_and_only_admins_change_its_settings()
    local mock, admin = start()
    local viewer, member = key(mock, admin, "viewer"), key(mock, admin, "member")
    local read = T.http(mock, "GET", "/v1/calendar", { key = viewer })
    T.eq(read.status, 200, read.body)
    T.eq(read.json.status, "off")
    T.eq(T.http(mock, "GET", "/v1/calendar").status, 401)
    for _, apiKey in ipairs({ viewer, member }) do
        local refused = T.http(mock, "PATCH", "/v1/calendar/settings", { key = apiKey, body = { havdalah_minutes = 50 } })
        T.eq(refused.status, 403, refused.body)
        T.eq(refused.json.code, "FORBIDDEN")
        T.eq(refused.json.required_role, "admin")
    end
end

function tests.a_settings_change_is_checked_before_it_is_refused()
    local mock, admin = start()
    local patch = function(body)
        return T.http(mock, "PATCH", "/v1/calendar/settings", { key = admin, body = body })
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
    local mock, admin = start()
    setCalendar("On")
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.jewish_calendar, true)
    local sceneId = scene(mock, admin)
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = { scene_id = sceneId, trigger = { type = "shabbat", event = "candle_lighting", offset = -30 }, days = EVERY_DAY } })
    T.eq(created.status, 201, created.body)
    T.same(created.json.trigger, { event = "candle_lighting", offset = -30, type = "shabbat" })
    T.eq(created.json.during_shabbat, "run")
    setCalendar("Off")
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.jewish_calendar, false)
end

function tests.calendar_schedules_are_kept_but_do_not_run_while_the_calendar_is_off()
    local eight = at(1, 8, 0)
    local mock, admin, clock, Scheduler = start(eight - 3600)
    local sceneId = scene(mock, admin)
    setCalendar("On")
    local function create(body)
        body.scene_id, body.days = sceneId, EVERY_DAY
        local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
        T.eq(created.status, 201, created.body)
        return created.json.id
    end
    local candles = create({ trigger = { type = "shabbat", event = "candle_lighting", offset = -30 } })
    local only = create({ trigger = { type = "time", at = "08:00" }, during_shabbat = "only" })
    local skip = create({ trigger = { type = "time", at = "08:00" }, during_shabbat = "skip" })
    local plain = create({ trigger = { type = "time", at = "08:00" } })
    setCalendar("Off")

    local function get(id)
        return T.http(mock, "GET", "/v1/schedules/" .. id, { key = admin }).json
    end
    for _, id in ipairs({ candles, only, skip }) do
        T.eq(get(id).calendar_status, "off", "it says why")
    end
    T.truthy(isNull(get(plain).calendar_status))
    T.truthy(isNull(get(candles).next_run), "a Shabbat trigger has no next run")
    T.truthy(isNull(get(only).next_run), "nothing counts as Shabbat, so no next run")
    local eightUtc = os.date("!%Y-%m-%dT%H:%M:%SZ", eight)
    T.eq(get(skip).next_run, eightUtc, "skip runs as usual")
    T.eq(get(plain).next_run, eightUtc)

    local before = #mock.commands
    clock.set(eight + 30)
    T.eq(Scheduler.tick(), 2, "the skip and the ordinary schedule")
    T.truthy(#mock.commands > before)
    T.eq(get(skip).last_run.ran, 1)
    T.truthy(isNull(get(only).last_run), "only on Shabbat: not run")
    T.truthy(isNull(get(candles).last_run))

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
    T.eq(cleared.json.next_run, os.date("!%Y-%m-%dT%H:%M:%SZ", at(2, 8, 0)))
    T.eq(get(skip).during_shabbat, "skip", "a refused change leaves it as it was")

    -- And they survive an update of the driver.
    local updated = Mock.updateDriver(mock)
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

return tests
