-- Thermostats as a US home reports them (1.10.2, ADR-076, #75): each in its own scale (`scale`, and
-- `*_f` fields on a °F one, which PATCH also takes), whole °F sent exactly, values not reported as
-- null (never 0° or -18°), a Nest's heat and cool setpoints, display-only thermostats as sensors,
-- weather drivers left out, and the project's scale in GET /v1/system.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

local function start(project)
    local mock = Mock.startDriver(project)
    local key = T.pair(mock)
    local function get(id)
        return T.http(mock, "GET", "/v1/thermostats/" .. tostring(id), { key = key })
    end
    local function patch(id, body)
        return T.http(mock, "PATCH", "/v1/thermostats/" .. tostring(id), { key = key, body = body })
    end
    return mock, key, get, patch
end

-- The commands one request sent: { command, params } pairs.
local function sentBy(mock, request)
    local before = #mock.commands
    local response = request()
    local list = {}
    for index = before + 1, #mock.commands do
        list[#list + 1] = { mock.commands[index].command, mock.commands[index].params }
    end
    return list, response
end

-- The app's °C for a whole °F (to 0.1, as scenes keep it): it comes back as that °F exactly.
local function celsiusOf(fahrenheit)
    return math.floor((fahrenheit - 32) * 5 / 9 * 10 + 0.5) / 10
end

function tests.a_minisplit_in_fahrenheit_is_shown_and_set_in_whole_fahrenheit()
    local mock, _, get, patch = start(Mock.withMinisplit(Mock.project()))
    local thermostat = get(33).json
    T.eq(thermostat.scale, "F")
    T.eq(thermostat.current_temperature_f, 74, "74 °F now, not 23°")
    T.eq(thermostat.target_temperature_f, 69, "69 °F set, not 21°")
    T.eq(thermostat.current_temperature, 23.3)
    T.eq(thermostat.target_temperature, 20.6, "°C to 0.1, which is 69 °F again")
    T.eq(thermostat.target_temperature_min_f, 61, "16 °C is 60.8 °F: the whole °F inside")
    T.eq(thermostat.target_temperature_max_f, 89)
    T.eq(thermostat.sensor, false)
    T.eq(thermostat.setpoints, "single")
    T.truthy(isNull(thermostat.heat_setpoint_f) and isNull(thermostat.setpoint_deadband_f))
    T.same(thermostat.modes, { "auto", "cool", "heat", "off" })

    local sent, response = sentBy(mock, function()
        return patch(33, { target_temperature_f = 69 })
    end)
    T.eq(response.status, 202, response.body)
    T.same(sent, { { "SET_SETPOINT_SINGLE", { FAHRENHEIT = 69 } } }, "the °F chosen, in the project's scale")
    sent = sentBy(mock, function()
        return patch(33, { mode = "heat", target_temperature_f = 72 })
    end)
    T.same(sent, { { "SET_MODE_HVAC", { MODE = "Heat" } }, { "SET_SETPOINT_SINGLE", { FAHRENHEIT = 72 } } })
    -- What a 1.10.1 app or a script sends in °C reaches the same whole °F, for every one in range.
    for fahrenheit = 61, 89 do
        sent = sentBy(mock, function()
            return patch(33, { target_temperature = celsiusOf(fahrenheit) })
        end)
        T.same(sent, { { "SET_SETPOINT_SINGLE", { FAHRENHEIT = fahrenheit } } }, fahrenheit .. " °F")
    end

    for _, body in ipairs({ { target_temperature_f = 60 }, { target_temperature_f = 90 }, { target_temperature_f = "70" } }) do
        sent, response = sentBy(mock, function()
            return patch(33, body)
        end)
        T.eq(response.status, 400, response.body)
        T.eq(response.json.code, "INVALID_FIELD")
        T.eq(response.json.errors[1].field, "target_temperature_f")
        T.eq(#sent, 0)
    end
    sent, response = sentBy(mock, function()
        return patch(33, { target_temperature = 21, target_temperature_f = 70 })
    end)
    T.eq(response.status, 400)
    T.eq(response.json.code, "INVALID_REQUEST")
    T.eq(#sent, 0)

    OnWatchedVariableChanged(33, 1149, "70")
    OnWatchedVariableChanged(33, 1130, "75")
    thermostat = get(33).json
    T.eq(thermostat.target_temperature_f, 70)
    T.eq(thermostat.current_temperature_f, 75)
    T.eq(thermostat.current_temperature, 23.9)
end

-- A °C thermostat takes °F too (converted, to 0.1 °C), and its view has no `*_f` fields.
function tests.a_celsius_zone_takes_fahrenheit_and_says_its_scale()
    local mock, _, get, patch = start(Mock.project())
    local thermostat = get(30).json
    T.eq(thermostat.scale, "C")
    T.eq(thermostat.target_temperature_f, nil)
    T.eq(thermostat.current_temperature_f, nil)
    local sent = sentBy(mock, function()
        return patch(30, { target_temperature_f = 72 })
    end)
    T.same(sent, { { "SET_SETPOINT_SINGLE", { CELSIUS = 22.2 } } })
end

-- A Nest (#75): no single setpoint (0 °F, which 1.10.1 showed as -18°), its heat and cool setpoints
-- instead. Its target is the setpoint of its mode, as Control4 shows it.
function tests.a_nest_reports_and_takes_its_heat_and_cool_setpoints()
    local mock, _, get, patch = start(Mock.withNestThermostat(Mock.project()))
    local thermostat = get(34).json
    T.eq(thermostat.setpoints, "dual")
    T.eq(thermostat.mode, "cool")
    T.eq(thermostat.target_temperature_f, 71, "its cool setpoint, not -18°")
    T.eq(thermostat.target_temperature, 21.7)
    T.eq(thermostat.heat_setpoint_f, 68)
    T.eq(thermostat.cool_setpoint_f, 71)
    T.eq(thermostat.setpoint_deadband_f, 3)
    T.eq(thermostat.current_temperature_f, 72)
    T.eq(thermostat.target_temperature_min_f, 41)
    T.eq(thermostat.target_temperature_max_f, 95)
    -- Its own fan speeds (1121), not the Low, Medium and High of a CoolMaster zone.
    T.eq(thermostat.fan_speed, "auto")
    T.eq(table.concat(thermostat.fan_speeds, ","), "auto,on")

    local sent, response = sentBy(mock, function()
        return patch(34, { target_temperature_f = 72 })
    end)
    T.eq(response.status, 202, response.body)
    T.same(sent, { { "SET_SETPOINT_COOL", { FAHRENHEIT = 72 } } })
    sent = sentBy(mock, function()
        return patch(34, { fan_speed = "on" })
    end)
    T.same(sent, { { "SET_MODE_FAN", { MODE = "On" } } }, "in its own spelling")
    T.eq(patch(34, { fan_speed = "low" }).status, 409)

    OnWatchedVariableChanged(34, 1104, "Heat")
    T.eq(get(34).json.target_temperature_f, 68, "in Heat, its heat setpoint")
    sent = sentBy(mock, function()
        return patch(34, { mode = "auto", heat_setpoint_f = 66, cool_setpoint_f = 74 })
    end)
    T.same(sent, {
        { "SET_MODE_HVAC", { MODE = "Auto" } },
        { "SET_SETPOINT_COOL", { FAHRENHEIT = 74 } },
        { "SET_SETPOINT_HEAT", { FAHRENHEIT = 66 } },
    })
    OnWatchedVariableChanged(34, 1104, "Auto")
    thermostat = get(34).json
    T.truthy(isNull(thermostat.target_temperature) and isNull(thermostat.target_temperature_f), "auto: two setpoints, no one target")
    for _, command in ipairs(mock.commands) do
        T.truthy(command.command ~= "SET_SETPOINT_SINGLE", "never its single setpoint")
    end
end

-- A Nest whose mode's setpoint is not reported (left at 0) has no target: null, never 0 or -18°.
function tests.a_nest_without_the_setpoint_of_its_mode_shows_none()
    local _, _, get, patch = start(Mock.withNestThermostat(Mock.project(), { cool = "0", coolC = "0" }))
    local thermostat = get(34).json
    T.truthy(isNull(thermostat.target_temperature) and isNull(thermostat.target_temperature_f))
    T.truthy(isNull(thermostat.cool_setpoint) and isNull(thermostat.cool_setpoint_f))
    T.eq(thermostat.heat_setpoint_f, 68)
    T.eq(patch(34, { target_temperature_f = 72 }).status, 409, "no cool setpoint to set")
    OnWatchedVariableChanged(34, 1134, "73")
    OnWatchedVariableChanged(34, 1135, "22.8")
    T.eq(get(34).json.target_temperature_f, 73, "once it is reported")
end

-- A thermostat with no mode to set and no setpoint ("Bathroom": 73° and 30 % in Control4) is a
-- sensor: its reading, nothing else, nothing to set. With no scale variable, the °F it reports.
function tests.a_display_only_thermostat_is_a_sensor()
    local mock, key, get, patch = start(Mock.withTemperatureSensor(Mock.project()))
    local thermostat = get(36).json
    T.eq(thermostat.sensor, true)
    T.eq(thermostat.scale, "F", "only °F reported")
    T.eq(thermostat.current_temperature_f, 73, "not 0°")
    T.eq(thermostat.current_temperature, 22.8)
    T.eq(thermostat.humidity, 30)
    T.truthy(isNull(thermostat.mode) and isNull(thermostat.activity), "not Undefined")
    T.truthy(isNull(thermostat.target_temperature) and isNull(thermostat.target_temperature_f), "not -18°")
    T.eq(#thermostat.modes, 0)
    T.eq(#thermostat.fan_speeds, 0)

    for _, body in ipairs({ { mode = "heat" }, { target_temperature = 22 }, { target_temperature_f = 72 } }) do
        local sent, response = sentBy(mock, function()
            return patch(36, body)
        end)
        T.eq(response.status, 409, response.body)
        T.eq(response.json.code, "NOT_SUPPORTED")
        T.eq(#sent, 0)
    end

    -- A scene never sets it: by its id it is skipped; a room's climate step leaves it out.
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
        { type = "climate", device_ids = { 36 }, set = { mode = "cool" } },
    } } })
    T.eq(tried.json.ran, 0)
    T.eq(tried.json.skipped, 1)
    T.eq(tried.json.problems[1].code, "NOT_SUPPORTED")
    local sent, room = sentBy(mock, function()
        return T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
            { type = "climate", room_id = 11, set = { mode = "off" } },
        } } })
    end)
    T.eq(room.json.ran, 1, "the room's AC only")
    T.eq(room.json.skipped, 0)
    T.same(sent, { { "SET_MODE_HVAC", { MODE = "Off" } } })
    T.eq(mock.commands[#mock.commands].device, 30)

    OnWatchedVariableChanged(36, 1138, "35")
    OnWatchedVariableChanged(36, 1130, "72")
    thermostat = get(36).json
    T.eq(thermostat.humidity, 35)
    T.eq(thermostat.current_temperature_f, 72)
end

-- A sensor that fills both scales and says no scale, in a project that says none: °C, as read.
function tests.a_sensor_without_any_scale_reads_what_it_reports()
    local _, _, get = start(Mock.withTemperatureSensor(Mock.project(), { fahrenheit = "73", celsius = "22.8", humidity = "0" }))
    local thermostat = get(36).json
    T.eq(thermostat.sensor, true)
    T.eq(thermostat.scale, "C")
    T.eq(thermostat.current_temperature, 22.8)
    T.eq(thermostat.humidity, nil, "0 % is not reported")

    local project = Mock.withTemperatureSensor(Mock.project())
    project.projectProperties.TemperatureScale = "FAHRENHEIT"
    local _, _, getF = start(project)
    T.eq(getF(36).json.current_temperature_f, 73, "the project's scale")
end

-- An outdoor weather driver on the thermostat proxy is the weather, not an AC: left out.
function tests.a_weather_driver_is_left_out_of_climate()
    local project = Mock.withWeatherThermostat(Mock.project())
    Mock.withWeatherThermostat(project, { id = 38, protocol = 176, name = "Outside", driver = "openweather_agent.c4z" })
    Mock.withMinisplit(project, { id = 39, protocol = 177, name = "Weatherby Room" })
    local mock, key, get = start(project)
    local ids = {}
    for _, item in ipairs(T.http(mock, "GET", "/v1/thermostats", { key = key }).json.items) do
        ids[#ids + 1] = item.id
    end
    table.sort(ids)
    T.same(ids, { 30, 39 }, "by its name or its driver's; a name that only starts so is not")
    T.eq(get(37).status, 404)
    T.eq(get(38).status, 404)
end

-- A zone that reports no room temperature (1131 left at 0, a CoolMaster floor zone) has none: null.
function tests.a_zone_without_a_room_temperature_has_none()
    local _, _, get = start(Mock.withUnreportedTemperatureZone(Mock.project()))
    local thermostat = get(35).json
    T.truthy(isNull(thermostat.current_temperature), "not 0°")
    T.eq(thermostat.target_temperature, 25)
    T.eq(thermostat.scale, "C")
    OnWatchedVariableChanged(35, 1131, "21.5")
    T.eq(get(35).json.current_temperature, 21.5)
    OnWatchedVariableChanged(35, 1131, "0")
    T.truthy(isNull(get(35).json.current_temperature))
end

-- A single setpoint read as 0 °F and -17.8 °C is not reported: null, never -18°.
function tests.a_setpoint_of_minus_eighteen_is_not_reported()
    local project = Mock.project()
    project.variables[30][1149] = "0"
    project.variables[30][1150] = "-17.8"
    local _, _, get = start(project)
    T.truthy(isNull(get(30).json.target_temperature))
end

-- GET /v1/system says the project's scale: Composer's, else the thermostats', else °C.
function tests.the_project_scale_comes_from_composer_then_the_thermostats()
    local function scaleOf(project)
        local mock, key = start(project)
        return T.http(mock, "GET", "/v1/system", { key = key }).json.temperature_scale
    end
    T.eq(scaleOf(Mock.project()), "C")
    local composer = Mock.project()
    composer.projectProperties.TemperatureScale = "FAHRENHEIT"
    T.eq(scaleOf(composer), "F")
    local thermostats = Mock.withNestThermostat(Mock.withMinisplit(Mock.project()))
    T.eq(scaleOf(thermostats), "F", "two °F thermostats and one °C")
    local none = Mock.project()
    Mock.removeDevice(none, 30)
    T.eq(scaleOf(none), "C", "a project without thermostats stays °C")
end

-- A scene keeps °C to 0.1: a step made at a whole °F runs to exactly that °F, on a single and on a
-- dual setpoint; a step of 1.10.1 (0.5 °C) to the °F it always did.
function tests.a_scene_runs_fahrenheit_thermostats_to_the_whole_degree_chosen()
    local mock, key = start(Mock.withNestThermostat(Mock.withMinisplit(Mock.project())))
    local function run(set)
        return sentBy(mock, function()
            return T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = {
                { type = "climate", device_ids = { 33, 34 }, set = set },
            } } })
        end)
    end
    for fahrenheit = 61, 89 do
        local sent = run({ mode = "cool", target_temperature = celsiusOf(fahrenheit) })
        T.same(sent[2], { "SET_SETPOINT_SINGLE", { FAHRENHEIT = fahrenheit } }, fahrenheit .. " °F")
        -- Below 71 °F the Nest's heat setpoint (68 °F) moves down first, to stay 3 °F below.
        T.same(sent[#sent], { "SET_SETPOINT_COOL", { FAHRENHEIT = fahrenheit } }, fahrenheit .. " °F")
    end
    local sent = run({ mode = "cool", target_temperature = 22.5 })
    T.same(sent[2], { "SET_SETPOINT_SINGLE", { FAHRENHEIT = 73 } }, "72.5 °F, rounded up")
end

-- The dev server's °F project starts every thermostat of #75; the weather driver is not one.
function tests.the_fahrenheit_demo_project_starts()
    local mock, key = start(Mock.fahrenheitProject())
    T.contains(mock.properties["Inventory"], "6 thermostats")
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.temperature_scale, "F")
    local byId = {}
    for _, item in ipairs(T.http(mock, "GET", "/v1/thermostats", { key = key }).json.items) do
        byId[item.id] = item
        T.eq(item.scale, "F", item.name)
    end
    T.eq(byId[37], nil)
    T.eq(byId[30].target_temperature_f, 72)
    T.eq(byId[31].heat_setpoint_f, 68)
    T.eq(byId[32].target_temperature_f, 71)
    T.eq(byId[33].target_temperature_f, 69)
    T.eq(byId[34].target_temperature_f, 71)
    T.eq(byId[36].sensor, true)
end

return tests
