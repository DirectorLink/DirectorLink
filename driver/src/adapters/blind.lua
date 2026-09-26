local Log = require("src.core.log")

-- Blind proxy (blind.c4i). Commands are the proxy's own: SET_LEVEL_TARGET {LEVEL_TARGET = 0..100}
-- (0 closed, 100 open) and STOP. The protocol driver reports MOVING / STOPPED {LEVEL} to the
-- proxy, which keeps its "Level" variable; -255 means the level is unknown (e.g. after a reboot
-- on a blind without a KNX status address).
local Blind = {}

local LEVEL_UNKNOWN = -255
-- Variable names of the blind proxy; the IDs are looked up at startup.
local LEVEL_NAMES = { ["level"] = true, ["current level"] = true }

local tracked = {}

local function position(value)
    local number = tonumber(value)
    if not number or number == LEVEL_UNKNOWN or number < 0 or number > 100 then
        return nil
    end
    return math.floor(number + 0.5)
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

function Blind.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "blind.c4i" or driver == "blind.c4z"
end

function Blind.initialize(device)
    local levelVariable, levelValue
    local names = {}
    for id, variable in pairs(deviceVariables(device.id)) do
        local name = type(variable) == "table" and tostring(variable.name or "") or ""
        names[#names + 1] = tostring(id) .. "=" .. name
        if LEVEL_NAMES[string.lower(name)] and not levelVariable then
            levelVariable, levelValue = tonumber(id), variable.value
        end
    end
    table.sort(names)
    Log.debug("blind", "proxy variables", { device_id = device.id, variables = table.concat(names, ", ") })

    tracked[device.id] = { level_variable = levelVariable }

    device.supported = true
    device.adapter_error = nil
    device.capabilities = { position = true, stop = true, position_reported = levelVariable ~= nil }
    device.state = { position = position(levelValue) }
    device.actions = { "set_position", "stop" }

    if levelVariable then
        local ok, err = pcall(function()
            C4:RegisterVariableListener(device.id, levelVariable)
        end)
        if not ok then
            tracked[device.id].level_variable = nil
            device.capabilities.position_reported = false
            Log.warn("blind", "unable to watch the blind level", { device_id = device.id, error = tostring(err) })
        end
    else
        Log.warn("blind", "blind proxy has no Level variable; position stays unknown", { device_id = device.id })
    end

    return true
end

function Blind.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    if not info or not device.state or tonumber(variableId) ~= info.level_variable then
        return false
    end
    device.state.position = position(value)
    Log.debug("blind", "level changed", { device_id = device.id, value = value, position = device.state.position })
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
        sent, sendError = send(device.id, "SET_LEVEL_TARGET", { LEVEL_TARGET = math.floor(target + 0.5) })
    elseif action == "stop" then
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
