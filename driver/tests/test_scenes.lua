-- Scenes (src/core/scenes.lua, /v1/scenes): admins make them, members run them, and a run sends
-- the same commands as the device routes.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function start()
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Chrome on Windows")
    return mock, admin
end

local function createKey(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role .. " phone", role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key
end

local function commandsSince(mock, before)
    local list = {}
    for index = before + 1, #mock.commands do
        list[#list + 1] = mock.commands[index]
    end
    return list
end

local function devicesOf(commands)
    local devices = {}
    for _, command in ipairs(commands) do
        devices[#devices + 1] = command.device
    end
    return devices
end

local GOOD_NIGHT = {
    name = "Good night",
    icon = "moon",
    show_on_home = true,
    steps = {
        { type = "lights", set = { on = false } },
        { type = "climate", room_id = 11, set = { mode = "cool", target_temperature = 24, fan_speed = "low" } },
        { type = "blinds", room_id = 10, set = { position = 0 } },
        { type = "lights", room_id = 11, device_ids = { 22 }, set = { brightness = 10 } },
        { type = "relays", device_ids = { 70 }, set = { state = "closed" } },
    },
}

function tests.an_admin_makes_a_scene_and_a_member_runs_it()
    local mock, admin = start()
    local created = T.http(mock, "POST", "/v1/scenes", { key = admin, body = GOOD_NIGHT })
    T.eq(created.status, 201, created.body)
    local scene = created.json
    T.truthy(scene.id:match("^%x%x%x%x%x%x%x%x$"))
    T.eq(scene.version, 1)
    T.eq(#scene.steps, 5)
    T.contains(created.body, '"room_id":null', "the whole home")
    T.contains(created.body, '"device_ids":[22]')

    local member = createKey(mock, admin, "member")
    T.eq(T.http(mock, "GET", "/v1/scenes", { key = member }).json.items[1].name, "Good night")
    local before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = member })
    T.eq(ran.status, 202, ran.body)
    T.eq(ran.json.scene_id, scene.id)
    T.eq(ran.json.ran, 6, "3 lights, the AC, a blind and the desk lamp")
    T.eq(ran.json.skipped, 1, "the door needs door access")
    T.eq(ran.json.failed, 0)
    T.eq(ran.json.problems[1].step, 5)
    T.eq(ran.json.problems[1].device_id, 70)
    T.eq(ran.json.problems[1].code, "FORBIDDEN")

    local sent = commandsSince(mock, before)
    local devices = devicesOf(sent)
    local lights = { devices[1], devices[2], devices[3] }
    table.sort(lights)
    T.same(lights, { 20, 21, 22 }, "every light in the home, first")
    T.eq(devices[#devices], 22, "the desk lamp last, dimmed")
    T.same(sent[#sent].params, { PERCENT = 10 })
    local thermostat = {}
    for _, command in ipairs(sent) do
        if command.device == 30 then
            thermostat[#thermostat + 1] = command.command
        end
    end
    T.same(thermostat, { "SET_MODE_HVAC", "SET_MODE_FAN", "SET_SETPOINT_SINGLE" })
    T.truthy(devices[#devices - 1] == 51, "only the kitchen blind")
    for _, device in ipairs(devices) do
        T.truthy(device ~= 70 and device ~= 50, "no door, no living-room blind")
    end
end

function tests.doors_run_only_with_door_access_and_door_control()
    local mock, admin = start()
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Gate", steps = { { type = "relays", device_ids = { 70 }, set = { state = "open" } } } } }).json
    local run = function()
        return T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = admin }).json
    end
    Properties["Door Control"] = "Disabled"
    local off = run()
    T.eq(off.skipped, 1)
    T.eq(off.problems[1].code, "DOOR_CONTROL_DISABLED")
    Properties["Door Control"] = "Enabled"
    local before = #mock.commands
    local on = run()
    T.eq(on.ran, 1, on)
    T.eq(mock.commands[before + 1].device, 70)
    local doors = createKey(mock, admin, "doors")
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = doors }).json.ran, 1)
end

function tests.roles_limit_who_changes_and_runs_scenes()
    local mock, admin = start()
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "All off", steps = { { type = "lights", set = { on = false } } } } }).json
    local member = createKey(mock, admin, "member")
    local viewer = createKey(mock, admin, "viewer")
    T.eq(T.http(mock, "GET", "/v1/scenes/" .. scene.id, { key = viewer }).status, 200, "everyone sees them")
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = viewer }).status, 403, "viewers do not run them")
    T.eq(T.http(mock, "POST", "/v1/scenes", { key = member, body = { name = "Mine" } }).status, 403, "members do not make them")
    T.eq(T.http(mock, "PATCH", "/v1/scenes/" .. scene.id, { key = member, body = { name = "X" } }).status, 403)
    T.eq(T.http(mock, "DELETE", "/v1/scenes/" .. scene.id, { key = member }).status, 403)
    T.eq(T.http(mock, "POST", "/v1/scenes/try", { key = member, body = { steps = {} } }).status, 403)
    T.eq(T.http(mock, "GET", "/v1/scenes/nothex", { key = viewer }).status, 400)
    T.eq(T.http(mock, "GET", "/v1/scenes/deadbeef", { key = viewer }).status, 404)
end

function tests.scene_input_is_checked()
    local mock, admin = start()
    local before = #mock.commands
    local post = function(body)
        return T.http(mock, "POST", "/v1/scenes", { key = admin, body = body }).json
    end
    local step = function(item)
        local answer = post({ name = "Test", steps = { item } })
        T.eq(answer.code, "INVALID_FIELD", answer)
        return answer
    end
    T.eq(post({ icon = "moon" }).code, "INVALID_FIELD", "a name is needed")
    T.eq(post({ name = "X", icon = "rocket" }).code, "INVALID_FIELD")
    T.eq(post({ name = "X", show_on_home = "yes" }).code, "INVALID_FIELD")
    T.eq(post({ name = "X", colour = "red" }).code, "INVALID_FIELD")
    step({ type = "fans", set = { on = true } })
    step({ type = "lights", room_id = 99, set = { on = true } })
    step({ type = "lights", device_ids = { 30 }, set = { on = true } })
    step({ type = "climate", device_ids = { 20 }, set = { mode = "cool" } })
    step({ type = "lights", device_ids = {}, set = { on = true } })
    step({ type = "lights", set = { on = true, brightness = 50 } })
    step({ type = "lights", set = { brightness = 101 } })
    step({ type = "lights", set = {} })
    step({ type = "climate", set = { mode = "off", target_temperature = 22 } })
    step({ type = "climate", set = { mode = "dry" } })
    step({ type = "climate", set = { target_temperature = 60 } })
    step({ type = "blinds", set = { position = "open" } })
    step({ type = "relays", set = { state = "pulse" } })
    step({ type = "lights", set = { on = true }, delay = 5 })
    local many = {}
    for index = 1, 41 do
        many[index] = { type = "lights", set = { on = true } }
    end
    T.eq(post({ name = "Long", steps = many }).code, "INVALID_FIELD", "at most 40 steps")
    T.eq(#commandsSince(mock, before), 0, "nothing is sent")
    T.eq(#T.http(mock, "GET", "/v1/scenes", { key = admin }).json.items, 0, "nothing is saved")
end

function tests.scenes_are_changed_kept_across_updates_and_deleted()
    local mock, admin = start()
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = GOOD_NIGHT }).json
    local patch = function(body)
        return T.http(mock, "PATCH", "/v1/scenes/" .. scene.id, { key = admin, body = body })
    end
    local renamed = patch({ name = "Night", show_on_home = false, version = 1 })
    T.eq(renamed.status, 200, renamed.body)
    T.eq(renamed.json.version, 2)
    T.eq(#renamed.json.steps, 5, "steps stay unless sent")
    T.eq(patch({ name = "Late", version = 1 }).json.code, "VERSION_CONFLICT")
    local shorter = patch({ steps = { { type = "blinds", set = { position = 100 } } } })
    T.eq(#shorter.json.steps, 1)

    local updated = Mock.updateDriver(mock)
    local kept = T.http(updated, "GET", "/v1/scenes/" .. scene.id, { key = admin })
    T.eq(kept.status, 200, "kept across a driver update")
    T.eq(kept.json.name, "Night")
    T.eq(kept.json.show_on_home, false)
    T.eq(kept.json.version, 3)
    T.same(kept.json.steps[1].set, { position = 100 })

    T.eq(T.http(updated, "DELETE", "/v1/scenes/" .. scene.id, { key = admin }).status, 204)
    T.eq(T.http(updated, "GET", "/v1/scenes/" .. scene.id, { key = admin }).status, 404)
    T.eq(#T.http(Mock.updateDriver(updated), "GET", "/v1/scenes", { key = admin }).json.items, 0)
end

function tests.try_runs_steps_without_saving_them_and_keeps_the_thermostat_range()
    local mock, admin = start()
    local max = T.http(mock, "GET", "/v1/thermostats/30", { key = admin }).json.target_temperature_max
    local before = #mock.commands
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = admin, body = { steps = { { type = "climate", set = { target_temperature = 38 } } } } })
    T.eq(tried.status, 202, tried.body)
    T.eq(tried.json.ran, 1)
    T.truthy(tried.json.scene_id == nil)
    local sent = commandsSince(mock, before)
    T.eq(#sent, 1)
    T.eq(sent[1].params.CELSIUS, max, "kept within the thermostat's range")
    T.eq(#T.http(mock, "GET", "/v1/scenes", { key = admin }).json.items, 0, "nothing is saved")

    local unsupported = T.http(mock, "POST", "/v1/scenes/try", { key = admin, body = { steps = { { type = "climate", set = { mode = "auto" } } } } }).json
    T.eq(unsupported.skipped, 1)
    T.eq(unsupported.problems[1].code, "MODE_NOT_SUPPORTED")
end

function tests.a_device_gone_from_the_project_is_skipped()
    local mock, admin = start()
    local scene = T.http(mock, "POST", "/v1/scenes", { key = admin, body = { name = "Desk", steps = {
        { type = "lights", device_ids = { 22, 20 }, set = { brightness = 50 } },
    } } }).json
    local project = Mock.project()
    project.devices[22] = nil
    project.devices[103] = nil
    local updated = Mock.updateDriver(mock, project)
    local before = #updated.commands
    local ran = T.http(updated, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = admin }).json
    T.eq(ran.ran, 1)
    T.eq(ran.skipped, 1)
    T.eq(ran.problems[1].device_id, 22)
    T.eq(ran.problems[1].code, "NOT_FOUND")
    T.same(devicesOf(commandsSince(updated, before)), { 20 })
end

return tests
