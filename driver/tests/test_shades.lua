-- Shades on the blind proxy (1.1.0): what a shade can do, from its setup (GET_SETUP), and what it is
-- doing, from the proxy's Target Level, Opening, Closing and Stopped, as KNX blinds show them on
-- Director 3.4.3 (Mock.withShade). 52 goes anywhere and stops; 53 only opens and closes fully and
-- cannot stop; 50 and 51 are proxies that answer no setup and report only their level. Movement is
-- the shade's movement type ("Up to Down"), never whether it moves.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local function start(project, prepare)
    local mock = Mock.startDriver(project or Mock.withShades(Mock.project()), nil, nil, prepare)
    local key = T.pair(mock)
    return mock, key
end

local function blind(mock, key, id)
    return T.http(mock, "GET", "/v1/blinds/" .. id, { key = key }).json
end

local function logged(message)
    local found = {}
    for _, entry in ipairs(require("src.core.log").query({ limit = 500 })) do
        if entry.message == message then
            found[#found + 1] = entry
        end
    end
    return found
end

local function debugLevel()
    Properties["Log Level"] = "Debug"
end

function tests.a_shade_reports_what_it_can_do_and_where_it_is_going()
    local mock, key = start()
    local shade = blind(mock, key, 52)
    T.same(shade.capabilities, { position = true, stop = true })
    T.eq(shade.position, 35)
    T.eq(shade.moving, false)
    T.eq(shade.direction, Json.null)
    T.eq(shade.target_position, 35)

    -- The move starts: the proxy says where to, which way, and (its estimate) the level.
    Mock.setShade(mock, 52, { ["Target Level"] = "80", Stopped = "0", Opening = "1", Level = "40" })
    shade = blind(mock, key, 52)
    T.eq(shade.moving, true)
    T.eq(shade.direction, "opening")
    T.eq(shade.target_position, 80)
    T.eq(shade.position, 40)
    -- And stops where it was sent.
    Mock.setShade(mock, 52, { Stopped = "1", Opening = "0", Level = "80" })
    shade = blind(mock, key, 52)
    T.eq(shade.moving, false)
    T.eq(shade.direction, Json.null)
    T.eq(shade.position, 80)

    local closing = T.http(mock, "GET", "/v1/blinds?room_id=11", { key = key }).json.items
    T.eq(#closing, 2)
    Mock.setShade(mock, 52, { ["Target Level"] = "20", Stopped = "0", Closing = "1" })
    T.eq(blind(mock, key, 52).direction, "closing")
end

-- Movement (1007) is the movement type the proxy's setup offers (Snap One: "A string
-- representation of the enumeration for the movement"). Read as motion, every shade at rest showed
-- Closing... (Up to Down) or Opening... (Down to Up), and the app read the blinds every 2 s.
function tests.a_shade_at_rest_is_not_moving_whatever_its_movement_type()
    local types = { "Up to Down", "Down to Up", "Open/Close", "Out to In", "Left to Right", "Right to Left", "Up-Down", "Down-Up", "1", "2", "0" }
    for _, movement in ipairs(types) do
        local project = Mock.withShades(Mock.project())
        project.variables[52][1007] = movement
        local mock, key = start(project)
        local shade = blind(mock, key, 52)
        T.eq(shade.moving, false, movement)
        T.eq(shade.direction, Json.null, movement)
        T.eq(shade.position, 35, movement)
    end

    -- A move of a shade that goes up to down, and its stop: Movement stays as it is.
    local mock, key = start()
    Mock.setShade(mock, 52, { ["Target Level"] = "0", Stopped = "0", Closing = "1", Level = "35" })
    local shade = blind(mock, key, 52)
    T.eq(shade.moving, true)
    T.eq(shade.direction, "closing")
    Mock.setShade(mock, 52, { Stopped = "1", Closing = "0", Level = "0", ["Target Level"] = "0" })
    shade = blind(mock, key, 52)
    T.eq(shade.moving, false)
    T.eq(shade.direction, Json.null)
    T.eq(shade.position, 0)
    -- Movement changing (an installer picks another type) moves nothing.
    Mock.setShade(mock, 52, { Movement = "Down to Up" })
    T.eq(blind(mock, key, 52).moving, false)
end

-- How Director writes the booleans has not been seen: 1/0, true/false, True/False, with spaces.
function tests.movement_booleans_are_read_however_they_are_written()
    for _, spelling in ipairs({ { "1", "0" }, { "true", "false" }, { "True", "False" }, { " TRUE ", " FALSE " } }) do
        local yes, no = spelling[1], spelling[2]
        local mock, key = start()
        Mock.setShade(mock, 52, { Stopped = yes, Opening = no, Closing = no })
        T.eq(blind(mock, key, 52).moving, false, "at rest: " .. yes)
        Mock.setShade(mock, 52, { ["Target Level"] = "90", Stopped = no, Opening = yes })
        local shade = blind(mock, key, 52)
        T.eq(shade.moving, true, "opening: " .. yes)
        T.eq(shade.direction, "opening", yes)
        Mock.setShade(mock, 52, { Opening = no, Closing = yes, ["Target Level"] = "10" })
        T.eq(blind(mock, key, 52).direction, "closing", yes)
        Mock.setShade(mock, 52, { Stopped = yes, Closing = no })
        T.eq(blind(mock, key, 52).moving, false, "stopped: " .. yes)
    end
end

function tests.a_shade_that_only_opens_and_closes_takes_only_0_and_100()
    local mock, key = start()
    local shutter = blind(mock, key, 53)
    T.same(shutter.capabilities, { position = false, stop = false })
    local sent = #mock.commands

    local between = T.http(mock, "PATCH", "/v1/blinds/53", { key = key, body = { position = 50 } })
    T.eq(between.status, 409)
    T.eq(between.json.code, "POSITION_NOT_SUPPORTED")
    T.contains(between.json.detail, "only opens and closes fully")
    local stop = T.http(mock, "POST", "/v1/blinds/53/stop", { key = key })
    T.eq(stop.status, 409)
    T.eq(stop.json.code, "STOP_NOT_SUPPORTED")
    T.eq(#mock.commands, sent, "nothing is sent")

    T.eq(T.http(mock, "PATCH", "/v1/blinds/53", { key = key, body = { position = 100 } }).status, 202)
    T.same(mock.commands[#mock.commands], { device = 53, command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = 100 } })
    T.eq(T.http(mock, "PATCH", "/v1/blinds/53", { key = key, body = { position = 0 } }).status, 202, "0 and 100 always work")
    T.eq(T.http(mock, "PATCH", "/v1/blinds/53", { key = key, body = { position = 101 } }).json.code, "INVALID_FIELD", "a bad position is still a 400")

    T.eq(T.http(mock, "PATCH", "/v1/blinds/52", { key = key, body = { position = 50 } }).status, 202, "a shade with position control takes 50")
    T.eq(T.http(mock, "POST", "/v1/blinds/52/stop", { key = key }).status, 202)
    T.same(mock.commands[#mock.commands], { device = 52, command = "STOP", params = {} })
end

function tests.proxies_that_say_nothing_keep_the_slider_and_stop()
    local project = Mock.withShades(Mock.project())
    -- An answer without the setup's fields, and one that is not XML at all.
    project.blindSetups[50] = "<blind_setup></blind_setup>"
    project.blindSetups[51] = "OK"
    local mock, key = start(project)
    for _, id in ipairs({ 50, 51 }) do
        local item = blind(mock, key, id)
        T.same(item.capabilities, { position = true, stop = true }, "blind " .. id)
        T.eq(item.moving, Json.null, "no movement variables: not known")
        T.eq(item.direction, Json.null)
    end
    T.eq(blind(mock, key, 50).target_position, 40, "Target Level is read by name")
    T.eq(blind(mock, key, 51).target_position, Json.null, "-255 is unknown")
    T.eq(T.http(mock, "PATCH", "/v1/blinds/51", { key = key, body = { position = 30 } }).status, 202, "as before 1.1.0")
    T.eq(T.http(mock, "POST", "/v1/blinds/50/stop", { key = key }).status, 202)

    -- A proxy that fails the request (Mock.project's blinds, as before).
    local plain, plainKey = start(Mock.project())
    T.same(blind(plain, plainKey, 51).capabilities, { position = true, stop = true })
end

function tests.levels_outside_0_to_100_are_unknown()
    local mock, key = start()
    for _, value in ipairs({ "-155", "-255", "101", "unknown", "" }) do
        Mock.setShade(mock, 52, { Level = value, ["Target Level"] = value })
        local shade = blind(mock, key, 52)
        T.eq(shade.position, Json.null, "Level " .. value)
        T.eq(shade.target_position, Json.null, "Target Level " .. value)
    end
    Mock.setShade(mock, 52, { Level = "62.6" })
    T.eq(blind(mock, key, 52).position, 63)
end

-- A proxy with only some of the variables (their names differ between Control4 versions).
local function shadeWith(names)
    local project = Mock.withShade(Mock.project(), { id = 52, protocol = 114, name = "Terrace Shade", level = "35" })
    for variableId, name in pairs(project.variableNames[52]) do
        if not names[name] then
            project.variableNames[52][variableId] = nil
            project.variables[52][variableId] = nil
        end
    end
    return project
end

function tests.movement_is_read_from_whichever_variables_the_proxy_has()
    local mock, key = start(shadeWith({ Level = true, ["Target Level"] = true, Stopped = true }))
    T.eq(blind(mock, key, 52).moving, false)
    Mock.setShade(mock, 52, { Stopped = "False", ["Target Level"] = "10" })
    local shade = blind(mock, key, 52)
    T.eq(shade.moving, true, "only Stopped: not stopped is moving")
    T.eq(shade.direction, "closing", "towards the target")
    Mock.setShade(mock, 52, { Level = "10" })
    T.eq(blind(mock, key, 52).moving, false, "at its target it is not moving, even if Stopped stays false")

    -- Opening and Closing both clear but Stopped false: moving, the way the target says.
    mock, key = start()
    Mock.setShade(mock, 52, { Stopped = "0", ["Target Level"] = "90" })
    shade = blind(mock, key, 52)
    T.eq(shade.moving, true)
    T.eq(shade.direction, "opening")
    Mock.setShade(mock, 52, { ["Target Level"] = "-255" })
    shade = blind(mock, key, 52)
    T.eq(shade.moving, true, "where to is not known")
    T.eq(shade.direction, Json.null)

    -- Only Level and Movement: whether it moves is not known, whatever Movement says.
    mock, key = start(shadeWith({ Level = true, Movement = true }))
    for _, value in ipairs({ "Up to Down", "Down to Up", "Moving Down", "Opening", "Closing", "Stopped", "2" }) do
        Mock.setShade(mock, 52, { Movement = value })
        shade = blind(mock, key, 52)
        T.eq(shade.moving, Json.null, value)
        T.eq(shade.direction, Json.null, value)
    end

    mock, key = start(shadeWith({ Level = true, Opening = true, Closing = true }))
    Mock.setShade(mock, 52, { Opening = "True" })
    T.eq(blind(mock, key, 52).direction, "opening")
    Mock.setShade(mock, 52, { Opening = "False", Closing = "False" })
    T.eq(blind(mock, key, 52).moving, false)

    -- Spelled as other proxies spell their variables.
    local project = shadeWith({ Level = true, ["Target Level"] = true, Closing = true, Movement = true })
    project.variableNames[52] = { [1004] = "LEVEL", [1005] = "TARGET_LEVEL", [1007] = "MOVEMENT", [1009] = "CLOSING" }
    mock, key = start(project)
    Mock.setShade(mock, 52, { TARGET_LEVEL = "20", CLOSING = "1", LEVEL = "36" })
    shade = blind(mock, key, 52)
    T.eq(shade.target_position, 20)
    T.eq(shade.direction, "closing")
    T.eq(shade.position, 36)
end

function tests.the_setup_is_read_again_after_ten_minutes_or_on_a_project_refresh()
    local mock, key = start(nil, debugLevel)
    T.eq(blind(mock, key, 53).capabilities.position, false)
    local logs = #logged("proxy setup")
    mock.project.blindSetups[53] = "<blind_setup><has_level>True</has_level><level_discrete_control>True</level_discrete_control><can_stop>True</can_stop></blind_setup>"
    T.eq(blind(mock, key, 53).capabilities.position, false, "not yet: read at start")

    local Clock = require("src.core.clock")
    local now = Clock.now
    Clock.now = function()
        return now() + 601
    end
    local listed = T.http(mock, "GET", "/v1/blinds", { key = key }).json.items
    Clock.now = now
    local shutter
    for _, item in ipairs(listed) do
        shutter = item.id == 53 and item or shutter
    end
    T.same(shutter.capabilities, { position = true, stop = true }, "an installer added a percent address")
    T.eq(#logged("proxy setup"), logs + 1, "the new setup is logged")
    T.eq(T.http(mock, "PATCH", "/v1/blinds/53", { key = key, body = { position = 40 } }).status, 202)

    mock.project.blindSetups[53] = mock.project.blindSetups[53]:gsub("<level_discrete_control>True", "<level_discrete_control>False")
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(blind(mock, key, 53).capabilities.position, false, "a project refresh reads it at once")
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(#logged("proxy setup"), logs + 2, "an unchanged setup is not logged again")
end

function tests.the_raw_setup_and_variables_are_logged_at_debug_level()
    start(nil, debugLevel)
    local setups = {}
    for _, entry in ipairs(logged("proxy setup")) do
        setups[entry.data.device_id] = entry.data.setup
    end
    T.contains(setups[53], "<level_discrete_control>False</level_discrete_control>")
    T.contains(setups[50], "failed:", "a failed request says so")
    local variables = {}
    for _, entry in ipairs(logged("proxy variables")) do
        variables[entry.data.device_id] = entry.data.variables
    end
    T.contains(variables[52], "1002=Stopped:1")
    T.contains(variables[52], "1005=Target Level:35")
    T.contains(variables[52], "1007=Movement:Up to Down")
    T.contains(variables[52], "1008=Opening:0")
end

function tests.movement_changes_are_logged_with_their_raw_value()
    local mock = start(nil, debugLevel)
    Mock.setShade(mock, 52, { Opening = "True" })
    local entry = logged("movement changed")[1]
    T.eq(entry.data.variable, "opening")
    T.eq(entry.data.value, "True")
    T.eq(entry.data.moving, true)
    -- Movement too, though it moves nothing.
    Mock.setShade(mock, 52, { Opening = "False" })
    Mock.setShade(mock, 52, { Movement = "Down to Up" })
    entry = logged("movement changed")[3]
    T.eq(entry.data.variable, "movement")
    T.eq(entry.data.value, "Down to Up")
    T.eq(entry.data.moving, false)
end

-- A shade whose levels are not 0 to 100 (Snap One: level_open defaults to 1; a shade that can stop
-- uses 0 closed, 1 in between and 2 open). The API shows 0 to 100 as for every shade.
function tests.a_shade_with_other_levels_shows_them_as_0_to_100()
    local project = Mock.withShade(Mock.project(), { id = 52, protocol = 114, name = "Terrace Shade", level = "1", open = 2 })
    local mock, key = start(project)
    local shade = blind(mock, key, 52)
    T.eq(shade.position, 50)
    T.eq(shade.target_position, 50)
    Mock.setShade(mock, 52, { Level = "2", ["Target Level"] = "2" })
    T.eq(blind(mock, key, 52).position, 100)
    Mock.setShade(mock, 52, { Level = "3" })
    T.eq(blind(mock, key, 52).position, Json.null, "outside its levels: unknown")
    Mock.setShade(mock, 52, { Level = "0", ["Target Level"] = "2", Stopped = "0", Opening = "1" })
    shade = blind(mock, key, 52)
    T.eq(shade.target_position, 100)
    T.eq(shade.direction, "opening")

    for position, level in pairs({ [100] = 2, [0] = 0, [50] = 1, [80] = 2 }) do
        T.eq(T.http(mock, "PATCH", "/v1/blinds/52", { key = key, body = { position = position } }).status, 202)
        T.same(mock.commands[#mock.commands].params, { LEVEL_TARGET = level }, "position " .. position)
    end

    -- Levels given as the capabilities are named, without the named levels: 0 to 5.
    project = Mock.withShade(Mock.project(), {
        id = 52, protocol = 114, name = "Terrace Shade", level = "5",
        setup = "<blind_setup><has_level>True</has_level><level_closed>0</level_closed><level_open>5</level_open></blind_setup>",
    })
    mock, key = start(project)
    T.eq(blind(mock, key, 52).position, 100)
    T.http(mock, "PATCH", "/v1/blinds/52", { key = key, body = { position = 60 } })
    T.same(mock.commands[#mock.commands].params, { LEVEL_TARGET = 3 })

    -- Levels that make no sense are not used: 0 to 100, as before.
    project = Mock.withShade(Mock.project(), {
        id = 52, protocol = 114, name = "Terrace Shade", level = "40",
        setup = '<blind_setup><levels minimum="0" maximum="100"><level name="Closed" level="100"/><level name="Open" level="0"/></levels></blind_setup>',
    })
    mock, key = start(project)
    T.eq(blind(mock, key, 52).position, 40)
    T.http(mock, "PATCH", "/v1/blinds/52", { key = key, body = { position = 60 } })
    T.same(mock.commands[#mock.commands].params, { LEVEL_TARGET = 60 })
end

-- KNX shades (0 closed, 100 open, as their setup says) send and report positions as they are.
function tests.knx_levels_are_positions_as_they_are()
    local mock, key = start()
    for _, value in ipairs({ "0", "1", "35", "99", "100" }) do
        Mock.setShade(mock, 52, { Level = value })
        T.eq(blind(mock, key, 52).position, tonumber(value))
    end
    for _, position in ipairs({ 0, 1, 53, 99, 100 }) do
        T.http(mock, "PATCH", "/v1/blinds/52", { key = key, body = { position = position } })
        T.same(mock.commands[#mock.commands], { device = 52, command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = position } })
    end
end

function tests.scenes_leave_out_positions_a_shade_cannot_take()
    local mock, key = start()
    local run = function(position)
        return T.http(mock, "POST", "/v1/scenes/try", { key = key, body = {
            steps = { { type = "blinds", device_ids = { 52, 53 }, set = { position = position } } },
        } }).json
    end
    local sent = #mock.commands
    local half = run(50)
    T.eq(half.ran, 1)
    T.eq(half.skipped, 1)
    T.eq(half.problems[1].device_id, 53)
    T.eq(half.problems[1].code, "NOT_SUPPORTED")
    T.contains(half.problems[1].detail, "only opens and closes fully")
    T.eq(#mock.commands, sent + 1, "only the shade that can take 50")
    local open = run(100)
    T.eq(open.ran, 2, "fully open works on both")
    T.eq(open.skipped, 0)
end

-- The demo project the dev server and the app preview serve has both kinds.
function tests.the_demo_project_has_both_kinds_of_shade()
    local mock = Mock.startDriver(Mock.demoProject())
    T.contains(mock.properties["Inventory"], "4 blinds")
end

return tests
