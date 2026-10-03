-- Alerts to the home's admins (ADR-047, docs/RELAY.md): the driver tells the relay when a schedule
-- failed, with its time only, and which of its keys are admin keys.

local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

-- The driver's messages to the relay since the last look (key id lists included).
local function sent(connection)
    local messages = {}
    for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
        messages[#messages + 1] = { text = frame.payload, message = Json.decode(frame.payload) }
    end
    connection.sent = ""
    return messages
end

local function ofType(messages, kind)
    local found = {}
    for _, item in ipairs(messages) do
        if type(item.message) == "table" and item.message.type == kind then
            found[#found + 1] = item
        end
    end
    return found
end

-- Local time `hh:mm` on the day `days` after today.
local function at(days, hh, mm)
    local fields = os.date("*t", os.time() + days * 86400)
    fields.hour, fields.min, fields.sec = hh, mm, 0
    return os.time(fields)
end

function tests.a_schedule_that_fails_tells_the_relay_its_time_and_nothing_else()
    local mock, connection = Harness.connected()
    local admin = T.pair(mock, "Chrome on Windows")
    local now = os.time()
    local Clock = require("src.core.clock")
    Clock.now = function()
        return now
    end
    local Scheduler = require("src.core.scheduler")
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Morning blinds", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } })
    T.eq(scene.status, 201, scene.body)
    local schedule = T.http(mock, "POST", "/v1/schedules", { key = admin, body = { scene_id = scene.json.id, trigger = { type = "time", at = "08:00" }, days = { 0, 1, 2, 3, 4, 5, 6 } } })
    T.eq(schedule.status, 201, schedule.body)
    sent(connection)

    -- It runs: nothing to tell.
    now = at(1, 8, 0) + 5
    T.eq(Scheduler.tick(), 1)
    T.eq(#ofType(sent(connection), "alert"), 0, "a schedule that ran tells nothing")

    -- A device refuses: the time of the run, and nothing about the schedule, the scene or the device.
    local Manager = require("src.adapters.manager")
    local execute = Manager.execute
    Manager.execute = function()
        return false, { code = "DEVICE_UNAVAILABLE", message = "Living room light did not answer" }
    end
    now = at(2, 8, 0) + 5
    local ok, err = pcall(function()
        T.eq(Scheduler.tick(), 1)
    end)
    Manager.execute = execute
    T.truthy(ok, err)
    local alerts = ofType(sent(connection), "alert")
    T.eq(#alerts, 1, "one alert")
    local message = alerts[1].message
    T.eq(message.kind, "schedule_failed")
    T.eq(message.at, os.date("!%Y-%m-%dT%H:%M:%SZ", now))
    local fields = 0
    for _ in pairs(message) do
        fields = fields + 1
    end
    T.eq(fields, 3, "type, kind and at only")
    for _, word in ipairs({ "Morning", "Living", scene.json.id, schedule.json.id, "DEVICE" }) do
        T.notContains(alerts[1].text, word, "no names or ids")
    end

    -- A scene that cannot run at all.
    local SceneHandlers = require("src.api.handlers.scenes")
    local runSaved = SceneHandlers.runSaved
    SceneHandlers.runSaved = function()
        return nil, "SCENE_NOT_FOUND"
    end
    now = at(3, 8, 0) + 5
    ok, err = pcall(function()
        T.eq(Scheduler.tick(), 1)
    end)
    SceneHandlers.runSaved = runSaved
    T.truthy(ok, err)
    T.eq(#ofType(sent(connection), "alert"), 1, "a run that could not start is a failure too")

    -- Remote Access off: nothing is sent, and the schedule still runs.
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    connection.sent = ""
    Manager.execute = function()
        return false, { code = "DEVICE_UNAVAILABLE", message = "no answer" }
    end
    now = at(4, 8, 0) + 5
    ok, err = pcall(function()
        T.eq(Scheduler.tick(), 1)
    end)
    Manager.execute = execute
    T.truthy(ok, err)
    T.eq(connection.sent, "", "nothing goes out without the relay")
end

function tests.the_relay_learns_which_keys_are_admin_keys()
    local mock, connection = Harness.connected()
    local admin = T.pair(mock)
    local function lastKeys()
        local found = ofType(sent(connection), "keys")
        return found[#found].message
    end
    local first = lastKeys()
    T.eq(#first.admins, 1, "the paired key is an admin key")
    T.eq(first.admins[1], first.ids[1])

    local viewer = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Wall tablet", role = "viewer" } }).json
    local afterViewer = lastKeys()
    T.eq(#afterViewer.ids, 2)
    T.eq(#afterViewer.admins, 1, "a viewer is not an admin")
    T.eq(afterViewer.admins[1], first.ids[1])

    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. viewer.id, { key = admin, body = { role = "admin" } }).status, 200)
    T.eq(#lastKeys().admins, 2, "made an admin: the relay is told")
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. viewer.id, { key = admin, body = { role = "member" } }).status, 200)
    local demoted = lastKeys()
    T.eq(#demoted.admins, 1, "and when it no longer is")
    T.eq(demoted.admins[1], first.ids[1])
end

return tests
