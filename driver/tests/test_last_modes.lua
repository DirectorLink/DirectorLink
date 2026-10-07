-- On, as it was (1.10.0, ADR-070, docs/SCENES.md): DirectorLink remembers each thermostat's last
-- mode that was not off, wherever it was set (src/core/last_modes.lua: at start and at every change
-- of its variables), keeps it across restarts, and a scene's climate step with mode "on" turns each
-- AC that is off back on in it, with nothing else sent (its temperature and fan stay as they were).
-- One that is on is left as it is; one whose last mode is not known yet is skipped, and the run and
-- History say so. Going back to 1.9.0 keeps the step (src/core/scenes.lua, KEPT).

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

-- A Thermostat V2 AC zone like the project's zone 30 (Off, Heat, Cool; fan Low, Medium, High).
local function addAc(project, id, protocol, roomId, name, mode)
    local roomName = roomId == 10 and "Kitchen" or "Living Room"
    project.devices[protocol] = {
        deviceName = "AC Zone", driverFileName = "coolautomation_cmnet_zone.c4z", roomId = roomId, roomName = roomName,
        proxies = { [id] = { deviceName = name, driverFileName = "thermostatV2.c4i" } },
    }
    project.devices[id] = {
        deviceName = name, driverFileName = "thermostatV2.c4i", roomId = roomId, roomName = roomName,
        protocol = { [protocol] = { deviceName = "AC Zone", driverFileName = "coolautomation_cmnet_zone.c4z" } },
    }
    project.variables[id] = {
        [1100] = "CELSIUS", [1104] = mode, [1105] = "Medium", [1107] = mode, [1112] = "1",
        [1120] = "Off,Heat,Cool", [1131] = "24", [1149] = "71.6",
    }
    return project
end

-- The project's AC 30 (Living Room, in cool), two AC zones in the Kitchen (33 in heat, 34 off and
-- never seen on), a thermostat with heat and cool setpoints (31, Kitchen, in auto) and floor heating
-- that only heats (32, Living Room, in heat). `modes`: id -> the mode a thermostat starts in.
local function project(modes)
    local p = Mock.withHeatOnlyZone(Mock.withDualThermostat(Mock.project()))
    addAc(p, 33, 114, 10, "Kitchen AC", "Heat")
    addAc(p, 34, 115, 10, "Guest AC", "Off")
    for id, mode in pairs(modes or {}) do
        p.variables[id][1104] = mode
    end
    return p
end

local function start(modes)
    local mock = Mock.startDriver(project(modes))
    local admin = T.pair(mock, "Chrome on Windows")
    return mock, admin
end

local function thermostat(mock, key, id)
    local answer = T.http(mock, "GET", "/v1/thermostats/" .. id, { key = key })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function stored(mock)
    local value = mock.persist.directorlink_last_modes
    return value and Json.decode((value:gsub("^json:", ""))) or nil
end

-- What each thermostat was sent since `before`, as { command, params }.
local function sentSince(mock, before)
    local by = {}
    for index = before + 1, #mock.commands do
        local command = mock.commands[index]
        by[command.device] = by[command.device] or {}
        table.insert(by[command.device], { command.command, command.params })
    end
    return by
end

-- Turned off as the family does (a keypad, Control4's app): the mode variable says Off.
local function turnOff(mock, ids)
    for _, id in ipairs(ids) do
        T.eq(Mock.changeVariable(mock, id, 1104, "Off"), 1, "thermostat " .. id .. " watches its mode")
    end
end

local function scene(mock, key, steps, name)
    local created = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = name or "Shabbat AC", steps = steps } })
    T.eq(created.status, 201, created.body)
    return created.json
end

local function run(mock, key, sceneId)
    local before = #mock.commands
    local answer = T.http(mock, "POST", "/v1/scenes/" .. sceneId .. "/run", { key = key })
    T.eq(answer.status, 202, answer.body)
    return answer.json, sentSince(mock, before)
end

-- ---- the last mode -----------------------------------------------------------------------------

function tests.each_thermostat_s_last_mode_is_seen_at_start_and_at_every_change_and_kept()
    local writes = 0
    local mock = Mock.startDriver(project(), nil, nil, function()
        local write = C4.PersistSetValue
        C4.PersistSetValue = function(self, name, value, encrypted)
            if name == "directorlink_last_modes" then
                writes = writes + 1
            end
            return write(self, name, value, encrypted)
        end
    end)
    local key = T.pair(mock)
    T.eq(thermostat(mock, key, 30).last_mode, "cool", "on at start")
    T.eq(thermostat(mock, key, 31).last_mode, "auto")
    T.eq(thermostat(mock, key, 32).last_mode, "heat", "floor heating")
    T.eq(thermostat(mock, key, 34).last_mode, Json.null, "off since DirectorLink started")
    T.same(stored(mock).modes, { ["30"] = "cool", ["31"] = "auto", ["32"] = "heat", ["33"] = "heat" })
    local started = writes

    -- Turned off: the last mode stays. The room's temperature changes often: nothing is written.
    turnOff(mock, { 30 })
    Mock.changeVariable(mock, 30, 1131, "25")
    T.eq(thermostat(mock, key, 30).mode, "off")
    T.eq(thermostat(mock, key, 30).last_mode, "cool")
    T.eq(writes, started, "written only when a last mode changes")
    -- Heat from a keypad, then off again; the guest room's AC turned on in Control4's app.
    Mock.changeVariable(mock, 30, 1104, "Heat")
    turnOff(mock, { 30 })
    Mock.changeVariable(mock, 34, 1104, "Cool")
    T.eq(writes, started + 2)
    T.eq(thermostat(mock, key, 30).last_mode, "heat")
    T.eq(thermostat(mock, key, 34).last_mode, "cool")
    -- The dual thermostat's mode, through the Control4 thermostat proxy.
    Mock.changeVariable(mock, 31, 1104, "Cool")
    T.eq(thermostat(mock, key, 31).last_mode, "cool")
    Mock.changeVariable(mock, 31, 1104, "Off")

    -- Kept across a restart, while they are off.
    local updated = Mock.updateDriver(mock, mock.project)
    T.eq(thermostat(updated, key, 30).mode, "off")
    T.eq(thermostat(updated, key, 30).last_mode, "heat")
    T.eq(thermostat(updated, key, 31).last_mode, "cool")
    T.eq(thermostat(updated, key, 34).last_mode, "cool")
    T.eq(T.http(updated, "GET", "/v1/system", { key = key }).json.features.climate_last_mode, true)
end

-- ---- a scene: on, as it was --------------------------------------------------------------------

-- The owner's "Shabbat and holiday" scene: one AC by name and all the AC of two rooms. Each comes
-- back as the family last left it, in its own mode, with its own temperature and fan.
function tests.a_scene_turns_each_ac_on_as_it_was()
    local mock, admin = start()
    Mock.changeVariable(mock, 34, 1104, "Cool")
    turnOff(mock, { 30, 31, 32, 33, 34 })
    local shabbat = scene(mock, admin, {
        { type = "climate", device_ids = { 30 }, set = { mode = "on" } },
        { type = "climate", room_id = 10, set = { mode = "on" } },
        { type = "climate", room_id = 11, set = { mode = "on" } },
    })
    T.same(shabbat.steps[1].set, { mode = "on" })
    local result, sent = run(mock, admin, shabbat.id)
    T.eq(result.ran, 6, result)
    T.eq(result.skipped, 0)
    T.eq(#result.problems, 0)
    T.same(sent[30], { { "SET_MODE_HVAC", { MODE = "Cool" } }, { "SET_MODE_HVAC", { MODE = "Cool" } } }, "only the mode, twice: by name and with its room")
    T.same(sent[33], { { "SET_MODE_HVAC", { MODE = "Heat" } } })
    T.same(sent[34], { { "SET_MODE_HVAC", { MODE = "Cool" } } })
    T.same(sent[31], { { "SET_MODE_HVAC", { MODE = "Auto" } } }, "both setpoints kept")
    T.same(sent[32], { { "SET_MODE_HVAC", { MODE = "Heat" } } }, "floor heating: its heat setpoint kept")
end

function tests.an_ac_that_is_on_is_left_as_it_is()
    local mock, admin = start()
    turnOff(mock, { 33 })
    local both = scene(mock, admin, { { type = "climate", device_ids = { 30, 33 }, set = { mode = "on" } } })
    local result, sent = run(mock, admin, both.id)
    T.eq(result.ran, 2, "the one already on counts as ran")
    T.eq(#result.problems, 0)
    T.eq(sent[30], nil, "nothing is sent to an AC that is on")
    T.same(sent[33], { { "SET_MODE_HVAC", { MODE = "Heat" } } })
end

function tests.an_ac_whose_last_mode_is_not_known_is_left_off_and_the_run_says_so()
    local mock, admin = start({ [30] = "Off" })
    local guest = scene(mock, admin, { { type = "climate", device_ids = { 30, 33 }, set = { mode = "on" } } })
    turnOff(mock, { 33 })
    local result, sent = run(mock, admin, guest.id)
    T.eq(result.ran, 1)
    T.eq(result.skipped, 1)
    T.same({ result.problems[1].device_id, result.problems[1].outcome, result.problems[1].code }, { 30, "skipped", "NO_LAST_MODE" })
    T.contains(result.problems[1].detail, "No last mode known yet; set it once")
    T.eq(sent[30], nil, "never a guessed heat or cool")
    -- History says so.
    local entry = T.http(mock, "GET", "/v1/activity?kind=scene", { key = admin }).json.items[1]
    T.same({ entry.kind, entry.action, entry.what }, { "scene", "run", "Shabbat AC" })
    T.same(entry.counts, { ran = 1, skipped = 1, failed = 0, no_last_mode = 1 })

    -- Set once (the family turns it on in cool), then off: from now on it comes back in cool.
    Mock.changeVariable(mock, 30, 1104, "Cool")
    turnOff(mock, { 30 })
    result, sent = run(mock, admin, guest.id)
    T.eq(result.ran, 2)
    T.same(sent[30], { { "SET_MODE_HVAC", { MODE = "Cool" } } })
    entry = T.http(mock, "GET", "/v1/activity?kind=scene", { key = admin }).json.items[1]
    T.eq(entry.counts.no_last_mode, nil)
end

-- A schedule that leaves ACs off this way alerts the admins who chose "a schedule had a problem",
-- once a run, with the scene's name only (the same sealed alert as a device that refused: ADR-047,
-- ADR-050). A run from the app says so on the spot, and alerts nobody.
function tests.a_scheduled_run_that_leaves_acs_off_alerts_the_admins_once()
    local alerts = {}
    local mock = Mock.startDriver(project({ [30] = "Off", [33] = "Off" }), nil, nil, function()
        require("src.cloud.alerts").scheduleFailed = function(at, info)
            alerts[#alerts + 1] = { at = at, info = info }
            return 1
        end
    end)
    local admin = T.pair(mock)
    local fields = os.date("*t")
    fields.hour, fields.min, fields.sec = 10, 0, 0
    local now = os.time(fields)
    require("src.core.clock").now = function()
        return now
    end
    local Scheduler = require("src.core.scheduler")
    local shabbat = scene(mock, admin, { { type = "climate", device_ids = { 30, 33, 34 }, set = { mode = "on" } } }, "Shabbat AC")
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = { scene_id = shabbat.id, trigger = { type = "time", at = "10:05" }, days = { 0, 1, 2, 3, 4, 5, 6 } } })
    T.eq(created.status, 201, created.body)
    T.eq(run(mock, admin, shabbat.id).skipped, 3)
    T.eq(#alerts, 0, "a run from the app alerts nobody")
    now = now + 5 * 60 + 1
    T.eq(Scheduler.tick(), 1)
    T.eq(#alerts, 1, "one alert for the run, not one per AC")
    T.eq(alerts[1].at, now)
    T.same(alerts[1].info, { what = "Shabbat AC" }, "the scene's name, as for a device that refused")
    T.eq(T.http(mock, "GET", "/v1/activity?kind=schedule", { key = admin }).json.items[1].counts.no_last_mode, 3)

    -- Seen on once each: the next day's run turns them on, and alerts nobody.
    for _, id in ipairs({ 30, 33, 34 }) do
        Mock.changeVariable(mock, id, 1104, "Cool")
    end
    turnOff(mock, { 30, 33, 34 })
    now = now + 86400
    T.eq(Scheduler.tick(), 1)
    T.eq(#alerts, 1)
end

function tests.a_last_mode_directorlink_cannot_set_is_never_replaced_by_another()
    local mock, admin = start()
    -- Dry from the AC's own remote, on a zone that lists it: not one of the modes DirectorLink sets.
    Mock.changeVariable(mock, 30, 1120, "Off,Heat,Cool,Dry")
    Mock.changeVariable(mock, 30, 1104, "Dry")
    turnOff(mock, { 30 })
    T.eq(thermostat(mock, admin, 30).last_mode, "dry")
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = admin, body = { steps = { { type = "climate", device_ids = { 30 }, set = { mode = "on" } } } } })
    T.eq(tried.status, 202, tried.body)
    T.eq(tried.json.skipped, 1)
    T.eq(tried.json.problems[1].code, "MODE_NOT_SUPPORTED")
    T.contains(tried.json.problems[1].detail, "dry")
end

-- Only one of the thermostat's own modes (its HVAC_MODES_LIST) is remembered: a value outside it,
-- such as "Undefined" while the zone's driver starts, or Dry on a zone that does not list it, leaves
-- the last mode as it was.
function tests.a_mode_outside_the_thermostat_s_own_list_is_never_remembered()
    local mock, admin = start({ [34] = "Off" })
    Mock.changeVariable(mock, 30, 1104, "Undefined")
    turnOff(mock, { 30 })
    T.eq(thermostat(mock, admin, 30).last_mode, "cool", "not undefined")
    Mock.changeVariable(mock, 30, 1104, "Dry")
    turnOff(mock, { 30 })
    T.eq(thermostat(mock, admin, 30).last_mode, "cool", "Dry is not one of this zone's modes")
    Mock.changeVariable(mock, 34, 1104, "Undefined")
    T.eq(thermostat(mock, admin, 34).last_mode, Json.null, "never seen in one of its modes")
    T.same(stored(mock).modes, { ["30"] = "cool", ["31"] = "auto", ["32"] = "heat", ["33"] = "heat" })
    -- So the scene turns it back on in cool.
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = admin, body = { steps = { { type = "climate", device_ids = { 30 }, set = { mode = "on" } } } } })
    T.eq(tried.status, 202, tried.body)
    T.eq(tried.json.ran, 1, tried.json)
end

-- Keep: a step with a mode alone sends no setpoint and no fan speed (the app's Keep).
function tests.a_mode_alone_keeps_the_temperature_and_the_fan()
    local mock, admin = start()
    turnOff(mock, { 30, 31, 32 })
    local before = #mock.commands
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = admin, body = { steps = {
        { type = "climate", device_ids = { 30, 31 }, set = { mode = "cool" } },
        { type = "climate", device_ids = { 31 }, set = { mode = "auto" } },
        { type = "climate", device_ids = { 32 }, set = { mode = "heat" } },
    } } })
    T.eq(tried.status, 202, tried.body)
    T.eq(tried.json.ran, 4)
    local sent = sentSince(mock, before)
    T.same(sent[30], { { "SET_MODE_HVAC", { MODE = "Cool" } } })
    T.same(sent[31], { { "SET_MODE_HVAC", { MODE = "Cool" } }, { "SET_MODE_HVAC", { MODE = "Auto" } } })
    T.same(sent[32], { { "SET_MODE_HVAC", { MODE = "Heat" } } })
end

function tests.on_takes_nothing_else_and_older_words_are_refused()
    local mock, admin = start()
    for _, set in ipairs({
        { mode = "on", target_temperature = 22 },
        { mode = "on", fan_speed = "medium" },
        { mode = "on", heat_setpoint = 20, cool_setpoint = 24 },
        { mode = "last" },
    }) do
        local answer = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Test", steps = { { type = "climate", set = set } } } })
        T.eq(answer.status, 400, answer.body)
        T.eq(answer.json.code, "INVALID_FIELD")
    end
    local refused = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Test", steps = { { type = "climate", set = { mode = "on", fan_speed = "low" } } } } })
    T.contains(refused.body, "as it was")
    T.eq(#T.http(mock, "GET", "/v1/scenes", { key = admin }).json.items, 0)
end

-- Composer's Print Schedules and Scenes.
function tests.the_printout_says_on_as_it_was()
    local mock, admin = start()
    scene(mock, admin, { { type = "climate", room_id = 10, set = { mode = "on" } } })
    local lines = {}
    local realPrint = _G.print
    _G.print = function(...)
        lines[#lines + 1] = table.concat({ ... }, " ")
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    T.contains(table.concat(lines, "\n"), "all climate in Kitchen (10) -> on, as it was")
end

-- ---- going back to 1.9.0 and returning -----------------------------------------------------------

local function storedScenes(mock)
    return Json.decode((mock.persist.directorlink_scenes:gsub("^json:", "")))
end

-- DirectorLink 1.9.0 knows the modes off, heat, cool and auto: it leaves an "on" step out when it
-- loads the scenes, and its next save writes them without it (with steps_kept and
-- music_steps_kept, and without climate_steps_kept, which it does not know). Back on 1.10.0 the
-- step comes back in its place.
function tests.on_steps_come_back_after_a_downgrade_to_1_9_0()
    local mock, admin = start()
    local shabbat = scene(mock, admin, {
        { type = "lights", device_ids = { 20 }, set = { on = false } },
        { type = "climate", device_ids = { 30 }, set = { mode = "on" } },
        { type = "climate", room_id = 10, set = { mode = "cool", target_temperature = 20, fan_speed = "medium" } },
    })
    T.truthy(mock.persist.directorlink_scene_steps_3, "kept apart")
    local record = storedScenes(mock)
    T.same({ record.steps_kept, record.music_steps_kept, record.climate_steps_kept }, { true, true, true })

    -- What 1.9.0 does with its own scenes module: the step is left out as it loads.
    local Scenes = require("src.core.scenes")
    Scenes.MODES.on = nil
    local loaded = Scenes.read(storedScenes(mock))
    Scenes.MODES.on = true
    T.eq(#loaded[1].steps, 2, "1.9.0 runs the lights and the cool step")
    -- Its save: the steps it knows and its two marks.
    local data = storedScenes(mock)
    table.remove(data.scenes[1].steps, 2)
    data.scenes[1].name = "Shabbat AC (1.9.0)"
    data.climate_steps_kept = nil
    mock.persist.directorlink_scenes = "json:" .. Json.encode(data)

    local updated = Mock.updateDriver(mock, mock.project)
    local back = T.http(updated, "GET", "/v1/scenes/" .. shabbat.id, { key = admin }).json
    T.eq(back.name, "Shabbat AC (1.9.0)")
    T.same(back.steps[2], { type = "climate", room_id = Json.null, device_ids = { 30 }, set = { mode = "on" } }, "in its place")
    T.eq(#back.steps, 3)
    T.same(storedScenes(updated).climate_steps_kept, true)
    -- Removed on 1.10.0, it stays removed.
    T.eq(T.http(updated, "PATCH", "/v1/scenes/" .. shabbat.id, { key = admin, body = { steps = { back.steps[1], back.steps[3] } } }).status, 200)
    local again = Mock.updateDriver(updated, updated.project)
    T.eq(#T.http(again, "GET", "/v1/scenes/" .. shabbat.id, { key = admin }).json.steps, 2)
end

return tests
