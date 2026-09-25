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

local function sortedList(values)
    local result = {}
    for _, value in pairs(values or {}) do
        table.insert(result, value)
    end

    table.sort(result, function(a, b)
        local aName = string.lower(tostring(a.name or ""))
        local bName = string.lower(tostring(b.name or ""))
        if aName == bName then
            return tonumber(a.id or 0) < tonumber(b.id or 0)
        end
        return aName < bName
    end)

    return result
end

function Registry.getDevice(id)
    return Registry.devices[tonumber(id)]
end

function Registry.roomList()
    return sortedList(Registry.rooms)
end

function Registry.deviceList()
    return sortedList(Registry.devices)
end

function Registry.lightList()
    local lights = {}

    for id, device in pairs(Registry.devices or {}) do
        if device.kind == "light" and device.supported == true then
            lights[id] = device
        end
    end

    return sortedList(lights)
end

function Registry.climateList()
    local climate = {}

    for id, device in pairs(Registry.devices or {}) do
        if device.kind == "climate" and device.supported == true then
            climate[id] = device
        end
    end

    return sortedList(climate)
end

function Registry.counts()
    local recognized = 0
    local unsupported = 0
    local supported = 0
    local supportedLights = 0
    local supportedClimate = 0

    for _, device in pairs(Registry.devices) do
        if device.recognized then
            recognized = recognized + 1
        else
            unsupported = unsupported + 1
        end

        if device.supported then
            supported = supported + 1
            if device.kind == "light" then
                supportedLights = supportedLights + 1
            elseif device.kind == "climate" then
                supportedClimate = supportedClimate + 1
            end
        end
    end

    return {
        locations = count(Registry.locations),
        rooms = count(Registry.rooms),
        devices = count(Registry.devices),
        protocols = count(Registry.protocols),
        recognized = recognized,
        unsupported = unsupported,
        supported = supported,
        supported_lights = supportedLights,
        supported_climate = supportedClimate,
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
