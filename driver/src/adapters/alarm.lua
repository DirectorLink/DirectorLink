-- Security partitions (security.c4i), read-only, and only while the Composer property Alarm Status
-- is On (ADR-038). A partition is one area of the home's alarm; its proxy keeps the state in
-- variables 1000-1012, as bkwagner read them on a live Director (#15): armed home or away and the
-- panel's name for how, in alarm and of what type, open zones, the entry or exit delay, trouble.
-- 1004 is not read, as in #15. A partition the panel does not use says IS_ACTIVE = 0 and is left
-- out of the lists; the panel may connect after Director starts, so that is followed as it changes.
--
-- Nothing is ever sent to a partition: arming and disarming (PARTITION_ARM / PARTITION_DISARM)
-- take the user's alarm code, which needs a stronger design than an API key. Nor is the state
-- logged, at any level: GET /v1/logs can be read without a seal, and the state is only ever sent
-- sealed. scripts/check_package.py fails the build if this file asks Director for anything but
-- reading and watching variables.
local Alarm = {}

Alarm.PROPERTY = "Alarm Status"

local HOME_STATE = 1000
local AWAY_STATE = 1001
local DISARMED_STATE = 1002
local ALARM_STATE = 1003
local TROUBLE_TEXT = 1005
local IS_ACTIVE = 1006
local PARTITION_STATE = 1007
local DELAY_TIME_TOTAL = 1008
local DELAY_TIME_REMAINING = 1009
local OPEN_ZONE_COUNT = 1010
local ALARM_TYPE = 1011
local ARMED_TYPE = 1012

local WATCHED = {
    IS_ACTIVE,
    PARTITION_STATE,
    HOME_STATE,
    AWAY_STATE,
    DISARMED_STATE,
    ALARM_STATE,
    TROUBLE_TEXT,
    DELAY_TIME_TOTAL,
    DELAY_TIME_REMAINING,
    OPEN_ZONE_COUNT,
    ALARM_TYPE,
    ARMED_TYPE,
}

local IS_WATCHED = {}
for _, variableId in ipairs(WATCHED) do
    IS_WATCHED[variableId] = true
end

-- device id -> { raw = variable id -> value, watched = variable ids with a listener }
local tracked = {}

-- Read at every discovery and whenever Composer changes it (Manager.onPropertyChanged).
function Alarm.enabled()
    return Properties ~= nil and Properties[Alarm.PROPERTY] == "On"
end

function Alarm.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "security.c4i" and Alarm.enabled()
end

local function read(deviceId, variableId)
    local ok, value = pcall(function()
        return C4:GetVariable(deviceId, variableId)
    end)
    if ok then
        return value
    end
    return nil
end

local function flag(value)
    local text = string.lower(tostring(value or ""))
    return text == "1" or text == "true"
end

local function text(value)
    if value == nil then
        return nil
    end
    local trimmed = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function count(value)
    local number = tonumber(value)
    if not number or number < 0 then
        return nil
    end
    return math.floor(number + 0.5)
end

-- The partition's state from its variables as last reported.
local function update(device, raw)
    local active = string.lower(tostring(raw[IS_ACTIVE] or ""))
    device.state = {
        -- Only a partition that says so is unused: one that has not said yet counts as in use.
        active = active ~= "0" and active ~= "false",
        partition_state = text(raw[PARTITION_STATE]),
        home = flag(raw[HOME_STATE]),
        away = flag(raw[AWAY_STATE]),
        disarmed = flag(raw[DISARMED_STATE]),
        alarm = flag(raw[ALARM_STATE]),
        armed_type = text(raw[ARMED_TYPE]),
        alarm_type = text(raw[ALARM_TYPE]),
        open_zones = count(raw[OPEN_ZONE_COUNT]),
        delay_total = count(raw[DELAY_TIME_TOTAL]),
        delay_remaining = count(raw[DELAY_TIME_REMAINING]),
        trouble = text(raw[TROUBLE_TEXT]),
    }
end

-- Stops watching the partition and forgets its state (Alarm Status turned Off, or a failed start).
function Alarm.release(device)
    local info = tracked[device.id]
    for _, variableId in ipairs(info and info.watched or {}) do
        pcall(function()
            C4:UnregisterVariableListener(device.id, variableId)
        end)
    end
    tracked[device.id] = nil
    device.supported = false
    device.state = nil
    device.capabilities = nil
    device.actions = nil
end

function Alarm.initialize(device)
    local raw = {}
    for _, variableId in ipairs(WATCHED) do
        raw[variableId] = read(device.id, variableId)
    end
    if raw[PARTITION_STATE] == nil then
        return false, "Partition State variable (1007) is unavailable"
    end

    -- Known before the listeners: Director calls OnWatchedVariableChanged as each one registers.
    local info = { raw = raw, watched = {} }
    tracked[device.id] = info
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { read_only = true }
    device.actions = {}
    update(device, raw)

    for _, variableId in ipairs(WATCHED) do
        if raw[variableId] ~= nil then
            local ok, err = pcall(function()
                C4:RegisterVariableListener(device.id, variableId)
            end)
            if not ok then
                Alarm.release(device)
                return false, "Unable to watch partition variable " .. tostring(variableId) .. ": " .. tostring(err)
            end
            info.watched[#info.watched + 1] = variableId
        end
    end
    return true
end

function Alarm.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    variableId = tonumber(variableId)
    if not info or not IS_WATCHED[variableId] then
        return false
    end
    info.raw[variableId] = value
    update(device, info.raw)
    return true
end

-- Nothing is sent to a partition, whatever is asked.
function Alarm.execute()
    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Alarm partitions are read-only in DirectorLink",
    }
end

function Alarm.reset()
    tracked = {}
end

return Alarm
