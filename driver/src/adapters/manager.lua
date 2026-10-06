local Clock = require("src.core.clock")
local Log = require("src.core.log")
local LightV2 = require("src.adapters.light_v2")
local LightV1 = require("src.adapters.light_v1")
local ThermostatV2 = require("src.adapters.thermostat_v2")
local ThermostatProxy = require("src.adapters.thermostat_proxy")
local Fan = require("src.adapters.fan")
local Blind = require("src.adapters.blind")
local Camera = require("src.adapters.camera")
local KnxRelay = require("src.adapters.knx_relay")
local RelayController = require("src.adapters.relay_controller")
local DoorBird = require("src.adapters.doorbird")
local Alarm = require("src.adapters.alarm")
local Refrigerator = require("src.adapters.refrigerator")

local Manager = {}

local adapters = {
    LightV2,
    LightV1,
    ThermostatV2,
    ThermostatProxy,
    Fan,
    Blind,
    Camera,
    -- Before KnxRelay: a KNX Contact/Relay that is a Relay Door or Gate Controller's door is the
    -- controller's (ADR-069).
    RelayController,
    KnxRelay,
    DoorBird,
    Alarm,
    Refrigerator,
}

local attached = {}
-- The adapter that took each device, whether it could start it or not (a refrigerator whose driver
-- lacks a variable): what a driver update may set up again (Manager.setUpAgain).
local matched = {}
-- Told of each device event an adapter took (alerts: a doorbell's ring, a door opened elsewhere).
local eventListener = nil
-- When DirectorLink last sent each device a command that worked (Clock.now()): what the device
-- reports soon after is that command's doing. A command to a device counts for its partners too (a
-- gate's controller and the DoorBird doorbell whose relay it drives, ADR-069).
local commanded = {}
-- Device whose events (and variables) belong to another device: a DoorBird driver's events -> its
-- doorbell, a Samsung Refrigerator driver's variables and events -> its refrigerator.
local eventTargets = {}
local registry = nil
local initializedCounts = { total = 0, light = 0, climate = 0, fan = 0, blind = 0, camera = 0, relay = 0, doorbell = 0, alarm = 0, refrigerator = 0 }

local function log(message)
    Log.info("adapters", tostring(message))
end

local function countKind(device, step)
    initializedCounts.total = initializedCounts.total + step
    local kind = tostring(device.kind or "")
    if initializedCounts[kind] ~= nil then
        initializedCounts[kind] = initializedCounts[kind] + step
    end
end

-- Starts `adapter` on the device; true when it controls (or watches) it from now on.
local function attach(id, device, adapter, before, quietly)
    attached[id] = adapter
    local ok, success, err
    if quietly then
        ok, success, err = Log.quietly(pcall, adapter.initialize, device, registry, before)
    else
        ok, success, err = pcall(adapter.initialize, device, registry, before)
    end
    if not ok then
        attached[id] = nil
        device.supported = false
        device.adapter_error = tostring(success)
        log("failed to initialize device " .. tostring(id) .. ": " .. tostring(success))
        return false
    elseif not success then
        attached[id] = nil
        device.supported = false
        device.adapter_error = tostring(err or "adapter initialization failed")
        log("unsupported device " .. tostring(id) .. ": " .. tostring(device.adapter_error))
        return false
    end
    if device.event_source_id then
        eventTargets[tonumber(device.event_source_id)] = id
    end
    countKind(device, 1)
    return true
end

-- previous: the devices before a project refresh (id -> device). An adapter gets the device it
-- controlled with the same id and kind, to keep what Director cannot tell it again (a relay's last
-- state, a doorbell's rings); everything else is read again. What the adapters log at info level
-- about each device is written at debug level then: the first discovery logged it already.
function Manager.initialize(deviceRegistry, previous)
    registry = deviceRegistry
    attached = {}
    matched = {}
    eventTargets = {}
    initializedCounts = { total = 0, light = 0, climate = 0, fan = 0, blind = 0, camera = 0, relay = 0, doorbell = 0, alarm = 0, refrigerator = 0 }
    local refreshing = previous ~= nil and next(previous) ~= nil

    pcall(function()
        C4:UnregisterAllVariableListeners()
    end)

    for _, adapter in ipairs(adapters) do
        if adapter.reset then
            adapter.reset()
        end
    end
    -- What adapters must know of the whole project before any device starts (which KNX relay is a
    -- door controller's, ADR-069).
    for _, adapter in ipairs(adapters) do
        if adapter.survey then
            local ok, err = pcall(adapter.survey, registry)
            if not ok then
                log("survey failed: " .. tostring(err))
            end
        end
    end

    local initialized = 0

    for id, device in pairs(registry.devices or {}) do
        local before = previous and previous[tonumber(id)]
        if before and (before.kind ~= device.kind or before.supported ~= true) then
            before = nil
        end
        for _, adapter in ipairs(adapters) do
            if adapter.matches(device) then
                matched[tonumber(id)] = adapter
                if attach(tonumber(id), device, adapter, before, refreshing) then
                    initialized = initialized + 1
                end
                break
            end
        end
    end

    log("initialized " .. tostring(initialized) .. " controllable proxies")
    return initialized
end

-- A Composer property that decides which devices an adapter takes changed (Alarm Status: the
-- alarm's partitions, ADR-038). The devices it takes now start; the ones it no longer takes are
-- let go, their variables no longer watched. Nothing else is read again. Returns how many
-- devices started and how many were let go.
function Manager.onPropertyChanged(name)
    local started, released = 0, 0
    if not registry then
        return started, released
    end
    for _, adapter in ipairs(adapters) do
        if adapter.PROPERTY ~= nil and adapter.PROPERTY == name then
            for rawId, device in pairs(registry.devices or {}) do
                local id = tonumber(rawId)
                if attached[id] == adapter and not adapter.matches(device) then
                    if adapter.release then
                        pcall(adapter.release, device)
                    end
                    attached[id] = nil
                    matched[id] = nil
                    device.supported = false
                    countKind(device, -1)
                    released = released + 1
                elseif attached[id] == nil and adapter.matches(device) then
                    matched[id] = adapter
                    if attach(id, device, adapter, nil, false) then
                        started = started + 1
                    end
                end
            end
        end
    end
    return started, released
end

-- The ids of the drivers behind a device, whose versions src/control4/driver_updates.lua watches:
-- its protocol drivers (a refrigerator's Samsung driver, a KNX light's driver), else the device.
function Manager.driverIds(device)
    local ids = {}
    for _, protocol in ipairs(type(device) == "table" and device.protocols or {}) do
        if tonumber(protocol.id) then
            ids[#ids + 1] = tonumber(protocol.id)
        end
    end
    if #ids == 0 and type(device) == "table" and tonumber(device.id) then
        ids[1] = tonumber(device.id)
    end
    return ids
end

-- The devices an adapter took, whether it could start them or not: id -> device.
function Manager.matchedDevices()
    local devices = {}
    for id in pairs(matched) do
        local device = registry and registry.getDevice(id)
        if device then
            devices[id] = device
        end
    end
    return devices
end

-- Stops watching every variable of `sourceId` (its adapter registers again what it watches).
local function stopWatching(sourceId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(sourceId)
    end)
    if not ok or type(variables) ~= "table" then
        return
    end
    for variableId in pairs(variables) do
        if tonumber(variableId) then
            pcall(function()
                C4:UnregisterVariableListener(sourceId, tonumber(variableId))
            end)
        end
    end
end

-- Devices whose driver was updated in Composer (src/control4/driver_updates.lua): each one's adapter
-- sets it up again as at a project refresh (its variables, listeners and capabilities), keeping what
-- a refresh keeps (a relay's last state, a doorbell's rings), and no other device is touched. The
-- variables of the devices, their drivers and where their events come from are let go first, unless
-- another device is watched there too. Returns id -> true when the device works now, false if not.
function Manager.setUpAgain(deviceIds)
    local results = {}
    if not registry then
        return results
    end
    local chosen = {}
    for _, rawId in ipairs(deviceIds or {}) do
        local id = tonumber(rawId)
        if id and matched[id] and registry.getDevice(id) then
            chosen[id] = true
        end
    end
    local sources, others = {}, {}
    for id in pairs(matched) do
        local device = registry.getDevice(id)
        if device then
            local list = Manager.driverIds(device)
            list[#list + 1] = id
            list[#list + 1] = tonumber(device.event_source_id)
            for _, source in ipairs(list) do
                if chosen[id] then
                    sources[source] = true
                else
                    others[source] = true
                end
            end
        end
    end
    for source in pairs(sources) do
        if not others[source] then
            stopWatching(source)
        end
    end
    for id in pairs(chosen) do
        local device = registry.getDevice(id)
        local before = nil
        if attached[id] then
            local state = {}
            for key, value in pairs(type(device.state) == "table" and device.state or {}) do
                state[key] = value
            end
            before = { kind = device.kind, supported = device.supported, state = state }
            countKind(device, -1)
        end
        attached[id] = nil
        if device.event_source_id then
            eventTargets[tonumber(device.event_source_id)] = nil
        end
        device.supported = false
        results[id] = attach(id, device, matched[id], before, false)
    end
    return results
end

-- Devices whose driver now says something else of what they are, which their adapter looks at a few
-- a minute (the scheduler's tick): a camera driver's marker of DirectorLink's camera agreement that
-- came after the driver started, or its kind (ADR-065). Each is set up again, as at a driver update.
-- Returns id -> true when the device works now, false if not.
function Manager.lookAgain()
    local results = {}
    if not registry then
        return results
    end
    for _, adapter in ipairs(adapters) do
        if adapter.lookAgain then
            local ok, ids = pcall(adapter.lookAgain, registry)
            if not ok then
                log("looking at devices again failed: " .. tostring(ids))
            elseif type(ids) == "table" and #ids > 0 then
                for id, works in pairs(Manager.setUpAgain(ids)) do
                    results[id] = works
                end
            end
        end
    end
    return results
end

function Manager.counts()
    return {
        total = initializedCounts.total,
        light = initializedCounts.light,
        climate = initializedCounts.climate,
        fan = initializedCounts.fan,
        blind = initializedCounts.blind,
        camera = initializedCounts.camera,
        relay = initializedCounts.relay,
        doorbell = initializedCounts.doorbell,
        alarm = initializedCounts.alarm,
        refrigerator = initializedCounts.refrigerator,
    }
end

function Manager.onVariableChanged(deviceId, variableId, value)
    deviceId = tonumber(deviceId)
    deviceId = eventTargets[deviceId] or deviceId
    local adapter = attached[deviceId]
    if not adapter or not registry then
        return false
    end

    local device = registry.getDevice(deviceId)
    if not device then
        return false
    end

    local ok, changed = pcall(adapter.onVariableChanged, device, variableId, value)
    if not ok then
        log("state update failed for device " .. tostring(deviceId) .. ": " .. tostring(changed))
        return false
    end

    return changed == true
end

function Manager.onDeviceEvent(deviceId, eventId)
    -- The device that fired it, which the adapter and the listener are told too (a door controller's
    -- door hears its controller and its own KNX relay, whose event ids differ in meaning).
    local sourceId = tonumber(deviceId)
    deviceId = eventTargets[sourceId] or sourceId
    local adapter = attached[deviceId]
    if not adapter or not adapter.onDeviceEvent or not registry then
        return false
    end
    local device = registry.getDevice(deviceId)
    if not device then
        return false
    end
    -- The state as it was, for the listener (a relay closing from open is a door opened).
    local before = {}
    for key, value in pairs(type(device.state) == "table" and device.state or {}) do
        before[key] = value
    end
    local ok, changed = pcall(adapter.onDeviceEvent, device, eventId, sourceId)
    if not ok then
        log("event handling failed for device " .. tostring(deviceId) .. ": " .. tostring(changed))
        return false
    end
    if changed == true and eventListener then
        local told, err = pcall(eventListener, device, eventId, before, sourceId)
        if not told then
            log("event listener failed for device " .. tostring(deviceId) .. ": " .. tostring(err))
        end
    end
    return changed == true
end

-- `listener(device, eventId, before, sourceId)` is told of each event an adapter took, after it did
-- (`before`: a copy of the device's state before; `sourceId`: the device that fired it).
function Manager.onEvent(listener)
    eventListener = listener
end

-- When DirectorLink last sent `deviceId` a command that worked (Clock.now()), or nil.
function Manager.commandedAt(deviceId)
    return commanded[tonumber(deviceId)]
end

function Manager.execute(deviceId, action, params)
    deviceId = tonumber(deviceId)
    if not deviceId or not registry then
        return false, {
            code = "DEVICE_NOT_FOUND",
            message = "Invalid device ID",
        }
    end

    local device = registry.getDevice(deviceId)
    if not device then
        return false, {
            code = "DEVICE_NOT_FOUND",
            message = "Device " .. tostring(deviceId) .. " does not exist",
        }
    end

    local adapter = attached[deviceId]
    if not adapter then
        return false, {
            code = "DEVICE_NOT_SUPPORTED",
            message = "Device " .. tostring(deviceId) .. " has no controllable DirectorLink adapter",
        }
    end

    local ok, success, result = pcall(adapter.execute, device, action, params or {})
    if not ok then
        return false, {
            code = "ADAPTER_ERROR",
            message = tostring(success),
        }
    end

    if not success then
        return false, result
    end

    local now = Clock.now()
    commanded[deviceId] = now
    for _, partner in ipairs(type(device.partners) == "table" and device.partners or {}) do
        if tonumber(partner) then
            commanded[tonumber(partner)] = now
        end
    end
    return true, result
end

-- Checks a command without sending anything: true, or false and a failure like execute's (a
-- failure may name the request `field` it is about). A request that sends several commands checks
-- them all first, so a refused setpoint cannot leave the mode already changed. Adapters without
-- prepare accept everything here and check in execute.
function Manager.prepare(deviceId, action, params)
    local adapter = attached[tonumber(deviceId)]
    if not adapter or not adapter.prepare or not registry then
        return true
    end
    local ok, success, failure = pcall(adapter.prepare, registry.getDevice(tonumber(deviceId)), action, params or {})
    if not ok then
        return false, { code = "ADAPTER_ERROR", message = tostring(success) }
    end
    return success ~= false, failure
end

-- Lets an adapter read again what it keeps about a device and what may change without a project
-- refresh (a blind's setup, when it is some minutes old). Cheap when nothing is due.
function Manager.refresh(deviceId)
    local adapter = attached[tonumber(deviceId)]
    local device = adapter and adapter.refresh and registry and registry.getDevice(tonumber(deviceId))
    if device then
        local ok, err = pcall(adapter.refresh, device)
        if not ok then
            log("refresh failed for device " .. tostring(deviceId) .. ": " .. tostring(err))
        end
    end
end

function Manager.shutdown()
    pcall(function()
        C4:UnregisterAllVariableListeners()
    end)

    attached = {}
    matched = {}
    eventTargets = {}
    registry = nil
    initializedCounts = { total = 0, light = 0, climate = 0, fan = 0, blind = 0, camera = 0, relay = 0, doorbell = 0, alarm = 0, refrigerator = 0 }

    for _, adapter in ipairs(adapters) do
        if adapter.reset then
            adapter.reset()
        end
    end
end

return Manager
