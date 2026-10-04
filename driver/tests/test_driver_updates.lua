-- A device whose driver is updated in Composer is set up again (1.8.0, ADR-059,
-- src/control4/driver_updates.lua, src/adapters/manager.lua setUpAgain). Director tells other
-- drivers nothing when one is updated; DirectorLink reads each driver's <version> when it sets its
-- devices up, and again, a few drivers a minute, from the scheduler's tick. The owner's case: the
-- Samsung Refrigerator driver updated from 1.0.0 to 1.1.0 in Composer, adding REPORTED_VARIABLES and
-- TEMPERATURE_UNIT (ADR-049), which the refrigerator adapter reads only when it sets the device up.
-- The fake refrigerator is Mock.withRefrigerator: driver 140, the refrigerator 141.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function start(options)
    local mock = Mock.startDriver(Mock.withFans(Mock.withRefrigerator(Mock.project(), options)))
    return mock, T.pair(mock)
end

-- `count` scheduler minutes.
local function minutes(count)
    local Scheduler = require("src.core.scheduler")
    for _ = 1, count or 1 do
        Scheduler.tick()
    end
end

local function fridge(mock, key)
    local answer = T.http(mock, "GET", "/v1/refrigerators/141", { key = key })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function listeners(mock, deviceId)
    local found = {}
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId then
            found[#found + 1] = entry[2]
        end
    end
    table.sort(found)
    return found
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

function tests.the_refrigerator_is_set_up_again_when_composer_updates_its_driver()
    local mock, key = start({ version = "100", values = { FRIDGE_SETPOINT = "38", FREEZER_SETPOINT = "0", FREEZER_TEMP = "0" } })
    local before = fridge(mock, key)
    T.eq(before.features_reported, false, "driver 1.0.0 says nothing of the model")
    T.eq(#before.features, 4)
    T.eq(require("src.control4.driver_updates").version(140), "100")
    local otherListeners = listeners(mock, 20)
    local fanListeners = listeners(mock, 41)
    T.truthy(#otherListeners > 0 and #fanListeners > 0, "lights and fans are watched")

    -- Minutes go by: nothing changes, nothing is set up again.
    minutes(3)
    T.eq(logged(mock, "set up again"), 0)

    -- Composer updates the refrigerator's driver: a new version, and the two new variables (the
    -- model has Power Cool and Ice Maker only, in °F). Director says nothing to DirectorLink.
    Mock.updateDeviceDriver(mock, 140, "110", { REPORTED_VARIABLES = "POWER_COOL,ICE_MAKER,FRIDGE_SETPOINT,FRIDGE_TEMP,ONLINE,DOOR_OPEN", TEMPERATURE_UNIT = "F" })
    T.eq(fridge(mock, key).features_reported, false, "not until DirectorLink looks")
    minutes(1)
    local after = fridge(mock, key)
    T.eq(after.features_reported, true, "the refrigerator was set up again with the new variables")
    T.same(after.features, { "power_cool", "ice_maker" })
    T.eq(tostring(after.freezer_setpoint), "null", "what the model lacks is not reported")
    T.eq(after.fridge_setpoint, 3.3, "38 °F")
    T.eq(logged(mock, "a device's driver was updated in Composer; set up again"), 1, "logged once")
    T.eq(require("src.control4.driver_updates").version(140), "110")

    -- Its new variables are watched: a change of the unit, reported later, is taken.
    local watched = listeners(mock, 140)
    T.eq(#watched, 13, "the twelve but the power, and the two new ones")
    Mock.setRefrigerator(mock, 140, { TEMPERATURE_UNIT = "C", FRIDGE_SETPOINT = "4" })
    T.eq(fridge(mock, key).fridge_setpoint, 4)
    -- Each variable once: the old ones were let go before they were watched again.
    T.eq(Mock.changeVariable(mock, 140, 1009, "5"), 1, "FRIDGE_SETPOINT is delivered once")

    -- Nothing else was touched: the lights' and fans' variables are watched as before, and the
    -- project was not read again.
    T.same(listeners(mock, 20), otherListeners)
    T.same(listeners(mock, 41), fanListeners)
    T.eq(logged(mock, "project rediscovered"), 0)

    -- The next minutes find the same version: set up once.
    minutes(3)
    T.eq(logged(mock, "a device's driver was updated in Composer; set up again"), 1)
end

-- A refrigerator whose driver lacked a variable DirectorLink needs is not supported; the update
-- that adds it makes it work, without a project refresh.
function tests.a_device_that_could_not_be_set_up_works_once_its_driver_is_updated()
    local project = Mock.withRefrigerator(Mock.project())
    -- A driver without ONLINE (1005), neither by name nor at its id.
    project.variables[140][1005] = nil
    project.variableNames[140][1005] = nil
    local mock = Mock.startDriver(project)
    local key = T.pair(mock)
    T.eq(#T.http(mock, "GET", "/v1/refrigerators", { key = key }).json.items, 0, "not set up")
    local device = T.http(mock, "GET", "/v1/devices/141", { key = key }).json
    T.eq(device.supported, false)
    Mock.updateDeviceDriver(mock, 140, "101", { ONLINE = "1" })
    minutes(1)
    T.eq(#T.http(mock, "GET", "/v1/refrigerators", { key = key }).json.items, 1, "set up now")
    T.eq(fridge(mock, key).online, true)
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.inventory.refrigerators, 1, "counted")
end

-- Drivers are looked at a few a minute, one after another: every one within a few minutes.
function tests.drivers_are_looked_at_a_few_a_minute_in_turn()
    local DriverUpdates
    local mock, key = start()
    DriverUpdates = require("src.control4.driver_updates")
    local Manager = require("src.adapters.manager")
    local devices = 0
    for _ in pairs(Manager.matchedDevices()) do
        devices = devices + 1
    end
    T.truthy(devices > 5, "the project's devices are watched: " .. devices)
    DriverUpdates.CHECK_PER_TICK = 2
    local reads = 0
    local real = C4.GetDeviceData
    C4.GetDeviceData = function(self, id, tag)
        reads = reads + 1
        return real(self, id, tag)
    end
    minutes(1)
    T.eq(reads, 2, "two drivers a minute here")
    Mock.updateDeviceDriver(mock, 140, "200", { REPORTED_VARIABLES = "POWER_COOL,ONLINE" })
    local turns = 0
    while fridge(mock, key).features_reported ~= true and turns < 40 do
        minutes(1)
        turns = turns + 1
    end
    T.truthy(turns < 40, "the refrigerator's driver came round")
    C4.GetDeviceData = real
end

-- A Director that gives no versions: nothing is watched, and the log says to use Refresh Project.
function tests.without_driver_versions_nothing_is_watched_and_the_log_says_so()
    local mock = Mock.startDriver(Mock.withRefrigerator(Mock.project()), nil, nil, function()
        C4.GetDeviceData = nil -- a Director without it
    end)
    local key = T.pair(mock)
    T.eq(logged(mock, "Director gives no driver versions"), 1)
    T.eq(require("src.control4.driver_updates").version(140), nil)
    Mock.updateDeviceDriver(mock, 140, "110", { REPORTED_VARIABLES = "POWER_COOL,ONLINE" })
    minutes(2)
    T.eq(fridge(mock, key).features_reported, false, "only Refresh Project reads it again")
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(fridge(mock, key).features_reported, true)
    T.eq(logged(mock, "Director gives no driver versions"), 1, "said once a run")
end

return tests
