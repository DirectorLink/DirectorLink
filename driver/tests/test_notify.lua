-- DirectorLink's notification agreement (1.13.0, ADR-086, docs/NOTIFY_DRIVERS.md,
-- src/control4/notify_targets.lua, src/core/notify.lua, src/core/notify_words.lua): a screen's driver
-- says so with DIRECTORLINK_NOTIFY ("1") and the kinds it shows with DIRECTORLINK_NOTIFY_KINDS;
-- DirectorLink finds it by name, tells it every alert of those kinds with the command
-- DIRECTORLINK_NOTIFY (VERSION, ID, KIND, TITLE, MESSAGE, PICTURE), in the owner's language, with a
-- picture its driver fetches without a key for 60 seconds, apart from the phones' alerts and never
-- held up by a screen. The fake screens are Mock.withNotifyTargets: 301 "Living Room TV" (every kind)
-- unless a test says otherwise; the cameras are Mock.withAgreementCameras' 67 "Porch" (driver 157)
-- and the doorbell 68 "Entrance" (driver 158).

local T = require("helpers")
local Json = require("src.core.json")
local Mock = require("c4mock")
local Harness = require("relay_harness")

local tests = {}

local RLM = "\226\128\143"

-- A connected driver with the clock in the test's hands: { mock, connection, clock, admin }.
-- `screens`: Mock.withNotifyTargets' list; `setup` runs before the start; `project` instead of the
-- default one with the agreement's cameras.
local function home(screens, setup, connected, project)
    project = Mock.withNotifyTargets(project or Mock.withAgreementCameras(Mock.project()), screens)
    local mock = Mock.startDriver(project, nil, nil, setup)
    local connection
    if connected ~= false then
        _, connection = Harness.connected({ mock = mock })
    end
    local Clock = require("src.core.clock")
    local clock = { now = os.time() }
    Clock.now = function()
        return clock.now
    end
    local admin = T.pair(mock, "Chrome on Windows")
    return { mock = mock, connection = connection, clock = clock, admin = admin }
end

local function only(mock, id)
    local got = Mock.notifications(mock, id)
    T.eq(#got, 1, "one notification for screen " .. id .. ": " .. Json.encode(got))
    return got[1]
end

local function hhmm(at)
    return os.date("%H:%M", at)
end

local function logged(mock, text)
    local lines = {}
    for _, line in ipairs(mock.debugLog) do
        if line:find(text, 1, true) then
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function pathOf(url)
    return url:match("^http://[^/]+(/.*)$")
end

-- ---- the app's words ------------------------------------------------------------------------------

-- A dictionary of the app (app/i18n/<code>.js) as key paths ("alerts.camera") -> text: a small
-- reader for what those files hold (objects of strings, comments, trailing commas), as
-- scripts/check_app.py reads them.
local function dictionary(code)
    local file = assert(io.open("app/i18n/" .. code .. ".js", "rb"))
    local text = file:read("*a")
    file:close()
    local pos = text:find("{", (assert(text:find("export default", 1, true))), true)
    local flat = {}
    local function skip()
        while true do
            local _, finish = text:find("^%s+", pos)
            if finish then
                pos = finish + 1
            end
            if text:sub(pos, pos + 1) == "//" then
                pos = (text:find("\n", pos, true) or #text) + 1
            elseif text:sub(pos, pos + 1) == "/*" then
                local _, close = text:find("*/", pos + 2, true)
                pos = close + 1
            else
                return
            end
        end
    end
    local function utf8(code)
        if code < 0x80 then
            return string.char(code)
        elseif code < 0x800 then
            return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
        end
        return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    local function str()
        local quote = text:sub(pos, pos)
        pos = pos + 1
        local out = {}
        while true do
            local char = text:sub(pos, pos)
            assert(char ~= "" and char ~= "\n", "an unclosed string in " .. code .. ".js")
            if char == quote then
                pos = pos + 1
                return table.concat(out)
            elseif char == "\\" then
                local escape = text:sub(pos + 1, pos + 1)
                if escape == "u" then
                    out[#out + 1] = utf8(tonumber(text:sub(pos + 2, pos + 5), 16))
                    pos = pos + 6
                else
                    out[#out + 1] = ({ n = "\n", t = "\t", r = "\r" })[escape] or escape
                    pos = pos + 2
                end
            else
                out[#out + 1] = char
                pos = pos + 1
            end
        end
    end
    local value
    local function list(path, open, close)
        pos = pos + 1
        local index = 0
        while true do
            skip()
            if text:sub(pos, pos) == close then
                pos = pos + 1
                return
            end
            local key
            if open == "[" then
                index = index + 1
                key = tostring(index)
            elseif text:sub(pos, pos) == '"' or text:sub(pos, pos) == "'" then
                key = str()
            else
                local start, finish = text:find("^[%w_$]+", pos)
                assert(start, "a key in " .. code .. ".js at " .. pos)
                key = text:sub(start, finish)
                pos = finish + 1
            end
            if open == "{" then
                skip()
                assert(text:sub(pos, pos) == ":", "a colon in " .. code .. ".js at " .. pos)
                pos = pos + 1
            end
            skip()
            value(path == "" and key or (path .. "." .. key))
            skip()
            if text:sub(pos, pos) == "," then
                pos = pos + 1
            end
        end
    end
    value = function(path)
        local char = text:sub(pos, pos)
        if char == "{" then
            list(path, "{", "}")
        elseif char == "[" then
            list(path, "[", "]")
        elseif char == '"' or char == "'" then
            flat[path] = str()
        else
            local start, finish = text:find("^[^,}%]%s]+", pos)
            flat[path] = text:sub(start, finish)
            pos = finish + 1
        end
    end
    value("")
    return flat
end

function tests.the_words_are_the_apps_own_in_every_language()
    local Words = require("src.core.notify_words")
    local keys = {}
    for key in pairs(Words.WORDS.en) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    T.truthy(#keys >= 40, "the sentences and the camera's labels")
    for _, code in ipairs({ "en", "he", "es", "it" }) do
        local app = dictionary(code)
        for _, key in ipairs(keys) do
            T.eq(Words.WORDS[code][key], app[key], code .. " " .. key .. " is the app's")
        end
        -- Every label a camera alert may say (Camera.DETECTIONS), and "Alert" for any other.
        for _, what in pairs(require("src.adapters.camera").DETECTIONS) do
            T.truthy(Words.WORDS[code]["alerts.cameraSaw." .. what], code .. " says " .. what)
        end
        local extra = 0
        for key in pairs(Words.WORDS[code]) do
            if Words.WORDS.en[key] == nil then
                extra = extra + 1
            end
        end
        T.eq(extra, 0, code .. " has no sentence English does not")
    end
    T.eq(Words.language("he"), "he")
    T.eq(Words.language("auto"), "en", "Auto is unknown on the controller")
    T.eq(Words.language(nil), "en")
    T.eq(Words.language("fr"), "en")
end

function tests.each_alert_says_what_the_phone_says()
    local Words = require("src.core.notify_words")
    local at = os.time({ year = 2026, month = 10, day = 11, hour = 21, min = 14, sec = 5 })
    local function said(detail, language)
        return { Words.say(detail, language, at) }
    end
    T.same(said({ kind = "doorbell", name = "Gate" }), { "Someone is at the door", "Gate rang at 21:14." })
    T.same(said({ kind = "camera", name = "Garden", what = "smoke_alarm" }), { "Camera alert", "Smoke alarm at Garden at 21:14." })
    T.same(said({ kind = "camera", name = "Garden", what = "nonsense" }), { "Camera alert", "Alert at Garden at 21:14." })
    T.same(said({ kind = "door_opened", action = "pulse", name = "Main Gate", who = { type = "key", name = "iPhone", profile = "Dana" } }),
        { "DirectorLink", "Main Gate was opened by Dana (iPhone) at 21:14." })
    T.same(said({ kind = "door_opened", action = "pulse", name = "Main Gate", via = "Good night", who = { type = "key", name = "iPhone" } }),
        { "DirectorLink", "Main Gate was opened by iPhone, with the scene Good night, at 21:14." })
    T.same(said({ kind = "door_opened", action = "hold", name = "Main Gate", who = { type = "key" } }),
        { "DirectorLink", "Main Gate was held open by a removed device at 21:14." })
    T.same(said({ kind = "door_opened", action = "pulse", name = "Main Gate", who = { type = "control4" } }),
        { "DirectorLink", "Main Gate was opened in Control4 at 21:14." })
    T.same(said({ kind = "fridge_door", name = "Refrigerator", minutes = 7 }), { "DirectorLink", "Refrigerator – the door has been open for at least 7 min (21:14)." })
    T.same(said({ kind = "fridge_door", name = "Refrigerator" }), { "DirectorLink", "Refrigerator – the door was left open (21:14)." })
    T.same(said({ kind = "schedule_failed", name = "Morning blinds" }),
        { "DirectorLink", "Your home – the schedule for Morning blinds had a problem at 21:14. Open the app to see what happened." })
    T.same(said({ kind = "schedule_failed" }), { "DirectorLink", "Your home – a schedule had a problem at 21:14. Open the app to see what happened." })
    T.same(said({ kind = "doorbell" }), { "DirectorLink", "Your home – something needs your attention. Open the app to see what happened." }, "no name: the general words")
    -- Hebrew begins with a right-to-left mark; Spanish and Italian as the app says them.
    T.same(said({ kind = "doorbell", name = "Gate" }, "he"), { RLM .. "מישהו בדלת", RLM .. "צלצול ב-Gate ב-21:14." })
    T.same(said({ kind = "camera", name = "Garden", what = "person" }, "es"), { "Alerta de cámara", "Persona en Garden a las 21:14." })
    T.same(said({ kind = "doorbell", name = "Cancello" }, "it"), { "C’è qualcuno alla porta", "Cancello ha suonato alle 21:14." })
end

-- ---- finding the screens ------------------------------------------------------------------------

function tests.a_screen_is_found_by_its_marker_with_its_kinds_and_room()
    local home = home({
        { id = 301, name = "Living Room TV", room = 11, kinds = "doorbell, Camera ,door" },
        { id = 302, name = "Kitchen TV", room = 10 }, -- no kinds: every kind
        { id = 303, name = "Bedroom TV", room = 11, marker = false, kinds = "doorbell" },
        { id = 304, name = "Future TV", room = 10, marker = "2", kinds = "doorbell,popcorn" }, -- a later version reads as 1
        { id = 305, name = "Broken TV", room = 10, marker = "yes", kinds = "doorbell" },
        { id = 306, name = "Quiet TV", room = 11, kinds = "" }, -- shows nothing
    })
    local Targets = require("src.control4.notify_targets")
    local found = {}
    for _, target in ipairs(Targets.list()) do
        found[#found + 1] = { target.id, target.name, target.room_id, table.concat(Targets.kindList(target.kinds), ",") }
    end
    T.same(found, {
        { 304, "Future TV", 10, "doorbell" },
        { 302, "Kitchen TV", 10, "doorbell,camera,door,alarm,other" },
        { 301, "Living Room TV", 11, "doorbell,camera,door" },
        { 306, "Quiet TV", 11, "" },
    })
    -- Their variables are watched: the marker and the kinds (302 has no kinds variable).
    local watched = {}
    for _, listener in ipairs(home.mock.listeners) do
        if listener[1] >= 300 then
            watched[#watched + 1] = listener[1] .. ":" .. listener[2]
        end
    end
    table.sort(watched)
    T.same(watched, { "301:1002", "301:1003", "302:1002", "304:1002", "304:1003", "306:1002", "306:1003" })
    T.eq(#logged(home.mock, "a screen of DirectorLink's notification agreement"), 4)

    -- Settings → Alerts' list, for admins.
    local answer = T.http(home.mock, "GET", "/v1/alerts/screens", { key = home.admin })
    T.eq(answer.status, 200, answer.body)
    T.same(answer.json, {
        items = {
            { id = 304, name = "Future TV", room_id = 10, room = "Kitchen", kinds = { "doorbell" } },
            { id = 302, name = "Kitchen TV", room_id = 10, room = "Kitchen", kinds = { "doorbell", "camera", "door", "alarm", "other" } },
            { id = 301, name = "Living Room TV", room_id = 11, room = "Living Room", kinds = { "doorbell", "camera", "door" } },
            { id = 306, name = "Quiet TV", room_id = 11, room = "Living Room", kinds = Json.array() },
        },
        language = "en",
    })
    T.contains(answer.body, '"kinds":[]', "an empty list, not an object")
    T.eq(T.http(home.mock, "GET", "/v1/system", { key = home.admin }).json.features.alert_screens, true)
    -- Members do not see them; nobody without a key.
    local member = T.http(home.mock, "POST", "/v1/api-keys", { key = home.admin, body = { name = "Kids phone", role = "member" } }).json.key
    T.eq(T.http(home.mock, "GET", "/v1/alerts/screens", { key = member }).status, 403)
    T.eq(T.http(home.mock, "GET", "/v1/alerts/screens").status, 401)
end

function tests.no_screen_no_notification()
    local mock = Mock.startDriver(Mock.withAgreementCameras(Mock.project()))
    local _, connection = Harness.connected({ mock = mock })
    local admin = T.pair(mock, "Chrome on Windows")
    T.eq(Mock.cameraRing(mock, 158), 1)
    T.eq(Mock.cameraAlert(mock, 157, "Person"), 1)
    for _, command in ipairs(mock.commands) do
        T.truthy(command.command ~= "DIRECTORLINK_NOTIFY", "no screen told: " .. Json.encode(command))
    end
    T.same(T.http(mock, "GET", "/v1/alerts/screens", { key = admin }).json, { items = Json.array(), language = "en" })
    T.truthy(connection, "connected")
    -- Drivers looked at: every protocol driver and every driver without proxies, never DirectorLink.
    local Targets = require("src.control4.notify_targets")
    local looked = {}
    for _ = 1, 3 do
        for _, id in ipairs(Targets.lookAgain()) do
            looked[id] = true
        end
    end
    T.truthy(looked[101] and looked[110] and looked[157] and looked[70], "protocol drivers and drivers without proxies")
    T.eq(looked[572], nil, "not DirectorLink")
    T.eq(looked[20], nil, "not a proxy")
end

function tests.kinds_and_markers_that_change_are_followed()
    local home = home({ { id = 301, name = "Living Room TV", room = 11, kinds = "camera" }, { id = 302, name = "Kitchen TV", room = 10, marker = false } })
    local mock = home.mock
    T.eq(Mock.cameraRing(mock, 158), 1)
    T.eq(#Mock.notifications(mock, 301), 0, "not its kind")

    -- The installer adds the doorbell in the TV driver's properties: its driver says so at once.
    Mock.addVariables(mock, 301, { DIRECTORLINK_NOTIFY_KINDS = "camera,doorbell" })
    home.clock.now = home.clock.now + 60
    T.eq(Mock.cameraRing(mock, 158), 1)
    T.eq(only(mock, 301).KIND, "doorbell")
    T.eq(#logged(mock, "a screen's kinds changed"), 1)

    -- Its marker goes (the driver says it is not one now): told nothing, and back when it says "1".
    Mock.addVariables(mock, 301, { DIRECTORLINK_NOTIFY = "0" })
    home.clock.now = home.clock.now + 60
    Mock.cameraRing(mock, 158)
    T.eq(#Mock.notifications(mock, 301), 0, "off")
    T.same(T.http(mock, "GET", "/v1/alerts/screens", { key = home.admin }).json.items, Json.array())
    Mock.addVariables(mock, 301, { DIRECTORLINK_NOTIFY = "1" })
    home.clock.now = home.clock.now + 60
    Mock.cameraRing(mock, 158)
    T.eq(#Mock.notifications(mock, 301), 1, "on again")

    -- A driver that sets the marker after the project was read is found within minutes.
    Mock.addVariables(mock, 302, { DIRECTORLINK_NOTIFY = "1", DIRECTORLINK_NOTIFY_KINDS = "doorbell" })
    local Scheduler = require("src.core.scheduler")
    local Targets = require("src.control4.notify_targets")
    for _ = 1, 10 do
        Scheduler.tick()
        if #Targets.list() == 2 then
            break
        end
    end
    T.eq(#Targets.list(), 2, "the Kitchen TV found by a later look")
    home.clock.now = home.clock.now + 60
    Mock.cameraRing(mock, 158)
    T.eq(#Mock.notifications(mock, 302), 1)
    T.eq(#Mock.notifications(mock, 301), 1)

    -- A driver whose variables are gone (Composer reloading it) is kept one look, forgotten at two.
    mock.project.variables[302], mock.project.variableNames[302] = {}, {}
    local looks = 0
    while #Targets.list() == 2 and looks < 40 do
        Scheduler.tick()
        looks = looks + 1
    end
    T.eq(#Targets.list(), 1, "forgotten")
    T.truthy(looks > 1, "not at the first look")

    -- Refresh Project reads every driver again.
    Mock.addVariables(mock, 302, { DIRECTORLINK_NOTIFY = "1" })
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(#Targets.list(), 2, "found again by the refresh")
end

-- ---- what a screen is told ---------------------------------------------------------------------

function tests.a_ring_tells_the_screen_with_a_picture_for_sixty_seconds()
    local home = home({ { id = 301, name = "Living Room TV", room = 11 }, { id = 302, name = "Kitchen TV", room = 10, kinds = "doorbell" } })
    local mock = home.mock
    T.eq(Mock.cameraRing(mock, 158), 1)
    local told = only(mock, 301)
    T.eq(told.VERSION, "1")
    T.eq(told.KIND, "doorbell")
    T.eq(told.TITLE, "Someone is at the door")
    T.eq(told.MESSAGE, "Entrance rang at " .. hhmm(require("src.core.clock").parseIso(require("src.core.registry").getDevice(68).state.last.doorbell)) .. ".")
    T.truthy(told.ID:match("^%x+$") and #told.ID >= 16, "a random id")
    local url = told.PICTURE
    T.truthy(url:match("^http://192%.168%.1%.10:41999/v1/notify%-pictures/%x+%.jpg$"), "the controller's own address: " .. tostring(url))
    T.eq(#url:match("/(%x+)%.jpg$"), 32, "128 random bits")
    local other = only(mock, 302)
    T.eq(other.ID, told.ID, "one id for one alert")
    T.truthy(other.PICTURE ~= url, "each screen its own picture")
    for name, value in pairs(told) do
        T.eq(type(value), "string", name .. " is text")
    end

    -- The picture: the doorbell's camera's, without a key, three times at most, for 60 seconds.
    local path = pathOf(url)
    local picture = T.http(mock, "GET", path)
    T.eq(picture.status, 200, picture.body)
    T.eq(picture.headers["content-type"], "image/jpeg")
    T.eq(picture.body, "\255\216JPEG-/snapshot.jpg?size=640x360\255\217", "the camera's picture, 640 wide")
    home.clock.now = home.clock.now + 59
    T.eq(T.http(mock, "GET", path).status, 200, "a second time")
    local otherPath = pathOf(other.PICTURE)
    home.clock.now = home.clock.now + 1
    T.eq(T.http(mock, "GET", otherPath).status, 404, "gone after 60 seconds")
    T.eq(T.http(mock, "GET", path).status, 404)
    -- Nothing else is a picture; the log never names one.
    for _, wrong in ipairs({ "/v1/notify-pictures/" .. ("0"):rep(32) .. ".jpg", "/v1/notify-pictures/abc.jpg", "/v1/notify-pictures/" .. url:match("/(%x+)%.jpg$") }) do
        T.eq(T.http(mock, "GET", wrong).status, 404, wrong)
    end
    for _, line in ipairs(mock.debugLog) do
        T.notContains(line, url:match("/(%x+)%.jpg$"), "the picture's name in the log")
    end
    T.truthy(#logged(mock, "/v1/notify-pictures/…") > 0, "its requests are logged without it")
end

function tests.a_picture_is_used_three_times_at_most_and_none_without_an_address()
    local home = home(nil, function(mock)
        mock.controllerAddress = "10.0.0.5"
    end)
    local mock = home.mock
    Mock.cameraAlert(mock, 157, "Person")
    local told = only(mock, 301)
    T.truthy(told.PICTURE:match("^http://10%.0%.0%.5:41999/"), told.PICTURE)
    local path = pathOf(told.PICTURE)
    for _ = 1, 3 do
        T.eq(T.http(mock, "GET", path).status, 200)
    end
    T.eq(T.http(mock, "GET", path).status, 404, "a fourth time")
    -- A door has no picture; without the controller's address, nothing has.
    mock.controllerAddress = false
    home.clock.now = home.clock.now + 61
    Mock.cameraAlert(mock, 157, "Vehicle")
    T.eq(only(mock, 301).PICTURE, nil)
end

function tests.a_camera_alert_says_its_label_and_a_smoke_alarm_is_an_alarm()
    local home = home({ { id = 301, name = "Living Room TV", room = 11, kinds = "camera" }, { id = 302, name = "Kitchen TV", room = 10, kinds = "alarm,doorbell" } })
    local mock = home.mock
    local now = home.clock.now
    T.eq(Mock.cameraAlert(mock, 157, "License Plate"), 1)
    local told = only(mock, 301)
    T.eq(told.KIND, "camera")
    T.eq(told.TITLE, "Camera alert")
    T.eq(told.MESSAGE, "License plate at Porch at " .. hhmm(now) .. ".")
    T.truthy(told.PICTURE, "the camera's picture")
    T.eq(#Mock.notifications(mock, 302), 0, "the Kitchen TV shows no cameras")

    -- A smoke alarm the camera heard is an alarm on a screen, and never too soon.
    T.eq(Mock.cameraAlert(mock, 157, "Smoke Alarm"), 1)
    local alarm = only(mock, 302)
    T.eq(alarm.KIND, "alarm")
    T.eq(alarm.MESSAGE, "Smoke alarm at Porch at " .. hhmm(now) .. ".")
    T.truthy(alarm.PICTURE)
    T.eq(#Mock.notifications(mock, 301), 0, "not a camera alert there")
    Mock.cameraAlert(mock, 157, "CO Alarm")
    T.eq(only(mock, 302).MESSAGE, "CO alarm at Porch at " .. hhmm(now) .. ".")
end

function tests.at_most_one_of_a_kind_a_screen_in_five_seconds_but_rings_and_alarms_always()
    local home = home({ { id = 301, name = "Living Room TV", room = 11 }, { id = 302, name = "Kitchen TV", room = 10, kinds = "camera" } })
    local mock = home.mock
    Mock.cameraAlert(mock, 157, "Person")
    T.eq(#Mock.notifications(mock, 301), 1)
    T.eq(#Mock.notifications(mock, 302), 1)
    home.clock.now = home.clock.now + 4
    Mock.cameraAlert(mock, 157, "Vehicle")
    T.eq(#Mock.notifications(mock, 301), 0, "a camera again within 5 s")
    T.eq(#logged(mock, "notification not sent to a screen"), 2, "neither screen")
    -- Another kind is not held back by it.
    Mock.cameraRing(mock, 158)
    T.eq(only(mock, 301).KIND, "doorbell")
    home.clock.now = home.clock.now + 1
    Mock.cameraAlert(mock, 157, "Animal")
    T.eq(only(mock, 301).MESSAGE:match("^Animal") ~= nil, true, "5 s after the first")
    T.eq(#Mock.notifications(mock, 302), 1)
    -- Rings and alarms always: the phones' 30 s between rings do not hold the screen back either.
    for _ = 1, 3 do
        Mock.cameraRing(mock, 158)
        Mock.cameraAlert(mock, 157, "Smoke Alarm")
    end
    local kinds = {}
    for _, told in ipairs(Mock.notifications(mock, 301)) do
        kinds[#kinds + 1] = told.KIND
    end
    T.same(kinds, { "doorbell", "alarm", "doorbell", "alarm", "doorbell", "alarm" })
end

function tests.doors_the_refrigerator_and_schedules_are_doors_and_other()
    local home = home({ { id = 301, name = "Living Room TV", room = 11 } }, function()
        Properties["Door Control"] = "Enabled"
    end)
    local mock = home.mock
    local now = home.clock.now
    local profile = T.http(mock, "GET", "/v1/profile", { key = home.admin }).json
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profile.id, { key = home.admin, body = { name = "Dana" } }).status, 200)
    T.eq(T.http(mock, "POST", "/v1/relays/70/pulse", { key = home.admin }).status, 202)
    local door = only(mock, 301)
    T.eq(door.KIND, "door")
    T.eq(door.TITLE, "DirectorLink")
    T.eq(door.MESSAGE, "Main Door was opened by Dana (Chrome on Windows) at " .. hhmm(now) .. ".")
    T.eq(door.PICTURE, nil)

    -- Opened in Control4 (its relay closed from open, not DirectorLink's command).
    home.clock.now = now + 120
    Mock.fireDeviceEvent(mock, 70, 3)
    Mock.fireDeviceEvent(mock, 70, 4)
    T.eq(only(mock, 301).MESSAGE, "Main Door was opened in Control4 at " .. hhmm(home.clock.now) .. ".")

    -- The refrigerator's door left open (its integration calls the alert): a door too, so not
    -- within 5 s of the last; and a schedule that failed.
    local Alerts = require("src.cloud.alerts")
    Alerts.fridgeDoor({ id = 141, name = "Refrigerator", room_name = "Kitchen", room_id = 10 }, 60)
    T.eq(#Mock.notifications(mock, 301), 0, "a door 5 s after the last")
    home.clock.now = home.clock.now + 5
    Alerts.fridgeDoor({ id = 141, name = "Refrigerator", room_name = "Kitchen", room_id = 10 }, 7 * 60 + 59)
    local fridge = only(mock, 301)
    T.eq(fridge.KIND, "door")
    T.eq(fridge.MESSAGE, "Refrigerator – the door has been open for at least 7 min (" .. hhmm(home.clock.now) .. ").")
    Alerts.scheduleFailed(now, { what = "Morning blinds" })
    local schedule = only(mock, 301)
    T.eq(schedule.KIND, "other")
    T.eq(schedule.MESSAGE, "Your home – the schedule for Morning blinds had a problem at " .. hhmm(now) .. ". Open the app to see what happened.")
end

function tests.a_hebrew_owner_gets_hebrew()
    local home = home()
    local mock = home.mock
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { language = "he" } } }).status, 200)
    -- A member's language is not the home's.
    local member = T.http(mock, "POST", "/v1/api-keys", { key = home.admin, body = { name = "Kids phone", role = "member" } }).json.key
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = member, body = { prefs = { language = "it" } } }).status, 200)
    Mock.cameraAlert(mock, 157, "Person")
    local told = only(mock, 301)
    T.eq(told.TITLE, RLM .. "התראת מצלמה")
    T.eq(told.MESSAGE, RLM .. "אדם ב-Porch ב-" .. hhmm(home.clock.now) .. ".")
    T.eq(T.http(mock, "GET", "/v1/alerts/screens", { key = home.admin }).json.language, "he")
    -- Auto, and no app said what it shows (an app before 1.13.0): English.
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { language = "auto" } } }).status, 200)
    home.clock.now = home.clock.now + 60
    Mock.cameraAlert(mock, 157, "Person")
    T.eq(only(mock, 301).TITLE, "Camera alert")
end

-- With Auto the screens speak what the owner's app shows (the device's language), as the app
-- reports it on its profile (shown_language); a language the owner chose wins; without a report,
-- English. Only the owner's own report counts, and it changes no profile version.
function tests.with_auto_the_screens_speak_what_the_owners_app_shows()
    local home = home()
    local mock = home.mock
    local profile = T.http(mock, "GET", "/v1/profile", { key = home.admin }).json
    T.eq(profile.prefs.shown_language, Json.null, "null until the app says")
    T.contains(T.http(mock, "GET", "/v1/profile", { key = home.admin }).body, '"shown_language":null', "there, for the app to know it may tell")

    -- The owner's app shows Hebrew with Auto (a Hebrew phone).
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { language = "auto" } } }).status, 200)
    local before = T.http(mock, "GET", "/v1/profile", { key = home.admin }).json.version
    local reported = T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { shown_language = "he" } } })
    T.eq(reported.status, 200, reported.body)
    T.eq(reported.json.prefs.shown_language, "he")
    T.eq(reported.json.prefs.language, "auto", "the choice stays Auto")
    T.eq(reported.json.version, before, "a report is no choice: the version stays")
    Mock.cameraAlert(mock, 157, "Person")
    T.eq(only(mock, 301).TITLE, RLM .. "התראת מצלמה")
    T.eq(T.http(mock, "GET", "/v1/alerts/screens", { key = home.admin }).json.language, "he")

    -- A member's app says Italian: not the home's.
    local member = T.http(mock, "POST", "/v1/api-keys", { key = home.admin, body = { name = "Kids phone", role = "member" } }).json.key
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = member, body = { prefs = { shown_language = "it" } } }).status, 200)
    home.clock.now = home.clock.now + 60
    Mock.cameraAlert(mock, 157, "Person")
    T.eq(only(mock, 301).TITLE, RLM .. "התראת מצלמה")

    -- The owner chooses Spanish: it wins over what the app showed.
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { language = "es" } } }).status, 200)
    home.clock.now = home.clock.now + 60
    Mock.cameraAlert(mock, 157, "Person")
    T.eq(only(mock, 301).TITLE, "Alerta de cámara")

    -- What a profile cannot say, and a report kept across a restart.
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { shown_language = "auto" } } }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { shown_language = 7 } } }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { language = "auto" } } }).status, 200)
    local restarted = Mock.updateDriver(mock, mock.project)
    T.eq(T.http(restarted, "GET", "/v1/profile", { key = home.admin }).json.prefs.shown_language, "he")
    T.eq(T.http(restarted, "GET", "/v1/alerts/screens", { key = home.admin }).json.language, "he")
    -- A language the screens do not speak: English.
    T.eq(T.http(restarted, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { shown_language = "fr" } } }).status, 200)
    T.eq(T.http(restarted, "GET", "/v1/alerts/screens", { key = home.admin }).json.language, "en")

    local Words = require("src.core.notify_words")
    T.eq(Words.choose("es", "he"), "es")
    T.eq(Words.choose("auto", "he"), "he")
    T.eq(Words.choose(nil, "it"), "it")
    T.eq(Words.choose("auto", nil), "en")
    T.eq(Words.choose("fr", "he"), "he", "a choice the screens cannot speak: what the app shows")
    T.eq(Words.choose(nil, "fr"), "en")
end

function tests.screens_are_told_without_phones_or_the_relay_and_nothing_goes_into_the_history()
    -- Not connected, no device with alerts on.
    local home = home(nil, nil, false)
    local mock = home.mock
    local before = #T.http(mock, "GET", "/v1/activity", { key = home.admin }).json.items
    T.eq(Mock.cameraRing(mock, 158), 1)
    T.eq(Mock.cameraAlert(mock, 157, "Person"), 1)
    local got = Mock.notifications(mock, 301)
    T.eq(#got, 2, "both, with no phone and no relay")
    T.eq(#T.http(mock, "GET", "/v1/activity", { key = home.admin }).json.items, before, "no history entry")
    -- One line in the log each: the screen and the kind, never the words.
    local lines = logged(mock, "notification sent to a screen")
    T.eq(#lines, 2)
    T.contains(lines[1], '"driver_id":301')
    T.contains(lines[1], '"kind":"doorbell"')
    T.contains(lines[2], '"kind":"camera"')
    for _, line in ipairs(lines) do
        T.notContains(line, "Entrance")
        T.notContains(line, "Porch")
        T.notContains(line, "http://")
    end
end

function tests.a_screen_that_fails_holds_up_nothing()
    local home = home({
        { id = 301, name = "Broken TV", room = 11, fails = "the TV driver threw" },
        { id = 302, name = "Kitchen TV", room = 10 },
    })
    local mock = home.mock
    -- A phone that wants rings.
    local adminId = T.http(mock, "GET", "/v1/api-keys/current", { key = home.admin }).json.id
    T.eq(T.http(mock, "PUT", "/v1/alerts/choices", { key = home.admin, body = { on = true } }).status, 200)
    home.connection.sent = ""
    T.eq(Mock.cameraRing(mock, 158), 1)
    T.eq(#Mock.notifications(mock, 302), 1, "the other screen")
    local notified = 0
    for _, frame in ipairs(Harness.clientFrames(home.connection.sent)) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" and message.type == "notify" and message["for"][adminId] then
            notified = notified + 1
        end
    end
    T.eq(notified, 1, "the phone's ring alert still goes")
    T.eq(#logged(mock, "notification not sent to a screen"), 1)
    T.contains(logged(mock, "notification not sent to a screen")[1], "the TV driver threw")
    -- The doorbell still rang.
    T.truthy(require("src.core.registry").getDevice(68).state.last.doorbell)
    -- And a listener that throws stops nothing either.
    local Notify = require("src.core.notify")
    local alert = Notify.alert
    Notify.configure({ targets = { list = function()
        error("broken")
    end } })
    local Alerts = require("src.cloud.alerts")
    home.clock.now = home.clock.now + 60
    T.eq(Alerts.ring(require("src.core.registry").getDoorbell(68)), 1, "the phone's alert")
    T.eq(#logged(mock, "the screens were not told of an alert"), 1)
    T.truthy(alert)
end

-- ---- the home's alarm going off (the owner's decision of 2026-10-12) ---------------------------

-- The default project with the alarm's partitions (Mock.withPartitions: 80 "House", disarmed with a
-- zone open; 81 "Garage", armed away; 82 "Partition 3", which the panel does not use) and the
-- screens; Alarm Status On unless `off`.
local function alarmHome(screens, off, setup, connected)
    return home(screens, function(mock)
        if not off then
            Properties["Alarm Status"] = "On"
        end
        if setup then
            setup(mock)
        end
    end, connected, Mock.withPartitions(Mock.project()))
end

local function switchAlarm(value)
    Properties["Alarm Status"] = value
    OnPropertyChanged("Alarm Status")
end

function tests.a_partition_going_into_alarm_tells_the_screens_once_until_it_clears()
    local home = alarmHome({ { id = 301, name = "Living Room TV", room = 11 }, { id = 302, name = "Kitchen TV", room = 10, kinds = "doorbell" } })
    local mock = home.mock
    -- The panel names the type first: still no alarm.
    Mock.setPartition(mock, 80, { ALARM_TYPE = "Fire" })
    T.eq(#Mock.notifications(mock, 301), 0, "a type is no alarm")
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    local told = only(mock, 301)
    T.eq(told.VERSION, "1")
    T.eq(told.KIND, "alarm")
    T.eq(told.TITLE, "Alarm")
    T.eq(told.MESSAGE, "Fire alarm at House at " .. hhmm(home.clock.now) .. ".")
    T.eq(told.PICTURE, nil, "no picture")
    T.truthy(told.ID:match("^%x+$") and #told.ID >= 16, "a random id")
    T.eq(#Mock.notifications(mock, 302), 0, "the Kitchen TV shows no alarms")

    -- The same alarm going on: told once.
    home.clock.now = home.clock.now + 30
    Mock.setPartition(mock, 80, { PARTITION_STATE = "ALARM" })
    Mock.setPartition(mock, 80, { ALARM_TYPE = "Burglary" })
    Mock.setPartition(mock, 80, { OPEN_ZONE_COUNT = "3" })
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(mock, 301), 0, "one alarm, one notification")

    -- It clears: nothing. It goes off again: told again.
    Mock.setPartition(mock, 80, { ALARM_STATE = "0" })
    Mock.setPartition(mock, 80, { PARTITION_STATE = "DISARMED_READY" })
    T.eq(#Mock.notifications(mock, 301), 0, "nothing when it clears")
    home.clock.now = home.clock.now + 60
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    T.eq(only(mock, 301).MESSAGE, "Burglary alarm at House at " .. hhmm(home.clock.now) .. ".")

    -- A panel that says it only by the partition's state, as the app reads it too.
    Mock.setPartition(mock, 80, { ALARM_STATE = "0" })
    Mock.setPartition(mock, 80, { ALARM_TYPE = "" })
    Mock.setPartition(mock, 80, { PARTITION_STATE = "ALARM" })
    T.eq(only(mock, 301).MESSAGE, "The alarm went off at House at " .. hhmm(home.clock.now) .. ".", "without a type")
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(mock, 301), 0, "the same alarm")

    -- Another partition in the same second: alarms are never too soon.
    Mock.setPartition(mock, 81, { ALARM_STATE = "1" })
    T.eq(only(mock, 301).MESSAGE, "The alarm went off at Garage at " .. hhmm(home.clock.now) .. ".")
    T.eq(#logged(mock, "too soon"), 0)
    T.eq(#Mock.notifications(mock, 302), 0)
end

function tests.the_alarm_tells_nothing_of_armed_disarmed_or_trouble()
    local home = alarmHome()
    local mock = home.mock
    local changes = {
        { 80, { PARTITION_STATE = "EXIT_DELAY", DISARMED_STATE = "0", DELAY_TIME_TOTAL = "30", DELAY_TIME_REMAINING = "30" } },
        { 80, { PARTITION_STATE = "ARMED", HOME_STATE = "1", ARMED_TYPE = "Stay", DELAY_TIME_REMAINING = "0" } },
        { 80, { PARTITION_STATE = "ENTRY_DELAY", DELAY_TIME_TOTAL = "20", DELAY_TIME_REMAINING = "12" } },
        { 80, { PARTITION_STATE = "DISARMED_READY", HOME_STATE = "0", DISARMED_STATE = "1", OPEN_ZONE_COUNT = "0" } },
        { 81, { TROUBLE_TEXT = "AC power lost" } },
        { 81, { TROUBLE_TEXT = "" } },
        { 81, { PARTITION_STATE = "DISARMED_NOT_READY", AWAY_STATE = "0", DISARMED_STATE = "1", OPEN_ZONE_COUNT = "2" } },
        { 81, { PARTITION_STATE = "ARMED", AWAY_STATE = "1", ARMED_TYPE = "Away" } },
        { 81, { ALARM_TYPE = "Fire" } },
        { 82, { IS_ACTIVE = "1" } },
        { 82, { IS_ACTIVE = "0" } },
    }
    for _, change in ipairs(changes) do
        Mock.setPartition(mock, change[1], change[2])
        home.clock.now = home.clock.now + 10
    end
    T.eq(#Mock.notifications(mock, 301), 0, "no notification but the alarm going off")
    Mock.setPartition(mock, 81, { ALARM_STATE = "1" })
    T.eq(only(mock, 301).MESSAGE, "Fire alarm at Garage at " .. hhmm(home.clock.now) .. ".")
    -- A partition the panel does not use is not told.
    Mock.setPartition(mock, 82, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(mock, 301), 0, "an unused partition")
end

function tests.the_alarm_goes_to_the_screens_only_while_alarm_status_is_on()
    local home = alarmHome(nil, true)
    local mock = home.mock
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(mock, 301), 0, "Alarm Status Off: the alarm is not even watched")

    -- Turned On while House is in alarm: it was already, so nothing; the next time it goes off, told.
    switchAlarm("On")
    Mock.setPartition(mock, 80, { OPEN_ZONE_COUNT = "2" })
    T.eq(#Mock.notifications(mock, 301), 0, "in alarm before it was watched")
    Mock.setPartition(mock, 80, { ALARM_STATE = "0" })
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    T.eq(only(mock, 301).KIND, "alarm")

    -- Turned Off: nothing, whatever the partitions do.
    switchAlarm("Off")
    Mock.setPartition(mock, 80, { ALARM_STATE = "0" })
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    Mock.setPartition(mock, 81, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(mock, 301), 0, "Alarm Status Off")

    -- Off in the properties before Director says it changed: nothing either.
    switchAlarm("On")
    Mock.setPartition(mock, 81, { ALARM_STATE = "0" })
    Properties["Alarm Status"] = "Off"
    Mock.setPartition(mock, 81, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(mock, 301), 0, "Off, before OnPropertyChanged")
    Properties["Alarm Status"] = "On"

    -- A driver update during an alarm, or Refresh Project, tells it no second time.
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    Mock.setPartition(mock, 81, { OPEN_ZONE_COUNT = "2" })
    T.eq(#Mock.notifications(mock, 301), 0, "a refresh")
    local updated = Mock.updateDriver(mock, mock.project, function()
        Properties["Alarm Status"] = "On"
    end)
    Mock.setPartition(updated, 81, { OPEN_ZONE_COUNT = "3" })
    T.eq(#Mock.notifications(updated, 301), 0, "a driver update")
    Mock.setPartition(updated, 81, { ALARM_STATE = "0" })
    Mock.setPartition(updated, 81, { ALARM_STATE = "1" })
    T.eq(#Mock.notifications(updated, 301), 1, "the next alarm after the update")
end

function tests.the_alarm_says_its_type_in_every_language()
    local Words = require("src.core.notify_words")
    local at = os.time({ year = 2026, month = 10, day = 12, hour = 21, min = 14, sec = 5 })
    local function said(what, language, name)
        return { Words.say({ kind = "alarm_triggered", name = name or "House", what = what }, language, at) }
    end
    T.same(said("Fire"), { "Alarm", "Fire alarm at House at 21:14." })
    T.same(said(" BURGLARY "), { "Alarm", "Burglary alarm at House at 21:14." }, "without case or spaces")
    T.same(said("Smoke"), { "Alarm", "Fire alarm at House at 21:14." })
    T.same(said("carbon monoxide"), { "Alarm", "Carbon monoxide alarm at House at 21:14." })
    T.same(said(nil), { "Alarm", "The alarm went off at House at 21:14." })
    T.same(said("Zone 7 AUX"), { "Alarm", "The alarm went off at House at 21:14." }, "the panel's own words never")
    T.same(said("Fire", "en", ""), { "DirectorLink", "Your home – something needs your attention. Open the app to see what happened." }, "no name")
    T.same(said("Fire", "he"), { RLM .. "אזעקה", RLM .. "אזעקת שריפה ב-House ב-21:14." })
    T.same(said(nil, "he"), { RLM .. "אזעקה", RLM .. "אזעקה ב-House ב-21:14." })
    T.same(said("fire", "es"), { "Alarma", "Alarma de incendio en House a las 21:14." })
    T.same(said(nil, "es"), { "Alarma", "La alarma saltó en House a las 21:14." })
    T.same(said("intrusion", "it"), { "Allarme", "Allarme intrusione presso House alle 21:14." })
    T.same(said(nil, "it"), { "Allarme", "L’allarme è scattato presso House alle 21:14." })

    -- The types are the app's (app/js/alarm.js ALARM_TYPES), each with its word in every language.
    local file = assert(io.open("app/js/alarm.js", "rb"))
    local source = file:read("*a")
    file:close()
    local block = assert(source:match("const ALARM_TYPES = (%b{})"), "ALARM_TYPES in app/js/alarm.js")
    local app = {}
    for line in block:gmatch("[^\n]+") do
        local key, value = line:match('^%s*"?([%w ]-)"?%s*:%s*"(%w+)",?%s*$')
        if key then
            app[key] = value
        end
    end
    T.truthy(next(app) ~= nil, "read the app's types")
    T.same(Words.ALARM_TYPES, app, "the app's types")
    for _, code in ipairs({ "en", "he", "es", "it" }) do
        for _, word in pairs(Words.ALARM_TYPES) do
            T.truthy(Words.WORDS[code]["alarm.types." .. word], code .. " says " .. word)
        end
    end
end

function tests.a_hebrew_owner_hears_the_alarm_in_hebrew()
    local home = alarmHome()
    local mock = home.mock
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = home.admin, body = { prefs = { language = "he" } } }).status, 200)
    Mock.setPartition(mock, 80, { ALARM_TYPE = "FIRE" })
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    local told = only(mock, 301)
    T.eq(told.TITLE, RLM .. "אזעקה")
    T.eq(told.MESSAGE, RLM .. "אזעקת שריפה ב-House ב-" .. hhmm(home.clock.now) .. ".")
end

function tests.the_alarm_going_off_is_never_logged_nor_sent_to_a_phone_or_the_cloud()
    local home = alarmHome(nil, false, function()
        Properties["Log Level"] = "Debug"
    end)
    local mock = home.mock
    -- A phone with every alert on.
    T.eq(T.http(mock, "PUT", "/v1/alerts/choices", { key = home.admin, body = { on = true } }).status, 200)
    local history = #T.http(mock, "GET", "/v1/activity", { key = home.admin }).json.items
    home.connection.sent = ""
    local before = #mock.debugLog

    -- Director has the type a moment before its change reaches the driver.
    mock.project.variables[80][1011] = "Burglary"
    Mock.setPartition(mock, 80, { ALARM_STATE = "1" })
    T.eq(only(mock, 301).MESSAGE, "Burglary alarm at House at " .. hhmm(home.clock.now) .. ".", "the type Director has")
    Mock.setPartition(mock, 80, { ALARM_TYPE = "Burglary" })
    Mock.setPartition(mock, 80, { PARTITION_STATE = "ALARM", TROUBLE_TEXT = "Siren tamper" })
    T.eq(#Mock.notifications(mock, 301), 0)

    -- The log: one line, the screen and the kind; nothing of the partition or its state.
    local lines = {}
    for index = before + 1, #mock.debugLog do
        lines[#lines + 1] = mock.debugLog[index]
    end
    local sentLines = logged(mock, "notification sent to a screen")
    T.eq(#sentLines, 1, table.concat(lines, "\n"))
    T.contains(sentLines[1], '"driver_id":301')
    T.contains(sentLines[1], '"kind":"alarm"')
    local logs = T.http(mock, "GET", "/v1/logs?limit=500", { key = home.admin })
    T.eq(logs.status, 200)
    for _, text in ipairs({ table.concat(lines, "\n"), logs.body }) do
        for _, word in ipairs({ "House", "Burglary", "ALARM", "Siren tamper", "alarm at", "went off", '"device_id":80' }) do
            T.notContains(text, word, "nothing of the alarm in the log")
        end
    end

    -- No phone and no cloud: nothing to the relay; nothing in the history.
    for _, frame in ipairs(Harness.clientFrames(home.connection.sent)) do
        local message = Json.decode(frame.payload)
        T.truthy(not (type(message) == "table" and message.type == "notify"), "no alert to a phone: " .. tostring(frame.payload))
    end
    T.eq(#T.http(mock, "GET", "/v1/activity", { key = home.admin }).json.items, history, "no history entry")
end

return tests
