local Clock = require("src.core.clock")
local Log = require("src.core.log")

-- Blind proxy (blind.c4i). Commands are the proxy's own: SET_LEVEL_TARGET {LEVEL_TARGET = 0..100}
-- (0 closed, 100 open) and STOP. The protocol driver reports MOVING / STOPPED {LEVEL} to the
-- proxy, which keeps its variables. On Director 3.4.3 with KNX blinds they are 1000 Open,
-- 1001 Fully Closed, 1002 Stopped, 1003 Fully Open, 1004 Level, 1005 Target Level, 1006 Type,
-- 1007 Movement, 1008 Opening and 1009 Closing; they are found by name. A Level outside 0..100 is
-- unknown: -255 after a reboot on a blind without a KNX status address, -155 when the actuator
-- reports 255 ("position unknown"). The proxy sets Level when a move starts (its estimate), when
-- it ends (the driver's timer) and whenever the actuator reports.
--
-- What a shade can do comes from the proxy's setup, which Control4's own apps read with the UI
-- request GET_SETUP: <blind_setup><has_level>True</has_level><level_discrete_control>True
-- </level_discrete_control><can_stop>True</can_stop>... level_discrete_control is False on shades
-- that only open and close fully (a KNX blind without a percent address, whose driver sends up for
-- any target above 0). Without a usable answer a shade is taken to do both, as before 1.1.0.
local Blind = {}

-- The setup is read again when the blinds are listed and it is older than this: an installer can
-- change the protocol driver without changing the project.
Blind.SETUP_TTL_SECONDS = 600

-- Proxy variables by what they tell, as the names they may have.
local VARIABLES = {
    level = { ["level"] = true, ["current level"] = true },
    target = { ["target level"] = true, ["level target"] = true },
    stopped = { ["stopped"] = true },
    movement = { ["movement"] = true },
    opening = { ["opening"] = true },
    closing = { ["closing"] = true },
}

local tracked = {}
-- The setup last logged for each blind; kept across a project refresh, so it is logged again only
-- when it changes.
local loggedSetups = {}

local function position(value)
    local number = tonumber(value)
    if not number or number < 0 or number > 100 then
        return nil
    end
    return math.floor(number + 0.5)
end

-- True or false as a variable or the setup says it ("1", "True", ...); nil when it says neither.
local function flag(value)
    local text = string.lower(tostring(value or ""))
    if text == "1" or text == "true" or text == "yes" or text == "on" then
        return true
    elseif text == "0" or text == "false" or text == "no" or text == "off" then
        return false
    end
    return nil
end

-- Movement in words ("Opening", "Moving Down", "Stopped", ...). Anything else, a number among
-- them, is left unread until a real controller shows its format (it is logged).
local function movementOf(value)
    local text = string.lower(tostring(value or "")):gsub("^%s+", ""):gsub("%s+$", "")
    local function has(word)
        return text:find(word, 1, true) ~= nil
    end
    local function last(word)
        return text == word or text:sub(-#word - 1) == " " .. word
    end
    if has("opening") or has("raising") or last("up") then
        return "opening"
    elseif has("closing") or has("lowering") or last("down") then
        return "closing"
    elseif has("stop") or text == "idle" or text == "none" then
        return "stopped"
    end
    return nil
end

-- Moving (true/false, nil when the proxy does not tell) and the direction, if known.
local function motion(values)
    local opening, closing = flag(values.opening), flag(values.closing)
    local movement = movementOf(values.movement)
    if opening or closing then
        return true, opening and "opening" or "closing"
    elseif movement == "opening" or movement == "closing" then
        return true, movement
    elseif opening == false or closing == false or movement == "stopped" then
        return false
    end
    local stopped = flag(values.stopped)
    if stopped ~= nil then
        return not stopped
    end
    return nil
end

-- The state the API shows, from the variables' last values.
local function update(device, info)
    local state = device.state
    state.position = position(info.values.level)
    state.target_position = position(info.values.target)
    local moving, direction = motion(info.values)
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

local function setupFlag(xml, name)
    if not xml then
        return nil
    end
    return flag(xml:match("<" .. name .. ">%s*([^<]-)%s*</" .. name .. ">"))
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
    update(device, info)

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

-- Reads the setup again when it is older than SETUP_TTL_SECONDS (the blinds are being listed).
function Blind.refresh(device, now)
    local info = tracked[device.id]
    now = now or Clock.now()
    if info and device.capabilities and math.abs(now - info.setupAt) >= Blind.SETUP_TTL_SECONDS then
        readSetup(device, info, now)
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
    if not tracked[device.id] or not device.supported then
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
        sent, sendError = send(device.id, "SET_LEVEL_TARGET", { LEVEL_TARGET = math.floor(target + 0.5) })
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
