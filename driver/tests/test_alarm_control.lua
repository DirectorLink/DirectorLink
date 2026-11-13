-- Arming and disarming the alarm (1.15.0, ADR-091): POST /v1/alarm/{id}/arm and /disarm, only with
-- Alarm Status and Alarm Control On, by admins and the members given it, sealed, with the code a
-- person typed, which goes to the partition and nowhere else; the modes a driver declares; what a
-- driver of DirectorLink's alarm agreement says; the limits; the history, only in sealed reads.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local CODE = "2580"

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

-- The default project with the partitions (Mock.withPartitions: 80 House, 81 Garage, 82 unused, on
-- the Alarm Panel driver 130, which declares Away, Home and Night); Alarm Status On, Alarm Control
-- On unless `control` is false. An admin key paired at home.
local function start(control, prepare)
    local mock = Mock.startDriver(Mock.withPartitions(Mock.project()), nil, nil, function(m)
        Properties["Alarm Status"] = "On"
        Properties["Alarm Control"] = control == false and "Off" or "On"
        if prepare then
            prepare(m)
        end
    end)
    require("src.control4.alarm_control").reset()
    require("src.api.handlers.alarm").reset()
    local key = T.pair(mock)
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    return mock, key, me.id, me.profile_id
end

local counter = 0

-- A request sealed at home, as the app sends it; returns the opened answer, `json` decoded.
local function sealed(mock, key, keyId, request)
    local Lock = require("src.cloud.lock")
    local info = T.http(mock, "GET", "/v1/sealed").json
    counter = counter + 1
    request.id = request.id or ("control-" .. counter)
    request.ts = request.ts or info.time
    local lock = Lock.deviceKey(key)
    local envelope = Lock.seal(lock, info.home, keyId, "req", Json.encode(request))
    local response = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer
end

local function post(mock, key, keyId, path, body)
    return sealed(mock, key, keyId, { method = "POST", path = path, body = body })
end

local function partition(mock, key, keyId, id)
    for _, item in ipairs(sealed(mock, key, keyId, { method = "GET", path = "/v1/alarm" }).json.partitions) do
        if item.id == id then
            return item
        end
    end
end

local function member(mock, admin, access)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Kid", role = "member", access = access } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json.id
end

local function sentTo(mock, from)
    local list = {}
    for i = from + 1, #mock.commands do
        list[#list + 1] = mock.commands[i]
    end
    return list
end

local function everythingSaid(mock)
    return table.concat(mock.debugLog, "\n")
end

function tests.off_by_default_the_app_only_shows_the_alarm()
    local mock, key, keyId = start(false)
    local system = T.http(mock, "GET", "/v1/system", { key = key }).json
    T.eq(system.features.alarm_arming, true)
    T.eq(system.features.alarm_control, false)
    local garage = partition(mock, key, keyId, 81)
    T.same(garage.modes, { "Away", "Home", "Night" })
    T.eq(garage.control.allowed, false, "Alarm Control is Off")
    T.eq(garage.control.available, true, "a driver that keeps no agreement is not asked")
    local before = #mock.commands
    local answer = post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE })
    T.eq(answer.status, 403)
    T.eq(answer.json.code, "ALARM_CONTROL_DISABLED")
    T.eq(#sentTo(mock, before), 0, "nothing was sent")
    -- Alarm Control alone does nothing without Alarm Status.
    Properties["Alarm Status"] = "Off"
    Properties["Alarm Control"] = "On"
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.features.alarm_control, false)
    T.eq(post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE }).json.code, "ALARM_CONTROL_DISABLED")
end

function tests.an_admin_disarms_and_arms_with_the_code_they_typed()
    local mock, key, keyId = start()
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.features.alarm_control, true)
    T.eq(partition(mock, key, keyId, 81).control.allowed, true)
    local before = #mock.commands
    local answer = post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE })
    T.eq(answer.status, 202, answer.body)
    T.eq(answer.json.partition_id, 81)
    T.eq(answer.json.action, "disarm")
    T.eq(isNull(answer.json.mode), true)
    answer = post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "away", code = "1470" })
    T.eq(answer.status, 202, answer.body)
    T.eq(answer.json.mode, "Away", "the driver's own word for the mode")
    local sent = sentTo(mock, before)
    T.eq(#sent, 2)
    T.eq(sent[1].device, 81)
    T.eq(sent[1].command, "PARTITION_DISARM")
    T.same(sent[1].params, { UserCode = CODE, InterfaceID = "DirectorLink" })
    T.eq(sent[1].log, false, "Director does not log the command")
    T.eq(sent[2].device, 80)
    T.eq(sent[2].command, "PARTITION_ARM")
    T.same(sent[2].params, { ArmType = "Away", UserCode = "1470", InterfaceID = "DirectorLink" })
    T.eq(sent[2].log, false)
    -- The code goes nowhere else: not the log, not an answer.
    T.notContains(everythingSaid(mock), CODE)
    T.notContains(everythingSaid(mock), "1470")
    T.notContains(answer.body, "1470")
end

function tests.every_mode_the_driver_declares_and_no_other()
    local mock, key, keyId = start()
    for _, mode in ipairs({ "Away", "home", "NIGHT" }) do
        T.eq(post(mock, key, keyId, "/v1/alarm/80/arm", { mode = mode, code = CODE }).status, 202, mode)
    end
    local before = #mock.commands
    local wrong = post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "Vacation", code = CODE })
    T.eq(wrong.status, 400)
    T.eq(wrong.json.code, "INVALID_FIELD")
    T.contains(wrong.json.detail, "Away, Home, Night")
    T.eq(post(mock, key, keyId, "/v1/alarm/80/arm", { code = CODE }).status, 400, "arming needs a mode")
    T.eq(#sentTo(mock, before), 0)
end

function tests.a_driver_that_declares_no_modes_is_disarmed_but_not_armed()
    local mock, key, keyId = start(true, function(m)
        m.project.deviceData[130] = nil
    end)
    local garage = partition(mock, key, keyId, 81)
    T.eq(#garage.modes, 0)
    local arm = post(mock, key, keyId, "/v1/alarm/81/arm", { mode = "Away", code = CODE })
    T.eq(arm.status, 409)
    T.eq(arm.json.code, "NO_ARM_MODES")
    T.eq(post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE }).status, 202)
end

function tests.the_code_is_digits_a_person_typed_and_never_in_a_problem()
    local mock, key, keyId = start()
    local before = #mock.commands
    for _, code in ipairs({ "12a4", "", " 1234", "1234567890123", "١٢٣٤" }) do
        local answer = post(mock, key, keyId, "/v1/alarm/81/disarm", { code = code })
        T.eq(answer.status, 400, code)
        T.eq(answer.json.code, "INVALID_FIELD", code)
        if code ~= "" then
            T.notContains(answer.body, code)
        end
    end
    for _, body in ipairs({ { code = 1234 }, {}, { code = CODE, mode = "Away" }, { code = CODE, user = "x" } }) do
        T.eq(post(mock, key, keyId, "/v1/alarm/81/disarm", body).status, 400)
    end
    T.eq(#sentTo(mock, before), 0, "nothing was sent")
end

function tests.only_in_sealed_requests()
    local mock, key = start()
    local before = #mock.commands
    local plain = T.http(mock, "POST", "/v1/alarm/81/disarm", { key = key, body = { code = CODE } })
    T.eq(plain.status, 403)
    T.eq(plain.json.code, "SEALED_REQUEST_REQUIRED")
    T.eq(#sentTo(mock, before), 0)
end

function tests.members_only_when_an_admin_gives_it_and_with_the_alarm_status()
    local mock, admin, adminId = start()
    local kid, kidId = member(mock, admin, {})
    T.eq(T.http(mock, "GET", "/v1/api-keys/current", { key = kid }).json.access.alarm_control, false, "off for a new member")
    T.eq(T.http(mock, "GET", "/v1/api-keys/current", { key = admin }).json.access.alarm_control, true, "an admin always")
    T.eq(partition(mock, kid, kidId, 81).control.allowed, false)
    local before = #mock.commands
    local refused = post(mock, kid, kidId, "/v1/alarm/81/disarm", { code = CODE })
    T.eq(refused.status, 403)
    T.eq(refused.json.code, "FORBIDDEN")

    local profile = T.http(mock, "GET", "/v1/api-keys/current", { key = kid }).json.profile_id
    local patched = T.http(mock, "PATCH", "/v1/profiles/" .. profile .. "/access", { key = admin, body = { alarm_control = true } })
    T.eq(patched.status, 200, patched.body)
    T.eq(patched.json.alarm_control, true)
    T.eq(partition(mock, kid, kidId, 81).control.allowed, true)
    T.eq(post(mock, kid, kidId, "/v1/alarm/81/disarm", { code = CODE }).status, 202)

    -- Without the alarm's status, arming and disarming go too, though the record keeps it.
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profile .. "/access", { key = admin, body = { alarm = false } }).status, 200)
    T.eq(T.http(mock, "GET", "/v1/api-keys/current", { key = kid }).json.access.alarm_control, false)
    T.eq(post(mock, kid, kidId, "/v1/alarm/81/disarm", { code = CODE }).json.code, "FORBIDDEN")
    T.eq(#sentTo(mock, before), 1, "only the allowed disarm")
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profile .. "/access", { key = admin, body = { alarm_control = "yes" } }).status, 400)
    T.eq(post(mock, admin, adminId, "/v1/alarm/81/disarm", { code = CODE }).status, 202)
end

function tests.never_directorlink_itself()
    start()
    local Access = require("src.auth.access")
    T.eq(Access.canControlAlarm({ system = true }), false)
    T.eq(Access.canControlAlarm({ id = "schedule:abc" }), false)
    T.eq(Access.canControlAlarm({ id = "link:abc" }), false)
    T.eq(Access.canControlAlarm(nil), false)
end

function tests.a_partition_not_in_use_or_unknown_is_not_found()
    local mock, key, keyId = start()
    local before = #mock.commands
    T.eq(post(mock, key, keyId, "/v1/alarm/82/disarm", { code = CODE }).status, 404, "IS_ACTIVE = 0")
    T.eq(post(mock, key, keyId, "/v1/alarm/999/disarm", { code = CODE }).status, 404)
    T.eq(post(mock, key, keyId, "/v1/alarm/20/disarm", { code = CODE }).status, 404, "a light")
    T.eq(post(mock, key, keyId, "/v1/alarm/x/disarm", { code = CODE }).status, 400)
    T.eq(#sentTo(mock, before), 0)
end

function tests.a_driver_of_the_agreement_says_when_it_cannot()
    local mock, key, keyId = start(true, function(m)
        m.project.variables[130] = { [1] = "1", [2] = "0" }
        m.project.variableNames = m.project.variableNames or {}
        m.project.variableNames[130] = { [1] = "DIRECTORLINK_ALARM", [2] = "DIRECTORLINK_ALARM_CONTROL" }
    end)
    local garage = partition(mock, key, keyId, 81)
    T.eq(garage.control.allowed, true)
    T.eq(garage.control.available, false, "its panel only reports")
    local before = #mock.commands
    local answer = post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE })
    T.eq(answer.status, 409)
    T.eq(answer.json.code, "ALARM_UNAVAILABLE")
    T.eq(#sentTo(mock, before), 0)
    -- Its panel connects: read again within AVAILABLE_SECONDS.
    mock.project.variables[130][2] = "1"
    local realTime = os.time
    local now = realTime()
    os.time = function(date)
        if date then
            return realTime(date)
        end
        return now + 6
    end
    local ok, err = pcall(function()
        T.eq(partition(mock, key, keyId, 81).control.available, true)
        T.eq(post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE }).status, 202)
    end)
    os.time = realTime
    assert(ok, err)
    -- A marker that is no version of the agreement is no agreement.
    mock.project.variables[130] = { [1] = "yes", [2] = "0" }
    require("src.control4.alarm_control").reset()
    T.eq(partition(mock, key, keyId, 81).control.available, true)
end

function tests.at_most_six_commands_a_person_in_five_minutes_and_twenty_an_hour_in_the_home()
    local mock, admin, adminId = start()
    for i = 1, 6 do
        T.eq(post(mock, admin, adminId, "/v1/alarm/81/disarm", { code = CODE }).status, 202, "command " .. i)
    end
    local before = #mock.commands
    local limited = post(mock, admin, adminId, "/v1/alarm/81/disarm", { code = CODE })
    T.eq(limited.status, 429)
    T.eq(limited.json.code, "RATE_LIMITED")
    T.eq(limited.json.retry_after > 0 and limited.json.retry_after <= 300, true)
    T.eq(#sentTo(mock, before), 0)
    T.contains(everythingSaid(mock), "alarm commands limited")
    -- Another person still may, until the home's twenty.
    local others = {}
    for i = 1, 3 do
        local key, id = member(mock, admin, { alarm_control = true })
        others[i] = { key = key, id = id }
    end
    local sent = 6
    for _, other in ipairs(others) do
        for _ = 1, 6 do
            local status = post(mock, other.key, other.id, "/v1/alarm/81/disarm", { code = CODE }).status
            if sent < 20 then
                T.eq(status, 202)
                sent = sent + 1
            else
                T.eq(status, 429, "the home's twenty")
            end
        end
    end
    T.eq(sent, 20)
end

function tests.a_command_director_refuses_is_502_and_names_nothing()
    local mock, key, keyId = start(true, function(m)
        m.project.sendFails = { [81] = true }
    end)
    local answer = post(mock, key, keyId, "/v1/alarm/81/disarm", { code = CODE })
    T.eq(answer.status, 502)
    T.eq(answer.json.code, "CONTROLLER_COMMAND_FAILED")
    T.notContains(answer.body, CODE)
    T.notContains(everythingSaid(mock), CODE)
end

function tests.the_history_has_each_command_only_in_sealed_reads()
    local mock, key, keyId = start()
    T.eq(post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "Night", code = CODE }).status, 202)
    T.eq(post(mock, key, keyId, "/v1/alarm/80/disarm", { code = CODE }).status, 202)
    local read = sealed(mock, key, keyId, { method = "GET", path = "/v1/activity?kind=alarm" })
    T.eq(read.status, 200, read.body)
    local items = read.json.items
    T.eq(#items, 2)
    T.eq(items[1].kind, "alarm")
    T.eq(items[1].action, "disarm")
    T.eq(items[2].action, "arm")
    T.eq(items[2].note, "Night")
    T.eq(items[2].what, "House")
    T.eq(items[2].who.type, "key")
    T.notContains(read.body, CODE)
    -- In the clear (the API console, a script): never.
    local plain = T.http(mock, "GET", "/v1/activity", { key = key })
    T.eq(plain.status, 200)
    for _, item in ipairs(plain.json.items) do
        T.eq(item.kind ~= "alarm", true, "no alarm entry in the clear")
    end
    T.eq(#T.http(mock, "GET", "/v1/activity?kind=alarm", { key = key }).json.items, 0)
end

function tests.the_sealed_answer_keeps_its_size_whatever_the_driver_says()
    local mock, key, keyId = start(true, function(m)
        m.project.variables[130] = { [1] = "1", [2] = "1" }
        m.project.variableNames = m.project.variableNames or {}
        m.project.variableNames[130] = { [1] = "DIRECTORLINK_ALARM", [2] = "DIRECTORLINK_ALARM_CONTROL" }
    end)
    local first = sealed(mock, key, keyId, { method = "GET", path = "/v1/alarm" })
    mock.project.variables[130][2] = "0"
    require("src.control4.alarm_control").reset()
    Properties["Alarm Control"] = "Off"
    local second = sealed(mock, key, keyId, { method = "GET", path = "/v1/alarm" })
    T.eq(#second.body, #first.body)
    T.eq(second.json.partitions[1].control.available, false)
end

function tests.the_driver_modes_are_read_from_its_capabilities()
    local AlarmControl = require("src.control4.alarm_control")
    T.same(AlarmControl.parseModes("<arm_states>Away,Home,Night</arm_states>"), { "Away", "Home", "Night" })
    T.same(AlarmControl.parseModes("&lt;arm_states&gt;Stay, Away ,Stay(No Delay),,Away&lt;/arm_states&gt;"), { "Stay", "Away", "Stay(No Delay)" })
    T.same(AlarmControl.parseModes("<devicedata><capabilities><arm_states>Home,Vacation</arm_states></capabilities></devicedata>"), { "Home", "Vacation" })
    T.same(AlarmControl.parseModes("<!-- <arm_states>A</arm_states> -->"), {})
    T.same(AlarmControl.parseModes(nil), {})
    local many = {}
    for i = 1, 12 do
        many[i] = "Mode " .. i
    end
    T.eq(#AlarmControl.parseModes("<arm_states>" .. table.concat(many, ",") .. "</arm_states>"), AlarmControl.MAX_MODES)
    T.eq(#AlarmControl.parseModes("<arm_states>" .. string.rep("x", 50) .. "</arm_states>")[1], AlarmControl.MODE_BYTES)
end


-- ---- version 2 of the agreement: the command sealed to the driver, and without a code (1.16.0) --

local Base64 = require("src.core.base64")
local X25519 = require("src.core.x25519")

-- The fake alarm driver's (130) key pair: a fixed private key, as a driver keeps its own.
local DRIVER_SECRET = string.rep(string.char(77), 32)

local function hmacHex(keyHex, data)
    return C4:HMAC("SHA256", keyHex, data, { key_encoding = "HEX", data_encoding = "NONE", return_encoding = "HEX" }):lower()
end

-- Driver 130 keeps the agreement's version `version` (2 with its key), able now, and lets
-- DirectorLink go without a code as far as `level` says.
local function agreement(version, level)
    return function(m)
        local public = Base64.toHex(X25519.publicKey(DRIVER_SECRET))
        m.project.variables[130] = { [1] = tostring(version), [2] = "1", [3] = version >= 2 and public or "", [4] = level or "none" }
        m.project.variableNames = m.project.variableNames or {}
        m.project.variableNames[130] = {
            [1] = "DIRECTORLINK_ALARM", [2] = "DIRECTORLINK_ALARM_CONTROL",
            [3] = "DIRECTORLINK_ALARM_KEY", [4] = "DIRECTORLINK_ALARM_WITHOUT_CODE",
        }
    end
end

-- Opens a sealed command as the driver does: its fields, after the MAC checked out.
local function openToken(token)
    T.eq(token:sub(1, 4), "dl2:", "a sealed command")
    local raw = assert(Base64.decode(token:sub(5)))
    local public, iv = raw:sub(1, 32), raw:sub(33, 48)
    local ct, mac = raw:sub(49, #raw - 32), raw:sub(#raw - 31)
    local shared = assert(X25519.shared(DRIVER_SECRET, public))
    local prk = hmacHex(Base64.toHex(shared), "DirectorLink alarm v2" .. public .. X25519.publicKey(DRIVER_SECRET))
    local encKey, macKey = hmacHex(prk, "enc"), hmacHex(prk, "mac")
    T.eq(hmacHex(macKey, public .. iv .. ct), Base64.toHex(mac), "the MAC checks out")
    local plaintext = C4:Decrypt("AES-256-CBC", encKey, Base64.toHex(iv), Base64.toHex(ct), {
        key_encoding = "HEX", iv_encoding = "HEX", data_encoding = "HEX", return_encoding = "NONE", padding = true,
    })
    return Json.decode(plaintext), public
end

local function admin(mock, key, path, body)
    return T.http(mock, path and "PUT" or "GET", "/v1/alarm/settings", { key = key, body = body })
end

function tests.a_driver_of_version_2_gets_every_command_sealed_never_the_code()
    local mock, key, keyId = start(true, agreement(2, "none"))
    local before = #mock.commands
    local started = os.time()
    T.eq(post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "away", code = CODE }).status, 202)
    T.eq(post(mock, key, keyId, "/v1/alarm/80/disarm", { code = CODE }).status, 202)
    local sent = sentTo(mock, before)
    T.eq(#sent, 2)
    T.eq(sent[1].params.ArmType, "Away")
    T.eq(sent[1].params.InterfaceID, "DirectorLink")
    T.eq(sent[1].log, false)
    local arm, armKey = openToken(sent[1].params.UserCode)
    local disarm, disarmKey = openToken(sent[2].params.UserCode)
    T.eq(arm.v, 2)
    T.eq(arm.a, "arm")
    T.eq(arm.m, "Away")
    T.eq(arm.c, CODE)
    T.eq(#arm.n, 16)
    -- Pure-Lua X25519 is slow: the time is between the test's start and now, however long that took.
    T.eq(arm.t >= started and arm.t <= os.time(), true, "the controller's time")
    T.eq(disarm.a, "disarm")
    T.eq(isNull(disarm.m), true)
    T.eq(disarm.c, CODE)
    T.eq(armKey ~= disarmKey, true, "a fresh key each command")
    T.eq(arm.n ~= disarm.n, true, "a fresh nonce each command")
    for _, command in ipairs(sent) do
        T.notContains(Json.encode(command.params), CODE, "the code is in no parameter Director sees")
    end
end

function tests.without_a_code_only_as_far_as_the_admins_and_the_driver_both_allow()
    local mock, key, keyId = start(true, agreement(2, "arm"))
    -- The admins' setting ships "none": a code each time.
    T.same(admin(mock, key).json, { without_code = "none" })
    T.eq(partition(mock, key, keyId, 80).control.without_code, "none")
    local refused = post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "Away" })
    T.eq(refused.status, 400)
    T.eq(refused.json.code, "CODE_REQUIRED")
    -- The admins allow both; the driver allows arming only: arming only.
    T.same(admin(mock, key, true, { without_code = "arm_disarm" }).json, { without_code = "arm_disarm" })
    T.eq(partition(mock, key, keyId, 80).control.without_code, "arm")
    local before = #mock.commands
    local armed = post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "Home" })
    T.eq(armed.status, 202, armed.body)
    T.eq(armed.json.without_code, true)
    local command = openToken(sentTo(mock, before)[1].params.UserCode)
    T.eq(isNull(command.c), true, "no code: the driver uses its own")
    T.eq(command.m, "Home")
    T.eq(post(mock, key, keyId, "/v1/alarm/80/disarm", {}).json.code, "CODE_REQUIRED")
    T.eq(post(mock, key, keyId, "/v1/alarm/80/disarm", { code = CODE }).status, 202, "a typed code still goes")
    -- The driver allows both too: disarming without a code.
    mock.project.variables[130][4] = "arm_disarm"
    require("src.control4.alarm_control").reset()
    T.eq(partition(mock, key, keyId, 80).control.without_code, "arm_disarm")
    T.eq(post(mock, key, keyId, "/v1/alarm/80/disarm", { code = Json.null }).status, 202)
    -- The admins narrow it again: arming only.
    admin(mock, key, true, { without_code = "arm" })
    T.eq(post(mock, key, keyId, "/v1/alarm/80/disarm", {}).json.code, "CODE_REQUIRED")
    local history = sealed(mock, key, keyId, { method = "GET", path = "/v1/activity?kind=alarm" }).json.items
    local reasons = {}
    for _, item in ipairs(history) do
        reasons[#reasons + 1] = item.action .. ":" .. tostring(item.reason)
    end
    T.same(reasons, { "settings:nil", "disarm:without_code", "disarm:nil", "arm:without_code", "settings:nil" })
end

function tests.a_driver_of_version_1_never_gets_a_command_without_a_code()
    local mock, key, keyId = start(true, agreement(1, "arm_disarm"))
    admin(mock, key, true, { without_code = "arm_disarm" })
    T.eq(partition(mock, key, keyId, 80).control.without_code, "none", "no key, no sealed command")
    T.eq(post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "Away" }).json.code, "CODE_REQUIRED")
    local before = #mock.commands
    T.eq(post(mock, key, keyId, "/v1/alarm/80/arm", { mode = "Away", code = CODE }).status, 202)
    T.eq(sentTo(mock, before)[1].params.UserCode, CODE, "as 1.15.0 sent it")
end

function tests.the_settings_are_the_admins()
    local mock, key = start(true)
    local member = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Kid", role = "member", access = { alarm_control = true } } }).json.key
    T.eq(admin(mock, member).status, 403)
    T.eq(admin(mock, member, true, { without_code = "arm" }).status, 403)
    T.eq(admin(mock, key, true, { without_code = "always" }).status, 400)
    T.eq(admin(mock, key, true, {}).status, 400)
    T.eq(admin(mock, key, true, { without_code = "arm", other = 1 }).status, 400)
    T.same(admin(mock, key).json, { without_code = "none" })
    local AlarmSettings = require("src.core.alarm_settings")
    T.eq(admin(mock, key, true, { without_code = "arm" }).status, 200)
    AlarmSettings.reset()
    T.eq(AlarmSettings.withoutCode(), "arm", "kept across a restart")
end

function tests.a_disarm_without_a_code_is_told_to_the_admins_only()
    local Harness = require("relay_harness")
    local mock, key, keyId = start(true, agreement(2, "arm_disarm"))
    local _, connection = Harness.connected({ mock = mock })
    admin(mock, key, true, { without_code = "arm_disarm" })
    local member, memberId = member(mock, key, { alarm_control = true })
    T.eq(T.http(mock, "PUT", "/v1/alerts/choices", { key = key, body = { on = true } }).status, 200)
    local memberChoices = T.http(mock, "PUT", "/v1/alerts/choices", { key = member, body = { on = true, kinds = { alarm_disarmed = true } } }).json
    T.eq(memberChoices.kinds.alarm_disarmed, nil, "admins only")
    T.eq(T.http(mock, "GET", "/v1/alerts/choices", { key = key }).json.kinds.alarm_disarmed, true, "on unless turned off")
    connection.sent = ""
    T.eq(post(mock, member, memberId, "/v1/alarm/81/disarm", {}).status, 202)
    local notified = {}
    for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" and message.type == "notify" then
            notified[#notified + 1] = message
        end
    end
    T.eq(#notified, 1)
    local recipients = 0
    for id in pairs(notified[1]["for"]) do
        recipients = recipients + 1
        T.eq(id, keyId, "the admin")
    end
    T.eq(recipients, 1)
    -- With a typed code: nothing to tell.
    connection.sent = ""
    T.eq(post(mock, member, memberId, "/v1/alarm/81/disarm", { code = CODE }).status, 202)
    for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
        local message = Json.decode(frame.payload)
        T.eq(type(message) == "table" and message.type == "notify", false, "no alert for a typed code")
    end
end

function tests.the_sealed_command_matches_the_shared_vector()
    local file = assert(io.open("tests/vectors/alarm_command.json", "rb"))
    local vector = Json.decode(file:read("*a"))
    file:close()
    start(true)
    local token = require("src.control4.alarm_control").token(vector.driver_public,
        { a = vector.fields.a, m = vector.fields.m, c = vector.fields.c },
        Base64.fromHex(vector.ephemeral_secret), Base64.fromHex(vector.iv), vector.fields.n, vector.fields.t)
    T.eq(token, vector.token)
    T.eq(Base64.toHex(X25519.publicKey(DRIVER_SECRET)), vector.driver_public)
end

return tests
