-- Light V2 lights (src/adapters/light_v2.lua) in 1.10.2 (ADR-077): a dimmer or a switch by what its
-- driver declares in its driver.xml's <capabilities> (src/control4/light_capabilities.lua), read once
-- per driver file; a level set with SET_BRIGHTNESS_TARGET, LIGHT_BRIGHTNESS_TARGET and RATE 0 (#11).
-- The fake project (Mock.project): 20 a KNX dimmer (driver 101, knx_dimmer.c4i), 21 a KNX switch
-- (driver 102, knx_switch.c4i) whose proxy has a level of 0 as the real ones do, 22 a dimmer whose
-- driver declares nothing (driver 103).

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

local function byId(items, id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
end

local function start(project, prepare)
    local mock = Mock.startDriver(project or Mock.project(), nil, nil, prepare)
    return mock, T.pair(mock)
end

local function light(mock, key, id)
    local answer = T.http(mock, "GET", "/v1/lights/" .. id, { key = key })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function lastCommand(mock)
    return mock.commands[#mock.commands]
end

local function commandsSince(mock, before)
    local sent = {}
    for index = before + 1, #mock.commands do
        sent[#sent + 1] = mock.commands[index]
    end
    return sent
end

local function listening(mock, deviceId, variableId)
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId and entry[2] == variableId then
            return true
        end
    end
    return false
end

local function logged(mock, text)
    local count = 0
    for _, line in ipairs(mock.debugLog) do
        if line:find(text, 1, true) then
            count = count + 1
        end
    end
    return count
end

-- Counts C4:GetDeviceData calls by tag ("capabilities", "devicedata" for none; versions left out).
local function countReads(reads)
    return function()
        local real = C4.GetDeviceData
        C4.GetDeviceData = function(self, id, tag)
            if tag ~= "version" then
                local name = tag or "devicedata"
                reads[name] = (reads[name] or 0) + 1
                reads[name .. " " .. tostring(id)] = (reads[name .. " " .. tostring(id)] or 0) + 1
            end
            return real(self, id, tag)
        end
    end
end

-- `count` KNX switches (proxies 2001.., drivers 3001.., each its own knx_switch.c4i driver, as in
-- a real project) in the Living Room, off, their level 0.
local function withKnxSwitches(project, count)
    for index = 1, count do
        local id, protocol = 2000 + index, 3000 + index
        project.devices[protocol] = {
            deviceName = "KNX Switch " .. index, driverFileName = "knx_switch.c4i", roomId = 11, roomName = "Living Room",
            proxies = { [id] = { deviceName = "Switch " .. index, driverFileName = "light_v2.c4i" } },
        }
        project.devices[id] = {
            deviceName = "Switch " .. index, driverFileName = "light_v2.c4i", roomId = 11, roomName = "Living Room",
            protocol = { [protocol] = { deviceName = "KNX Switch " .. index, driverFileName = "knx_switch.c4i" } },
        }
        project.variables[id] = { [1000] = "0", [1001] = "0" }
        project.deviceData[protocol] = { capabilities = Mock.KNX_SWITCH_CAPABILITIES }
    end
    return project
end

-- ---- dimmer or switch ------------------------------------------------------------------------

-- The owner's case: a KNX switch's proxy reports a level (0 or 100), and its driver declares
-- <dimmer>False</dimmer> and <set_level>False</set_level>. It is a switch: no level, no slider, no
-- set_brightness, and its level is not watched.
function tests.a_knx_switch_that_reports_a_level_is_a_switch()
    local mock, key = start()
    local switch = light(mock, key, 21)
    T.eq(switch.dimmable, false, "its driver declares it a switch")
    T.eq(switch.brightness_reported, false)
    T.truthy(isNull(switch.brightness), "a switch has no level")
    T.truthy(listening(mock, 21, 1000), "its Light State is watched")
    T.truthy(not listening(mock, 21, 1001), "its level (0 or 100) is not")

    local Manager = require("src.adapters.manager")
    local device = require("src.core.registry").getDevice(21)
    T.same(device.actions, { "on", "off" })
    T.eq(device.capabilities.brightness, false)

    -- It turns on and off as before; a level is refused, and nothing is sent.
    T.eq(T.http(mock, "PATCH", "/v1/lights/21", { key = key, body = { on = true } }).status, 202)
    T.same(lastCommand(mock), { device = 21, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } })
    local before = #mock.commands
    local refused = T.http(mock, "PATCH", "/v1/lights/21", { key = key, body = { brightness = 50 } })
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "NOT_SUPPORTED")
    local ok, failure = Manager.execute(21, "set_brightness", { value = 50 })
    T.eq(ok, false)
    T.eq(failure.code, "ACTION_NOT_SUPPORTED")
    T.eq(#mock.commands, before, "nothing is sent to a switch for a level")

    -- Its state follows Light State.
    T.eq(Mock.changeVariable(mock, 21, 1000, "1"), 1)
    T.eq(light(mock, key, 21).on, true)
    T.truthy(isNull(light(mock, key, 21).brightness))
end

-- A scene's level turns a switch on, and sets the dimmers' level.
function tests.a_scene_turns_a_switch_on_where_it_dims_a_dimmer()
    local mock, key = start()
    local before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
        { type = "lights", device_ids = { 20, 21, 22 }, set = { brightness = 30 } },
    } } })
    T.eq(ran.status, 202, ran.body)
    T.eq(ran.json.ran, 3)
    local byDevice = {}
    for _, command in ipairs(commandsSince(mock, before)) do
        byDevice[command.device] = command
    end
    T.same(byDevice[20], { device = 20, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 0 } })
    T.same(byDevice[21], { device = 21, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } }, "the switch turns on")
    T.same(byDevice[22], { device = 22, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 0 } })
end

-- A driver that declares nothing keeps the rule of 1.10.1: a level variable makes a dimmer, none a
-- switch. So does a light with no protocol driver to ask.
function tests.without_declared_capabilities_the_level_variable_decides()
    local project = Mock.project()
    -- A dimmer's driver that declares nothing, and a switch's driver that declares nothing and whose
    -- proxy has no level.
    Mock.addLight(project, 23, 104, 11, "Reading Lamp", 25)
    project.devices[105] = {
        deviceName = "Relay", driverFileName = "generic_switch.c4i", roomId = 11, roomName = "Living Room",
        proxies = { [24] = { deviceName = "Porch Light", driverFileName = "light_v2.c4i" } },
    }
    project.devices[24] = {
        deviceName = "Porch Light", driverFileName = "light_v2.c4i", roomId = 11, roomName = "Living Room",
        protocol = { [105] = { deviceName = "Relay", driverFileName = "generic_switch.c4i" } },
    }
    project.variables[24] = { [1000] = "1" }
    project.deviceData[105] = { capabilities = "<on_off>True</on_off>" }
    -- A light that is its own driver (no protocol driver), with a level.
    project.devices[28] = { deviceName = "Strip", driverFileName = "light_v2.c4z", roomId = 10, roomName = "Kitchen" }
    project.variables[28] = { [1000] = "1", [1001] = "55" }
    local mock, key = start(project)

    T.eq(light(mock, key, 22).dimmable, true)
    T.eq(light(mock, key, 22).brightness, 40)
    T.eq(light(mock, key, 22).brightness_reported, true)
    T.eq(light(mock, key, 23).dimmable, true)
    T.eq(light(mock, key, 23).brightness, 25)
    T.eq(light(mock, key, 24).dimmable, false, "no level, nothing declared: a switch")
    T.eq(light(mock, key, 24).on, true)
    T.eq(light(mock, key, 28).dimmable, true)
    T.eq(light(mock, key, 28).brightness, 55)
end

-- A driver may declare a dimmer by set_level alone, or by dimmer alone; a light whose driver
-- declares itself a dimmer but whose proxy has no level dims, its level unknown.
function tests.dimmer_or_set_level_true_makes_a_dimmer()
    local project = Mock.project()
    project.deviceData[103] = { capabilities = "<dimmer>False</dimmer><set_level>True</set_level>" }
    Mock.addLight(project, 23, 104, 11, "Reading Lamp", 25)
    project.deviceData[104] = { capabilities = "<dimmer>true</dimmer>" }
    project.variables[23] = { [1000] = "1" }
    local mock, key = start(project)
    T.eq(light(mock, key, 22).dimmable, true, "set_level True")
    T.eq(light(mock, key, 22).brightness, 40)
    local lamp = light(mock, key, 23)
    T.eq(lamp.dimmable, true, "dimmer True")
    T.truthy(isNull(lamp.brightness), "no level variable: not known")
    T.eq(lamp.brightness_reported, false)
    T.truthy(not listening(mock, 23, 1001))
    T.eq(T.http(mock, "PATCH", "/v1/lights/23", { key = key, body = { brightness = 45 } }).status, 202)
    T.same(lastCommand(mock), { device = 23, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET = 45, RATE = 0 } })
end

-- ---- read once per driver file ---------------------------------------------------------------

-- The owner's home has 107 lights on knx_switch.c4i: one Director call for all of them at each
-- project read, not one a light (the CORE-1 has one Lua thread).
function tests.capabilities_are_read_once_per_driver_file_and_project_read()
    local reads = {}
    local mock, key = start(withKnxSwitches(Mock.project(), 107), countReads(reads))
    T.eq(reads.capabilities, 3, "knx_switch.c4i, knx_dimmer.c4i and zigbee_dimmer.c4i, once each")
    local switchReads = reads["capabilities 102"] or 0
    for index = 1, 107 do
        switchReads = switchReads + (reads["capabilities " .. (3000 + index)] or 0)
    end
    T.eq(switchReads, 1, "one of the 108 knx_switch.c4i drivers is read, the others are not")
    T.eq(reads.devicedata, 1, "the whole <devicedata> only of the driver that gave no text (103)")
    T.eq(reads["devicedata 103"], 1)

    local lights = T.http(mock, "GET", "/v1/lights?room_id=11", { key = key }).json.items
    T.eq(#lights, 109)
    local dimmers = 0
    for _, item in ipairs(lights) do
        if item.dimmable then
            dimmers = dimmers + 1
        end
    end
    T.eq(dimmers, 1, "only the desk lamp dims in the Living Room")
    T.eq(byId(lights, 2107).dimmable, false)
    T.eq(logged(mock, "light driver capabilities"), 3, "one line a driver file")

    -- Refresh Project reads each driver file again, once.
    for name in pairs(reads) do
        reads[name] = nil
    end
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(reads.capabilities, 3)
    T.eq(light(mock, key, 2050).dimmable, false)
end

-- A driver updated in Composer may declare otherwise: its lights are read again when they are set
-- up again (src/control4/driver_updates.lua).
function tests.a_driver_update_reads_its_capabilities_again()
    local reads = {}
    local mock, key = start(nil, countReads(reads))
    T.eq(light(mock, key, 21).dimmable, false)
    T.eq(reads.capabilities, 3)

    -- Composer updates the switch's driver, which now declares a dimmer.
    Mock.updateDeviceDriver(mock, 102, "2")
    mock.project.deviceData[102].capabilities = Mock.KNX_DIMMER_CAPABILITIES
    require("src.core.scheduler").tick()
    T.eq(reads["capabilities 102"], 2, "read again")
    T.eq(reads.capabilities, 4, "and no other driver")
    local now = light(mock, key, 21)
    T.eq(now.dimmable, true)
    T.eq(now.brightness, 0)
    T.truthy(listening(mock, 21, 1001))
end

-- ---- what Director answers -------------------------------------------------------------------

-- An error, nothing, or something other than text: the rule of 1.10.1 (so the switch with a level
-- is a dimmer, as in 1.10.1), and nothing fails.
function tests.when_director_says_nothing_usable_the_level_variable_decides()
    local answers = {
        ["an error"] = function()
            error("no such device")
        end,
        ["nothing"] = function()
            return nil
        end,
        ["a table"] = function()
            return { dimmer = "False" }
        end,
        ["a number"] = function()
            return 0
        end,
        ["an empty text"] = function()
            return "  "
        end,
    }
    for name, answer in pairs(answers) do
        local mock, key = start(nil, function()
            C4.GetDeviceData = function(self, id, tag)
                if tag == "version" then
                    return "1"
                end
                return answer()
            end
        end)
        T.eq(light(mock, key, 21).dimmable, true, name .. ": the level variable decides")
        T.eq(light(mock, key, 20).dimmable, true, name)
        T.eq(light(mock, key, 21).brightness, 0, name)
        T.contains(table.concat(mock.debugLog, "\n"), '"capabilities_tag":"' .. name .. '"', name)
    end

    -- A Director without C4:GetDeviceData at all.
    local mock, key = start(nil, function()
        C4.GetDeviceData = nil
    end)
    T.eq(light(mock, key, 21).dimmable, true)
    T.eq(light(mock, key, 22).dimmable, true)
end

-- No text for the tag, but the whole <devicedata> has the capabilities: they are read from it.
function tests.the_whole_devicedata_when_the_tag_gives_no_text()
    local reads = {}
    local project = Mock.project()
    project.deviceData[102] = {
        devicedata = "<devicedata><version>3</version><proxies><proxy>light_v2</proxy></proxies>"
            .. "<capabilities><dimmer>False</dimmer><set_level>False</set_level></capabilities>"
            .. "<config><properties><property><name>dimmer</name><dimmer>True</dimmer></property></properties></config>"
            .. "</devicedata>",
    }
    local mock, key = start(project, countReads(reads))
    T.eq(reads["capabilities 102"], 1)
    T.eq(reads["devicedata 102"], 1)
    T.eq(light(mock, key, 21).dimmable, false, "only <capabilities> counts")
end

-- The text as Director may give it.
function tests.capabilities_text_is_read_in_its_forms()
    start()
    local LightCapabilities = require("src.control4.light_capabilities")
    local parse = LightCapabilities.parse
    T.same(parse(Mock.KNX_SWITCH_CAPABILITIES), { dimmer = false, set_level = false })
    T.same(parse(Mock.KNX_DIMMER_CAPABILITIES), { dimmer = true, set_level = true })
    T.same(parse("<capabilities>\n  <dimmer> True </dimmer>\n</capabilities>"), { dimmer = true }, "the tag itself around it")
    T.same(parse("&lt;dimmer&gt;False&lt;/dimmer&gt;&lt;set_level&gt;false&lt;/set_level&gt;"), { dimmer = false, set_level = false }, "escaped")
    T.same(parse("<dimmer>1</dimmer><set_level>0</set_level>"), { dimmer = true, set_level = false })
    T.same(parse('<dimmer type="bool">true</dimmer>'), { dimmer = true }, "with an attribute")
    T.same(parse("<!-- <dimmer>True</dimmer> --><dimmer>False</dimmer>"), { dimmer = false }, "comments left out")
    T.same(parse("<dimmer_levels>True</dimmer_levels><set_level_max>100</set_level_max>"), {}, "other tags are not these")
    T.same(parse("<dimmer/><set_level></set_level><on_off>True</on_off>"), {}, "empty: not declared")
    T.same(parse("<dimmer>maybe</dimmer>"), {}, "neither yes nor no: not declared")
    T.same(parse("<devicedata><version>1</version></devicedata>"), {}, "a <devicedata> without capabilities declares nothing")
    T.same(parse("<devicedata><capabilities><set_level>True</set_level></capabilities></devicedata>"), { set_level = true })
    T.eq(parse(""), nil)
    T.eq(parse(nil), nil)
    T.eq(parse(12), nil)

    local dimmable, by = LightCapabilities.dimmable({ protocols = {} }, true)
    T.eq(dimmable, true)
    T.eq(by, "level variable")
end

-- ---- setting a level (#11) -------------------------------------------------------------------

-- Every Light V2 dimmer, the KNX dimmer too, gets SET_BRIGHTNESS_TARGET with the level in
-- LIGHT_BRIGHTNESS_TARGET and RATE 0 (at once): the parameters Snap One documents and the KNX
-- dimmer's driver reads. Never PERCENT (read by neither) nor RAMP_TO_LEVEL (did not move it).
function tests.a_level_is_sent_as_light_brightness_target_with_rate_0()
    local mock, key = start()
    local before = #mock.commands
    local answer = T.http(mock, "PATCH", "/v1/lights/20", { key = key, body = { brightness = 60 } })
    T.eq(answer.status, 202, answer.body)
    T.same(lastCommand(mock), { device = 20, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 0 } })
    T.eq(T.http(mock, "PATCH", "/v1/lights/22", { key = key, body = { brightness = 7 } }).status, 202)
    T.same(lastCommand(mock), { device = 22, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET = 7, RATE = 0 } })
    T.eq(T.http(mock, "PATCH", "/v1/lights/20", { key = key, body = { brightness = 0 } }).status, 202)
    T.same(lastCommand(mock).params, { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 })
    for _, command in ipairs(commandsSince(mock, before)) do
        T.eq(command.command, "SET_BRIGHTNESS_TARGET")
        T.eq(command.params.PERCENT, nil)
    end

    -- On and off stay the presets.
    T.http(mock, "PATCH", "/v1/lights/20", { key = key, body = { on = false } })
    T.same(lastCommand(mock), { device = 20, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2 } })
    T.http(mock, "PATCH", "/v1/lights/20", { key = key, body = { on = true } })
    T.same(lastCommand(mock), { device = 20, command = "SET_BRIGHTNESS_TARGET", params = { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } })

    -- The log says what was sent.
    local line
    for _, entry in ipairs(mock.debugLog) do
        if entry:find("sending brightness target", 1, true) and entry:find('"device_id":20', 1, true) then
            line = entry
        end
    end
    T.truthy(line, "logged")
    T.contains(line, '"LIGHT_BRIGHTNESS_TARGET":0')
    T.contains(line, '"RATE":0')
    T.contains(line, '"command":"SET_BRIGHTNESS_TARGET"')
end

-- A KNX dimmer counts as reporting its level once it reports one between 0 and 100 (at start or
-- later); until then the app says the level is not reported, and does not wait for it.
function tests.a_knx_dimmer_reports_its_level_once_it_reports_one_between_0_and_100()
    local project = Mock.project()
    project.variables[20][1001] = "100"
    local mock, key = start(project)
    T.eq(light(mock, key, 20).brightness_reported, false, "only 0 and 100 seen")
    T.eq(T.http(mock, "PATCH", "/v1/lights/20", { key = key, body = { brightness = 40 } }).status, 202)
    T.eq(light(mock, key, 20).brightness_reported, false)
    Mock.changeVariable(mock, 20, 1001, "0")
    T.eq(light(mock, key, 20).brightness_reported, false)
    T.eq(light(mock, key, 20).on, false)
    Mock.changeVariable(mock, 20, 1001, "40")
    local dimmer = light(mock, key, 20)
    T.eq(dimmer.brightness_reported, true)
    T.eq(dimmer.brightness, 40)
    T.eq(dimmer.on, true)
    Mock.changeVariable(mock, 20, 1001, "100")
    T.eq(light(mock, key, 20).brightness_reported, true, "it stays so")
    T.eq(logged(mock, "the KNX dimmer reports its level"), 1)
    T.eq(light(mock, key, 22).brightness_reported, true, "other dimmers report theirs")
end

return tests
