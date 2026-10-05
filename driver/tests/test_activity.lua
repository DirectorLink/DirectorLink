-- The activity history (ADR-046, src/core/activity.lua, GET /v1/activity): what is kept and for how
-- long, how it is written and that it survives a driver update, every event hooked into it, and the
-- API with its roles, kinds and pages.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")
local Helpers = require("calendar_helpers")

local tests = {}

local DAY = 24 * 3600

local function start(prepare, initType)
    local mock = Mock.startDriver(nil, nil, initType, prepare)
    local admin = T.pair(mock, "Chrome on Windows")
    return mock, admin
end

local function history(mock, key, query)
    local answer = T.http(mock, "GET", "/v1/activity" .. (query or ""), { key = key })
    T.eq(answer.status, 200, answer.body)
    return answer.json.items, answer.json
end

-- The newest entry of this kind and action, or nil.
local function newest(mock, key, kind, action)
    for _, item in ipairs(history(mock, key, "?limit=200")) do
        if item.kind == kind and item.action == action then
            return item
        end
    end
    return nil
end

local function all(mock, key, kind, action)
    local found = {}
    for _, item in ipairs(history(mock, key, "?limit=200")) do
        if item.kind == kind and (action == nil or item.action == action) then
            found[#found + 1] = item
        end
    end
    return found
end

local function createKey(mock, admin, role, name)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name or (role .. " phone"), role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json.id
end

-- The history's save timers that wait.
local function saveTimers(mock)
    local found = {}
    for _, timer in ipairs(mock.timers) do
        if not timer.fired and not timer.cancelled and timer.source:find("core/activity", 1, true) then
            found[#found + 1] = timer
        end
    end
    return found
end

local function fire(timer)
    T.truthy(timer, "a timer is waiting")
    timer.fired = true
    timer.callback()
end

-- os.time (and with it Clock.now) moved on by what `body` adds with advance(seconds).
local function withClock(body)
    local realTime = os.time
    local offset = 0
    os.time = function(date)
        if date then
            return realTime(date)
        end
        return realTime() + offset
    end
    local ok, err = pcall(body, function(seconds)
        offset = offset + seconds
    end)
    os.time = realTime
    if not ok then
        error(err, 0)
    end
end

-- ---- what is kept, and how ----------------------------------------------------------------------

function tests.the_newest_entries_are_kept_and_none_older_than_thirty_days()
    local mock, admin = start()
    local Activity = require("src.core.activity")
    Activity.MAX_ENTRIES, Activity.PAGE_SIZE = 20, 5
    for index = 1, 33 do
        Activity.record("scene", "run", { what = "Scene " .. index })
    end
    local items = history(mock, admin, "?limit=200")
    T.truthy(#items >= 16 and #items <= 20, "the newest 16 to 20: " .. #items)
    T.eq(items[1].what, "Scene 33", "newest first")
    T.eq(items[#items].what, "Scene " .. (34 - #items), "the oldest ones went")
    T.eq(Activity.count(), #items)
    Activity.flush()
    for slot = 1, 4 do
        T.truthy(mock.persist["directorlink_activity_" .. slot], "page " .. slot .. " is written")
    end
    T.eq(mock.persist["directorlink_activity_5"], nil, "never more pages than MAX_ENTRIES needs")

    withClock(function(advance)
        advance(31 * DAY)
        T.eq(#history(mock, admin), 0, "nothing older than 30 days is shown")
        Activity.record("scene", "run", { what = "A month later" })
        T.eq(Activity.count(), 1, "and the old pages go")
        Activity.flush()
        local stored = 0
        for slot = 1, 4 do
            stored = stored + select(2, mock.persist["directorlink_activity_" .. slot]:gsub('"kind":', ""))
        end
        T.eq(stored, 1, "their pages are written empty")
        T.eq(history(mock, admin)[1].what, "A month later")
    end)
end

function tests.names_are_cut_whole_and_a_failure_never_reaches_the_caller()
    local mock, admin = start()
    local Activity = require("src.core.activity")
    local hebrew = string.rep("א", 80)
    local entry = Activity.record("scene", "run", { what = hebrew, room = "Kitchen\nNorth" })
    T.eq(#entry.what, 100, "100 bytes: 50 Hebrew letters")
    T.eq(entry.what, string.rep("א", 50))
    T.eq(entry.room, "Kitchen North", "no control characters")
    local odd = Activity.record("scene", "run", { what = "a" .. string.rep("א", 80) })
    T.eq(#odd.what, 99, "never half a letter")
    T.eq(Activity.record("scene", "run", nil), nil, "nothing happened: nothing recorded")
    T.eq(Activity.record("lights", "on", {}), nil, "an unknown kind")
    -- A who that cannot be worked out is logged, not raised.
    local broken = Activity.record("scene", "run", { by = setmetatable({}, { __index = function()
        error("broken key")
    end }) })
    T.eq(broken, nil)
    T.eq(history(mock, admin)[1].what, "a" .. string.rep("א", 49))
end

function tests.entries_are_written_a_page_at_a_time_at_most_every_three_seconds()
    local mock = start()
    local Activity = require("src.core.activity")
    local writes = {}
    local original = C4.PersistSetValue
    C4.PersistSetValue = function(self, name, value, encrypted)
        writes[name] = (writes[name] or 0) + 1
        return original(self, name, value, encrypted)
    end
    local ok, err = pcall(function()
        local waiting = saveTimers(mock)
        T.eq(#waiting, 1, "one save waits for the entries of the start")
        T.eq(waiting[1].delay, 3000)
        T.eq(writes["directorlink_activity_1"], nil, "not yet written")
        for index = 1, 5 do
            Activity.record("door", "pulse", { what = "Gate " .. index })
        end
        T.eq(#saveTimers(mock), 1, "still one")
        fire(waiting[1])
        T.eq(writes["directorlink_activity_1"], 1, "five entries, one write")
        T.contains(mock.persist["directorlink_activity_1"], "Gate 5")
        T.eq(#saveTimers(mock), 0)
        -- Only the page that changed is written.
        Activity.PAGE_SIZE = 8
        for index = 1, 3 do
            Activity.record("door", "pulse", { what = "Door " .. index })
        end
        fire(saveTimers(mock)[1])
        T.eq(writes["directorlink_activity_1"], 2)
        T.eq(writes["directorlink_activity_2"], 1, "a new page")
        Activity.record("door", "pulse", { what = "Door 4" })
        fire(saveTimers(mock)[1])
        T.eq(writes["directorlink_activity_1"], 2, "the full page is not written again")
        T.eq(writes["directorlink_activity_2"], 2)
        T.notContains(mock.persist["directorlink_activity_2"], "Gate", "a page holds only its own entries")
    end)
    C4.PersistSetValue = original
    if not ok then
        error(err, 0)
    end
end

function tests.the_history_survives_a_driver_update_and_says_which()
    local mock, admin = start()
    local items = history(mock, admin)
    T.eq(items[#items].action, "driver_started", "the first start")
    T.eq(items[#items].to, "dev")
    T.eq(items[#items].who.type, "controller")
    local Activity = require("src.core.activity")
    Activity.record("scene", "run", { what = "Just before the update" })
    -- Director stops the old driver: what waits is written at once.
    OnDriverDestroyed("DIT_UPDATING")
    T.contains(mock.persist["directorlink_activity_1"], "Just before the update")
    local updated = Mock.updateDriver(mock)
    items = history(updated, admin)
    T.eq(items[1].action, "driver_updated")
    T.eq(items[1].from, "dev")
    T.eq(items[1].to, "dev")
    T.eq(items[2].what, "Just before the update", "kept across the update")
    T.truthy(items[1].id > items[2].id, "ids go on")

    -- From 1.5.0, which kept no history: an update to this version.
    local function system()
        return require("src.core.activity").list({ kinds = { system = true } })[1]
    end
    start(nil, "DIT_UPDATING")
    T.eq(system().action, "driver_updated")
    T.eq(system().from, nil)
    T.eq(system().to, "dev")
    -- Another version ran before (a restart after an update while the driver was off), or added.
    start(function(fresh)
        fresh.persist["directorlink_activity"] = "json:" .. Json.encode({ version = 1, driver = "1.5.0" })
    end)
    T.eq(system().action, "driver_updated")
    T.eq(system().from, "1.5.0")
    start(nil, "DIT_ADDING")
    T.eq(system().action, "driver_added")
end

-- ---- the API ------------------------------------------------------------------------------------

function tests.admins_read_the_history_newest_first_by_kind_and_in_pages()
    local mock, admin = start()
    local Activity = require("src.core.activity")
    for index = 1, 7 do
        Activity.record(index % 2 == 0 and "door" or "scene", "run", { what = "Entry " .. index })
    end
    local items, answer = history(mock, admin, "?limit=3")
    T.eq(#items, 3)
    T.eq(items[1].what, "Entry 7")
    T.eq(answer.next_before, items[3].id, "the next page starts before the last one shown")
    T.truthy(items[1].at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), "ISO times")
    local second = history(mock, admin, "?limit=3&before=" .. answer.next_before)
    T.eq(second[1].what, "Entry 4")
    local doors, doorsAnswer = history(mock, admin, "?kind=door")
    T.eq(#doors, 3)
    T.eq(doors[1].what, "Entry 6")
    T.truthy(doorsAnswer.next_before == Json.null, "no more")
    T.eq(#history(mock, admin, "?kind=door,scene&limit=200"), 7)
    T.eq(#history(mock, admin, "?kind=door%2Cscene&limit=200"), 7, "the comma may be encoded")
    T.eq(#history(mock, admin, "?kind=system"), 1, "the start")
    T.contains(T.http(mock, "GET", "/v1/activity", { key = admin }).body, '"next_before":null')

    for _, bad in ipairs({ "?kind=lights", "?kind=door,", "?before=0", "?before=x", "?limit=0", "?limit=201" }) do
        local refused = T.http(mock, "GET", "/v1/activity" .. bad, { key = admin })
        if bad == "?kind=door," then
            T.eq(refused.status, 200, "an empty part is left out")
        else
            T.eq(refused.status, 400, bad)
            T.eq(refused.json.code, "INVALID_PARAMETER", bad)
        end
    end
    for _, role in ipairs({ "viewer", "member", "doors" }) do
        local key = createKey(mock, admin, role)
        local refused = T.http(mock, "GET", "/v1/activity", { key = key })
        T.eq(refused.status, 403, role)
        T.eq(refused.json.code, "FORBIDDEN")
    end
    T.eq(T.http(mock, "GET", "/v1/activity").status, 401)
end

function tests.sealed_requests_read_it_too()
    local mock, admin = start()
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = admin }).json
    local Lock = require("src.cloud.lock")
    local info = T.http(mock, "GET", "/v1/sealed").json
    local lock = Lock.deviceKey(admin)
    local envelope = Lock.seal(lock, info.home, me.id, "req", Json.encode({ id = "history-1", ts = info.time, method = "GET", path = "/v1/activity?kind=access&limit=5" }))
    local response = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    T.eq(answer.status, 200)
    local items = Json.decode(answer.body).items
    T.eq(#items, 1)
    T.eq(items[1].action, "paired")
end

-- A console key (ADR-040) that expired a minute ago, before the scheduler's minute removed it, goes
-- when the history looks up who ran a scene with another key: that "expired" entry is recorded
-- while the scene's is built, and each gets an id of its own, in the order of the pages.
function tests.an_entry_recorded_while_another_is_built_gets_its_own_id()
    withClock(function(advance)
        local mock, admin = start()
        local sceneId = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Good night", steps = { { type = "lights", device_ids = { 20 }, set = { on = false } } } } }).json.id
        T.truthy(require("src.auth.keys").create("API console", "admin", nil, os.time() + 60))
        advance(120)
        T.eq(T.http(mock, "POST", "/v1/scenes/" .. sceneId .. "/run", { key = admin }).status, 202)
        local items = history(mock, admin, "?limit=200")
        T.eq(items[1].action, "run")
        T.eq(items[2].action, "expired")
        T.eq(items[2].what, "API console")
        local seen = {}
        for index, item in ipairs(items) do
            T.eq(seen[item.id], nil, "id " .. item.id .. " once")
            seen[item.id] = true
            if index > 1 then
                T.truthy(item.id < items[index - 1].id, "newest first, by id")
            end
        end
        -- A page that ends on the scene run goes on with the key that expired.
        local first, answer = history(mock, admin, "?limit=1")
        T.eq(first[1].action, "run")
        T.eq(history(mock, admin, "?limit=1&before=" .. answer.next_before)[1].action, "expired")
    end)
end

-- ---- what goes in ---------------------------------------------------------------------------------

function tests.scenes_run_from_the_app_say_who_and_how_it_went()
    local mock, admin = start(function()
        Properties["Door Control"] = "Enabled"
    end)
    local profile = T.http(mock, "GET", "/v1/profile", { key = admin }).json
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profile.id, { key = admin, body = { name = "Dana" } }).status, 200)
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = {
        name = "Good night", steps = {
            { type = "lights", device_ids = { 20, 21 }, set = { on = false } },
            { type = "relays", device_ids = { 70 }, set = { action = "pulse" } },
        },
    } }).json
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = admin }).status, 202)
    local ran = newest(mock, admin, "scene", "run")
    T.eq(ran.what, "Good night")
    T.eq(ran.outcome, "ran")
    T.same(ran.counts, { failed = 0, ran = 3, skipped = 0 })
    T.eq(ran.ids.scene_id, scene.id)
    T.eq(ran.who.type, "key")
    T.eq(ran.who.name, "Chrome on Windows", "the device")
    T.eq(ran.who.profile, "Dana", "and the person")
    local door = newest(mock, admin, "door", "pulse")
    T.eq(door.what, "Main Door")
    T.eq(door.room, "Kitchen")
    T.eq(door.via, "Good night", "opened by the scene")
    T.eq(door.ids.device_id, 70)

    -- A member's run of a scene chosen for them: in full (ADR-054), the door too. With Door
    -- Control off, the door is skipped; a scene of only doors does nothing.
    local member = createKey(mock, admin, "member", "Kids tablet")
    local gate = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Gate", steps = { { type = "relays", device_ids = { 70 }, set = { action = "pulse" } } } } }).json
    local memberProfile = T.http(mock, "GET", "/v1/api-keys/current", { key = member }).json.profile_id
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. memberProfile .. "/access", { key = admin, body = { scenes = { scene.id, gate.id } } }).status, 200)
    T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = member })
    T.same(newest(mock, admin, "scene", "run").counts, { failed = 0, ran = 3, skipped = 0 })
    T.eq(newest(mock, admin, "scene", "run").who.name, "Kids tablet")
    T.eq(#all(mock, admin, "door"), 2, "the member's run opened the door")
    Properties["Door Control"] = "Disabled"
    T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = member })
    T.same(newest(mock, admin, "scene", "run").counts, { failed = 0, ran = 2, skipped = 1 })
    T.http(mock, "POST", "/v1/scenes/" .. gate.id .. "/run", { key = member })
    local skipped = newest(mock, admin, "scene", "run")
    T.eq(skipped.outcome, "skipped", "nothing ran")
    T.eq(#all(mock, admin, "door"), 2, "no door opened")
    -- A device the controller cannot reach: failed, and on how many.
    local send = C4.SendToDevice
    C4.SendToDevice = function(self, deviceId, command, params)
        if deviceId == 20 then
            error("device offline")
        end
        return send(self, deviceId, command, params)
    end
    local answer = T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = member })
    C4.SendToDevice = send
    T.eq(answer.status, 202)
    local failed = newest(mock, admin, "scene", "run")
    T.eq(failed.outcome, "failed")
    T.same(failed.counts, { failed = 1, ran = 1, skipped = 1 })

    -- Home's Turn off all.
    T.eq(T.http(mock, "POST", "/v1/off", { key = member, body = { type = "lights", device_ids = { 20, 22 } } }).status, 202)
    local off = newest(mock, admin, "scene", "off")
    T.eq(off.note, "lights")
    T.eq(off.counts.ran, 2)
    T.eq(off.who.name, "Kids tablet")
end

function tests.doors_and_gates_say_who_opened_them()
    local mock, admin = start(function()
        Properties["Door Control"] = "Enabled"
        Properties["Relay Hold"] = "Allowed"
    end)
    local doors = createKey(mock, admin, "doors", "Gate phone")
    T.eq(T.http(mock, "POST", "/v1/relays/70/pulse", { key = doors }).status, 202)
    local pulse = newest(mock, admin, "door", "pulse")
    T.eq(pulse.what, "Main Door")
    T.eq(pulse.room, "Kitchen")
    T.eq(pulse.who.name, "Gate phone")
    T.eq(pulse.via, nil)
    T.eq(T.http(mock, "PATCH", "/v1/relays/70", { key = admin, body = { state = "closed" } }).status, 202)
    T.eq(newest(mock, admin, "door", "hold").who.name, "Chrome on Windows")
    T.eq(T.http(mock, "PATCH", "/v1/relays/70", { key = admin, body = { state = "open" } }).status, 202)
    T.truthy(newest(mock, admin, "door", "release"))
    T.eq(T.http(mock, "POST", "/v1/doorbells/93/open", { key = doors }).status, 202)
    local gate = newest(mock, admin, "door", "doorbell")
    T.eq(gate.what, "Front Gate")
    T.eq(gate.ids.device_id, 93)
    -- Refused (Door Control off): nothing opened, nothing recorded.
    Properties["Door Control"] = "Disabled"
    OnPropertyChanged("Door Control")
    T.eq(T.http(mock, "POST", "/v1/relays/70/pulse", { key = doors }).status, 403)
    local items = history(mock, admin, "?kind=door")
    T.eq(#items, 4)
    T.eq(items[1].action, "doorbell")
end

-- Shabbat and Shmini Atzeret 5787 in Tel Aviv (Mock.project): candle lighting on Friday 2 October
-- 2026 at 15:04 UTC, havdalah on Saturday at 16:05 UTC.
local CANDLES = Helpers.epoch("2026-10-02T15:04:00Z")
local HAVDALAH = Helpers.epoch("2026-10-03T16:05:00Z")

local function weather(temperature, rain)
    return {
        current = { temperature_2m = temperature, precipitation = rain or 0, weather_code = 0, wind_speed_10m = 5, wind_gusts_10m = 8 },
        daily = { temperature_2m_max = Json.array({ temperature + 2 }), temperature_2m_min = Json.array({ temperature - 8 }), precipitation_probability_max = Json.array({ 10 }) },
    }
end

-- The driver with the Jewish calendar on and the clock at `now`; `previous`: started again with
-- its data.
local function startCalendar(now, previous)
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
        require("src.core.clock").now = function()
            return clock.now
        end
    end)
    return mock, clock, require("src.core.scheduler")
end

local function schedule(mock, admin, sceneId, due, extra)
    local body = { scene_id = sceneId, trigger = { type = "time", at = os.date("%H:%M", due) }, days = { os.date("*t", due).wday - 1 } }
    for name, value in pairs(extra or {}) do
        body[name] = value
    end
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = body })
    T.eq(created.status, 201, created.body)
    return created.json.id
end

local function scheduleEntry(mock, admin, id)
    for _, item in ipairs(history(mock, admin, "?kind=schedule&limit=200")) do
        if item.ids.schedule_id == id then
            return item
        end
    end
    return nil
end

function tests.schedules_say_when_they_ran_and_why_they_did_not()
    local before, inside, after = CANDLES - 2 * 3600, HAVDALAH - 2 * 3600, HAVDALAH + 2 * 3600
    local mock, clock, Scheduler = startCalendar(CANDLES - 3 * 3600)
    local admin = T.pair(mock)
    local sceneId = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Evening AC", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } }).json.id
    local plain = schedule(mock, admin, sceneId, before)
    local dry = schedule(mock, admin, sceneId, before, { only_if = { not_raining = true } })
    local onlyShabbat = schedule(mock, admin, sceneId, before, { during_shabbat = "only" })
    local notShabbat = schedule(mock, admin, sceneId, inside, { during_shabbat = "skip" })
    local whilePaused = schedule(mock, admin, sceneId, after)
    local calendarOff = schedule(mock, admin, sceneId, after + 3600, { during_shabbat = "only" })
    mock.weather = weather(18, 1.2)

    clock.set(before + 30)
    T.eq(Scheduler.tick(), 1)
    local ran = scheduleEntry(mock, admin, plain)
    T.eq(ran.outcome, "ran")
    T.eq(ran.what, "Evening AC")
    T.eq(ran.counts.ran, 1)
    T.eq(ran.who.type, "schedule")
    T.eq(ran.who.schedule_id, plain)
    T.eq(ran.who.trigger.type, "time")
    T.eq(ran.who.trigger.at, os.date("%H:%M", before), "its time, for the app to say")
    T.same(ran.who.days, { os.date("*t", before).wday - 1 })
    T.eq(ran.ids.scene_id, sceneId)
    local rain = scheduleEntry(mock, admin, dry)
    T.eq(rain.outcome, "skipped")
    T.eq(rain.reason, "only_if")
    T.eq(scheduleEntry(mock, admin, onlyShabbat), nil, "not Shabbat yet: like a day not in its days")

    clock.set(inside + 30)
    T.eq(Scheduler.tick(), 0)
    local shabbat = scheduleEntry(mock, admin, notShabbat)
    T.eq(shabbat.outcome, "skipped")
    T.eq(shabbat.reason, "shabbat")

    Properties["Schedules"] = "Paused"
    OnPropertyChanged("Schedules")
    local setting = newest(mock, admin, "composer", "setting")
    T.eq(setting.what, "Schedules")
    T.eq(setting.to, "Paused")
    T.eq(setting.who.type, "composer")
    clock.set(after + 10)
    T.eq(Scheduler.tick(), 0)
    local paused = scheduleEntry(mock, admin, whilePaused)
    T.eq(paused.reason, "paused")
    clock.set(after + 70)
    Scheduler.tick()
    T.eq(#all(mock, admin, "schedule"), 4, "said once")
    -- Resumed within its 5 minutes: it still runs.
    Properties["Schedules"] = "On"
    OnPropertyChanged("Schedules")
    clock.set(after + 130)
    T.eq(Scheduler.tick(), 1)
    T.eq(scheduleEntry(mock, admin, whilePaused).outcome, "ran")

    Properties["Jewish Calendar"] = "Off"
    OnPropertyChanged("Jewish Calendar")
    T.eq(newest(mock, admin, "composer", "setting").what, "Jewish Calendar")
    clock.set(after + 3600 + 30)
    T.eq(Scheduler.tick(), 0)
    local off = scheduleEntry(mock, admin, calendarOff)
    T.eq(off.outcome, "skipped")
    T.eq(off.reason, "calendar_off")
end

-- Paused in Composer for days: each schedule's skip is listed once for the pause, not once a run,
-- so that two weeks away with many daily schedules leave the rest of the history in place.
function tests.a_schedule_skipped_while_paused_is_listed_once_a_pause()
    local monday = Helpers.epoch("2026-10-05T05:00:00Z") -- no holiday that week
    local mock, clock, Scheduler = startCalendar(monday)
    local admin = T.pair(mock)
    local sceneId = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Morning", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } }).json.id
    local due = monday + 3600
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = { scene_id = sceneId, trigger = { type = "time", at = os.date("%H:%M", due) }, days = { 0, 1, 2, 3, 4, 5, 6 } } })
    T.eq(created.status, 201, created.body)
    Properties["Schedules"] = "Paused"
    OnPropertyChanged("Schedules")
    for day = 0, 2 do
        clock.set(due + day * DAY + 30)
        T.eq(Scheduler.tick(), 0)
    end
    local entries = all(mock, admin, "schedule")
    T.eq(#entries, 1, "once for the pause")
    T.eq(entries[1].reason, "paused")
    -- Resumed, it runs; paused again, its next skip is listed again.
    Properties["Schedules"] = "On"
    OnPropertyChanged("Schedules")
    clock.set(due + 3 * DAY + 30)
    T.eq(Scheduler.tick(), 1)
    Properties["Schedules"] = "Paused"
    OnPropertyChanged("Schedules")
    clock.set(due + 4 * DAY + 30)
    Scheduler.tick()
    clock.set(due + 5 * DAY + 30)
    Scheduler.tick()
    entries = all(mock, admin, "schedule")
    T.eq(#entries, 3)
    T.eq(entries[1].reason, "paused")
    T.eq(entries[2].outcome, "ran")
end

function tests.a_schedule_caught_up_after_a_restart_says_so()
    local friday, saturday = 739891, 739892
    local mock = startCalendar(Helpers.localAt(friday, 12, 0))
    local admin = T.pair(mock)
    local sceneId = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Shabbat lights", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } }).json.id
    local only = T.http(mock, "POST", "/v1/schedules", { key = admin, body = { scene_id = sceneId, trigger = { type = "time", at = "08:00" }, days = { 6 }, during_shabbat = "only" } }).json
    OnDriverDestroyed("DIT_STARTUP")
    local restarted, _, Again = startCalendar(Helpers.localAt(saturday, 9, 40), mock)
    T.eq(Again.tick(), 1)
    local late = scheduleEntry(restarted, admin, only.id)
    T.eq(late.outcome, "ran")
    T.eq(late.note, "late")
    T.eq(history(restarted, admin, "?kind=system")[1].action, "driver_updated")
end

function tests.keys_paired_created_changed_revoked_and_forgotten()
    local mock, admin = start()
    local paired = newest(mock, admin, "access", "paired")
    T.eq(paired.what, "Chrome on Windows")
    T.eq(paired.to, "admin")
    T.eq(paired.who.name, "Chrome on Windows", "the new device itself")
    local _, memberId = createKey(mock, admin, "member", "Kitchen tablet")
    local created = newest(mock, admin, "access", "created")
    T.eq(created.what, "Kitchen tablet")
    T.eq(created.to, "member")
    T.eq(created.who.name, "Chrome on Windows")
    T.eq(created.ids.key_id, memberId)

    -- Roles are a person's (ADR-054): doors is a member's permission, admin a role.
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. memberId, { key = admin, body = { role = "doors" } }).status, 200)
    T.eq(newest(mock, admin, "access", "permissions_changed").what, "Kitchen tablet", "the person")
    T.eq(#all(mock, admin, "access", "role_changed"), 0)
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. memberId, { key = admin, body = { role = "admin" } }).status, 200)
    local changed = newest(mock, admin, "access", "role_changed")
    T.eq(changed.what, "Kitchen tablet")
    T.eq(changed.from, "member")
    T.eq(changed.to, "admin")
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. memberId, { key = admin, body = { name = "Hall tablet" } }).status, 200)
    T.eq(#all(mock, admin, "access", "role_changed"), 1, "a new name is not a new role")

    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. memberId, { key = admin }).status, 204)
    local revoked = newest(mock, admin, "access", "revoked")
    T.eq(revoked.what, "Hall tablet")
    T.eq(revoked.who.name, "Chrome on Windows")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. memberId, { key = admin }).status, 404)
    T.eq(#all(mock, admin, "access", "revoked"), 1)

    local viewer = createKey(mock, admin, "viewer", "Guest phone")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/current", { key = viewer }).status, 204)
    local forgotten = newest(mock, admin, "access", "forgotten")
    T.eq(forgotten.what, "Guest phone")
    T.eq(forgotten.who.name, "Guest phone", "by itself")

    ExecuteCommand("LUA_ACTION", { ACTION = "REVOKE_API_KEYS" })
    local everyone = require("src.core.activity").list()[1]
    T.eq(everyone.action, "all_revoked")
    T.eq(everyone.who.type, "composer")
    T.eq(everyone.count, 1)
end

function tests.a_key_that_expires_says_so()
    withClock(function(advance)
        local mock = Mock.startDriver()
        ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
        local paired = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = mock.properties["Pairing Code"], name = "DirectorLink Console", expires_in = 3600 } })
        T.eq(paired.status, 201, paired.body)
        advance(2 * 3600)
        require("src.auth.keys").count()
        local expired = require("src.core.activity").list()[1]
        T.eq(expired.action, "expired")
        T.eq(expired.what, "DirectorLink Console")
        T.eq(expired.who.type, "controller")
    end)
end

function tests.an_invitation_accepted_says_who_joined()
    local mock = Mock.startDriver()
    local admin = T.pair(mock)
    local _, connection = Harness.connected({ mock = mock })
    local home = T.http(mock, "GET", "/v1/remote", { key = admin }).json.home_id
    local invitation = T.http(mock, "POST", "/v1/invitations", { key = admin, body = { role = "member" } }).json
    local Lock = require("src.cloud.lock")
    local lock = Lock.invitationKey(invitation.secret)
    local request = { id = "join-1", ts = os.time(), method = "POST", path = "/v1/auth/join", body = { name = "Safari on iPhone" } }
    local reply = Harness.relayRequest(mock, connection, { type = "join", id = "relay-join-1", invitation = invitation.id, envelope = Lock.seal(lock, home, invitation.id, "req", Json.encode(request)) })
    T.eq(reply.ok, true)
    local joined = newest(mock, admin, "access", "joined")
    T.eq(joined.what, "Safari on iPhone")
    T.eq(joined.to, "member")
    T.eq(joined.who.name, "Safari on iPhone")
    T.eq(joined.ids.invitation_id, invitation.id)
    T.eq(joined.ids.key_id, reply.key_id)
    local setting = newest(mock, admin, "composer", "setting")
    T.eq(setting.what, "Remote Access")
    T.eq(setting.to, "On")
end

function tests.composer_changes_are_listed_by_name()
    local mock, admin = start()
    -- A keypad's button DirectorLink cannot control is removed with the rest.
    Mock.removeDevice(mock.project, 90)
    Mock.renameDevice(mock.project, 20, "Island")
    Mock.moveDevice(mock.project, 51, 11)
    Mock.addLight(mock.project, 23, 109, 10, "Pantry Light", 60)
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    local entry = newest(mock, admin, "composer", "project")
    T.eq(entry.who.type, "composer")
    T.same(entry.changes, {
        { change = "removed", name = "Gate Intercom", room = "Kitchen", type = "device" },
        { change = "added", name = "Pantry Light", room = "Kitchen", type = "device" },
        { change = "renamed", from = "Kitchen Island", name = "Island", room = "Kitchen", type = "device" },
        { change = "moved", from = "Kitchen", name = "Kitchen Shutter", room = "Living Room", type = "device" },
    })
    T.eq(entry.more, nil)
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(#all(mock, admin, "composer", "project"), 1, "a refresh that finds nothing new says nothing")

    -- A big change: the first 20, and how many more.
    for index = 0, 24 do
        Mock.addLight(mock.project, 200 + index, 300 + index, 11, string.format("Light %02d", index), 0)
    end
    Mock.removeRoom(mock.project, 10)
    for id, device in pairs(mock.project.devices) do
        if device.roomId == 10 and id ~= 112 then
            Mock.moveDevice(mock.project, id, 11)
        end
    end
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    entry = newest(mock, admin, "composer", "project")
    T.eq(#entry.changes, 20)
    T.eq(entry.changes[1].change, "removed")
    T.eq(entry.changes[1].type, "room", "the kitchen")
    T.eq(entry.changes[1].name, "Kitchen")
    T.eq(entry.changes[2].name, "Light 00")
    T.truthy(entry.more > 0, "and more")

    -- Settings changed in Composer; not the log level.
    Properties["Door Control"] = "Enabled"
    OnPropertyChanged("Door Control")
    Properties["Log Level"] = "Debug"
    OnPropertyChanged("Log Level")
    local setting = newest(mock, admin, "composer", "setting")
    T.eq(setting.what, "Door Control")
    T.eq(setting.to, "Enabled")
    T.eq(#all(mock, admin, "composer", "setting"), 1)
    T.eq(#history(mock, admin, "?kind=composer"), 3)
end

-- A request sealed at home, as the app sends it, once opened (the key as principal).
local function opened(mock, keyId, method, path, body)
    local status, _, answer = require("src.api.server").handleRequest({
        method = method,
        path = path,
        query = {},
        headers = body and { ["content-type"] = "application/json" } or {},
        body = body and Json.encode(body) or "",
        principal = { id = keyId, name = "Chrome on Windows", role = "admin", sealed = true },
    }, { ip = "192.168.1.50", port = "0" })
    return status, Json.decode(answer)
end

function tests.backups_and_restores_say_who_and_the_history_is_not_in_them()
    local mock, admin = start()
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = admin }).json
    local status, document = opened(mock, me.id, "GET", "/v1/backup")
    T.eq(status, 200)
    local made = newest(mock, admin, "system", "backup")
    T.eq(made.who.name, "Chrome on Windows")
    T.eq(document.sections.activity, nil, "not in a backup")
    T.notContains(Json.encode(document), "driver_started")
    local before = #history(mock, admin, "?limit=200")
    status = opened(mock, me.id, "POST", "/v1/restore", { document = document, dry_run = false })
    T.eq(status, 200)
    local restored = newest(mock, admin, "system", "restore")
    T.eq(restored.from, document.created_at, "when the backup was made")
    T.eq(restored.who.name, "Chrome on Windows")
    T.eq(#history(mock, admin, "?limit=200"), before + 1, "the history stays as it was")
end

function tests.the_remote_connection_counts_only_when_away_for_more_than_a_minute()
    withClock(function(advance)
        local mock, connection = Harness.connected()
        local admin = T.pair(mock)
        local function reconnect(seconds)
            OnConnectionStatusChanged(Harness.BINDING, 443, "OFFLINE")
            advance(seconds)
            for index = #mock.timers, 1, -1 do
                local timer = mock.timers[index]
                if not timer.fired and not timer.cancelled and timer.source:find("cloud/relay", 1, true) and not timer.repeating and timer.delay <= 60000 then
                    fire(timer)
                    break
                end
            end
            connection.sent = ""
            OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
            Harness.accept(connection.sent)
            connection.sent = ""
            T.truthy(require("src.cloud.relay").connected(), "connected again")
        end
        advance(600)
        reconnect(2)
        T.eq(newest(mock, admin, "system", "remote_away"), nil, "a drop of seconds is not news")
        advance(600)
        reconnect(185)
        local away = newest(mock, admin, "system", "remote_away")
        T.truthy(away.seconds >= 185 and away.seconds <= 187, "away for about three minutes: " .. tostring(away.seconds))
        T.eq(away.who.type, "controller")
    end)
end

return tests
