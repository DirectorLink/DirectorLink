local HttpServer = {}

local API_PORT = 41999
local ALLOWED_ORIGINS = {
    ["https://app.c4bridge.io"] = true,
    ["https://c4bridge.io"] = true,
}

local config = nil
local online = false

local STATUS_TEXT = {
    [200] = "OK",
    [202] = "Accepted",
    [204] = "No Content",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [409] = "Conflict",
    [500] = "Internal Server Error",
}

local function log(message)
    if config and config.log then
        config.log("[HTTP] " .. tostring(message))
    end
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function urlDecode(value)
    value = tostring(value or ""):gsub("%+", " ")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function parseQuery(target)
    local result = {}
    local query = target:match("%?(.*)$")
    if not query or query == "" then
        return result
    end

    for pair in query:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=?(.*)$")
        if key then
            result[urlDecode(key)] = urlDecode(value)
        end
    end

    return result
end

local function parseRequest(raw)
    local requestLine = raw:match("^([^\r\n]+)")
    if not requestLine then
        return nil, "Missing request line"
    end

    local method, target = requestLine:match("^(%u+)%s+([^%s]+)%s+HTTP/%d%.%d$")
    if not method or not target then
        return nil, "Invalid request line"
    end

    local headers = {}
    for name, value in raw:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[string.lower(trim(name))] = trim(value)
    end

    return {
        method = method,
        target = target,
        path = target:match("^([^?]+)") or target,
        query = parseQuery(target),
        headers = headers,
        origin = headers["origin"],
    }
end

local function allowedOrigin(origin)
    if origin == nil or origin == "" then
        return nil
    end
    if ALLOWED_ORIGINS[origin] then
        return origin
    end
    return false
end

local function encodeJson(value)
    local body, err = C4:JsonEncode(value, false, true)
    if not body then
        log("JSON encode failed: " .. tostring(err))
        return '{"ok":false,"error":{"code":"JSON_ENCODE_FAILED","message":"Unable to encode response"}}'
    end
    return body
end

local function sendResponse(handle, status, payload, origin, extraHeaders)
    local body = payload == nil and "" or encodeJson(payload)
    local headers = {
        "HTTP/1.1 " .. tostring(status) .. " " .. (STATUS_TEXT[status] or "Response"),
        "Connection: close",
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
    }

    if body ~= "" then
        table.insert(headers, "Content-Type: application/json; charset=utf-8")
        table.insert(headers, "Content-Length: " .. tostring(#body))
    else
        table.insert(headers, "Content-Length: 0")
    end

    if origin then
        table.insert(headers, "Access-Control-Allow-Origin: " .. origin)
        table.insert(headers, "Vary: Origin")
    end

    for _, header in ipairs(extraHeaders or {}) do
        table.insert(headers, header)
    end

    C4:ServerSend(handle, table.concat(headers, "\r\n") .. "\r\n\r\n" .. body)
    C4:ServerCloseClient(handle)
end

local function unauthorized(handle, origin)
    sendResponse(handle, 401, {
        ok = false,
        error = {
            code = "UNAUTHORIZED",
            message = "Valid C4Bridge API token required",
        },
    }, origin)
end

local function isAuthorized(request)
    local authorization = request.headers["authorization"]
    if not authorization then
        return false
    end

    local scheme, token = authorization:match("^(%S+)%s+(.+)$")
    if not scheme or string.lower(scheme) ~= "bearer" then
        return false
    end

    return token == config.token
end

local function systemInfo()
    local metadata = config.registry.metadata or {}
    local properties = metadata.properties or {}

    return {
        ok = true,
        bridge = {
            version = config.version.BRIDGE_VERSION,
            protocol = config.version.PROTOCOL_VERSION,
            api_port = API_PORT,
            api_mode = "light-control-alpha",
        },
        director = {
            version = config.directorVersion,
            system_type = metadata.systemType,
            timezone = metadata.timezone,
            boot_id = metadata.bootId,
        },
        project = {
            city = properties.CityName,
            country_code = properties.CountryCode,
            country_name = properties.CountryName,
            latitude = properties.Latitude,
            longitude = properties.Longitude,
        },
        discovery = config.registry.counts(),
    }
end

local function roomList()
    return {
        ok = true,
        rooms = config.registry.roomList(),
    }
end

local function deviceList()
    return {
        ok = true,
        devices = config.registry.deviceList(),
    }
end

local function lightList()
    return {
        ok = true,
        lights = config.registry.lightList(),
    }
end

local GET_ROUTES = {
    ["/v1/system/info"] = systemInfo,
    ["/v1/rooms"] = roomList,
    ["/v1/devices"] = deviceList,
    ["/v1/lights"] = lightList,
}

local function actionErrorStatus(error)
    local code = error and error.code
    if code == "DEVICE_NOT_FOUND" then
        return 404
    end
    if code == "DEVICE_NOT_SUPPORTED" or code == "ACTION_NOT_SUPPORTED" then
        return 409
    end
    if code == "INVALID_BRIGHTNESS" then
        return 400
    end
    return 500
end

local function handleDeviceAction(handle, request, origin)
    local id, action = request.path:match("^/v1/devices/(%d+)/actions/([a-z_]+)$")
    if not id or not action then
        return false
    end

    if not config.actions or not config.actions.execute then
        sendResponse(handle, 500, {
            ok = false,
            error = {
                code = "ACTION_ENGINE_UNAVAILABLE",
                message = "C4Bridge action engine is unavailable",
            },
        }, origin)
        return true
    end

    local ok, result = config.actions.execute(tonumber(id), action, request.query)
    if not ok then
        sendResponse(handle, actionErrorStatus(result), {
            ok = false,
            error = result,
        }, origin)
        return true
    end

    sendResponse(handle, 202, {
        ok = true,
        accepted = result,
    }, origin)

    return true
end

function HttpServer.port()
    return API_PORT
end

function HttpServer.init(options)
    config = options
end

function HttpServer.start()
    if online then
        return true
    end

    local ok, err = pcall(function()
        C4:CreateServer(API_PORT, "\r\n\r\n", false)
    end)

    if not ok then
        log("CreateServer failed: " .. tostring(err))
        return false, tostring(err)
    end

    return true
end

function HttpServer.stop()
    pcall(function()
        C4:DestroyServer(API_PORT)
    end)
    online = false
end

function HttpServer.onStatusChanged(port, status)
    if tonumber(port) ~= API_PORT then
        return
    end

    online = tostring(status) == "ONLINE"
    log("server port " .. tostring(port) .. " status " .. tostring(status))

    if config and config.onStatus then
        config.onStatus(online, status)
    end
end

function HttpServer.onConnectionStatusChanged(handle, remotePort, status, clientIp)
    log(
        "client " .. tostring(clientIp or "?") ..
        ":" .. tostring(remotePort or "?") ..
        " " .. tostring(status)
    )
end

function HttpServer.onData(handle, raw)
    local request, parseError = parseRequest(raw)
    if not request then
        sendResponse(handle, 400, {
            ok = false,
            error = { code = "BAD_REQUEST", message = parseError },
        }, nil)
        return
    end

    local origin = allowedOrigin(request.origin)
    if origin == false then
        sendResponse(handle, 403, {
            ok = false,
            error = { code = "ORIGIN_NOT_ALLOWED", message = "Origin is not allowed" },
        }, nil)
        return
    end

    if request.method == "OPTIONS" then
        sendResponse(handle, 204, nil, origin, {
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Authorization, Content-Type",
            "Access-Control-Max-Age: 600",
            "Access-Control-Allow-Private-Network: true",
        })
        return
    end

    if request.method ~= "GET" and request.method ~= "POST" then
        sendResponse(handle, 405, {
            ok = false,
            error = { code = "METHOD_NOT_ALLOWED", message = "Only GET and POST are available" },
        }, origin)
        return
    end

    if not isAuthorized(request) then
        unauthorized(handle, origin)
        return
    end

    if request.method == "POST" then
        if handleDeviceAction(handle, request, origin) then
            return
        end

        sendResponse(handle, 404, {
            ok = false,
            error = { code = "NOT_FOUND", message = "Unknown C4Bridge action route" },
        }, origin)
        return
    end

    local handler = GET_ROUTES[request.path]
    if not handler then
        sendResponse(handle, 404, {
            ok = false,
            error = { code = "NOT_FOUND", message = "Unknown C4Bridge API route" },
        }, origin)
        return
    end

    local ok, result = pcall(handler)
    if not ok then
        log("handler failed for " .. request.path .. ": " .. tostring(result))
        sendResponse(handle, 500, {
            ok = false,
            error = { code = "INTERNAL_ERROR", message = "C4Bridge API handler failed" },
        }, origin)
        return
    end

    sendResponse(handle, 200, result, origin)
end

return HttpServer
