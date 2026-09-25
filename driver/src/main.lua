local Version = require("src.core.version")
local Registry = require("src.core.registry")
local Discovery = require("src.control4.discovery")
local Normalize = require("src.control4.normalize")
local HttpServer = require("src.server.http")
local AdapterManager = require("src.adapters.manager")
local Diagnostics = require("src.core.diagnostics")

local API_TOKEN_KEY = "c4bridge_api_token"
local RELOAD_COUNT_KEY = "c4bridge_reload_count"
local LAST_INIT_TYPE_KEY = "c4bridge_last_init_type"
local LAST_INIT_TIME_KEY = "c4bridge_last_init_time"
local LAST_DESTROY_TYPE_KEY = "c4bridge_last_destroy_type"
local LAST_DESTROY_TIME_KEY = "c4bridge_last_destroy_time"

local STATE = {
    directorVersion = nil,
    supported = false,
    apiToken = nil,
}

local updateProperty

local function log(message)
    print("[C4Bridge] " .. tostring(message))
    Diagnostics.info("driver", tostring(message))
end

local function lifecycleTime()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function persistValue(key, value)
    pcall(function()
        C4:PersistSetValue(key, tostring(value or ""), false)
    end)
end

local function readPersisted(key, defaultValue)
    local ok, value = pcall(function()
        return C4:PersistGetValue(key, false)
    end)
    if ok and value ~= nil and tostring(value) ~= "" then
        return value
    end
    return defaultValue
end

local function recordInit(driverInitType)
    local count = tonumber(readPersisted(RELOAD_COUNT_KEY, "0")) or 0
    count = count + 1

    local initType = tostring(driverInitType or "nil")
    local initTime = lifecycleTime()

    persistValue(RELOAD_COUNT_KEY, count)
    persistValue(LAST_INIT_TYPE_KEY, initType)
    persistValue(LAST_INIT_TIME_KEY, initTime)

    Diagnostics.info("lifecycle", "driver init", {
        type = initType,
        time = initTime,
        reload_count = count,
    })
end

local function recordDestroy(driverInitType)
    local destroyType = tostring(driverInitType or "nil")
    local destroyTime = lifecycleTime()

    persistValue(LAST_DESTROY_TYPE_KEY, destroyType)
    persistValue(LAST_DESTROY_TIME_KEY, destroyTime)

    Diagnostics.info("lifecycle", "driver destroy", {
        type = destroyType,
        time = destroyTime,
        reload_count = tonumber(readPersisted(RELOAD_COUNT_KEY, "0")) or 0,
    })
end

updateProperty = function(name, value)
    C4:UpdateProperty(name, tostring(value or ""))
end

local function updateLifecycleProperties()
    updateProperty("Reload Counter", readPersisted(RELOAD_COUNT_KEY, "0"))
    updateProperty("Last Init Type", readPersisted(LAST_INIT_TYPE_KEY, ""))
    updateProperty("Last Init Time", readPersisted(LAST_INIT_TIME_KEY, ""))
    updateProperty("Last Destroy Type", readPersisted(LAST_DESTROY_TYPE_KEY, ""))
    updateProperty("Last Destroy Time", readPersisted(LAST_DESTROY_TIME_KEY, ""))
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
        diagnostics = Diagnostics,
        version = Version,
        directorVersion = STATE.directorVersion,
        log = log,
        onStatus = function(isOnline, status)
            if isOnline then
                updateProperty("API Status", "Online - light control alpha")
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
    recordInit(driverInitType)

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
    updateLifecycleProperties()

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
    recordDestroy(driverInitType)
    HttpServer.stop()
    AdapterManager.shutdown()
    log("destroyed (" .. tostring(driverInitType) .. ")")
end
