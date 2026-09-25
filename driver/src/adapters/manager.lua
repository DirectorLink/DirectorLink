local LightV2 = require("src.adapters.light_v2")

local Manager = {}

local adapters = {
    LightV2,
}

local attached = {}
local registry = nil
local logger = nil

local function log(message)
    if logger then
        logger("[Adapters] " .. tostring(message))
    end
end

function Manager.initialize(deviceRegistry, logFunction)
    registry = deviceRegistry
    logger = logFunction
    attached = {}

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
                    log("unsupported light " .. tostring(id) .. ": " .. tostring(device.adapter_error))
                else
                    initialized = initialized + 1
                end
                break
            end
        end
    end

    log("initialized " .. tostring(initialized) .. " controllable light proxies")
    return initialized
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

    for _, adapter in ipairs(adapters) do
        if adapter.reset then
            adapter.reset()
        end
    end
end

return Manager
