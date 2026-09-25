local Registry = {
    metadata = {},
    locations = {},
    rooms = {},
    devices = {},
    protocols = {},
    refreshedAt = nil,
}

local function count(values)
    local total = 0
    for _, _ in pairs(values or {}) do
        total = total + 1
    end
    return total
end

function Registry.reset()
    Registry.metadata = {}
    Registry.locations = {}
    Registry.rooms = {}
    Registry.devices = {}
    Registry.protocols = {}
    Registry.refreshedAt = nil
end

function Registry.replace(normalized)
    Registry.metadata = normalized.metadata or {}
    Registry.locations = normalized.locations or {}
    Registry.rooms = normalized.rooms or {}
    Registry.devices = normalized.devices or {}
    Registry.protocols = normalized.protocols or {}
    Registry.refreshedAt = os.time()
end

function Registry.getDevice(id)
    return Registry.devices[tonumber(id)]
end

function Registry.counts()
    local recognized = 0
    local unsupported = 0

    for _, device in pairs(Registry.devices) do
        if device.recognized then
            recognized = recognized + 1
        else
            unsupported = unsupported + 1
        end
    end

    return {
        locations = count(Registry.locations),
        rooms = count(Registry.rooms),
        devices = count(Registry.devices),
        protocols = count(Registry.protocols),
        recognized = recognized,
        unsupported = unsupported,
    }
end

function Registry.snapshot()
    return {
        metadata = Registry.metadata,
        locations = Registry.locations,
        rooms = Registry.rooms,
        devices = Registry.devices,
        protocols = Registry.protocols,
        refreshedAt = Registry.refreshedAt,
    }
end

return Registry
