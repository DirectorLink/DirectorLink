-- The alarm's status (ADR-038): security partitions, read-only, off by default (the Composer
-- property Alarm Status), for members and admins only, and only in sealed answers, at home and
-- through the account. Nothing is ever sent to a partition, and its state is never logged.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

local PARTITIONS = { 80, 81, 82 }
-- Mock.project() as the inventory showed it before 1.2.0, with the three partitions among the devices.
local INVENTORY = "2 rooms, 17 devices, 3 lights, 1 thermostats, 2 blinds, 3 cameras, 1 relays, 1 doorbells"

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

-- The default project with the partitions, Alarm Status On or Off; an admin key paired at home.
local function start(on, prepare)
    local mock = Mock.startDriver(Mock.withPartitions(Mock.project()), nil, nil, function(m)
        if on then
            Properties["Alarm Status"] = "On"
        end
        if prepare then
            prepare(m)
        end
    end)
    local key = T.pair(mock)
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    return mock, key, me.id
end

local function switch(value)
    Properties["Alarm Status"] = value
    OnPropertyChanged("Alarm Status")
end

local counter = 0

-- A request sealed at home, as the app sends every request: POST /v1/sealed with the key's lock
-- key, no Authorization header. Returns the opened answer (its `json` decoded) and the response.
local function sealed(mock, key, keyId, request)
    local Lock = require("src.cloud.lock")
    local info = T.http(mock, "GET", "/v1/sealed").json
    counter = counter + 1
    request.id = request.id or ("alarm-" .. counter)
    request.ts = request.ts or info.time
    local lock = Lock.deviceKey(key)
    local envelope = Lock.seal(lock, info.home, keyId, "req", Json.encode(request))
    local response = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer, response
end

local function alarm(mock, key, keyId)
    return sealed(mock, key, keyId, { method = "GET", path = "/v1/alarm" })
end

local function partition(mock, key, keyId, id)
    for _, item in ipairs(alarm(mock, key, keyId).json.partitions) do
        if item.id == id then
            return item
        end
    end
    return nil
end

local function createKey(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role .. " phone", role = role } })
    T.eq(created.status, 201)
    return created.json.key, created.json.id
end

local function listeners(mock, deviceId)
    local count = 0
    for _, entry in ipairs(mock.listeners) do
        if entry[1] == deviceId then
            count = count + 1
        end
    end
    return count
end

local function discovered(mock)
    for _, line in ipairs(mock.debugLog) do
        local data = line:match("project discovered (.*)$")
        if data then
            return Json.decode(data)
        end
    end
end

function tests.off_by_default_the_partitions_are_not_watched_and_nothing_is_shown()
    -- The same project without its partitions, first: starting a driver replaces the one before.
    local before = discovered(Mock.startDriver(Mock.project()))
    local mock, key, keyId = start(false)
    for _, id in ipairs(PARTITIONS) do
        T.eq(listeners(mock, id), 0, "partition " .. id .. " is not watched")
    end
    T.eq(Mock.changeVariable(mock, 81, 1007, "ALARM"), 0, "a change is not even heard")

    local answer = alarm(mock, key, keyId)
    T.eq(answer.status, 200)
    T.eq(answer.json.enabled, false)
    T.eq(#answer.json.partitions, 0)
    local plain = T.http(mock, "GET", "/v1/alarm", { key = key })
    T.eq(plain.status, 200, "Off says only that, sealed or not")
    T.eq(plain.json.enabled, false)
    T.eq(#plain.json.partitions, 0)
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.features.alarm_status, false)

    -- Counted as unsupported, as before 1.2.0.
    T.eq(mock.properties["Inventory"], INVENTORY)
    local counts = discovered(mock)
    T.eq(counts.unsupported, before.unsupported + 3)
    T.eq(counts.recognized, before.recognized)
    T.eq(counts.supported, before.supported)
    local device = T.http(mock, "GET", "/v1/devices/81", { key = key }).json
    T.eq(device.type, "other")
    T.eq(device.supported, false)
    T.truthy(isNull(device.href))
end

function tests.on_members_and_admins_read_the_partitions_in_sealed_answers()
    local mock, key, keyId = start(true)
    for _, id in ipairs(PARTITIONS) do
        T.eq(listeners(mock, id), 12, "partition " .. id .. ": 1000-1003 and 1005-1012 are watched")
    end
    local answer = alarm(mock, key, keyId)
    T.eq(answer.status, 200)
    T.eq(answer.json.enabled, true)
    local items = answer.json.partitions
    T.eq(#items, 2, "the partition the panel does not use is left out")
    local garage, house = items[1], items[2]
    T.eq(garage.id, 81, "sorted by name")
    T.eq(garage.name, "Garage")
    T.eq(garage.room.id, 10)
    T.eq(garage.state, "armed")
    T.eq(garage.armed, true)
    T.eq(garage.armed_mode, "away")
    T.eq(garage.armed_type, "Away")
    T.eq(garage.alarm, false)
    T.truthy(isNull(garage.alarm_type))
    T.eq(garage.open_zones, 0)
    T.truthy(isNull(garage.delay))
    T.truthy(isNull(garage.trouble))
    T.eq(house.id, 80)
    T.eq(house.state, "disarmed_not_ready")
    T.eq(house.armed, false)
    T.truthy(isNull(house.armed_mode))
    T.truthy(isNull(house.armed_type))
    T.eq(house.open_zones, 1)
    T.notContains(answer.body, "Keypad text", "variable 1004 is not read")

    for _, role in ipairs({ "member", "doors" }) do
        local other, otherId = createKey(mock, key, role)
        local read = alarm(mock, other, otherId)
        T.eq(read.status, 200, role)
        T.eq(#read.json.partitions, 2, role)
    end
    local viewer, viewerId = createKey(mock, key, "viewer")
    local refused = alarm(mock, viewer, viewerId)
    T.eq(refused.status, 403, "never for viewers")
    T.eq(refused.json.code, "FORBIDDEN")
    T.notContains(refused.body, "Garage")
    T.eq(T.http(mock, "GET", "/v1/alarm", { key = viewer }).json.code, "FORBIDDEN")
    T.eq(T.http(mock, "GET", "/v1/system", { key = viewer }).json.features.alarm_status, true, "the app hides the card itself")

    -- Composer counts them for the installer; the API's device list and inventory do not change.
    T.eq(mock.properties["Inventory"], INVENTORY .. ", 2 alarm partitions")
    T.eq(T.http(mock, "GET", "/v1/devices/81", { key = viewer }).json.type, "other")
    T.eq(T.http(mock, "GET", "/v1/system", { key = viewer }).json.inventory.supported_devices, 11)
end

function tests.viewers_get_403_whether_it_is_on_or_off()
    local mock, key = start(false)
    local viewer, viewerId = createKey(mock, key, "viewer")
    T.eq(alarm(mock, viewer, viewerId).status, 403)
    T.eq(T.http(mock, "GET", "/v1/alarm", { key = viewer }).status, 403)
end

function tests.on_a_request_in_the_clear_gets_nothing_about_the_alarm()
    local mock, key = start(true)
    local plain = T.http(mock, "GET", "/v1/alarm", { key = key })
    T.eq(plain.status, 403)
    T.eq(plain.json.code, "SEALED_REQUEST_REQUIRED")
    local headers = {}
    for name, value in pairs(plain.headers) do
        headers[#headers + 1] = name .. ": " .. value
    end
    for _, word in ipairs({ "Garage", "House", "armed", "Armed", "Away", "disarmed", "zone" }) do
        T.notContains(plain.body, word, "nothing of the alarm in the clear")
        T.notContains(table.concat(headers, "\n"), word)
    end
end

function tests.through_the_account_the_alarm_comes_sealed_end_to_end()
    local mock, key, keyId = start(true)
    local _, connection = Harness.connected({ mock = mock })
    local home = T.http(mock, "GET", "/v1/remote", { key = key }).json.home_id
    local Lock = require("src.cloud.lock")
    local function remote(apiKey, id, requestId)
        local lock = Lock.deviceKey(apiKey)
        local envelope = Lock.seal(lock, home, id, "req", Json.encode({ id = requestId, ts = os.time(), method = "GET", path = "/v1/alarm" }))
        local reply, frame = Harness.relayRequest(mock, connection, { type = "e2e", id = "relay-" .. requestId, envelope = envelope })
        T.truthy(reply.envelope, "answered sealed")
        return Json.decode(Lock.open(lock, reply.envelope, "res")), frame
    end
    local answer, frame = remote(key, keyId, "remote-alarm-1")
    T.eq(answer.status, 200)
    local body = Json.decode(answer.body)
    T.eq(body.enabled, true)
    T.eq(#body.partitions, 2)
    for _, word in ipairs({ "Garage", "House", "armed", "disarmed", "away" }) do
        T.notContains(frame.payload, word, "the relay sees nothing of the alarm")
    end
    local viewer, viewerId = createKey(mock, key, "viewer")
    local refused = remote(viewer, viewerId, "remote-alarm-2")
    T.eq(refused.status, 403, "not for viewers through the account either")
end

function tests.the_status_follows_what_the_partitions_report()
    local mock, key, keyId = start(true)
    local commands = #mock.commands
    local function house()
        return partition(mock, key, keyId, 80)
    end

    Mock.setPartition(mock, 80, { PARTITION_STATE = "EXIT_DELAY", DISARMED_STATE = "0", OPEN_ZONE_COUNT = "0", DELAY_TIME_TOTAL = "30", DELAY_TIME_REMAINING = "30" })
    local arming = house()
    T.eq(arming.state, "exit_delay")
    T.eq(arming.armed, false)
    T.same(arming.delay, { type = "exit", remaining = 30, total = 30 })
    T.eq(arming.open_zones, 0)

    Mock.setPartition(mock, 80, { PARTITION_STATE = "ARMED", HOME_STATE = "1", ARMED_TYPE = "Stay", DELAY_TIME_REMAINING = "0", DELAY_TIME_TOTAL = "0" })
    local armed = house()
    T.eq(armed.armed, true)
    T.eq(armed.armed_mode, "home")
    T.eq(armed.armed_type, "Stay")
    T.truthy(isNull(armed.delay))

    Mock.setPartition(mock, 80, { PARTITION_STATE = "ENTRY_DELAY", DELAY_TIME_TOTAL = "20", DELAY_TIME_REMAINING = "12" })
    local entering = house()
    T.eq(entering.state, "entry_delay")
    T.eq(entering.armed, true)
    T.same(entering.delay, { type = "entry", remaining = 12, total = 20 })

    Mock.setPartition(mock, 80, { PARTITION_STATE = "ALARM", ALARM_STATE = "1", ALARM_TYPE = "Burglary", DELAY_TIME_REMAINING = "0" })
    local ringing = house()
    T.eq(ringing.state, "alarm")
    T.eq(ringing.alarm, true)
    T.eq(ringing.alarm_type, "Burglary")

    Mock.setPartition(mock, 81, { TROUBLE_TEXT = "AC power lost" })
    T.eq(partition(mock, key, keyId, 81).trouble, "AC power lost")
    Mock.setPartition(mock, 81, { TROUBLE_TEXT = "" })
    T.truthy(isNull(partition(mock, key, keyId, 81).trouble))

    Mock.setPartition(mock, 80, { PARTITION_STATE = "DISARMED_READY", ALARM_STATE = "0", HOME_STATE = "0", DISARMED_STATE = "1" })
    local disarmed = house()
    T.eq(disarmed.state, "disarmed_ready")
    T.eq(disarmed.armed, false)
    T.truthy(isNull(disarmed.armed_mode))
    T.truthy(isNull(disarmed.armed_type), "the type of arming goes with the arming")
    T.eq(disarmed.alarm, false)
    T.truthy(isNull(disarmed.alarm_type), "and the type of alarm with the alarm")

    -- A partition the panel starts to use appears; one it stops using goes.
    T.eq(partition(mock, key, keyId, 82), nil)
    Mock.setPartition(mock, 82, { IS_ACTIVE = "1" })
    T.eq(partition(mock, key, keyId, 82).name, "Partition 3")
    Mock.setPartition(mock, 81, { IS_ACTIVE = "0" })
    T.eq(partition(mock, key, keyId, 81), nil)
    T.contains(mock.properties["Inventory"], "2 alarm partitions")
    T.eq(#mock.commands, commands, "nothing is sent to anything")
end

function tests.nothing_is_ever_sent_to_a_partition()
    local mock, key = start(true)
    local commands = #mock.commands
    Properties["Door Control"] = "Enabled"
    local Manager = require("src.adapters.manager")
    for _, action in ipairs({ "arm", "disarm", "arm_away", "arm_home", "on", "off", "pulse", "open" }) do
        local ok, failure = Manager.execute(81, action, { code = "1234", mode = "away" })
        T.eq(ok, false, action)
        T.eq(failure.code, "ACTION_NOT_SUPPORTED", action)
    end
    for _, method in ipairs({ "POST", "PUT", "PATCH", "DELETE" }) do
        T.eq(T.http(mock, method, "/v1/alarm", { key = key, body = { state = "disarmed", code = "1234" } }).status, 405, method .. " /v1/alarm")
    end
    T.eq(T.http(mock, "POST", "/v1/alarm/81/disarm", { key = key }).status, 404)
    T.eq(T.http(mock, "PATCH", "/v1/lights/81", { key = key, body = { on = false } }).status, 404)
    T.eq(T.http(mock, "POST", "/v1/relays/81/pulse", { key = key }).status, 404)
    -- No scene step, and so no schedule, can name a partition.
    local named = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Leave", steps = { { type = "relays", device_ids = { 81 }, set = { action = "pulse" } } } } })
    T.eq(named.status, 400)
    T.contains(named.json.detail, "not one of this home's relays")
    for _, stepType in ipairs({ "alarm", "security", "partitions" }) do
        local tried = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = { { type = stepType, set = { state = "disarmed" } } } } })
        T.eq(tried.status, 400, stepType)
    end
    T.eq(#mock.commands, commands, "nothing was sent")
end

function tests.turning_it_off_in_composer_stops_watching_at_once()
    local mock, key, keyId = start(true)
    local light = listeners(mock, 20)
    switch("Off")
    for _, id in ipairs(PARTITIONS) do
        T.eq(listeners(mock, id), 0, "partition " .. id .. " is no longer watched")
    end
    T.eq(listeners(mock, 20), light, "other devices stay as they are")
    T.eq(Mock.changeVariable(mock, 81, 1007, "ALARM"), 0)
    local off = alarm(mock, key, keyId)
    T.eq(off.json.enabled, false)
    T.eq(#off.json.partitions, 0)
    T.eq(mock.properties["Inventory"], INVENTORY)
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.features.alarm_status, false)

    switch("On")
    T.eq(listeners(mock, 81), 12, "watched again")
    local garage = partition(mock, key, keyId, 81)
    T.eq(garage.state, "alarm", "read again when it is turned on")
    T.eq(mock.properties["Inventory"], INVENTORY .. ", 2 alarm partitions")
    T.eq(listeners(mock, 20), light)
end

-- A controller DirectorLink does not run on reads no project: switching it changes nothing.
function tests.on_an_unsupported_controller_the_switch_does_nothing()
    local project = Mock.withPartitions(Mock.project())
    project.osVersion = "3.2.9"
    local mock = Mock.startDriver(project)
    switch("On")
    T.eq(mock.properties["Inventory"], nil, "no inventory of a project it did not read")
    T.eq(#mock.listeners, 0)
end

function tests.a_project_refresh_keeps_watching_the_partitions()
    local mock, key, keyId = start(true)
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(listeners(mock, 81), 12)
    T.eq(#alarm(mock, key, keyId).json.partitions, 2)
    switch("Off")
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(listeners(mock, 81), 0, "and does not start watching them while it is Off")
end

function tests.a_partition_that_cannot_be_read_or_watched_is_left_out()
    local mock, key, keyId = start(true, function(m)
        m.project.variables[81][1007] = nil
        local register = C4.RegisterVariableListener
        function C4:RegisterVariableListener(deviceId, variableId)
            if deviceId == 82 and variableId == 1010 then
                error("listener refused")
            end
            return register(self, deviceId, variableId)
        end
    end)
    local items = alarm(mock, key, keyId).json.partitions
    T.eq(#items, 1)
    T.eq(items[1].id, 80)
    T.eq(listeners(mock, 81), 0)
    T.eq(listeners(mock, 82), 0, "what was watched before the refusal is let go")
    local log = table.concat(mock.debugLog, "\n")
    T.contains(log, "unsupported device 81: Partition State variable (1007) is unavailable")
    T.contains(log, "unsupported device 82: Unable to watch partition variable 1010")
    T.eq(mock.properties["Inventory"], INVENTORY .. ", 1 alarm partitions")
end

function tests.the_alarm_state_is_never_logged()
    local mock, key, keyId = start(true, function()
        Properties["Log Level"] = "Debug"
    end)
    Mock.setPartition(mock, 80, { PARTITION_STATE = "ALARM", ALARM_STATE = "1", ALARM_TYPE = "Burglary", TROUBLE_TEXT = "Siren tamper" })
    Mock.setPartition(mock, 81, { PARTITION_STATE = "ENTRY_DELAY", DELAY_TIME_REMAINING = "17" })
    T.eq(alarm(mock, key, keyId).status, 200)
    T.eq(T.http(mock, "GET", "/v1/alarm", { key = key }).status, 403)
    switch("Off")
    switch("On")
    local logs = T.http(mock, "GET", "/v1/logs?limit=500", { key = key })
    T.eq(logs.status, 200)
    local log = table.concat(mock.debugLog, "\n")
    for _, text in ipairs({ log, logs.body }) do
        for _, word in ipairs({ "ALARM", "Burglary", "Siren tamper", "ENTRY_DELAY", "DISARMED", "Away", "Keypad" }) do
            T.notContains(text, word, "no state in the log")
        end
    end
    T.contains(log, "alarm status off in Composer")
    T.contains(log, "alarm status on in Composer")
end

return tests
