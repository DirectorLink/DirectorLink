local Version = require("src.core.version")
local Registry = require("src.core.registry")
local Discovery = require("src.control4.discovery")
local Normalize = require("src.control4.normalize")
local HttpServer = require("src.server.http")
local AdapterManager = require("src.adapters.manager")

local API_TOKEN_KEY = "c4bridge_api_token"

local STATE = {
    directorVersion = nil,
    supported = false,
    apiToken = nil,
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

local function ensureApiToken()
    local token = C4:PersistGetValue(API_TOKEN_KEY, true)
    if type(token) == "string" and token ~= "" then
        return token
    end

    local generated, err = C4:UUID("RANDOM")
    if not generated then
        log("unable to generate API token: " .. tostring(err))
        return nil
    end

    C4:PersistSetValue(API_TOKEN_KEY, generated, true)
    return generated
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

local function startLanApi()
    if not STATE.apiToken then
        updateProperty("API Status", "Offline (token generation failed)")
        return
    end

    HttpServer.init({
        token = STATE.apiToken,
        registry = Registry,
        actions = AdapterManager,
        version = Version,
        directorVersion = STATE.directorVersion,
        log = log,
        onStatus = function(isOnline, status)
            if isOnline then
                updateProperty("API Status", "Online - read-only alpha")
            else
                updateProperty("API Status", "Offline (" .. tostring(status) .. ")")
            end
        end,
    })

    updateProperty("API Port", HttpServer.port())
    updateProperty("API Token", STATE.apiToken)
    updateProperty("API Status", "Starting...")

    local started, err = HttpServer.start()
    if not started then
        updateProperty("API Status", "Failed to start: " .. tostring(err))
    end
end

function OnDriverInit(driverInitType)
    STATE.directorVersion = readDirectorVersion()
    STATE.supported = Version.isSupported(STATE.directorVersion)

    log("loading " .. Version.BRIDGE_VERSION .. " (" .. tostring(driverInitType) .. ")")
    log("Director OS: " .. tostring(STATE.directorVersion))

    if not STATE.supported then
        log("unsupported Director OS; C4Bridge requires 3.3.0+")
        return
    end

    STATE.apiToken = ensureApiToken()
end

function OnDriverLateInit(driverInitType)
    log("late init (" .. tostring(driverInitType) .. ")")

    updateProperty("Bridge Version", Version.BRIDGE_VERSION)
    updateProperty("Director Version", STATE.directorVersion or "Unknown")

    if not STATE.supported then
        updateProperty("Status", "Unsupported Director OS (requires 3.3.0+)")
        updateProperty("API Status", "Disabled")
        return
    end

    updateProperty("Status", "Discovering project...")

    local ok, raw = pcall(Discovery.collect)
    if not ok then
        local message = "Discovery failed: " .. tostring(raw)
        log(message)
        updateProperty("Status", message)
        updateProperty("API Status", "Disabled (discovery failed)")
        return
    end

    local normalizeOk, normalized = pcall(Normalize.project, raw)
    if not normalizeOk then
        local message = "Normalization failed: " .. tostring(normalized)
        log(message)
        updateProperty("Status", message)
        updateProperty("API Status", "Disabled (normalization failed)")
        return
    end

    Registry.reset()
    Registry.replace(normalized)

    local supportedLights = AdapterManager.initialize(Registry, log)

    local metadata = Registry.metadata
    updateProperty("System Type", metadata.systemType or "Unknown")
    updateProperty("Project Location", projectLocation(metadata))
    updateProperty("Discovery Summary", discoverySummary())
    updateProperty("Supported Lights", supportedLights)
    updateProperty("Status", "Ready (light adapter initialized)")

    log("discovery complete: " .. discoverySummary())

    startLanApi()
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
    AdapterManager.onVariableChanged(idDevice, idVariable, strValue)
end

function OnServerStatusChanged(port, status)
    HttpServer.onStatusChanged(port, status)
end

function OnServerConnectionStatusChanged(handle, remotePort, status, clientIp)
    HttpServer.onConnectionStatusChanged(handle, remotePort, status, clientIp)
end

function OnServerDataIn(handle, data, clientAddress, clientPort)
    HttpServer.onData(handle, data, clientAddress, clientPort)
end

function OnDriverDestroyed(driverInitType)
    HttpServer.stop()
    AdapterManager.shutdown()
    log("destroyed (" .. tostring(driverInitType) .. ")")
end
