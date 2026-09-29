local Log = require("src.core.log")

-- The Fan proxy (fan.c4i), for fan speed controllers such as Control4's. The proxy keeps the
-- fan's state. On a live Director (bkwagner, #18) it has 1000 IS_ON, 1001 CURRENT_SPEED (0 when
-- off, else 1-4) and 1003 PRESET_SPEED, and its SET_SPEED command lists 0-4 (Off, Low, Medium,
-- Medium High, High). Snap One's proxy documentation adds that ON turns the fan on at its preset
-- speed (or at its last one, as the protocol driver chooses), OFF turns it off, and SET_SPEED
-- {SPEED} goes from 0 (off) to the fan's highest speed. The variables are found by name, as the
-- blind proxy's are, else by those ids. No DirectorLink command has run on a real fan yet, so at
-- Debug the start-up log lists each proxy's variables (the preset speed among them) and its setup.
--
-- The record the API layer reads (views, fan and scene handlers):
--   capabilities: on_off = true, speeds = 4 (the fan takes 1 to speeds)
--   state: power (true/false), speed (1-4 while on; nil when off or not reported)
--   actions: on, off, set_speed ({ speed = 1-4 })
local Fan = {}

Fan.MAX_SPEED = 4

-- The proxy variables by what they tell: the names they may have (lowercase, "_" read as a space;
-- the first as read on a live Director, the second as Snap One's documentation calls it) and the id
-- read on that Director.
local VARIABLES = {
    on = { id = 1000, names = { ["is on"] = true } },
    speed = { id = 1001, names = { ["current speed"] = true, ["current selected speed"] = true } },
}
local ROLES = { "on", "speed" }

local tracked = {}

-- True or false as a variable says it ("1", "True", " false ", ...); nil when it says neither.
local function flag(value)
    local text = string.lower(tostring(value or "")):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "1" or text == "true" or text == "yes" or text == "on" then
        return true
    elseif text == "0" or text == "false" or text == "no" or text == "off" then
        return false
    end
    return nil
end

-- A speed from 0 (off) to MAX_SPEED; nil for anything else (not reported, or not one of them).
local function speedValue(value)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) or number < 0 or number > Fan.MAX_SPEED then
        return nil
    end
    return number
end

-- A speed SET_SPEED takes from DirectorLink: 1 (low) to MAX_SPEED (high). Off is its own command.
local function isSpeed(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1 and value <= Fan.MAX_SPEED
end

-- The state the API shows, from the variables' last values. IS_ON says whether the fan runs, and
-- CURRENT_SPEED how fast while it does. When IS_ON reads neither on nor off, a speed above 0 is on.
local function update(device, info)
    local speed = speedValue(info.values.speed)
    local on = flag(info.values.on)
    if on == nil then
        on = speed ~= nil and speed > 0
    end
    device.state.power = on
    device.state.speed = (on and speed ~= nil and speed > 0) and speed or nil
end

local function safeGetVariable(deviceId, variableId)
    local ok, value = pcall(function()
        return C4:GetVariable(deviceId, variableId)
    end)
    if ok then
        return value
    end
    return nil
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

-- The fan's variables by role, found by name, else by the id read on a live Director: the ids, the
-- values, and "<id>=<name>:<value>, ..." of every variable for the Debug log.
local function findVariables(deviceId)
    local variables = deviceVariables(deviceId)
    local ids = {}
    for id in pairs(variables) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)

    local found, values, listed = {}, {}, {}
    for _, id in ipairs(ids) do
        local variable = variables[id]
        local name = type(variable) == "table" and tostring(variable.name or "") or ""
        local value = type(variable) == "table" and variable.value or nil
        listed[#listed + 1] = tostring(id) .. "=" .. name .. ":" .. tostring(value)
        local spoken = string.lower(name):gsub("_", " ")
        for _, role in ipairs(ROLES) do
            if VARIABLES[role].names[spoken] and not found[role] and tonumber(id) then
                found[role] = tonumber(id)
                values[role] = value
            end
        end
    end
    for _, role in ipairs(ROLES) do
        if not found[role] then
            local value = safeGetVariable(deviceId, VARIABLES[role].id)
            if value ~= nil then
                found[role] = VARIABLES[role].id
                values[role] = value
            end
        end
    end
    return found, values, table.concat(listed, ", ")
end

local function protocolDrivers(device)
    local drivers = {}
    for _, protocol in ipairs(device.protocols or {}) do
        drivers[#drivers + 1] = tostring(protocol.driver or "")
    end
    return drivers
end

-- The proxy's setup (the UI request GET_SETUP: how many speeds, their names, the preset), for the
-- Debug log only: Snap One documents it, but it has not been read on a real fan, and nothing here
-- depends on it yet.
local function logSetup(deviceId)
    if Log.getLevel() ~= "debug" then
        return
    end
    local ok, result = pcall(function()
        return C4:SendUIRequest(deviceId, "GET_SETUP", {})
    end)
    local raw = ok and (type(result) == "string" and result or type(result) .. ": " .. tostring(result)) or ("failed: " .. tostring(result))
    Log.debug("fan", "proxy setup", { device_id = deviceId, setup = raw:sub(1, 2000) })
end

function Fan.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "fan.c4i"
end

function Fan.initialize(device)
    local found, values, listed = findVariables(device.id)
    Log.debug("fan", "proxy variables", { device_id = device.id, variables = listed, protocols = protocolDrivers(device) })
    logSetup(device.id)
    if not found.on or not found.speed then
        device.supported = false
        device.adapter_error = "Fan state variables (IS_ON 1000, CURRENT_SPEED 1001) are unavailable"
        return false, device.adapter_error
    end

    -- Tracked before the listeners: Director calls OnWatchedVariableChanged right after each
    -- registration, and those first values should land in the state.
    local info = { roles = {}, values = values }
    for _, role in ipairs(ROLES) do
        info.roles[found[role]] = role
    end
    tracked[device.id] = info
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { on_off = true, speeds = Fan.MAX_SPEED }
    device.state = {}
    device.actions = { "on", "off", "set_speed" }
    update(device, info)

    local registered = {}
    for _, role in ipairs(ROLES) do
        local ok, err = pcall(function()
            C4:RegisterVariableListener(device.id, found[role])
        end)
        if not ok then
            for _, id in ipairs(registered) do
                pcall(function()
                    C4:UnregisterVariableListener(device.id, id)
                end)
            end
            tracked[device.id] = nil
            device.supported = false
            device.adapter_error = "Unable to watch the fan's " .. (role == "on" and "IS_ON" or "CURRENT_SPEED") .. ": " .. tostring(err)
            return false, device.adapter_error
        end
        registered[#registered + 1] = found[role]
    end

    Log.info("fan", "initialized fan", {
        device_id = device.id,
        on = device.state.power,
        speed = device.state.speed,
        is_on_variable = found.on,
        speed_variable = found.speed,
    })
    return true
end

function Fan.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    local role = info and info.roles[tonumber(variableId)]
    if not role or not device.state then
        return false
    end
    info.values[role] = value
    update(device, info)
    -- With the raw value: what a real fan reports has not been seen yet.
    Log.debug("fan_state", "fan variable changed", {
        device_id = device.id,
        variable = role,
        value = value,
        on = device.state.power,
        speed = device.state.speed,
    })
    return true
end

local function send(deviceId, command, params)
    params = params or {}
    Log.info("fan_command", "sending fan command", { device_id = deviceId, command = command, params = params })
    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, command, params)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

-- on -> ON, off -> OFF, set_speed { speed = 1-4 } -> SET_SPEED { SPEED }. Anything else is refused
-- before a command goes out.
function Fan.execute(device, action, params)
    local info = tracked[device.id]
    if not info or not device.supported then
        return false, {
            code = "DEVICE_NOT_SUPPORTED",
            message = "This fan is not initialized as a supported Fan device",
        }
    end

    local command, commandParams
    if action == "on" then
        command = "ON"
    elseif action == "off" then
        command = "OFF"
    elseif action == "set_speed" then
        local speed = params and params.speed
        if not isSpeed(speed) then
            return false, {
                code = "INVALID_SPEED",
                message = "Speed must be a whole number from 1 to " .. Fan.MAX_SPEED,
            }
        end
        command, commandParams = "SET_SPEED", { SPEED = speed }
    else
        return false, {
            code = "ACTION_NOT_SUPPORTED",
            message = "Unsupported fan action: " .. tostring(action),
        }
    end

    local sent, sendError = send(device.id, command, commandParams)
    if not sent then
        Log.error("fan_command", "Control4 command failed", {
            device_id = device.id,
            action = action,
            error = sendError,
        })
        return false, {
            code = "CONTROL4_COMMAND_FAILED",
            message = "Director rejected the fan command: " .. tostring(sendError),
        }
    end

    local result = {
        device_id = device.id,
        action = action,
        command = command,
        requested_speed = commandParams and commandParams.SPEED or nil,
    }
    Log.info("fan_command", "Control4 command dispatched", result)
    return true, result
end

function Fan.reset()
    tracked = {}
end

return Fan
