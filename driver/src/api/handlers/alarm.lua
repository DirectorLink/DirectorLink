-- The home's alarm (ADR-038): GET /v1/alarm lists its partitions for admins and the members given
-- the alarm's status (ADR-054; others get 403). Off by default: until an installer sets the Composer
-- property Alarm Status to On, the answer says only that, and DirectorLink does not watch the
-- partitions. While it is on, the partitions go only into sealed answers, the app's way at home and
-- through the account: whether a home is armed never crosses a network in the clear. Nor does the
-- size of the sealed answer tell it: the answer is padded with spaces to the size it would have with
-- every partition at its longest.
--
-- Arming and disarming (1.15.0, ADR-091): POST /v1/alarm/{partitionId}/arm {"mode", "code"} and
-- /disarm {"code"}, only while Alarm Control is On in Composer too (it ships Off), by admins and the
-- members given it, in sealed requests, with the code the person typed for this command: it goes to
-- the alarm's driver and the panel checks it (src/control4/alarm_control.lua). The code is never
-- kept, logged or answered, and no problem names it. At most PERSON_LIMIT commands a person in
-- PERSON_SECONDS and HOME_LIMIT in the home in HOME_SECONDS (wrong codes are only the panel's to
-- know, so every command counts). The answer says the command was sent, not what the alarm did: the
-- partition's state, read again, says that. Each command goes into the history (kind "alarm"),
-- which only sealed reads show.
--
-- Without a code (1.16.0, ADR-092): an admin's setting (GET and PUT /v1/alarm/settings,
-- src/core/alarm_settings.lua) and the alarm's driver (its Composer property, said in
-- DIRECTORLINK_ALARM_WITHOUT_CODE) both decide how far: "none", "arm" or "arm_disarm"; the lower of
-- the two counts. Then `code` may be left out of an arm or a disarm it covers, and the driver uses
-- its own code. Such a disarm is said to the admins' phones (src/cloud/alerts.lua, alarm_disarmed).

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local Access = require("src.auth.access")
local Activity = require("src.core.activity")
local AlarmControl = require("src.control4.alarm_control")
local AlarmSettings = require("src.core.alarm_settings")

local Alarm = {}

Alarm.PERSON_LIMIT = 6
Alarm.PERSON_SECONDS = 5 * 60
Alarm.HOME_LIMIT = 20
Alarm.HOME_SECONDS = 60 * 60
-- An alarm code: digits only, as keypads take them.
Alarm.CODE_PATTERN = "^%d+$"
Alarm.CODE_MAX = 12

-- The commands' times, oldest first: per person (their profile, or the key without one) and the home.
local sent = { people = {}, home = {} }

-- Forgets the commands' times (tests).
function Alarm.reset()
    sent = { people = {}, home = {} }
end

-- How long `body` is inside a sealed answer, which carries it as a JSON string (src/cloud/remote.lua):
-- a quote or a backslash takes two bytes there.
local function sealedLength(body)
    return #Json.encode(body) - 2
end

-- Whether the caller arms and disarms from DirectorLink now, and whether the partition's driver says
-- it can (DirectorLink's alarm agreement); with the modes it arms in. None of it follows the
-- partition's state, so the padding still holds.
-- How far the partition goes without a code: the lower of the admins' setting and its driver's.
local function withoutCode(device)
    return AlarmControl.lower(AlarmSettings.withoutCode(), AlarmControl.driverWithoutCode(device))
end

local function controlView(ctx, device)
    local modes = Json.array()
    for _, mode in ipairs(AlarmControl.modes(device)) do
        modes[#modes + 1] = mode
    end
    return modes, {
        allowed = ctx.services.alarmControlEnabled() and Access.canControlAlarm(ctx.apiKey),
        available = AlarmControl.available(device),
        without_code = withoutCode(device),
    }
end

function Alarm.status(ctx)
    local services = ctx.services
    if not services.alarmStatusEnabled() then
        return 200, { enabled = false, partitions = Json.array() }
    end
    -- Only for those who see the alarm's status (ADR-054: admins, members given it).
    if not Access.canSeeAlarm(ctx.apiKey) then
        return Problem.new(403, "FORBIDDEN", "The alarm's status is not among this person's permissions")
    end
    -- Sealed requests carry their key as principal (src/cloud/remote.lua); a request with an
    -- Authorization header came as plain HTTP.
    if not (ctx.request and ctx.request.principal) then
        return Problem.new(403, "SEALED_REQUEST_REQUIRED",
            "The alarm status is sent only in sealed requests, as the DirectorLink app sends them; this request came in the clear")
    end
    local registry = services.registry
    local partitions, longest = Json.array(), Json.array()
    for _, device in ipairs(registry.alarmList()) do
        local view = Views.alarmPartition(registry, device)
        view.modes, view.control = controlView(ctx, device)
        -- The alarm is the home's; a partition's room only when the caller sees that room (ADR-054).
        if not Access.seesRoom(ctx.apiKey, device.room_id) then
            view.room = Json.null
        end
        partitions[#partitions + 1] = view
        longest[#longest + 1] = Views.alarmPartitionLongest(view)
    end
    -- The same size, sealed, in every state: it depends only on the partitions there are (their
    -- names and rooms), never on whether they are armed. JSON allows the spaces after the value.
    local body = Json.encode({ enabled = true, partitions = partitions })
    local size = sealedLength(Json.encode({ enabled = true, partitions = longest }))
    return 200, body .. string.rep(" ", size - sealedLength(body))
end

-- ---- arming and disarming (1.15.0, ADR-091) ---------------------------------------------------------

-- Drops the times older than `seconds`; then true when there is room under `limit`, or false and
-- how many seconds until there is.
local function room(list, now, limit, seconds)
    while #list > 0 and (now - list[1] >= seconds or list[1] > now) do
        table.remove(list, 1)
    end
    if #list >= limit then
        return false, math.max(1, seconds - (now - list[1]))
    end
    return true
end

local function personOf(apiKey)
    local profile = apiKey and (apiKey.profile or apiKey.profile_id)
    if profile ~= nil then
        return "p:" .. tostring(profile)
    end
    return "k:" .. tostring(apiKey and apiKey.id)
end

-- The partition named in the path, as GET /v1/alarm lists it, or nil and a problem.
local function findPartition(ctx)
    local id, problem = Validate.id(ctx.params.partitionId, "partitionId")
    if problem then
        return nil, problem
    end
    for _, device in ipairs(ctx.services.registry.alarmList()) do
        if tonumber(device.id) == id and (device.state == nil or device.state.active ~= false) then
            return device
        end
    end
    return nil, Problem.notFound("Partition", id)
end

-- The code a person typed, or nil and a problem that never names it.
local function readCode(body)
    local code = body.code
    if type(code) ~= "string" or #code > Alarm.CODE_MAX or not code:match(Alarm.CODE_PATTERN) then
        return nil, Problem.invalidField("code", "code must be the alarm code a person typed: 1 to " .. Alarm.CODE_MAX .. " digits")
    end
    return code
end

local function absent(value)
    return value == nil or value == Json.null
end

local function command(ctx, action)
    local services = ctx.services
    if not Access.canSeeAlarm(ctx.apiKey) or not Access.canControlAlarm(ctx.apiKey) then
        return Problem.new(403, "FORBIDDEN", "Arming and disarming the alarm is not among this person's permissions")
    end
    if not services.alarmControlEnabled() then
        return Problem.new(403, "ALARM_CONTROL_DISABLED",
            "Arming and disarming is off; turn on the Alarm Status and Alarm Control properties of DirectorLink in Composer")
    end
    if not (ctx.request and ctx.request.principal) then
        return Problem.new(403, "SEALED_REQUEST_REQUIRED",
            "The alarm is armed and disarmed only in sealed requests, as the DirectorLink app sends them; this request came in the clear")
    end
    local device, problem = findPartition(ctx)
    if not device then
        return problem
    end
    local body = ctx.body
    problem = Validate.body(body, action == "arm" and { mode = true, code = true } or { code = true })
    if problem then
        return problem
    end
    local mode
    if action == "arm" then
        mode = AlarmControl.mode(device, body.mode)
        if not mode then
            local modes = AlarmControl.modes(device)
            if #modes == 0 then
                return Problem.new(409, "NO_ARM_MODES", "The alarm's driver declares no modes to arm in; arm it from its keypad")
            end
            return Problem.invalidField("mode", "mode must be one of the partition's modes: " .. table.concat(modes, ", "))
        end
    end
    local code
    if absent(body.code) then
        -- Without a code, only as far as both the admins and the alarm's driver allow (ADR-092).
        if not AlarmControl.allows(withoutCode(device), action) then
            return Problem.new(400, "CODE_REQUIRED", "This alarm needs a code to " .. action .. ": type it, or an admin allows it without one")
        end
    else
        code, problem = readCode(body)
        if not code then
            return problem
        end
    end
    if not AlarmControl.available(device) then
        return Problem.new(409, "ALARM_UNAVAILABLE",
            "The alarm's driver says it cannot arm or disarm now (its panel only reports, or is not connected)")
    end
    local now = os.time()
    local person = personOf(ctx.apiKey)
    sent.people[person] = sent.people[person] or {}
    local ok, wait = room(sent.people[person], now, Alarm.PERSON_LIMIT, Alarm.PERSON_SECONDS)
    if ok then
        ok, wait = room(sent.home, now, Alarm.HOME_LIMIT, Alarm.HOME_SECONDS)
    end
    if not ok then
        services.log.warn("alarm", "alarm commands limited", { key_id = ctx.apiKey and ctx.apiKey.id or Json.null, retry_after = wait })
        return Problem.new(429, "RATE_LIMITED", "Too many alarm commands; try again later", { retry_after = wait }),
            { { "Retry-After", tostring(wait) } }
    end
    table.insert(sent.people[person], now)
    table.insert(sent.home, now)
    local delivered
    if action == "arm" then
        delivered = AlarmControl.arm(device, mode, code)
    else
        delivered = AlarmControl.disarm(device, code)
    end
    if not delivered then
        return Problem.new(502, "CONTROLLER_COMMAND_FAILED", "Director did not take the command for the alarm")
    end
    Activity.record("alarm", action, {
        by = ctx.apiKey,
        what = device.name,
        room = device.room_name,
        note = mode,
        reason = code == nil and "without_code" or nil,
        ids = { device_id = device.id, room_id = device.room_id },
    })
    return 202, { partition_id = device.id, action = action, mode = mode or Json.null, without_code = code == nil }
end

-- POST /v1/alarm/{partitionId}/arm {"mode": "Away", "code": "1234"}
function Alarm.arm(ctx)
    return command(ctx, "arm")
end

-- POST /v1/alarm/{partitionId}/disarm {"code": "1234"}
function Alarm.disarm(ctx)
    return command(ctx, "disarm")
end

-- GET /v1/alarm/settings (admins): { without_code }.
function Alarm.settings(ctx)
    return 200, { without_code = AlarmSettings.withoutCode() }
end

-- PUT /v1/alarm/settings (admins): { "without_code": "none" | "arm" | "arm_disarm" }.
function Alarm.set_settings(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { without_code = true }, true)
    if problem then
        return problem
    end
    if not AlarmSettings.LEVELS[body.without_code] then
        return Problem.invalidField("without_code", "without_code is none, arm or arm_disarm")
    end
    local before = AlarmSettings.withoutCode()
    if not AlarmSettings.setWithoutCode(body.without_code) then
        return Problem.internal("The alarm settings could not be saved")
    end
    if before ~= body.without_code then
        Activity.record("alarm", "settings", { by = ctx.apiKey, from = before, to = body.without_code })
    end
    return 200, { without_code = AlarmSettings.withoutCode() }
end

return Alarm
