local Clock = require("src.core.clock")
local Log = require("src.core.log")

-- Blind proxy (blind.c4i). Commands are the proxy's own: SET_LEVEL_TARGET {LEVEL_TARGET} and STOP.
-- The protocol driver reports MOVING {LEVEL_TARGET, RAMP_RATE, LEVEL} and STOPPED {LEVEL} to the
-- proxy, which keeps its variables and tells Control4's apps (<moving><level>100</level>
-- <level_target>0</level_target>..., then <stopped>...). On Director 3.4.3 with KNX blinds they are
-- 1000 Open, 1001 Fully Closed, 1002 Stopped, 1003 Fully Open, 1004 Level, 1005 Target Level,
-- 1006 Type, 1007 Movement, 1008 Opening and 1009 Closing; they are found by name. Whether a shade
-- moves is told by Opening, Closing and Stopped (Snap One's proxy documentation). Movement is the
-- shade's movement type (Up to Down, Down to Up, ...), not whether it moves: it is only logged.
-- On that controller Stopped, Opening and Closing read "1"/"0", and Movement "Up-Down",
-- "Left-Right" or "Right-Left"; a move reads Stopped 0, then Target Level, then Opening or Closing
-- 1, and its end Level = Target Level, then Stopped 1. Each change is still logged at debug level
-- with its raw value. A Level outside the shade's range is unknown: -255 after a
-- reboot on a blind without a KNX status address, -155 when the actuator reports 255 ("position
-- unknown"). The proxy sets Level when a move starts (where it starts from), when it ends (the
-- driver's timer) and whenever the actuator reports, on KNX about a second after the stop.
--
-- What a shade can do comes from the proxy's setup, which Control4's own apps read with the UI
-- request GET_SETUP: <blind_setup><has_level>True</has_level><level_discrete_control>True
-- </level_discrete_control><can_stop>True</can_stop>...<levels minimum="0" maximum="100" ...>
-- <level name="Closed" ... level="0" .../><level name="Open" ... level="100" .../>...
-- level_discrete_control is False on shades that only open and close fully (a KNX blind without a
-- percent address, whose driver sends up for any target above 0). The Closed and Open levels are
-- the shade's range: 0 and 100 on KNX, and the API shows another range (0 closed, 2 open) as 0 to
-- 100 too. Without a usable answer a shade is taken to do both, from 0 to 100, as before 1.1.0.
local Blind = {}

-- The setup is read again when the blinds are listed and it is older than this: an installer can
-- change the protocol driver without changing the project.
Blind.SETUP_TTL_SECONDS = 600

-- A move that starts reads Stopped 0, then the new Target Level, then Opening or Closing 1 within
-- milliseconds. On a proxy that has Opening and Closing, the new Target Level counts as a move for
-- at most this long before they say so.
Blind.MOVE_START_SECONDS = 5

-- Proxy variables by what they tell, as the names they may have. Movement is only logged.
local VARIABLES = {
    level = { ["level"] = true, ["current level"] = true },
    target = { ["target level"] = true, ["level target"] = true },
    stopped = { ["stopped"] = true },
    opening = { ["opening"] = true },
    closing = { ["closing"] = true },
    movement = { ["movement"] = true },
}

local tracked = {}
-- The setup last logged for each blind; kept across a project refresh, so it is logged again only
-- when it changes.
local loggedSetups = {}

-- A level as a position from 0 (closed) to 100 (open); nil when it is outside the shade's range
-- (unknown). `range`: { closed, open, unknown } for a shade whose levels are not 0 to 100.
local function position(value, range)
    local number = tonumber(value)
    if not number then
        return nil
    end
    if range then
        if number < range.closed or number > range.open or number == range.unknown then
            return nil
        end
        number = (number - range.closed) * 100 / (range.open - range.closed)
    elseif number < 0 or number > 100 then
        return nil
    end
    return math.floor(number + 0.5)
end

-- The level to send for a position from 0 to 100.
local function levelOf(target, range)
    target = math.floor(target + 0.5)
    if not range then
        return target
    end
    return range.closed + math.floor((range.open - range.closed) * target / 100 + 0.5)
end

-- True or false as a variable or the setup says it ("1", "True", " false ", ...); nil when it says
-- neither.
local function flag(value)
    local text = string.lower(tostring(value or "")):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "1" or text == "true" or text == "yes" or text == "on" then
        return true
    elseif text == "0" or text == "false" or text == "no" or text == "off" then
        return false
    end
    return nil
end

-- Moving (true/false, nil when the proxy does not tell) and the direction, if known. Opening or
-- Closing tell both; otherwise Stopped false is moving only while Level and Target Level are both
-- known and apart (Target Level is where it stops, so it equals Level at rest). Stopped false alone
-- says nothing: Director may leave it false after a reboot, with Level unknown, some proxies have no
-- Target Level, and a Stopped that was never set again must not keep a shade moving. On a proxy
-- that has Opening and Closing (`directions`), the two at 0 mean it stands still, whatever Level and
-- Target Level are (Director may leave Stopped 0 with Level 49 and Target Level 50 after a reboot),
-- except while a move starts (`starting`: a new Target Level after Stopped 0, the moment before
-- Opening or Closing go to 1).
local function motion(values, level, target, directions, starting)
    local opening, closing = flag(values.opening), flag(values.closing)
    if opening or closing then
        if opening and closing then
            return true
        end
        return true, opening and "opening" or "closing"
    end
    local stopped = flag(values.stopped)
    local still = directions and opening == false and closing == false and not starting
    if stopped == false and level ~= nil and target ~= nil and not still then
        return level ~= target
    elseif stopped == true or opening == false or closing == false then
        return false
    end
    return nil
end

-- The state the API shows, from the variables' last values.
local function update(device, info, now)
    local state = device.state
    state.position = position(info.values.level, info.range)
    state.target_position = position(info.values.target, info.range)
    if info.startedAt and math.abs((now or Clock.now()) - info.startedAt) >= Blind.MOVE_START_SECONDS then
        info.startedAt = nil
    end
    local moving, direction = motion(info.values, state.position, state.target_position, info.directions, info.startedAt ~= nil)
    if moving and not direction and state.position and state.target_position and state.position ~= state.target_position then
        direction = state.target_position > state.position and "opening" or "closing"
    end
    state.moving = moving
    state.direction = moving and direction or nil
end

local function deviceVariables(deviceId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(deviceId)
    end)
    if ok and type(variables) == "table" then
        return variables
    end
    return {}
end

local function setupValue(xml, name)
    return xml and xml:match("<" .. name .. ">%s*([^<]-)%s*</" .. name .. ">")
end

local function setupFlag(xml, name)
    return flag(setupValue(xml, name))
end

local function attribute(tag, name)
    return tag and tag:match("%s" .. name .. '%s*=%s*"([^"]*)"')
end

-- The shade's levels from its setup: the levels named Closed and Open, else level_closed and
-- level_open (as the proxy's capabilities are named), else the minimum and maximum of <levels>.
-- nil for 0 to 100, and when the setup does not say (or says something impossible).
local function levelRange(xml)
    if not xml then
        return nil
    end
    local named = {}
    for tag in xml:gmatch("<level%s[^>]*>") do
        local name = string.lower(attribute(tag, "name") or "")
        named[name] = named[name] or tonumber(attribute(tag, "level"))
    end
    local levels = xml:match("<levels%s[^>]*>")
    local closed = named.closed or tonumber(setupValue(xml, "level_closed")) or tonumber(attribute(levels, "minimum"))
    local open = named.open or tonumber(setupValue(xml, "level_open")) or tonumber(attribute(levels, "maximum"))
    if not closed or not open or open <= closed or (closed == 0 and open == 100) then
        return nil
    end
    return { closed = closed, open = open, unknown = tonumber(attribute(levels, "unknown")) }
end

-- Reads what the shade can do (GET_SETUP on the proxy).
local function readSetup(device, info, now)
    info.setupAt = now
    local ok, result = pcall(function()
        return C4:SendUIRequest(device.id, "GET_SETUP", {})
    end)
    local raw = ok and (type(result) == "string" and result or type(result) .. ": " .. tostring(result)) or ("failed: " .. tostring(result))
    if loggedSetups[device.id] ~= raw then
        loggedSetups[device.id] = raw
        Log.debug("blind", "proxy setup", { device_id = device.id, setup = raw:sub(1, 2000) })
    end
    local xml = ok and type(result) == "string" and result:find("<", 1, true) and result or nil
    local discrete, hasLevel = setupFlag(xml, "level_discrete_control"), setupFlag(xml, "has_level")
    device.capabilities.position = discrete == true or (discrete == nil and hasLevel ~= false)
    device.capabilities.stop = setupFlag(xml, "can_stop") ~= false
    device.actions = device.capabilities.stop and { "set_position", "stop" } or { "set_position" }
    info.range = levelRange(xml)
end

function Blind.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "blind.c4i" or driver == "blind.c4z"
end

function Blind.initialize(device)
    local variables = deviceVariables(device.id)
    local ids = {}
    for id in pairs(variables) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)

    local info = { roles = {}, values = {}, setupAt = 0 }
    local found, listed = {}, {}
    for _, id in ipairs(ids) do
        local variable = variables[id]
        local name = type(variable) == "table" and tostring(variable.name or "") or ""
        local value = type(variable) == "table" and variable.value or nil
        listed[#listed + 1] = tostring(id) .. "=" .. name .. ":" .. tostring(value)
        -- "Target Level", or TARGET_LEVEL as other proxies spell their variables.
        local spoken = string.lower(name):gsub("_", " ")
        for role, names in pairs(VARIABLES) do
            if names[spoken] and not found[role] and tonumber(id) then
                found[role] = tonumber(id)
                info.values[role] = value
            end
        end
    end
    -- The values too, so the format of Target Level and the movement variables can be learnt.
    Log.debug("blind", "proxy variables", { device_id = device.id, variables = table.concat(listed, ", ") })

    tracked[device.id] = info
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { position = true, stop = true, position_reported = found.level ~= nil }
    device.state = {}
    readSetup(device, info, Clock.now())

    for role, id in pairs(found) do
        local ok, err = pcall(function()
            C4:RegisterVariableListener(device.id, id)
        end)
        if ok then
            info.roles[id] = role
        else
            if role == "level" then
                device.capabilities.position_reported = false
            end
            Log.warn("blind", "unable to watch a blind variable", { device_id = device.id, variable = role, error = tostring(err) })
        end
    end
    -- Opening and Closing tell the moves when the proxy has both and they are watched.
    info.directions = info.roles[found.opening] == "opening" and info.roles[found.closing] == "closing"
    update(device, info)
    if not found.level then
        Log.warn("blind", "blind proxy has no Level variable; position stays unknown", { device_id = device.id })
    end

    return true
end

function Blind.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    local role = info and info.roles[tonumber(variableId)]
    if not role or not device.state then
        return false
    end
    info.values[role] = value
    -- A new Target Level after Stopped 0 is a move starting, until Opening, Closing or Stopped say more.
    if role == "target" then
        info.startedAt = flag(info.values.stopped) == false and Clock.now() or nil
    elseif role == "opening" or role == "closing" or role == "stopped" then
        info.startedAt = nil
    end
    update(device, info)
    local state = device.state
    if role == "level" then
        Log.debug("blind", "level changed", { device_id = device.id, value = value, position = state.position })
    else
        Log.debug("blind", "movement changed", {
            device_id = device.id,
            variable = role,
            value = value,
            moving = state.moving,
            direction = state.direction,
            target_position = state.target_position,
        })
    end
    return true
end

-- Reads the setup again when it is older than SETUP_TTL_SECONDS (the blinds are being listed), and
-- ends a move that started more than MOVE_START_SECONDS ago without Opening or Closing.
function Blind.refresh(device, now)
    local info = tracked[device.id]
    now = now or Clock.now()
    if not info or not device.capabilities then
        return
    end
    if math.abs(now - info.setupAt) >= Blind.SETUP_TTL_SECONDS then
        readSetup(device, info, now)
        update(device, info, now)
    elseif info.startedAt then
        update(device, info, now)
    end
end

-- What this shade cannot do; nil when it can.
local function refusal(device, action, params)
    local capabilities = device.capabilities or {}
    local target = tonumber(params and params.position)
    if action == "set_position" and target and capabilities.position == false then
        target = math.floor(target + 0.5)
        if target ~= 0 and target ~= 100 then
            return {
                code = "POSITION_NOT_SUPPORTED",
                message = "This shade only opens and closes fully (position 0 or 100)",
            }
        end
    elseif action == "stop" and capabilities.stop == false then
        return {
            code = "STOP_NOT_SUPPORTED",
            message = "This shade cannot be stopped while it moves",
        }
    end
    return nil
end

-- Checks a command without sending it: a scene leaves out what a shade cannot do.
function Blind.prepare(device, action, params)
    local failure = device and refusal(device, action, params)
    if failure then
        return false, failure
    end
    return true
end

local function send(deviceId, command, params)
    Log.info("blind_command", "sending blind command", { device_id = deviceId, command = command, params = params })
    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, command, params)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

function Blind.execute(device, action, params)
    local info = tracked[device.id]
    if not info or not device.supported then
        return false, {
            code = "DEVICE_NOT_SUPPORTED",
            message = "This blind is not initialized",
        }
    end

    local sent, sendError
    if action == "set_position" then
        local target = tonumber(params and params.position)
        if not target or target < 0 or target > 100 then
            return false, {
                code = "INVALID_POSITION",
                message = "Position must be a number from 0 to 100",
            }
        end
        local failure = refusal(device, action, params)
        if failure then
            return false, failure
        end
        sent, sendError = send(device.id, "SET_LEVEL_TARGET", { LEVEL_TARGET = levelOf(target, info.range) })
    elseif action == "stop" then
        local failure = refusal(device, action, params)
        if failure then
            return false, failure
        end
        sent, sendError = send(device.id, "STOP", {})
    else
        return false, {
            code = "ACTION_NOT_SUPPORTED",
            message = "Unsupported blind action: " .. tostring(action),
        }
    end

    if not sent then
        Log.error("blind_command", "Control4 command failed", { device_id = device.id, action = action, error = sendError })
        return false, {
            code = "CONTROL4_COMMAND_FAILED",
            message = "Director rejected the blind command: " .. tostring(sendError),
        }
    end
    return true, { device_id = device.id, action = action }
end

function Blind.reset()
    tracked = {}
end

return Blind
