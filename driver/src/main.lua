local Version = require("src.core.version")
local Log = require("src.core.log")
local Registry = require("src.core.registry")
local Discovery = require("src.control4.discovery")
local Normalize = require("src.control4.normalize")
local AdapterManager = require("src.adapters.manager")
local Keys = require("src.auth.keys")
local RoomNames = require("src.core.room_names")
local Pairing = require("src.auth.pairing")
local Approvals = require("src.auth.approvals")
local Navigator = require("src.control4.navigator")
local Api = require("src.api.server")

local LIFECYCLE_KEYS = {
    reload_count = "c4bridge_reload_count",
    last_init_type = "c4bridge_last_init_type",
    last_init_time = "c4bridge_last_init_time",
    last_destroy_type = "c4bridge_last_destroy_type",
    last_destroy_time = "c4bridge_last_destroy_time",
}

-- Composer's "Log Level" list uses these labels.
local COMPOSER_LEVEL = {
    debug = "Debug",
    info = "Info",
    warn = "Warning",
    error = "Error",
}

local STATE = {
    controllerVersion = nil,
    supported = false,
    status = "starting",
    detail = nil,
}

local function updateProperty(name, value)
    pcall(function()
        C4:UpdateProperty(name, tostring(value or ""))
    end)
end

local function persistSet(key, value)
    pcall(function()
        C4:PersistSetValue(key, tostring(value or ""), false)
    end)
end

local function persistGet(key)
    local ok, value = pcall(function()
        return C4:PersistGetValue(key, false)
    end)
    if ok and value ~= nil and tostring(value) ~= "" then
        return tostring(value)
    end
    return nil
end

local function lifecycle()
    local snapshot = {}
    for field, key in pairs(LIFECYCLE_KEYS) do
        snapshot[field] = persistGet(key)
    end
    return snapshot
end

local function updateLifecycleProperties()
    local snapshot = lifecycle()
    updateProperty("Reload Counter", snapshot.reload_count or "0")
    updateProperty("Last Init Type", snapshot.last_init_type)
    updateProperty("Last Init Time", snapshot.last_init_time)
    updateProperty("Last Destroy Type", snapshot.last_destroy_type)
    updateProperty("Last Destroy Time", snapshot.last_destroy_time)
end

local function setStatus(status, detail)
    STATE.status = status
    STATE.detail = detail
    if status == "ok" then
        updateProperty("Status", "Ready")
    elseif status == "starting" then
        updateProperty("Status", detail or "Starting...")
    else
        updateProperty("Status", "Error: " .. tostring(detail))
    end
end

local function publishKeyCount()
    updateProperty("API Keys", Keys.count())
end

local services = {
    registry = Registry,
    adapters = AdapterManager,
    keys = Keys,
    pairing = Pairing,
    approvals = Approvals,
    log = Log,
    startedAt = os.time(),
    controllerVersion = nil,
    lifecycle = lifecycle,
    status = function()
        return { state = STATE.status, detail = STATE.detail }
    end,
    onKeysChanged = publishKeyCount,
    onLogLevelChanged = function(level)
        updateProperty("Log Level", COMPOSER_LEVEL[level] or "Info")
    end,
    onServerStatus = function(online, status)
        updateProperty("API Status", online and "Online" or ("Offline (" .. status .. ")"))
    end,
}

local function readControllerVersion()
    local ok, info = pcall(function()
        return C4:GetVersionInfo()
    end)
    if ok and type(info) == "table" then
        return info.version
    end
    return nil
end

local function locationText(metadata)
    local properties = metadata.properties or {}
    local parts = {}
    for _, name in ipairs({ "CityName", "CountryCode" }) do
        if properties[name] and tostring(properties[name]) ~= "" then
            parts[#parts + 1] = tostring(properties[name])
        end
    end
    return table.concat(parts, ", ")
end

local SHOW_BUTTON_ATTEMPTS = 6
local SHOW_BUTTON_DELAY_MS = 5000

local showAccessButton

local function retryShowAccessButton(attempt)
    pcall(function()
        C4:SetTimer(SHOW_BUTTON_DELAY_MS, function()
            showAccessButton(attempt)
        end, false)
    end)
end

-- Makes the C4Bridge Access button visible in the Security section of its room in the Control4
-- app, as Composer's Navigators view would. Runs after the driver is first added, and on demand.
showAccessButton = function(attempt)
    attempt = attempt or 1
    local ok, devices = pcall(function()
        return C4:GetDevices({})
    end)
    local bridgeId = tonumber((pcall(function() return C4:GetDeviceID() end)) and C4:GetDeviceID())
    local buttonId, roomId = Navigator.findAccessButton(bridgeId, ok and devices or nil)

    local result, reason
    if buttonId and roomId then
        result, reason = Navigator.showInSecurity(roomId, buttonId)
    else
        reason = "not_listed"
    end

    if result then
        Log.info("navigator", result == "made_visible"
            and "C4Bridge Access is now visible in the Control4 app (Security)"
            or "C4Bridge Access is already visible in the Control4 app", { room_id = roomId, button_id = buttonId })
    elseif reason == "not_listed" and attempt < SHOW_BUTTON_ATTEMPTS then
        retryShowAccessButton(attempt + 1)
    else
        Log.warn("navigator", "could not show C4Bridge Access in the Control4 app; make it visible in Composer (Navigators, Security)", {
            reason = reason,
            room_id = roomId,
            button_id = buttonId,
        })
    end
    return result, reason
end

local function fail(message)
    Log.error("discovery", message)
    setStatus("error", message)
end

local function discover()
    setStatus("starting", "Discovering project...")

    local ok, raw = pcall(Discovery.collect)
    if not ok then
        fail("Discovery failed: " .. tostring(raw))
        return false
    end

    local normalizeOk, normalized = pcall(Normalize.project, raw)
    if not normalizeOk then
        fail("Normalization failed: " .. tostring(normalized))
        return false
    end

    Registry.reset()
    Registry.replace(normalized)
    AdapterManager.initialize(Registry)

    local counts = Registry.counts()
    updateProperty("Location", locationText(Registry.metadata))
    updateProperty("Inventory", string.format(
        "%d rooms, %d devices, %d lights, %d thermostats, %d blinds, %d cameras, %d relays",
        counts.rooms,
        counts.devices,
        counts.supported_lights,
        counts.supported_climate,
        counts.supported_blinds,
        counts.supported_cameras,
        counts.supported_relays
    ))
    Log.info("discovery", "project discovered", counts)
    setStatus("ok")
    return true
end

function OnDriverInit(driverInitType)
    services.startedAt = os.time()
    if Properties then
        Log.setLevel(Properties["Log Level"])
    end

    local count = (tonumber(persistGet(LIFECYCLE_KEYS.reload_count)) or 0) + 1
    persistSet(LIFECYCLE_KEYS.reload_count, count)
    persistSet(LIFECYCLE_KEYS.last_init_type, tostring(driverInitType or "nil"))
    persistSet(LIFECYCLE_KEYS.last_init_time, os.date("%Y-%m-%d %H:%M:%S"))

    STATE.controllerVersion = readControllerVersion()
    services.controllerVersion = STATE.controllerVersion
    STATE.supported = Version.isSupported(STATE.controllerVersion)

    Log.info("lifecycle", "driver init", {
        version = Version.BRIDGE_VERSION,
        init_type = tostring(driverInitType),
        controller_os = STATE.controllerVersion,
        reload_count = count,
    })
end

function OnDriverLateInit(driverInitType)
    updateProperty("Version", Version.BRIDGE_VERSION)
    updateProperty("Controller OS", STATE.controllerVersion or "Unknown")
    updateProperty("API Port", Api.PORT)
    updateLifecycleProperties()

    if not STATE.supported then
        setStatus("error", "Unsupported controller OS (C4Bridge requires 3.3.0 or newer)")
        updateProperty("API Status", "Disabled")
        return
    end

    Keys.load()
    RoomNames.load()
    publishKeyCount()

    local pairingOk, pairingError = Pairing.initialize({
        log = Log,
        onChange = function(code, status)
            updateProperty("Pairing Code", code)
            updateProperty("Pairing Status", status)
        end,
    })
    if not pairingOk then
        Log.error("auth", "pairing is unavailable", { error = tostring(pairingError) })
    end

    Approvals.initialize({
        log = Log,
        onChange = function(text)
            updateProperty("Access Request", text)
        end,
    })

    -- Start the API before discovery so health and logs stay reachable if discovery fails.
    Api.init(services)
    local started = Api.start()
    updateProperty("API Status", started and "Starting..." or "Failed to start")

    Log.info("lifecycle", "late init", { init_type = tostring(driverInitType) })
    discover()

    -- New buttons are hidden in the Control4 app; show ours once, when the driver is added.
    if tostring(driverInitType) == "DIT_ADDING" then
        retryShowAccessButton(1)
    end
end

function ExecuteCommand(command, params)
    if command ~= "LUA_ACTION" or type(params) ~= "table" then
        return
    end
    if params.ACTION == "NEW_PAIRING_CODE" then
        Pairing.rotate()
    elseif params.ACTION == "SHOW_ACCESS_BUTTON" then
        showAccessButton(SHOW_BUTTON_ATTEMPTS)
    elseif params.ACTION == "REVOKE_API_KEYS" then
        local count = Keys.revokeAll()
        publishKeyCount()
        Log.warn("auth", "all API keys revoked from Composer", { count = count })
    end
end

-- The "C4Bridge Access" button in the Control4 app approves a waiting access request.
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if tonumber(idBinding) == Approvals.BUTTON_BINDING then
        if strCommand == "SELECT" then
            Approvals.onButtonPressed()
        else
            Log.debug("auth", "access button command ignored", { command = tostring(strCommand) })
        end
    end
end

function OnPropertyChanged(name)
    if name == "Log Level" and Properties then
        if Log.setLevel(Properties[name]) then
            Log.info("logs", "log level changed from Composer", { level = Log.getLevel() })
        end
    end
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
    AdapterManager.onVariableChanged(idDevice, idVariable, strValue)
end

-- Events of devices C4Bridge registered with C4:RegisterDeviceEvent (relay opened/closed).
function OnDeviceEvent(firingDevice, eventId)
    AdapterManager.onDeviceEvent(firingDevice, eventId)
end

function OnServerStatusChanged(port, status)
    Api.onStatusChanged(port, status)
end

function OnServerConnectionStatusChanged(handle, port, status)
    Api.onConnectionStatusChanged(handle, port, status)
end

function OnServerDataIn(handle, data, clientAddress, clientPort)
    Api.onData(handle, data, clientAddress, clientPort)
end

function OnDriverDestroyed(driverInitType)
    persistSet(LIFECYCLE_KEYS.last_destroy_type, tostring(driverInitType or "nil"))
    persistSet(LIFECYCLE_KEYS.last_destroy_time, os.date("%Y-%m-%d %H:%M:%S"))
    Log.info("lifecycle", "driver destroyed", { init_type = tostring(driverInitType) })
    Api.stop()
    AdapterManager.shutdown()
end
