local Version = require("src.core.version")
local Log = require("src.core.log")
local Registry = require("src.core.registry")
local Discovery = require("src.control4.discovery")
local Normalize = require("src.control4.normalize")
local AdapterManager = require("src.adapters.manager")
local Keys = require("src.auth.keys")
local RoomNames = require("src.core.room_names")
local RoomLayout = require("src.core.room_layout")
local Scenes = require("src.core.scenes")
local Profiles = require("src.auth.profiles")
local Pairing = require("src.auth.pairing")
local Api = require("src.api.server")
local Relay = require("src.cloud.relay")
local Remote = require("src.cloud.remote")
local Invitations = require("src.auth.invitations")

local LIFECYCLE_KEYS = {
    reload_count = "directorlink_reload_count",
    last_init_type = "directorlink_last_init_type",
    last_init_time = "directorlink_last_init_time",
    last_destroy_type = "directorlink_last_destroy_type",
    last_destroy_time = "directorlink_last_destroy_time",
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

-- A key was created, changed or revoked: profiles nobody uses go, then Composer's count and the
-- cloud's list of key ids.
local function keysChanged()
    Profiles.prune(Keys.list())
    publishKeyCount()
    Relay.announceKeys()
end

-- Keys from before 0.12.0 (or whose profile is gone) each get a profile of their own.
local function assignProfiles()
    local assigned = 0
    for _, key in ipairs(Keys.list()) do
        if not (key.profile and Profiles.find(key.profile)) then
            local profile = Profiles.create(key.name)
            if profile then
                Keys.update(key.id, { profile = profile.id })
                assigned = assigned + 1
            end
        end
    end
    local removed = Profiles.prune(Keys.list())
    if assigned > 0 or removed > 0 then
        Log.info("auth", "profiles updated", { new = assigned, removed = removed })
    end
end

local services = {
    registry = Registry,
    adapters = AdapterManager,
    keys = Keys,
    profiles = Profiles,
    invitations = Invitations,
    pairing = Pairing,
    log = Log,
    -- Remote access with accounts (src/cloud/remote.lua, src/api/handlers/remote.lua).
    remote = {
        enabled = function()
            return Properties ~= nil and Properties["Remote Access"] == "On"
        end,
        connected = function()
            return Relay.connected()
        end,
        available = function()
            return Remote.available()
        end,
        homeId = function()
            return Relay.identity().home_id
        end,
        createClaim = function(keyId)
            return Remote.createClaim(keyId)
        end,
    },
    startedAt = os.time(),
    controllerVersion = nil,
    lifecycle = lifecycle,
    -- Opening doors and gates from the API needs the Composer property "Door Control" = Enabled.
    doorControlEnabled = function()
        return Properties ~= nil and Properties["Door Control"] == "Enabled"
    end,
    status = function()
        return { state = STATE.status, detail = STATE.detail }
    end,
    onKeysChanged = keysChanged,
    onLogLevelChanged = function(level)
        updateProperty("Log Level", COMPOSER_LEVEL[level] or "Info")
    end,
    onServerStatus = function(online, status)
        updateProperty("API Status", online and ("Online - port " .. Api.PORT) or ("Offline (" .. status .. ")"))
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
    updateProperty("Inventory", string.format(
        "%d rooms, %d devices, %d lights, %d thermostats, %d blinds, %d cameras, %d relays, %d doorbells",
        counts.rooms,
        counts.devices,
        counts.supported_lights,
        counts.supported_climate,
        counts.supported_blinds,
        counts.supported_cameras,
        counts.supported_relays,
        counts.supported_doorbells
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

    if not STATE.supported then
        setStatus("error", "Unsupported controller OS (DirectorLink requires 3.3.0 or newer)")
        updateProperty("API Status", "Disabled")
        return
    end

    local keyCount, keysStoredAs, oldKeysStoredAs = Keys.load()
    Log.info("auth", "keys loaded", { count = keyCount, stored_as = keysStoredAs, old_store = oldKeysStoredAs })
    RoomNames.load()
    RoomLayout.load()
    local sceneCount, scenesStoredAs = Scenes.load()
    Log.info("scenes", "scenes loaded", { count = sceneCount, stored_as = scenesStoredAs })
    Profiles.load()
    -- Only with a key store read in full: after a failed read, keys may come back at the next start.
    if Keys.complete() then
        assignProfiles()
    end
    Invitations.load()
    publishKeyCount()

    -- A driver without keys (just added, or all keys revoked) offers a pairing code right away;
    -- otherwise codes are created on demand with the New Pairing Code action.
    local pairingOk, pairingError = Pairing.initialize({
        log = Log,
        openNow = Keys.count() == 0,
        onChange = function(code, status)
            updateProperty("Pairing Code", code)
            updateProperty("Pairing Status", status)
        end,
    })
    if not pairingOk then
        Log.error("auth", "pairing is unavailable", { error = tostring(pairingError) })
    end

    -- Start the API before discovery so health and logs stay reachable if discovery fails.
    Api.init(services)
    local started = Api.start()
    updateProperty("API Status", started and "Starting..." or "Failed to start")

    Log.info("lifecycle", "late init", { init_type = tostring(driverInitType) })
    discover()

    Remote.init({
        services = services,
        handleRequest = Api.handleRequest,
        homeId = function()
            return Relay.identity().home_id
        end,
    })
    Relay.init({
        services = services,
        remote = Remote.handle,
        onStatus = function(text)
            updateProperty("Remote Status", text)
        end,
    })
    if Properties and Properties["Remote Access"] == "On" then
        Relay.start()
    else
        updateProperty("Remote Status", "Off")
    end
end

function ExecuteCommand(command, params)
    if command ~= "LUA_ACTION" or type(params) ~= "table" then
        return
    end
    if params.ACTION == "NEW_PAIRING_CODE" then
        Pairing.open()
    elseif params.ACTION == "REVOKE_API_KEYS" then
        local count = Keys.revokeAll()
        -- Nobody may join afterwards with an invitation or claim the home with an older token.
        local invitations = Invitations.revokeAll()
        Remote.clearClaim()
        keysChanged()
        Log.warn("auth", "all API keys revoked from Composer", { count = count, invitations = invitations })
    end
end

function OnPropertyChanged(name)
    if name == "Remote Access" and Properties then
        if Properties[name] == "On" then
            Relay.start()
        else
            Relay.stop()
        end
    end
    if name == "Door Control" and Properties then
        Log.info("relay_command", "door control " .. string.lower(tostring(Properties[name])) .. " in Composer")
    end
    if name == "Log Level" and Properties then
        if Log.setLevel(Properties[name]) then
            Log.info("logs", "log level changed from Composer", { level = Log.getLevel() })
        end
    end
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
    AdapterManager.onVariableChanged(idDevice, idVariable, strValue)
end

-- Events of devices DirectorLink registered with C4:RegisterDeviceEvent (relay opened/closed).
function OnDeviceEvent(firingDevice, eventId)
    AdapterManager.onDeviceEvent(firingDevice, eventId)
end

-- The relay's outgoing connection (network binding 6001).
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    Relay.onConnectionStatus(idBinding, nPort, strStatus)
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    Relay.onData(idBinding, nPort, strData)
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
    Relay.stop()
    Api.stop()
    AdapterManager.shutdown()
end
