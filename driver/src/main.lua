local Version = require("src.core.version")
local Registry = require("src.core.registry")
local Discovery = require("src.control4.discovery")
local Normalize = require("src.control4.normalize")

local STATE = {
    directorVersion = nil,
    supported = false,
}

local function log(message)
    print("[C4Bridge] " .. tostring(message))
end

local function updateProperty(name, value)
    C4:UpdateProperty(name, tostring(value or ""))
end

local function readDirectorVersion()
    local info = C4:GetVersionInfo()
    if type(info) ~= "table" then
        return nil
    end
    return info.version
end

local function projectLocation(metadata)
    local properties = metadata.properties or {}
    local parts = {}

    if properties.CityName and tostring(properties.CityName) ~= "" then
        table.insert(parts, tostring(properties.CityName))
    end
    if properties.CountryCode and tostring(properties.CountryCode) ~= "" then
        table.insert(parts, tostring(properties.CountryCode))
    end

    return table.concat(parts, ", ")
end

local function discoverySummary()
    local counts = Registry.counts()
    return string.format(
        "%d rooms, %d devices, %d protocol drivers, %d recognized, %d unsupported",
        counts.rooms,
        counts.devices,
        counts.protocols,
        counts.recognized,
        counts.unsupported
    )
end

function OnDriverInit(driverInitType)
    STATE.directorVersion = readDirectorVersion()
    STATE.supported = Version.isSupported(STATE.directorVersion)

    log("loading " .. Version.BRIDGE_VERSION .. " (" .. tostring(driverInitType) .. ")")
    log("Director OS: " .. tostring(STATE.directorVersion))

    if not STATE.supported then
        log("unsupported Director OS; C4Bridge requires 3.3.0+")
    end
end

function OnDriverLateInit(driverInitType)
    log("late init (" .. tostring(driverInitType) .. ")")

    updateProperty("Bridge Version", Version.BRIDGE_VERSION)
    updateProperty("Director Version", STATE.directorVersion or "Unknown")

    if not STATE.supported then
        updateProperty("Status", "Unsupported Director OS (requires 3.3.0+)")
        return
    end

    updateProperty("Status", "Discovering project...")

    local ok, raw = pcall(Discovery.collect)
    if not ok then
        local message = "Discovery failed: " .. tostring(raw)
        log(message)
        updateProperty("Status", message)
        return
    end

    local normalizeOk, normalized = pcall(Normalize.project, raw)
    if not normalizeOk then
        local message = "Normalization failed: " .. tostring(normalized)
        log(message)
        updateProperty("Status", message)
        return
    end

    Registry.reset()
    Registry.replace(normalized)

    local metadata = Registry.metadata
    updateProperty("System Type", metadata.systemType or "Unknown")
    updateProperty("Project Location", projectLocation(metadata))
    updateProperty("Discovery Summary", discoverySummary())
    updateProperty("Status", "Ready (discovery complete)")

    log("discovery complete: " .. discoverySummary())
end

function OnDriverDestroyed(driverInitType)
    log("destroyed (" .. tostring(driverInitType) .. ")")
end
