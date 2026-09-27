-- Remote access, proof of concept (docs/RELAY.md): one outgoing WebSocket to the DirectorLink
-- relay, kept open while the Composer property "Remote Access" is On. Requests that arrive over it
-- run through the same API server as LAN requests, always as a read-only (viewer) principal.

local Json = require("src.core.json")
local Http = require("src.api.http")
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
-- Version 0: whatever the relay asks, relayed requests may only read.
Relay.ROLE = "viewer"

local IDENTITY_KEY = "DIRECTORLINK_REMOTE_IDENTITY"

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
    handleRequest = nil,
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

-- The home's identity: a public id and a secret, kept encrypted in the driver's data.
function Relay.identity()
    if state.identity then
        return state.identity
    end
    local ok, raw = pcall(function()
        return C4:PersistGetValue(IDENTITY_KEY, true)
    end)
    local stored = ok and type(raw) == "string" and Json.decode(raw) or nil
    if type(stored) == "table" and type(stored.home_id) == "string" and type(stored.home_secret) == "string" then
        state.identity = stored
        return stored
    end
    local identity = { home_id = randomHex(32), home_secret = randomHex(64) }
    pcall(function()
        C4:PersistSetValue(IDENTITY_KEY, Json.encode(identity), true)
    end)
    state.identity = identity
    log("info", "remote identity created", { home_id = identity.home_id })
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

local function isText(contentType)
    local value = string.lower(tostring(contentType or ""))
    return value == "" or value:find("json", 1, true) ~= nil or value:find("^text/") ~= nil
end

local function headerValue(headers, name)
    for _, header in ipairs(headers or {}) do
        if string.lower(header[1]) == name then
            return header[2]
        end
    end
    return nil
end

local function respond(id, status, headers, body)
    local contentType = headerValue(headers, "content-type") or ""
    local message = { type = "response", id = id, status = status, content_type = contentType }
    if isText(contentType) then
        message.body = body or ""
    else
        message.body_base64 = C4:Base64Encode(body or "")
    end
    send(message)
end

-- A relayed request, run as a viewer through the LAN API code.
local function handleRequest(message)
    local id = message.id
    if type(id) ~= "string" or id == "" then
        return
    end
    local method = tostring(message.method or "GET")
    local target = tostring(message.path or "")
    local path, query = target:match("^([^?]*)%??(.*)$")
    if method ~= "GET" or not path or path:sub(1, 4) ~= "/v1/" then
        respond(id, 405, { { "Content-Type", "application/problem+json" } }, Json.encode({
            type = "about:blank", title = "Method Not Allowed", status = 405,
            code = "RELAY_READ_ONLY", detail = "Remote access (test) only reads: GET /v1/...",
        }))
        return
    end
    local request = {
        method = "GET",
        path = path,
        query = Http.parseQuery(query or ""),
        headers = {},
        body = "",
        principal = { id = "relay", name = "Remote access (test)", role = Relay.ROLE },
    }
    local client = { ip = "relay", port = "0" }
    local status, headers, body = state.handleRequest(request, client, function(laterStatus, laterHeaders, laterBody)
        respond(id, laterStatus, laterHeaders, laterBody)
    end)
    if status then
        respond(id, status, headers, body)
    end
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
    if message.type == "request" then
        local ok, err = pcall(handleRequest, message)
        if not ok then
            log("error", "relayed request failed", { error = tostring(err) })
            respond(message.id, 500, { { "Content-Type", "application/problem+json" } },
                Json.encode({ type = "about:blank", title = "Internal Server Error", status = 500, code = "INTERNAL" }))
        end
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

local function onOpen()
    state.attempts = 0
    state.lastHeard = os.time()
    state.connectedAt = os.time()
    local identity = Relay.identity()
    send({ type = "hello", home = identity.home_id, version = Version.BRIDGE_VERSION })
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

-- options: { services, handleRequest = Server.handleRequest, onStatus = function(text) }
function Relay.init(options)
    state.services = options.services
    state.handleRequest = options.handleRequest
    state.onStatus = options.onStatus
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
