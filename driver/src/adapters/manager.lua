local Log = require("src.core.log")
local LightV2 = require("src.adapters.light_v2")
local ThermostatV2 = require("src.adapters.thermostat_v2")
local Blind = require("src.adapters.blind")
local Camera = require("src.adapters.camera")
local KnxRelay = require("src.adapters.knx_relay")

local Manager = {}

local adapters = {
    LightV2,
    ThermostatV2,
    Blind,
    Camera,
    KnxRelay,
}

local attached = {}
local registry = nil
local initializedCounts = { total = 0, light = 0, climate = 0, blind = 0, camera = 0, relay = 0 }

local function log(message)
    Log.info("adapters", tostring(message))
end

function Manager.initialize(deviceRegistry)
    registry = deviceRegistry
    attached = {}
    initializedCounts = { total = 0, light = 0, climate = 0, blind = 0, camera = 0, relay = 0 }

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
        for _, adapter in ipairs(adapters) do
            if adapter.matches(device) then
                attached[tonumber(id)] = adapter

                local ok, success, err = pcall(adapter.initialize, device)
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
            message = "Device " .. tostring(deviceId) .. " has no controllable C4Bridge adapter",
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

function Manager.shutdown()
    pcall(function()
        C4:UnregisterAllVariableListeners()
    end)

    attached = {}
    registry = nil
    initializedCounts = { total = 0, light = 0, climate = 0, blind = 0, camera = 0, relay = 0 }

    for _, adapter in ipairs(adapters) do
        if adapter.reset then
            adapter.reset()
        end
    end
end

return Manager
