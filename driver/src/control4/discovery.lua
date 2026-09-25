local Discovery = {}

local PROJECT_PROPERTIES = {
    "Latitude",
    "Longitude",
    "CountryCode",
    "CountryName",
    "CityName",
    "ZipCode",
    "Use24HourClock",
    "TemperatureScale",
}

local function safeCall(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

function Discovery.readProjectMetadata()
    local metadata = {
        timezone = safeCall(function()
            return C4:GetTimeZone()
        end),
        systemType = safeCall(function()
            return C4:GetSystemType()
        end),
        bootId = safeCall(function()
            return C4:GetBootID()
        end),
        bridgeDeviceId = safeCall(function()
            return C4:GetDeviceID()
        end),
        properties = {},
    }

    for _, propertyName in ipairs(PROJECT_PROPERTIES) do
        metadata.properties[propertyName] = safeCall(function()
            return C4:GetProjectProperty(propertyName)
        end)
    end

    return metadata
end

function Discovery.readHierarchy()
    return C4:GetProjectHierarchy() or {}
end

function Discovery.readDevices()
    -- An empty filter table is documented to return all project devices.
    return C4:GetDevices({}) or {}
end

function Discovery.collect()
    return {
        metadata = Discovery.readProjectMetadata(),
        hierarchy = Discovery.readHierarchy(),
        devices = Discovery.readDevices(),
    }
end

return Discovery
