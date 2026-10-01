-- DirectorLink's settings in the app (ADR-043, src/core/settings.lua, handlers/settings.lua):
-- GET and PATCH /v1/settings, GET /v1/settings/printout and POST /v1/project/refresh, for admins.
-- Schedules, Jewish Calendar and Log Level change as in Composer: the property is set, Composer
-- shows it, it takes effect once, and the change is logged with who made it. The others are
-- refused for every key. A change in Composer is seen by the API and wins.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local COMPOSER_ONLY = {
    door_control = { "disabled", "enabled" },
    relay_hold = { "not_allowed", "allowed" },
    alarm_status = { "off", "on" },
    remote_access = { "off", "on" },
}

-- A driver with an admin key paired at home ("Owner phone"): { mock, key, id }, and the clock at
-- `now` when given.
local function start(now, prepare)
    local mock = Mock.startDriver(nil, nil, nil, prepare)
    local s = { mock = mock }
    s.key = T.pair(mock, "Owner phone")
    s.id = T.http(mock, "GET", "/v1/api-keys/current", { key = s.key }).json.id
    if now then
        s.clock = { now = now }
        require("src.core.clock").now = function()
            return s.clock.now
        end
    end
    return s
end

local function createKey(s, name, role)
    local created = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = name, role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json.id
end

local function patch(s, body, key)
    return T.http(s.mock, "PATCH", "/v1/settings", { key = key or s.key, body = body })
end

local function settingsOf(document)
    local byKey = {}
    for _, setting in ipairs(document.settings) do
        byKey[setting.key] = setting
    end
    return byKey
end

local function current(s, key)
    local answer = T.http(s.mock, "GET", "/v1/settings", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    return settingsOf(answer.json)[key].value, answer.json
end

-- The "settings" log entries, oldest first.
local function changes(s)
    local answer = T.http(s.mock, "GET", "/v1/logs?category=settings&level=debug&limit=500", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    return answer.json.items
end

-- Every UpdateProperty call from now on.
local function watchUpdates()
    local updates = {}
    local update = C4.UpdateProperty
    function C4:UpdateProperty(name, value)
        updates[#updates + 1] = { name, value }
        return update(self, name, value)
    end
    return updates
end

local function composer(name, value)
    Properties[name] = value
    OnPropertyChanged(name)
end

-- A request sealed at home, as the app sends every request (POST /v1/sealed).
local sealedCount = 0
local function sealed(s, request)
    local Lock = require("src.cloud.lock")
    local info = T.http(s.mock, "GET", "/v1/sealed").json
    sealedCount = sealedCount + 1
    request.id = "settings-" .. sealedCount
    request.ts = info.time
    local lock = Lock.deviceKey(s.key)
    local envelope = Lock.seal(lock, info.home, s.id, "req", Json.encode(request))
    local response = T.http(s.mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer
end

-- ---- reading -----------------------------------------------------------------------------------

function tests.admins_see_every_setting_the_statuses_and_the_actions()
    local s = start()
    local answer = T.http(s.mock, "GET", "/v1/settings", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    local settings = answer.json.settings
    local keys = {}
    for index, setting in ipairs(settings) do
        keys[index] = setting.key .. "=" .. setting.value .. (setting.changeable and " app" or "")
    end
    -- As they ship (the fake Director has set none of them): Composer's defaults.
    T.eq(table.concat(keys, ", "), "door_control=disabled, relay_hold=not_allowed, alarm_status=off, remote_access=off, "
        .. "schedules=on app, jewish_calendar=off app, log_level=info app")
    local byKey = settingsOf(answer.json)
    T.same(byKey.log_level, {
        key = "log_level", property = "Log Level", value = "info", composer_value = "Info",
        choices = { "debug", "info", "warn", "error" }, changeable = true, set_in = "app_and_composer",
    })
    T.same(byKey.relay_hold, {
        key = "relay_hold", property = "Relay Hold", value = "not_allowed", composer_value = "Not allowed",
        choices = { "not_allowed", "allowed" }, changeable = false, set_in = "composer",
    })
    -- The statuses as Composer shows them; never the pairing code.
    local status = answer.json.status
    T.eq(status.status, "Ready")
    T.eq(status.api_status, "Online - port 41999")
    T.eq(status.inventory, s.mock.properties["Inventory"])
    T.eq(status.api_keys, "1")
    T.eq(status.remote_status, "Off")
    T.eq(status.schedule_status, "None")
    T.eq(status.calendar_status, "Off")
    T.eq(status.version, s.mock.properties["Version"])
    T.contains(status.pairing_status, "Used at")
    T.eq(tostring(status.last_automation), "null", "nothing ran yet")
    ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    local code = s.mock.properties["Pairing Code"]
    T.truthy(code:match("^%d%d%d%d %d%d%d%d$"))
    local again = T.http(s.mock, "GET", "/v1/settings", { key = s.key })
    T.contains(again.json.status.pairing_status, "Ready until")
    T.notContains(again.body, code, "whoever reads the code could pair")
    T.notContains(again.body, (code:gsub(" ", "")))
    local actions = {}
    for index, action in ipairs(answer.json.actions) do
        actions[index] = action.action .. (action.in_app and " (app)" or "")
    end
    T.eq(table.concat(actions, ", "), "New Pairing Code, Revoke All API Keys, Print Schedules and Scenes (app), Refresh Project (app), Reset Remote Identity")
end

function tests.only_admin_keys_reach_the_settings()
    local s = start()
    local before = #s.mock.commands
    for _, role in ipairs({ "viewer", "member", "doors" }) do
        local key = createKey(s, role .. " key", role)
        for _, request in ipairs({
            { "GET", "/v1/settings" },
            { "PATCH", "/v1/settings", { schedules = "paused" } },
            { "GET", "/v1/settings/printout" },
            { "POST", "/v1/project/refresh" },
        }) do
            local answer = T.http(s.mock, request[1], request[2], { key = key, body = request[3] })
            T.eq(answer.status, 403, role .. " " .. request[2])
            T.eq(answer.json.code, "FORBIDDEN")
            T.eq(answer.json.required_role, "admin")
        end
    end
    T.eq(T.http(s.mock, "GET", "/v1/settings").status, 401)
    T.eq(current(s, "schedules"), "on", "nothing changed")
    T.eq(s.mock.properties["Schedules"], nil, "Composer was not touched")
    T.eq(#s.mock.commands, before)
end

-- ---- the settings an admin changes -------------------------------------------------------------

-- Local time `hh:mm` tomorrow.
local function tomorrowAt(hh, mm)
    local fields = os.date("*t", os.time() + 86400)
    fields.hour, fields.min, fields.sec = hh, mm, 0
    return os.time(fields)
end

function tests.the_app_pauses_and_resumes_schedules_as_composer_does()
    local runAt = tomorrowAt(7, 30)
    local s = start(runAt - 3600)
    local Scheduler = require("src.core.scheduler")
    local scene = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Morning", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } })
    T.eq(scene.status, 201, scene.body)
    T.eq(T.http(s.mock, "POST", "/v1/schedules", { key = s.key, body = { scene_id = scene.json.id, trigger = { type = "time", at = "07:30" }, days = { 0, 1, 2, 3, 4, 5, 6 } } }).status, 201)
    local updates = watchUpdates()

    -- Sealed, as the app sends it.
    local paused = sealed(s, { method = "PATCH", path = "/v1/settings", body = { schedules = "paused" } })
    T.eq(paused.status, 200, paused.body)
    T.eq(settingsOf(paused.json).schedules.value, "paused")
    T.eq(settingsOf(paused.json).schedules.composer_value, "Paused")
    -- Composer shows it, and the driver reads it as it reads Composer's.
    T.eq(s.mock.properties["Schedules"], "Paused")
    T.eq(Properties["Schedules"], "Paused")
    T.eq(updates[1][1], "Schedules")
    T.eq(updates[1][2], "Paused")
    T.eq(s.mock.properties["Schedule Status"], "Paused - 1 schedule is not running")
    T.eq(T.http(s.mock, "GET", "/v1/schedules", { key = s.key }).json.paused, true)
    s.clock.now = runAt + 5
    T.eq(Scheduler.tick(), 0, "paused: nothing runs")

    local logged = changes(s)
    local entry = logged[#logged]
    T.eq(entry.message, "Schedules set to Paused in the app by Owner phone")
    T.same(entry.data, { setting = "schedules", property = "Schedules", value = "Paused", from = "app", key_id = s.id, key_name = "Owner phone" })

    -- Resumed as from Composer: within its 5 minutes the schedule still runs.
    local resumed = patch(s, { schedules = "on" })
    T.eq(resumed.status, 200, resumed.body)
    T.eq(s.mock.properties["Schedules"], "On")
    s.clock.now = runAt + 65
    T.eq(Scheduler.tick(), 1, "resumed within its 5 minutes: it runs")
    T.contains(s.mock.properties["Schedule Status"], "1 on")
    T.eq(changes(s)[#changes(s)].message, "Schedules set to On in the app by Owner phone")

    -- The same value again changes nothing and logs nothing.
    local count, updated = #changes(s), #updates
    T.eq(patch(s, { schedules = "on" }).status, 200)
    T.eq(#changes(s), count)
    T.eq(#updates, updated)
end

function tests.the_app_turns_the_jewish_calendar_on_and_off()
    local s = start()
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.features.jewish_calendar, false)
    T.eq(T.http(s.mock, "GET", "/v1/calendar", { key = s.key }).json.enabled, false)
    local on = patch(s, { jewish_calendar = "on" })
    T.eq(on.status, 200, on.body)
    T.eq(settingsOf(on.json).jewish_calendar.value, "on")
    T.eq(s.mock.properties["Jewish Calendar"], "On")
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.features.jewish_calendar, true)
    local calendar = T.http(s.mock, "GET", "/v1/calendar", { key = s.key }).json
    T.eq(calendar.enabled, true)
    T.eq(calendar.status, "ok", "Tel Aviv has a location")
    T.contains(s.mock.properties["Calendar Status"], "Israel (from the location)")
    T.contains(on.json.status.calendar_status, "Israel (from the location)", "the answer shows what it works out now")
    T.eq(T.http(s.mock, "PATCH", "/v1/calendar/settings", { key = s.key, body = { havdalah_minutes = 50 } }).status, 200)

    local off = patch(s, { jewish_calendar = "off" })
    T.eq(off.status, 200, off.body)
    T.eq(s.mock.properties["Jewish Calendar"], "Off")
    T.eq(s.mock.properties["Calendar Status"], "Off")
    T.eq(T.http(s.mock, "GET", "/v1/calendar", { key = s.key }).json.enabled, false)
    T.eq(T.http(s.mock, "PATCH", "/v1/calendar/settings", { key = s.key, body = { havdalah_minutes = 42 } }).json.code, "JEWISH_CALENDAR_OFF")
    local logged = changes(s)
    T.eq(logged[#logged - 1].message, "Jewish Calendar set to On in the app by Owner phone")
    T.eq(logged[#logged].message, "Jewish Calendar set to Off in the app by Owner phone")
    T.eq(logged[#logged].data.key_id, s.id)
end

function tests.the_app_changes_the_log_level_and_the_change_is_always_logged()
    local s = start()
    local Log = require("src.core.log")
    local debug = patch(s, { log_level = "debug" })
    T.eq(debug.status, 200, debug.body)
    T.eq(Log.getLevel(), "debug")
    T.eq(s.mock.properties["Log Level"], "Debug")
    T.eq(T.http(s.mock, "GET", "/v1/logs/settings", { key = s.key }).json.level, "debug")
    T.eq(changes(s)[#changes(s)].message, "Log Level set to Debug in the app by Owner phone")

    -- To Error: the change is logged at the level before, which still keeps it.
    T.eq(patch(s, { log_level = "error" }).status, 200)
    T.eq(Log.getLevel(), "error")
    T.eq(s.mock.properties["Log Level"], "Error")
    T.eq(changes(s)[#changes(s)].message, "Log Level set to Error in the app by Owner phone")
    -- From Error back to Info: logged at the new level.
    T.eq(patch(s, { log_level = "info" }).status, 200)
    local logged = changes(s)
    T.eq(logged[#logged].message, "Log Level set to Info in the app by Owner phone")
    T.eq(logged[#logged - 1].message, "Log Level set to Error in the app by Owner phone", "each change once")

    -- The API console and older apps set it with PATCH /v1/logs/settings: the same path.
    local console = T.http(s.mock, "PATCH", "/v1/logs/settings", { key = s.key, body = { level = "warn" } })
    T.eq(console.status, 200, console.body)
    T.eq(console.json.level, "warn")
    T.eq(s.mock.properties["Log Level"], "Warning")
    T.eq(current(s, "log_level"), "warn")
    T.eq(changes(s)[#changes(s)].message, "Log Level set to Warning in the app by Owner phone")
    T.eq(T.http(s.mock, "PATCH", "/v1/logs/settings", { key = s.key, body = { level = "verbose" } }).status, 400)
end

function tests.several_settings_at_once_and_bodies_that_are_refused()
    local s = start()
    local both = patch(s, { schedules = "paused", jewish_calendar = "on" })
    T.eq(both.status, 200, both.body)
    T.eq(s.mock.properties["Schedules"], "Paused")
    T.eq(s.mock.properties["Jewish Calendar"], "On")
    local count = #changes(s)
    for _, body in ipairs({
        { schedules = "off" },
        { log_level = "verbose" },
        { jewish_calendar = true },
        { schedules = "on", unknown = "x" },
        { schedules = "on", log_level = "loud" },
    }) do
        local answer = patch(s, body)
        T.eq(answer.status, 400, Json.encode(body))
        T.eq(answer.json.code, "INVALID_FIELD")
    end
    T.eq(patch(s, {}).status, 400)
    T.eq(T.http(s.mock, "PATCH", "/v1/settings", { key = s.key, body = "[]" }).status, 400)
    T.eq(T.http(s.mock, "PATCH", "/v1/settings", { key = s.key, body = "{nope" }).status, 400)
    T.eq(s.mock.properties["Schedules"], "Paused", "a refused body changes nothing")
    T.eq(#changes(s), count)
end

-- ---- set in Composer only ----------------------------------------------------------------------

function tests.composer_only_settings_are_refused_for_every_key()
    local s = start()
    local keys = { admin = s.key }
    for _, role in ipairs({ "viewer", "member", "doors" }) do
        keys[role] = createKey(s, role .. " key", role)
    end
    local pairing = s.mock.properties["Pairing Code"]
    local updates = watchUpdates()
    local count = #changes(s)
    for setting, values in pairs(COMPOSER_ONLY) do
        for _, value in ipairs(values) do
            for role, key in pairs(keys) do
                local answer = patch(s, { [setting] = value }, key)
                T.eq(answer.status, 403, role .. " " .. setting .. " " .. value)
                T.eq(answer.json.code, role == "admin" and "SET_IN_COMPOSER" or "FORBIDDEN", role .. " " .. setting)
            end
            -- With one the app may change: nothing at all changes.
            local mixed = patch(s, { schedules = "paused", [setting] = value })
            T.eq(mixed.status, 403)
            T.eq(mixed.json.code, "SET_IN_COMPOSER")
            T.eq(mixed.json.errors[1].field, setting)
        end
    end
    T.eq(#updates, 0, "no property was set")
    T.eq(#changes(s), count, "and nothing logged as changed")
    for setting in pairs(COMPOSER_ONLY) do
        T.eq(current(s, setting), COMPOSER_ONLY[setting][1], setting .. " as it was")
    end
    T.eq(current(s, "schedules"), "on")
    T.eq(Properties["Door Control"], nil)
    T.eq(Properties["Remote Access"], nil)
    T.eq(s.mock.properties["Pairing Code"], pairing)
    T.eq(s.mock.properties["Remote Status"], "Off", "remote access was not started")
    -- No route runs the actions made in Composer only.
    for _, route in ipairs(require("src.api.routes")) do
        T.truthy(not route.path:match("pair") or route.path == "/v1/auth/pair", "no pairing code from the API: " .. route.path)
        T.truthy(not route.path:match("identity"), "no identity reset from the API: " .. route.path)
    end
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys", { key = s.key }).status, 405, "no revoking every key at once")
end

-- ---- Composer and the app ----------------------------------------------------------------------

function tests.a_change_in_composer_is_seen_by_the_api_and_wins()
    local s = start()
    T.eq(patch(s, { schedules = "paused" }).status, 200)
    composer("Schedules", "On")
    T.eq(current(s, "schedules"), "on", "Composer's change wins")
    T.eq(T.http(s.mock, "GET", "/v1/schedules", { key = s.key }).json.paused, false)
    local logged = changes(s)
    T.eq(logged[#logged].message, "Schedules set to On in Composer")
    T.same(logged[#logged].data, { setting = "schedules", property = "Schedules", value = "On", from = "composer" })

    -- The ones set in Composer only show what Composer says, with who changed it in the log.
    composer("Door Control", "Enabled")
    composer("Relay Hold", "Allowed")
    composer("Remote Access", "On")
    local value, document = current(s, "door_control")
    T.eq(value, "enabled")
    T.eq(settingsOf(document).relay_hold.value, "allowed")
    T.eq(settingsOf(document).remote_access.value, "on")
    T.truthy(document.status.remote_status ~= "Off", "Remote Status follows: " .. tostring(document.status.remote_status))
    composer("Log Level", "Debug")
    T.eq(current(s, "log_level"), "debug")
    T.eq(require("src.core.log").getLevel(), "debug")
    local messages = {}
    for _, entry in ipairs(changes(s)) do
        messages[#messages + 1] = entry.message
    end
    local text = table.concat(messages, " | ")
    for _, message in ipairs({ "Door Control set to Enabled in Composer", "Relay Hold set to Allowed in Composer", "Remote Access set to On in Composer", "Log Level set to Debug in Composer" }) do
        T.contains(text, message)
    end
end

-- Director may report the property DirectorLink set back to it (OnPropertyChanged), at once or
-- later: the change is applied and logged once, and nothing loops.
function tests.an_app_change_is_applied_once_when_director_reports_it_back()
    local s = start()
    local Scheduler = require("src.core.scheduler")
    local switched = 0
    local switchesChanged = Scheduler.switchesChanged
    Scheduler.switchesChanged = function(...)
        switched = switched + 1
        return switchesChanged(...)
    end
    local update = C4.UpdateProperty
    local reported = 0
    function C4:UpdateProperty(name, value)
        update(self, name, value)
        if name == "Schedules" then
            reported = reported + 1
            OnPropertyChanged(name)
        end
    end
    local count = #changes(s)
    T.eq(patch(s, { schedules = "paused" }).status, 200)
    T.eq(reported, 1, "set once, no loop")
    T.eq(switched, 1, "applied once")
    T.eq(#changes(s), count + 1, "logged once")
    T.eq(changes(s)[#changes(s)].data.from, "app")

    -- Reported later instead.
    C4.UpdateProperty = update
    T.eq(patch(s, { schedules = "on" }).status, 200)
    OnPropertyChanged("Schedules")
    T.eq(switched, 2)
    T.eq(#changes(s), count + 2)
    -- And a change in Composer afterwards is one.
    composer("Schedules", "Paused")
    T.eq(switched, 3)
    T.eq(#changes(s), count + 3)
    T.eq(changes(s)[#changes(s)].data.from, "composer")
end

-- A Director that reports every UpdateProperty back to OnPropertyChanged at once, whichever the
-- property (ADR-043: not yet seen on a real controller whether it does).
local function reportEveryUpdate()
    local update = C4.UpdateProperty
    function C4:UpdateProperty(name, value)
        update(self, name, value)
        Properties[name] = value
        OnPropertyChanged(name)
    end
end

function tests.only_directorlink_s_settings_are_acted_on_and_the_pairing_code_is_never_logged()
    local s = start(nil, reportEveryUpdate)
    ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    local code = s.mock.properties["Pairing Code"]
    T.truthy(code and code:match("^%d%d%d%d %d%d%d%d$"), "a code: " .. tostring(code))
    T.eq(#changes(s), 0, "Status, Version, Pairing Code and the other statuses are DirectorLink's own: no change in Composer")
    -- Whatever a field is called, and in the message too.
    local Log = require("src.core.log")
    Log.warn("auth", "code " .. code .. " and " .. code:gsub(" ", ""), { value = code, typed = code:gsub(" ", "") })
    local logs = T.http(s.mock, "GET", "/v1/logs?level=debug&limit=500", { key = s.key })
    T.eq(logs.status, 200)
    T.notContains(logs.body, code)
    T.notContains(logs.body, (code:gsub(" ", "")))
    T.contains(logs.body, "[redacted]")
    for _, line in ipairs(s.mock.debugLog) do
        T.notContains(line, (code:gsub(" ", "")), "nor in Director's log")
        T.notContains(line, code)
    end
end

function tests.every_change_is_logged_whatever_the_log_level()
    local s = start()
    T.eq(patch(s, { log_level = "warn" }).status, 200)
    T.eq(patch(s, { log_level = "error" }).status, 200)
    local count = #changes(s)
    T.eq(patch(s, { schedules = "paused", jewish_calendar = "on" }).status, 200)
    T.eq(T.http(s.mock, "POST", "/v1/project/refresh", { key = s.key }).status, 200)
    composer("Door Control", "Enabled")
    composer("Remote Access", "On")
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    local messages = {}
    for index, entry in ipairs(changes(s)) do
        if index > count then
            messages[#messages + 1] = entry.message
        end
    end
    T.same(messages, {
        "Schedules set to Paused in the app by Owner phone",
        "Jewish Calendar set to On in the app by Owner phone",
        "Refresh Project run in the app by Owner phone",
        "Door Control set to Enabled in Composer",
        "Remote Access set to On in Composer",
        "Refresh Project run in Composer",
    }, "at Log Level Error, every one of them")
    T.eq(require("src.core.log").getLevel(), "error")
end

-- Director may report an app change back late, after another change: what it reports is the value
-- DirectorLink applied last, never a change in Composer.
function tests.a_late_report_of_an_app_change_is_never_taken_for_composer_s()
    local s = start()
    local queued = 0
    local update = C4.UpdateProperty
    function C4:UpdateProperty(name, value)
        update(self, name, value)
        if name == "Schedules" then
            queued = queued + 1
        end
    end
    local function deliver()
        for _ = 1, queued do
            OnPropertyChanged("Schedules")
        end
        queued = 0
    end
    local count = #changes(s)
    -- Two changes in the app before Director reports either.
    T.eq(patch(s, { schedules = "paused" }).status, 200)
    T.eq(patch(s, { schedules = "on" }).status, 200)
    deliver()
    T.eq(#changes(s), count + 2, "the two changes, nothing more")
    -- A change in Composer between the app's and its report.
    T.eq(patch(s, { schedules = "paused" }).status, 200)
    composer("Schedules", "On")
    deliver()
    local logged = changes(s)
    T.eq(#logged, count + 4)
    T.eq(logged[#logged].message, "Schedules set to On in Composer")
    T.eq(logged[#logged - 1].data.from, "app")
    T.eq(current(s, "schedules"), "on")
end

function tests.a_setting_whose_effect_fails_is_reported_as_it_stands()
    local s = start()
    local Scheduler = require("src.core.scheduler")
    local switchesChanged = Scheduler.switchesChanged
    Scheduler.switchesChanged = function()
        error("the scheduler broke")
    end
    local answer = patch(s, { schedules = "paused" })
    Scheduler.switchesChanged = switchesChanged
    T.eq(answer.status, 500)
    T.eq(answer.json.code, "SETTING_NOT_APPLIED")
    T.contains(answer.json.detail, "Schedules is set to Paused")
    T.eq(answer.json.errors[1].field, "schedules")
    T.eq(s.mock.properties["Schedules"], "Paused", "Composer shows what is set")
    T.eq(current(s, "schedules"), "paused", "and the API says the same")
    local logged = changes(s)
    T.contains(logged[#logged].message, "Schedules set to Paused in the app by Owner phone; applying it failed")
    T.contains(logged[#logged].data.error, "the scheduler broke")
end

-- Director keeps the properties when DirectorLink restarts or is updated: a change made in the app
-- is there afterwards, as Composer's are; DirectorLink keeps no copy of its own.
function tests.an_app_change_stays_after_an_update_as_composer_keeps_it()
    local s = start()
    T.eq(patch(s, { schedules = "paused", jewish_calendar = "on", log_level = "debug" }).status, 200)
    local kept = {}
    for name, value in pairs(Properties) do
        kept[name] = value
    end
    local previous = s.mock
    local mock = Mock.startDriver(nil, nil, "DIT_UPDATING", function(fresh)
        fresh.uuidCount = previous.uuidCount
        for name, value in pairs(previous.persist) do
            fresh.persist[name] = value
            fresh.persistEncrypted[name] = previous.persistEncrypted[name]
        end
        for name, value in pairs(kept) do
            Properties[name] = value
        end
    end)
    local answer = T.http(mock, "GET", "/v1/settings", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    local settings = settingsOf(answer.json)
    T.eq(settings.schedules.value, "paused")
    T.eq(settings.jewish_calendar.value, "on")
    T.eq(settings.log_level.value, "debug")
    T.eq(require("src.core.log").getLevel(), "debug")
    T.eq(T.http(mock, "GET", "/v1/schedules", { key = s.key }).json.paused, true)
    T.eq(T.http(mock, "GET", "/v1/system", { key = s.key }).json.features.jewish_calendar, true)
end

-- ---- Composer's actions in the app -------------------------------------------------------------

function tests.the_printout_is_what_composer_prints()
    local s = start()
    local scene = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Evening", steps = { { type = "lights", device_ids = { 20 }, set = { brightness = 40 } } } } })
    T.eq(T.http(s.mock, "POST", "/v1/schedules", { key = s.key, body = { scene_id = scene.json.id, trigger = { type = "sun", event = "sunset", offset = -30 }, days = { 0, 1, 2, 3, 4 } } }).status, 201)
    T.eq(patch(s, { schedules = "paused" }).status, 200)
    local printed = {}
    local realPrint = print
    _G.print = function(line)
        printed[#printed + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    local answer = T.http(s.mock, "GET", "/v1/settings/printout", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    T.same(answer.json.lines, printed)
    T.truthy(answer.json.printed_at:match("^%d%d%d%d%-%d%d%-%d%dT"))
    local text = table.concat(answer.json.lines, " | ")
    T.contains(text, "DirectorLink schedules: 1, PAUSED (Schedules property)")
    T.contains(text, "Evening (id " .. scene.json.id)
    T.contains(text, "Kitchen Island (20) -> 40%")
end

function tests.refresh_project_from_the_app()
    local s = start()
    T.eq(#T.http(s.mock, "GET", "/v1/lights", { key = s.key }).json.items, 3)
    Mock.addLight(s.mock.project, 24, 109, 10, "Pantry Light", 60)
    Mock.moveDevice(s.mock.project, 51, 11)
    local answer = T.http(s.mock, "POST", "/v1/project/refresh", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    T.eq(answer.json.inventory.lights, 4)
    T.eq(answer.json.changes.added, 1, "the light")
    T.eq(answer.json.changes.moved, 1)
    T.eq(answer.json.changes.removed, 0)
    T.eq(#T.http(s.mock, "GET", "/v1/lights", { key = s.key }).json.items, 4)
    T.contains(s.mock.properties["Inventory"], "4 lights")
    T.contains(T.http(s.mock, "GET", "/v1/settings", { key = s.key }).json.status.inventory, "4 lights")
    local logged = changes(s)
    T.eq(logged[#logged].message, "Refresh Project run in the app by Owner phone")
    T.same(logged[#logged].data, { action = "refresh_project", from = "app", key_id = s.id, key_name = "Owner phone" })

    -- Director cannot list the project: the one read before stays in use.
    local devices = C4.GetDevices
    function C4:GetDevices()
        error("Director is busy")
    end
    local failed = T.http(s.mock, "POST", "/v1/project/refresh", { key = s.key })
    C4.GetDevices = devices
    T.eq(failed.status, 503)
    T.eq(failed.json.code, "PROJECT_REFRESH_FAILED")
    T.eq(#T.http(s.mock, "GET", "/v1/lights", { key = s.key }).json.items, 4)
    T.eq(s.mock.properties["Status"], "Ready")

    -- The Composer action is logged as Composer's.
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    logged = changes(s)
    T.eq(logged[#logged].message, "Refresh Project run in Composer")
end

return tests
