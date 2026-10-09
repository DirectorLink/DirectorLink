-- Fans (the Fan proxy fan.c4i, src/adapters/fan.lua; #18): /v1/fans with on, off and speeds 1-4,
-- the state from IS_ON and CURRENT_SPEED, fan steps in scenes and schedules, roles, and requests
-- sealed at home and through the account. The fake fans are Mock.withFans: 41 on at speed 2 in the
-- living room, 42 off in the kitchen.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

local function start(change, prepare)
    local project = Mock.withFans(Mock.project())
    if change then
        change(project)
    end
    local mock = Mock.startDriver(project, nil, nil, prepare)
    return mock, T.pair(mock)
end

local function commandsSince(mock, before)
    local list = {}
    for index = before + 1, #mock.commands do
        local command = mock.commands[index]
        list[#list + 1] = { device = command.device, command = command.command, params = command.params }
    end
    return list
end

local function listening(mock, deviceId, variableId)
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId and entry[2] == variableId then
            return true
        end
    end
    return false
end

local function createKey(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role .. " phone", role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json.id
end

function tests.fans_are_listed_with_their_state()
    local mock, key = start()
    T.contains(mock.properties["Inventory"], "3 lights, 1 thermostats, 2 fans, 2 blinds")
    local fans = T.http(mock, "GET", "/v1/fans", { key = key }).json.items
    T.eq(#fans, 2)
    local ceiling = fans[1]
    T.eq(ceiling.id, 41)
    T.eq(ceiling.name, "Ceiling Fan")
    T.eq(ceiling.room.id, 11)
    T.eq(ceiling.room.name, "Living Room")
    T.eq(ceiling.on, true)
    T.eq(ceiling.speed, 2)
    T.same(ceiling.speeds, { 1, 2, 3, 4 })
    local keys = {}
    for name in pairs(ceiling) do
        keys[#keys + 1] = name
    end
    table.sort(keys)
    T.same(keys, { "id", "name", "on", "room", "speed", "speeds" }, "no Control4 names or ids")
    T.eq(fans[2].id, 42, "sorted by name")
    T.eq(fans[2].on, false)
    T.truthy(isNull(fans[2].speed), "no speed while off")
    T.same(fans[2].speeds, { 1, 2, 3, 4 })

    local kitchen = T.http(mock, "GET", "/v1/fans?room_id=10", { key = key }).json.items
    T.eq(#kitchen, 1)
    T.eq(kitchen[1].id, 42)
    T.eq(T.http(mock, "GET", "/v1/fans/41", { key = key }).json.speed, 2)
    T.eq(T.http(mock, "GET", "/v1/fans/20", { key = key }).status, 404, "a light is not a fan")

    local device = T.http(mock, "GET", "/v1/devices/41", { key = key }).json
    T.eq(device.type, "fan")
    T.eq(device.supported, true)
    T.eq(device.href, "/v1/fans/41")
    T.eq(#T.http(mock, "GET", "/v1/devices?type=fan", { key = key }).json.items, 2)
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.inventory.fans, 2)

    T.truthy(listening(mock, 41, 1000) and listening(mock, 41, 1001) and listening(mock, 42, 1000) and listening(mock, 42, 1001))
    T.truthy(not listening(mock, 41, 1003), "the preset speed is only logged")

    -- Composer changes: the fans are read again with the project.
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(#T.http(mock, "GET", "/v1/fans", { key = key }).json.items, 2)
    T.truthy(listening(mock, 41, 1001), "and watched again")
end

function tests.fan_patch_sends_on_off_and_set_speed()
    local mock, key = start()
    local function patch(id, body)
        local before = #mock.commands
        local response = T.http(mock, "PATCH", "/v1/fans/" .. id, { key = key, body = body })
        T.eq(response.status, 202, response.body)
        local sent = commandsSince(mock, before)
        T.eq(#sent, 1, "one command")
        return sent[1], response.json
    end
    local sent, answer = patch(42, { on = true })
    T.same(sent, { device = 42, command = "ON", params = {} })
    T.eq(answer.id, 42)
    T.eq(answer.on, false, "the answer is the last state reported")
    T.same((patch(41, { on = false })), { device = 41, command = "OFF", params = {} })
    T.same((patch(42, { speed = 3 })), { device = 42, command = "SET_SPEED", params = { SPEED = 3 } }, "SPEED is a number")
    T.same((patch(41, { on = true, speed = 1 })), { device = 41, command = "SET_SPEED", params = { SPEED = 1 } })
    T.same((patch(41, { speed = 4 })), { device = 41, command = "SET_SPEED", params = { SPEED = 4 } })
end

function tests.fan_patch_validates_input_and_sends_nothing()
    local mock, key = start()
    local before = #mock.commands
    local function refused(id, body, status, code)
        local response = T.http(mock, "PATCH", "/v1/fans/" .. id, { key = key, body = body })
        T.eq(response.status, status, response.body)
        T.eq(response.json.code, code, response.body)
        return response.json
    end
    T.eq(refused(41, { speed = 0 }, 400, "INVALID_FIELD").errors[1].field, "speed", "off is on: false")
    refused(41, { speed = 5 }, 400, "INVALID_FIELD")
    refused(41, { speed = 2.5 }, 400, "INVALID_FIELD")
    refused(41, { speed = "2" }, 400, "INVALID_FIELD")
    refused(41, { speed = -1 }, 400, "INVALID_FIELD")
    refused(41, { on = "yes" }, 400, "INVALID_FIELD")
    refused(41, { on = 1 }, 400, "INVALID_FIELD")
    refused(41, { direction = "reverse" }, 400, "INVALID_FIELD")
    refused(41, { on = false, speed = 2 }, 400, "INVALID_REQUEST")
    refused(41, {}, 400, "INVALID_REQUEST")
    refused(99, { on = true }, 404, "NOT_FOUND")
    refused(20, { on = true }, 404, "NOT_FOUND")
    refused("abc", { on = true }, 400, "INVALID_PARAMETER")
    T.eq(#mock.commands, before, "nothing is sent")
end

function tests.fan_state_follows_its_variables()
    local mock, key = start()
    local function fan()
        return T.http(mock, "GET", "/v1/fans/41", { key = key }).json
    end
    Mock.changeVariable(mock, 41, 1001, "4")
    T.eq(fan().speed, 4)
    T.eq(fan().on, true)
    Mock.changeVariable(mock, 41, 1000, "0")
    T.eq(fan().on, false, "IS_ON says whether it runs")
    T.truthy(isNull(fan().speed))
    Mock.changeVariable(mock, 41, 1001, "0")
    Mock.changeVariable(mock, 41, 1001, "3")
    Mock.changeVariable(mock, 41, 1000, "1")
    T.eq(fan().speed, 3, "speed first, then on")
    T.eq(fan().on, true)
    OnWatchedVariableChanged(41, "1000", "True")
    T.eq(fan().on, true, "ids as text and values in other words")

    -- Values that are not a speed, or neither on nor off, are unknown.
    Mock.changeVariable(mock, 41, 1001, "7")
    T.eq(fan().on, true)
    T.truthy(isNull(fan().speed), "not a speed")
    Mock.changeVariable(mock, 41, 1001, "2.5")
    T.truthy(isNull(fan().speed))
    Mock.changeVariable(mock, 41, 1001, "")
    T.truthy(isNull(fan().speed))
    Mock.changeVariable(mock, 41, 1001, "0")
    T.eq(fan().on, true, "on with no speed reported")
    T.truthy(isNull(fan().speed))
    Mock.changeVariable(mock, 41, 1000, "unknown")
    T.eq(fan().on, false, "without IS_ON, off at speed 0")
    Mock.changeVariable(mock, 41, 1001, "2")
    T.eq(fan().on, true, "and on at a speed above 0")
    T.eq(fan().speed, 2)

    T.eq(require("src.adapters.manager").onVariableChanged(41, 1003, "1"), false, "the preset speed is not watched")
    T.eq(fan().speed, 2)
    Mock.changeVariable(mock, 42, 1001, "1")
    Mock.changeVariable(mock, 42, 1000, "1")
    T.eq(T.http(mock, "GET", "/v1/fans/42", { key = key }).json.speed, 1, "each fan its own")
end

function tests.fan_variables_are_found_by_name_or_by_id()
    local mock, key = start(function(project)
        -- Other ids, the names read on a live Director.
        Mock.withFan(project, {
            id = 43, protocol = 118, name = "Attic Fan",
            variables = { [2000] = "1", [2001] = "4" },
            names = { [2000] = "IS_ON", [2001] = "CURRENT_SPEED" },
        })
        -- The names in Snap One's documentation.
        Mock.withFan(project, {
            id = 44, protocol = 119, name = "Bedroom Fan",
            variables = { [1000] = "0", [1001] = "0", [1004] = "1", [1005] = "3" },
            names = { [1000] = "Is Reversed", [1001] = "Current Preset", [1004] = "Is On", [1005] = "Current Selected Speed" },
        })
        -- No names: the ids read on a live Director.
        Mock.withFan(project, { id = 45, protocol = 128, name = "Garage Fan", on = true, speed = 1, names = {} })
    end)
    local function fan(id)
        return T.http(mock, "GET", "/v1/fans/" .. id, { key = key }).json
    end
    T.eq(fan(43).speed, 4)
    T.truthy(listening(mock, 43, 2000) and listening(mock, 43, 2001))
    Mock.changeVariable(mock, 43, 2001, "2")
    T.eq(fan(43).speed, 2)
    T.eq(fan(44).on, true)
    T.eq(fan(44).speed, 3)
    T.truthy(listening(mock, 44, 1004) and listening(mock, 44, 1005))
    T.truthy(not listening(mock, 44, 1000), "a name found is used, not the id")
    T.eq(fan(45).speed, 1)
    T.truthy(listening(mock, 45, 1000) and listening(mock, 45, 1001))
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.inventory.fans, 5)
end

function tests.a_fan_without_its_state_or_listeners_is_unsupported()
    local mock, key = start(function(project)
        Mock.withFan(project, { id = 43, protocol = 118, name = "Attic Fan", variables = { [1000] = "1" } })
        Mock.withFan(project, { id = 44, protocol = 119, name = "Bedroom Fan", variables = {} })
    end, function(mock)
        local register = C4.RegisterVariableListener
        function C4:RegisterVariableListener(deviceId, variableId)
            if deviceId == 42 and variableId == 1001 then
                error("listener refused")
            end
            return register(self, deviceId, variableId)
        end
        mock.patched = true
    end)
    T.truthy(mock.patched)
    for _, id in ipairs({ 42, 43, 44 }) do
        local device = T.http(mock, "GET", "/v1/devices/" .. id, { key = key }).json
        T.eq(device.type, "fan")
        T.eq(device.supported, false, "fan " .. id)
        T.truthy(isNull(device.href))
        T.eq(T.http(mock, "GET", "/v1/fans/" .. id, { key = key }).status, 404)
    end
    T.eq(#T.http(mock, "GET", "/v1/fans", { key = key }).json.items, 1, "the ceiling fan still works")
    T.contains(mock.properties["Inventory"], "1 fans")
    local before = #mock.commands
    T.eq(T.http(mock, "PATCH", "/v1/fans/42", { key = key, body = { on = true } }).status, 404)
    T.eq(#mock.commands, before)
end

function tests.a_refused_command_is_a_502()
    local mock, key = start(nil, function()
        local send = C4.SendToDevice
        function C4:SendToDevice(deviceId, command, params)
            if deviceId == 41 then
                error("device busy")
            end
            return send(self, deviceId, command, params)
        end
    end)
    local response = T.http(mock, "PATCH", "/v1/fans/41", { key = key, body = { speed = 3 } })
    T.eq(response.status, 502, response.body)
    T.eq(response.json.code, "CONTROLLER_COMMAND_FAILED")
    T.eq(T.http(mock, "PATCH", "/v1/fans/42", { key = key, body = { speed = 3 } }).status, 202)
end

-- The adapter itself refuses what the API never sends, before any command goes out.
function tests.the_adapter_sends_only_speeds_one_to_four()
    local mock = start()
    local Manager = require("src.adapters.manager")
    local before = #mock.commands
    for _, speed in ipairs({ 0, 5, 2.5, "3", -1 }) do
        local ok, failure = Manager.execute(41, "set_speed", { speed = speed })
        T.eq(ok, false, tostring(speed))
        T.eq(failure.code, "INVALID_SPEED")
    end
    local ok, failure = Manager.execute(41, "set_speed", {})
    T.eq(ok, false)
    T.eq(failure.code, "INVALID_SPEED")
    ok, failure = Manager.execute(41, "reverse", {})
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")
    T.eq(#mock.commands, before, "nothing is sent")
    T.eq((Manager.execute(41, "set_speed", { speed = 2 })), true)
    T.eq(#mock.commands, before + 1)
end

function tests.scenes_set_fans_by_id_by_room_and_in_the_whole_home()
    local mock, key = start()
    local before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
        { type = "fans", device_ids = { 41 }, set = { speed = 3 } },
        { type = "fans", room_id = 10, set = { on = true } },
        { type = "fans", set = { on = false } },
    } } })
    T.eq(ran.status, 202, ran.body)
    T.eq(ran.json.ran, 4)
    T.eq(ran.json.skipped, 0)
    local sent = commandsSince(mock, before)
    T.same(sent, {
        { device = 41, command = "SET_SPEED", params = { SPEED = 3 } },
        { device = 42, command = "ON", params = {} },
        { device = 41, command = "OFF", params = {} },
        { device = 42, command = "OFF", params = {} },
    })

    -- A fan added to the room later is in the room's step.
    local created = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Breeze", steps = { { type = "fans", room_id = 11, set = { speed = 1 } } } } })
    T.eq(created.status, 201, created.body)
    T.same(created.json.steps[1].set, { speed = 1 })
    Mock.withFan(mock.project, { id = 43, protocol = 118, name = "Attic Fan", room = 11 })
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    before = #mock.commands
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. created.json.id .. "/run", { key = key }).json.ran, 2)
    local devices = {}
    for _, command in ipairs(commandsSince(mock, before)) do
        T.eq(command.command, "SET_SPEED")
        devices[#devices + 1] = command.device
    end
    table.sort(devices)
    T.same(devices, { 41, 43 })
end

function tests.fan_steps_are_checked()
    local mock, key = start()
    local before = #mock.commands
    local function refused(set, deviceIds)
        local answer = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Bad", steps = { { type = "fans", device_ids = deviceIds, set = set } } } }).json
        T.eq(answer.code, "INVALID_FIELD", Json.encode(set))
        return answer
    end
    T.eq(refused({ speed = 0 }).errors[1].field, "steps[0].set.speed")
    refused({ speed = 5 })
    refused({ speed = 2.5 })
    refused({ speed = "2" })
    refused({ on = true, speed = 2 })
    refused({ on = "yes" })
    refused({})
    refused({ direction = "reverse" })
    refused({ on = true }, { 20 })
    T.eq(#T.http(mock, "GET", "/v1/scenes", { key = key }).json.items, 0, "nothing is saved")
    T.eq(#mock.commands, before, "nothing is sent")
end

function tests.fan_steps_are_kept_across_updates_and_checked_when_loaded()
    local mock, key = start()
    local scene = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Fans", steps = {
        { type = "fans", device_ids = { 41 }, set = { speed = 4 } },
        { type = "fans", room_id = 10, set = { on = false } },
    } } }).json
    local raw = mock.persist.directorlink_scenes
    local data = Json.decode(raw:sub(#"json:" + 1))
    local steps = data.scenes[1].steps
    steps[#steps + 1] = { type = "fans", set = { speed = 9 } }
    steps[#steps + 1] = { type = "fans", set = { on = true, speed = 2 } }
    steps[#steps + 1] = { type = "fans", set = { on = "true" } }
    mock.persist.directorlink_scenes = "json:" .. Json.encode(data)
    local updated = Mock.updateDriver(mock, Mock.withFans(Mock.project()))
    local loaded = T.http(updated, "GET", "/v1/scenes/" .. scene.id, { key = key }).json
    T.eq(#loaded.steps, 2, "only the valid steps are kept")
    T.same(loaded.steps[1].set, { speed = 4 })
    T.same(loaded.steps[2].set, { on = false })
    local before = #updated.commands
    T.eq(T.http(updated, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = key }).json.ran, 2)
    T.same(commandsSince(updated, before), {
        { device = 41, command = "SET_SPEED", params = { SPEED = 4 } },
        { device = 42, command = "OFF", params = {} },
    })
end

-- A member not given fans neither sees nor controls them (ADR-054); one given fans controls them.
function tests.members_given_fans_control_them_and_others_do_not_see_them()
    local mock, admin = start()
    local without = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Guest", role = "member", access = { kinds = { fan = false } } } }).json.key
    local member = createKey(mock, admin, "member")
    local before = #mock.commands
    T.eq(#T.http(mock, "GET", "/v1/fans", { key = without }).json.items, 0)
    T.eq(T.http(mock, "GET", "/v1/fans/41", { key = without }).status, 404)
    local refused = T.http(mock, "PATCH", "/v1/fans/41", { key = without, body = { on = false } })
    T.eq(refused.status, 404)
    T.eq(refused.json.code, "NOT_FOUND")
    T.eq(#mock.commands, before, "nothing is sent for them")
    T.eq(T.http(mock, "PATCH", "/v1/fans/41", { key = member, body = { on = false } }).status, 202)
    T.eq(#mock.commands, before + 1)
    T.eq(T.http(mock, "GET", "/v1/fans", {}).status, 401)

    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Fans off", steps = { { type = "fans", set = { on = false } } } } }).json
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = member }).status, 404, "a scene not chosen for them")
    local profile = T.http(mock, "GET", "/v1/api-keys/current", { key = member }).json.profile_id
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profile .. "/access", { key = admin, body = { scenes = { scene.id } } }).status, 200)
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = member }).json.ran, 2, "members run the fan scenes chosen for them")
end

function tests.a_schedule_runs_a_fan_scene()
    local mock, admin = start()
    local now = os.time()
    local Clock = require("src.core.clock")
    Clock.now = function()
        return now
    end
    local Scheduler = require("src.core.scheduler")
    local fields = os.date("*t", now + 86400)
    fields.hour, fields.min, fields.sec = 7, 30, 0
    local runAt = os.time(fields)
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Morning breeze", steps = { { type = "fans", room_id = 11, set = { speed = 2 } } } } }).json
    local created = T.http(mock, "POST", "/v1/schedules", { key = admin, body = {
        scene_id = scene.id, trigger = { type = "time", at = "07:30" }, days = { fields.wday - 1 },
    } })
    T.eq(created.status, 201, created.body)
    local before = #mock.commands
    now = runAt + 5
    T.eq(Scheduler.tick(), 1)
    T.same(commandsSince(mock, before), { { device = 41, command = "SET_SPEED", params = { SPEED = 2 } } })
    T.eq(T.http(mock, "GET", "/v1/schedules/" .. created.json.id, { key = admin }).json.last_run.ran, 1)
end

function tests.the_composer_printout_shows_fan_steps()
    local mock, admin = start()
    T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Fans", steps = {
        { type = "fans", room_id = 11, set = { speed = 3 } },
        { type = "fans", device_ids = { 42 }, set = { on = true } },
        { type = "fans", set = { on = false } },
    } } })
    local lines = {}
    local realPrint = print
    _G.print = function(line)
        lines[#lines + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    local text = table.concat(lines, " | ")
    T.contains(text, "all fans in Living Room (11) -> speed 3 of 4")
    T.contains(text, "Patio Fan (42) -> on")
    T.contains(text, "all fans in the whole home -> off")
end

-- Sealed at home (POST /v1/sealed) and through the account, as the app sends everything.
function tests.fans_work_sealed_at_home_and_through_the_account()
    local mock, key = start()
    local Lock = require("src.cloud.lock")
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    local lock = Lock.deviceKey(key)
    local counter = 0
    local function sealedAtHome(request)
        counter = counter + 1
        local info = T.http(mock, "GET", "/v1/sealed").json
        request.id, request.ts = "home-" .. counter, info.time
        local envelope = Lock.seal(lock, info.home, me.id, "req", Json.encode(request))
        local response = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
        T.eq(response.status, 200, response.body)
        return Json.decode(Lock.open(lock, response.json.envelope, "res"))
    end
    local before = #mock.commands
    T.eq(#Json.decode(sealedAtHome({ method = "GET", path = "/v1/fans" }).body).items, 2)
    T.eq(sealedAtHome({ method = "PATCH", path = "/v1/fans/42", body = { speed = 2 } }).status, 202)
    T.same(commandsSince(mock, before), { { device = 42, command = "SET_SPEED", params = { SPEED = 2 } } })

    local _, connection = Harness.connected({ mock = mock })
    local home = T.http(mock, "GET", "/v1/remote", { key = key }).json.home_id
    local function remote(request, apiKey, keyId)
        counter = counter + 1
        request.id, request.ts = "remote-" .. counter, os.time()
        local deviceLock = Lock.deviceKey(apiKey or key)
        local envelope = Lock.seal(deviceLock, home, keyId or me.id, "req", Json.encode(request))
        local reply = Harness.relayRequest(mock, connection, { type = "e2e", id = "relay-" .. counter, envelope = envelope })
        T.truthy(reply.envelope, "a sealed answer")
        return Json.decode(Lock.open(deviceLock, reply.envelope, "res"))
    end
    before = #mock.commands
    T.eq(Json.decode(remote({ method = "GET", path = "/v1/fans/41" }).body).speed, 2)
    T.eq(remote({ method = "PATCH", path = "/v1/fans/41", body = { on = false } }).status, 202)
    T.same(commandsSince(mock, before), { { device = 41, command = "OFF", params = {} } })
    local viewer, viewerId = createKey(mock, key, "viewer")
    local refused = remote({ method = "PATCH", path = "/v1/fans/41", body = { on = true } }, viewer, viewerId)
    T.eq(refused.status, 404, "a viewer of 1.7.0 has no rooms (ADR-054)")
    T.eq(Json.decode(refused.body).code, "NOT_FOUND")
    T.eq(remote({ method = "GET", path = "/v1/fans" }, viewer, viewerId).status, 200)
    T.eq(#mock.commands, before + 1)
end

function tests.the_debug_log_lists_what_a_fan_has()
    local setups = 0
    local mock = start(nil, function()
        Properties["Log Level"] = "Debug"
        local request = C4.SendUIRequest
        function C4:SendUIRequest(deviceId, name, params)
            if deviceId == 41 and name == "GET_SETUP" then
                setups = setups + 1
                return "<fan_setup><speeds_count>4</speeds_count><preset_speed>3</preset_speed></fan_setup>"
            end
            return request(self, deviceId, name, params)
        end
    end)
    local log = table.concat(mock.debugLog, "\n")
    T.contains(log, "proxy variables")
    T.contains(log, '"variables":"1000=IS_ON:1, 1001=CURRENT_SPEED:2, 1003=PRESET_SPEED:3"')
    T.contains(log, "fan_speed_controller.c4i", "the protocol driver, for the next field log")
    T.contains(log, "<speeds_count>4</speeds_count>", "the setup, as the proxy answers it")
    T.contains(log, "failed: ", "a setup the proxy does not give is logged as that")
    T.eq(setups, 1)
    T.contains(log, "initialized fan")

    -- At Info the setup is not asked for.
    setups = 0
    start(nil, function()
        local request = C4.SendUIRequest
        function C4:SendUIRequest(deviceId, name, params)
            if name == "GET_SETUP" and (deviceId == 41 or deviceId == 42) then
                setups = setups + 1
            end
            return request(self, deviceId, name, params)
        end
    end)
    T.eq(setups, 0)
end

-- The dev server's project has the fans too.
function tests.the_demo_project_has_fans()
    local mock = Mock.startDriver(Mock.demoProject())
    T.contains(mock.properties["Inventory"], "4 thermostats, 2 fans")
    local key = T.pair(mock)
    T.eq(T.http(mock, "GET", "/v1/fans/41", { key = key }).json.speed, 2)
end

return tests
