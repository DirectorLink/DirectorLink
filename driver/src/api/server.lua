-- C4Bridge LAN API server: DriverWorks TCP server + HTTP parsing + CORS + API-key auth +
-- routing + RFC 9457 errors + access logging.

local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Http = require("src.api.http")
local Router = require("src.api.router")
local Routes = require("src.api.routes")
local Problem = require("src.api.problem")

local HANDLERS = {
    system = require("src.api.handlers.system"),
    auth = require("src.api.handlers.auth"),
    rooms = require("src.api.handlers.rooms"),
    devices = require("src.api.handlers.devices"),
    lights = require("src.api.handlers.lights"),
    thermostats = require("src.api.handlers.thermostats"),
    logs = require("src.api.handlers.logs"),
}

local Server = {}

Server.PORT = 41999

local ALLOWED_ORIGINS = {
    ["https://app.c4bridge.io"] = true,
    ["https://c4bridge.io"] = true,
}

-- Connections that never finish a request are dropped after this many seconds.
local STALE_CONNECTION_SECONDS = 30

local router = Router.new(Routes)
local services = nil
local connections = {}
local listening = false

local function resolveHandler(name)
    local moduleName, functionName = name:match("^([%w_]+)%.([%w_]+)$")
    local module = HANDLERS[moduleName]
    return module and module[functionName]
end

for _, route in ipairs(Routes) do
    assert(resolveHandler(route.handler), "missing API handler " .. route.handler)
end

-- Browsers send Origin; other clients (curl, Postman, Home Assistant) do not.
-- localhost origins are allowed so the web app can be tested from a local server.
function Server.originAllowed(origin)
    if origin == nil or origin == "" then
        return true
    end
    if ALLOWED_ORIGINS[origin] then
        return true
    end
    return origin:match("^http://localhost:?%d*$") ~= nil
        or origin:match("^http://127%.0%.0%.1:?%d*$") ~= nil
end

local function authenticate(request)
    local header = request.headers["authorization"]
    if not header then
        return nil
    end
    local scheme, token = header:match("^(%S+)%s+(%S+)%s*$")
    if not scheme or string.lower(scheme) ~= "bearer" then
        return nil
    end
    return services.keys.verify(token)
end

local function decodeBody(request)
    if request.body == nil or request.body == "" then
        return nil
    end
    local contentType = string.lower(request.headers["content-type"] or "")
    if not contentType:find("application/json", 1, true) then
        return nil, Problem.new(415, "UNSUPPORTED_MEDIA_TYPE", "Send the request body as application/json")
    end
    local value, err = Json.decode(request.body)
    if value == nil then
        return nil, Problem.new(400, "INVALID_JSON", "The request body is not valid JSON: " .. tostring(err))
    end
    return value
end

local function runHandler(route, request, params, apiKey, client)
    local body, bodyProblem = decodeBody(request)
    if bodyProblem then
        return bodyProblem.status, bodyProblem
    end

    local ctx = {
        request = request,
        params = params,
        query = request.query,
        body = body,
        apiKey = apiKey,
        client = client,
        services = services,
    }

    local ok, first, second, third = pcall(resolveHandler(route.handler), ctx)
    if not ok then
        services.log.error("api", "handler failed", {
            route = route.method .. " " .. route.path,
            error = tostring(first),
        })
        local problem = Problem.internal()
        return problem.status, problem
    end
    if Problem.is(first) then
        return first.status, first, second
    end
    return first, second, third
end

local function encode(status, payload)
    if payload == nil or status == 204 then
        return nil, ""
    end
    if type(payload) == "string" then
        return "application/json; charset=utf-8", payload
    end
    local ok, body = pcall(Json.encode, payload)
    if not ok then
        services.log.error("api", "response could not be encoded", { error = tostring(body) })
        return "application/problem+json", Json.encode(Problem.internal("The response could not be encoded")), 500
    end
    if Problem.is(payload) then
        return "application/problem+json", body
    end
    return "application/json; charset=utf-8", body
end

local function logAccess(request, status, client, started, apiKey)
    local level = "debug"
    if status >= 500 then
        level = "error"
    elseif status >= 400 then
        level = "info"
    end
    services.log.write(level, "api", request.method .. " " .. request.path .. " -> " .. tostring(status), {
        client = client and client.ip or Json.null,
        duration_ms = Clock.millis() - started,
        key_id = apiKey and apiKey.id or Json.null,
    })
end

-- Handles one parsed request; returns status, headers, body. Used directly by tests.
function Server.handleRequest(request, client)
    local started = Clock.millis()
    local origin = request.headers["origin"]
    local status, payload, extraHeaders, apiKey

    if not Server.originAllowed(origin) then
        status = 403
        payload = Problem.new(403, "ORIGIN_NOT_ALLOWED", "Requests from " .. tostring(origin) .. " are not allowed")
        origin = nil
    elseif request.method == "OPTIONS" then
        status = 204
        extraHeaders = {
            { "Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS" },
            { "Access-Control-Allow-Headers", "Authorization, Content-Type" },
            { "Access-Control-Max-Age", "600" },
            { "Access-Control-Allow-Private-Network", "true" },
        }
    else
        local match = router:match(request.method, request.path)
        if match.error == "not_found" then
            status = 404
            payload = Problem.new(404, "NOT_FOUND", "No API route for " .. request.path)
        elseif match.error == "method_not_allowed" then
            status = 405
            payload = Problem.new(405, "METHOD_NOT_ALLOWED", request.method .. " is not supported for " .. request.path)
            extraHeaders = { { "Allow", table.concat(match.allowed, ", ") } }
        else
            if not match.route.public then
                apiKey = authenticate(request)
            end
            if not match.route.public and not apiKey then
                status = 401
                payload = Problem.unauthorized()
                extraHeaders = { { "WWW-Authenticate", 'Bearer realm="C4Bridge"' } }
            else
                status, payload, extraHeaders = runHandler(match.route, request, match.params, apiKey, client)
            end
        end
    end

    local contentType, body, encodeStatus = encode(status, payload)
    status = encodeStatus or status

    local headers = {}
    if origin then
        headers[#headers + 1] = { "Access-Control-Allow-Origin", origin }
        headers[#headers + 1] = { "Vary", "Origin" }
    end
    headers[#headers + 1] = { "Cache-Control", "no-store" }
    headers[#headers + 1] = { "X-Content-Type-Options", "nosniff" }
    if contentType then
        headers[#headers + 1] = { "Content-Type", contentType }
    end
    for _, header in ipairs(extraHeaders or {}) do
        headers[#headers + 1] = header
    end

    logAccess(request, status, client, started, apiKey)
    return status, headers, body
end

local function send(handle, status, headers, body)
    local ok, err = pcall(function()
        C4:ServerSend(handle, Http.buildResponse(status, headers, body))
        C4:ServerCloseClient(handle)
    end)
    if not ok then
        services.log.warn("api", "could not send a response", { error = tostring(err) })
    end
end

local function dropStaleConnections(now)
    for handle, connection in pairs(connections) do
        if now - connection.openedAt > STALE_CONNECTION_SECONDS then
            connections[handle] = nil
            pcall(function()
                C4:ServerCloseClient(handle)
            end)
        end
    end
end

function Server.init(options)
    services = options
end

function Server.start()
    if listening then
        return true
    end
    -- No delimiter: Director hands over data as it arrives and the parser assembles requests.
    local ok, err = pcall(function()
        C4:CreateServer(Server.PORT, "", false)
    end)
    if not ok then
        services.log.error("api", "could not start the API server", { port = Server.PORT, error = tostring(err) })
        return false, tostring(err)
    end
    return true
end

function Server.stop()
    pcall(function()
        C4:DestroyServer(Server.PORT)
    end)
    listening = false
    connections = {}
end

function Server.isListening()
    return listening
end

function Server.onStatusChanged(port, status)
    if not services or tonumber(port) ~= Server.PORT then
        return
    end
    listening = tostring(status) == "ONLINE"
    services.log.info("api", "API server " .. tostring(status), { port = Server.PORT })
    if services.onServerStatus then
        services.onServerStatus(listening, tostring(status))
    end
end

function Server.onConnectionStatusChanged(handle, _port, status)
    if tostring(status) == "OFFLINE" then
        connections[handle] = nil
    end
end

function Server.onData(handle, data, clientAddress, clientPort)
    if not services then
        return
    end
    local now = os.time()
    local connection = connections[handle]
    if not connection then
        dropStaleConnections(now)
        connection = {
            parser = Http.newParser(),
            client = { ip = clientAddress, port = clientPort },
            openedAt = now,
        }
        connections[handle] = connection
    end

    local result, value = Http.feed(connection.parser, data)
    if result == "incomplete" then
        return
    elseif result == "continue" then
        pcall(function()
            C4:ServerSend(handle, "HTTP/1.1 100 Continue\r\n\r\n")
        end)
        return
    end

    connections[handle] = nil

    if result == "error" then
        services.log.warn("api", "rejected a malformed request", {
            client = clientAddress,
            status = value.status,
            reason = value.detail,
        })
        local problem = Problem.new(value.status, value.code, value.detail)
        send(handle, problem.status, {
            { "Cache-Control", "no-store" },
            { "Content-Type", "application/problem+json" },
        }, Json.encode(problem))
        return
    end

    send(handle, Server.handleRequest(value, connection.client))
end

return Server
