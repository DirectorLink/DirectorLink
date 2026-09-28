-- Remote access (docs/RELAY.md, docs/ACCOUNTS.md): one outgoing WebSocket to the DirectorLink
-- relay, kept open while the Composer property "Remote Access" is On. Everything the relay passes
-- on is sealed end to end and handled by remote.lua; the plain requests of version 0 are refused,
-- so the relay cannot read the home.

local Json = require("src.core.json")
local Store = require("src.core.store")
local Version = require("src.core.version")
local WebSocket = require("src.cloud.websocket")

local Relay = {}

Relay.HOST = "api.directorlink.io"
Relay.PORT = 443
Relay.PATH = "/relay/connect"
Relay.BINDING = 6001
Relay.KEEPALIVE_MS = 25000
Relay.SILENCE_SECONDS = 60
Relay.BACKOFF_SECONDS = { 5, 10, 30, 60 }
Relay.REFUSED_RETRY_SECONDS = 300

local IDENTITY_KEY = "directorlink_remote_identity"
-- 0.9.0 kept the identity encrypted under this name; it is moved when Director can still read it.
local OLD_IDENTITY_KEY = "DIRECTORLINK_REMOTE_IDENTITY"

local state = {
    enabled = false,
    socket = nil,
    identity = nil,
    attempts = 0,
    connectedAt = nil,
    lastHeard = 0,
    keepalive = nil,
    retry = nil,
    services = nil,
    onStatus = nil,
    status = "Off",
}

local function log(level, message, data)
    if state.services and state.services.log then
        state.services.log.write(level, "relay", message, data)
    end
end

local function publish(text)
    state.status = text
    if state.onStatus then
        state.onStatus(text)
    end
end

local function randomHex(length)
    local hex = ""
    while #hex < length do
        hex = hex .. tostring(C4:UUID("RANDOM")):gsub("[^%x]", ""):lower()
    end
    return hex:sub(1, length)
end

local function readIdentity(name, encrypted)
    local stored, form = Store.read(name, encrypted)
    if type(stored) == "table" and type(stored.home_id) == "string" and type(stored.home_secret) == "string" then
        return { home_id = stored.home_id, home_secret = stored.home_secret }, form
    end
    return nil, form
end

-- The home's identity: a public id and a secret, kept in the driver's data.
function Relay.identity()
    if state.identity then
        return state.identity
    end
    local identity, form = readIdentity(IDENTITY_KEY, false)
    local moved = false
    if not identity then
        identity = readIdentity(OLD_IDENTITY_KEY, true)
        moved = identity ~= nil
        form = moved and "moved" or "created"
        identity = identity or { home_id = randomHex(32), home_secret = randomHex(64) }
    end
    -- Anything not stored the current way is written again, so the next load reads it as it is.
    if form ~= "json" and Store.write(IDENTITY_KEY, identity, false) and moved then
        Store.write(OLD_IDENTITY_KEY, {}, true)
    end
    state.identity = identity
    log("info", form == "created" and "remote identity created" or "remote identity loaded",
        { home_id = identity.home_id, stored_as = form })
    return identity
end

local function cancel(timer)
    if timer then
        pcall(function()
            timer:Cancel()
        end)
    end
end

local function stopTimers()
    cancel(state.keepalive)
    cancel(state.retry)
    state.keepalive = nil
    state.retry = nil
end

local connect

local function scheduleReconnect(reason, seconds)
    stopTimers()
    state.connectedAt = nil
    if not state.enabled then
        return
    end
    if not seconds then
        state.attempts = state.attempts + 1
        seconds = Relay.BACKOFF_SECONDS[math.min(state.attempts, #Relay.BACKOFF_SECONDS)]
    end
    publish("Reconnecting in " .. seconds .. " s (" .. tostring(reason) .. ")")
    pcall(function()
        state.retry = C4:SetTimer(seconds * 1000, function()
            state.retry = nil
            connect()
        end, false)
    end)
end

local function send(message)
    if state.socket then
        state.socket:send(type(message) == "string" and message or Json.encode(message))
    end
end

-- Version 0 relayed plain requests. Since 0.10.0 every remote request is sealed (remote.lua), so a
-- plain one is answered 410 without reaching the API: the relay cannot read the home.
local function refuseRequest(message)
    if type(message.id) ~= "string" or message.id == "" then
        return
    end
    log("warn", "refused a plain relayed request")
    send({
        type = "response",
        id = message.id,
        status = 410,
        content_type = "application/problem+json",
        body = Json.encode({
            type = "about:blank",
            title = "Gone",
            status = 410,
            code = "RELAY_REQUESTS_RETIRED",
            detail = "Plain relayed requests are refused; remote requests are sealed end to end (docs/ACCOUNTS.md)",
        }),
    })
end

local function onMessage(text, kind)
    state.lastHeard = os.time()
    if kind == "pong" or text == "pong" then
        return
    end
    local message = Json.decode(text or "")
    if type(message) ~= "table" then
        log("debug", "ignored a relay message that is not JSON")
        return
    end
    -- Sealed requests, invitations and claims (remote.lua).
    if state.remote and state.remote(message, send) then
        return
    end
    if message.type == "request" then
        refuseRequest(message)
    else
        log("debug", "ignored relay message", { type = tostring(message.type) })
    end
end

local function startKeepalive()
    cancel(state.keepalive)
    pcall(function()
        state.keepalive = C4:SetTimer(Relay.KEEPALIVE_MS, function()
            if os.time() - state.lastHeard > Relay.SILENCE_SECONDS then
                log("warn", "no answer from the relay; reconnecting")
                if state.socket then
                    state.socket:close(nil, true)
                end
                scheduleReconnect("no answer")
                return
            end
            send("ping")
        end, true)
    end)
end

-- Which API keys exist, as key ids only (the cloud sees them in every envelope anyway). The cloud
-- keeps which account uses which key; a member whose keys are all revoked leaves the home.
function Relay.announceKeys()
    if not state.socket or not state.services or not state.services.keys then
        return
    end
    local ids = Json.array()
    for _, key in ipairs(state.services.keys.list()) do
        ids[#ids + 1] = key.id
    end
    send({ type = "keys", ids = ids })
end

local function onOpen()
    state.attempts = 0
    state.lastHeard = os.time()
    state.connectedAt = os.time()
    local identity = Relay.identity()
    send({ type = "hello", home = identity.home_id, version = Version.BRIDGE_VERSION })
    Relay.announceKeys()
    startKeepalive()
    publish("Connected since " .. os.date("%H:%M", state.connectedAt) .. " - home " .. identity.home_id:sub(1, 8))
    log("info", "connected to the relay", { home_id = identity.home_id })
end

local function onClose(reason, status, body)
    if not state.enabled then
        return
    end
    if reason == "refused" then
        local problem = Json.decode(body or "")
        local detail = type(problem) == "table" and (problem.code or problem.detail) or ("HTTP " .. tostring(status))
        log("warn", "the relay refused the connection", { status = status, detail = tostring(detail) })
        scheduleReconnect("refused: " .. tostring(detail), status == 401 and Relay.REFUSED_RETRY_SECONDS or nil)
        return
    end
    log("info", "relay connection closed", { reason = tostring(reason) })
    scheduleReconnect(reason)
end

connect = function()
    if not state.enabled then
        return
    end
    local identity = Relay.identity()
    if not state.socket then
        state.socket = WebSocket.new({
            binding = Relay.BINDING,
            host = Relay.HOST,
            port = Relay.PORT,
            path = Relay.PATH,
            log = state.services and state.services.log,
            onOpen = onOpen,
            onMessage = onMessage,
            onClose = onClose,
        })
    end
    state.socket.headers = {
        { "Authorization", "Bearer " .. identity.home_secret },
        { "X-DirectorLink-Home", identity.home_id },
        { "X-DirectorLink-Version", Version.BRIDGE_VERSION },
        { "User-Agent", "DirectorLink/" .. Version.BRIDGE_VERSION },
    }
    publish("Connecting...")
    state.socket:connect()
end

-- options: { services, onStatus = function(text), remote = Remote.handle }
function Relay.init(options)
    state.services = options.services
    state.onStatus = options.onStatus
    state.remote = options.remote
end

-- True while the relay connection is up.
function Relay.connected()
    return state.enabled and state.connectedAt ~= nil
end

function Relay.start()
    if state.enabled then
        return
    end
    state.enabled = true
    state.attempts = 0
    log("info", "remote access switched on")
    connect()
end

function Relay.stop()
    local wasEnabled = state.enabled
    state.enabled = false
    stopTimers()
    if state.socket then
        state.socket:close()
    end
    state.connectedAt = nil
    publish("Off")
    if wasEnabled then
        log("info", "remote access switched off")
    end
end

function Relay.isEnabled()
    return state.enabled
end

function Relay.status()
    return state.status
end

-- Director network callbacks (routed by main.lua).
function Relay.onConnectionStatus(binding, port, status)
    if tonumber(binding) == Relay.BINDING and state.socket then
        log("debug", "relay connection status", { status = tostring(status) })
        state.socket:onConnectionStatus(status)
    end
end

function Relay.onData(binding, port, data)
    if tonumber(binding) == Relay.BINDING and state.socket then
        state.socket:onData(data)
    end
end

-- Test support: forget everything (a fresh driver instance).
function Relay.reset()
    Relay.stop()
    state.socket = nil
    state.identity = nil
    state.status = "Off"
end

return Relay
