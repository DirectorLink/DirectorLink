local Log = require("src.core.log")
local LightV2 = require("src.adapters.light_v2")
local LightV1 = require("src.adapters.light_v1")
local ThermostatV2 = require("src.adapters.thermostat_v2")
local ThermostatProxy = require("src.adapters.thermostat_proxy")
local Blind = require("src.adapters.blind")
local Camera = require("src.adapters.camera")
local KnxRelay = require("src.adapters.knx_relay")
local DoorBird = require("src.adapters.doorbird")

local Manager = {}

local adapters = {
    LightV2,
    LightV1,
    ThermostatV2,
    ThermostatProxy,
    Blind,
    Camera,
    KnxRelay,
    DoorBird,
}

local attached = {}
-- Device whose events belong to another device (a DoorBird driver's events -> its doorbell).
local eventTargets = {}
local registry = nil
local initializedCounts = { total = 0, light = 0, climate = 0, blind = 0, camera = 0, relay = 0, doorbell = 0 }

local function log(message)
    Log.info("adapters", tostring(message))
end

-- previous: the devices before a project refresh (id -> device). An adapter gets the device it
-- controlled with the same id and kind, to keep what Director cannot tell it again (a relay's last
-- state, a doorbell's rings); everything else is read again.
function Manager.initialize(deviceRegistry, previous)
    registry = deviceRegistry
    attached = {}
    eventTargets = {}
    initializedCounts = { total = 0, light = 0, climate = 0, blind = 0, camera = 0, relay = 0, doorbell = 0 }

    pcall(function()
        C4:UnregisterAllVariableListeners()
    end)

    for _, adapter in ipairs(adapters) do
        if adapter.reset then
            adapter.reset()
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
                attached[tonumber(id)] = adapter

                local ok, success, err = pcall(adapter.initialize, device, registry, before)
                if not ok then
                    attached[tonumber(id)] = nil
                    device.supported = false
                    device.adapter_error = tostring(success)
                    log("failed to initialize device " .. tostring(id) .. ": " .. tostring(success))
                elseif not success then
                    attached[tonumber(id)] = nil
                    device.supported = false
                    device.adapter_error = tostring(err or "adapter initialization failed")
                    log("unsupported device " .. tostring(id) .. ": " .. tostring(device.adapter_error))
                else
                    if device.event_source_id then
                        eventTargets[tonumber(device.event_source_id)] = tonumber(id)
                    end
                    initialized = initialized + 1
                    initializedCounts.total = initializedCounts.total + 1
                    local kind = tostring(device.kind or "")
                    if initializedCounts[kind] ~= nil then
                        initializedCounts[kind] = initializedCounts[kind] + 1
                    end
                end
                break
            end
        end
    end

    log("initialized " .. tostring(initialized) .. " controllable proxies")
    return initialized
end

function Manager.counts()
    return {
        total = initializedCounts.total,
        light = initializedCounts.light,
        climate = initializedCounts.climate,
        blind = initializedCounts.blind,
        camera = initializedCounts.camera,
        relay = initializedCounts.relay,
        doorbell = initializedCounts.doorbell,
    }
end

function Manager.onVariableChanged(deviceId, variableId, value)
    deviceId = tonumber(deviceId)
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
    deviceId = tonumber(deviceId)
    deviceId = eventTargets[deviceId] or deviceId
    local adapter = attached[deviceId]
    if not adapter or not adapter.onDeviceEvent or not registry then
        return false
    end
    local device = registry.getDevice(deviceId)
    if not device then
        return false
    end
    local ok, changed = pcall(adapter.onDeviceEvent, device, eventId)
    if not ok then
        log("event handling failed for device " .. tostring(deviceId) .. ": " .. tostring(changed))
        return false
    end
    return changed == true
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

function Manager.shutdown()
    pcall(function()
        C4:UnregisterAllVariableListeners()
    end)

    attached = {}
    eventTargets = {}
    registry = nil
    initializedCounts = { total = 0, light = 0, climate = 0, blind = 0, camera = 0, relay = 0, doorbell = 0 }

    for _, adapter in ipairs(adapters) do
        if adapter.reset then
            adapter.reset()
        end
    end
end

return Manager
