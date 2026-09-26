-- Camera snapshots through the Control4 camera proxy (camera.c4i), the way the Director's own
-- app backend does it: GET_PROPERTIES gives address, ports and login, GET_SNAPSHOT_QUERY_STRING
-- the snapshot path. The image is fetched on the controller, so camera passwords and addresses
-- never leave it. Basic and digest (RFC 7616, MD5, qop=auth) logins are supported.

local Log = require("src.core.log")

local Camera = {}

Camera.TIMEOUT_SECONDS = 8
-- Snapshots in flight at once; more requests wait for a free slot (lights and blinds keep working).
Camera.MAX_IN_FLIGHT = 3
-- Waiting requests beyond this are refused with CAMERA_BUSY.
Camera.MAX_QUEUED = 12
-- Camera setup (address, login, snapshot path) is cached this long.
local SOURCE_TTL_SECONDS = 300

local sources = {}
local inFlight = 0
local queue = {}
local cnonceCounter = 0

local function unescape(value)
    value = tostring(value or "")
    value = value:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    return (value:gsub("&amp;", "&"))
end

local function tag(xml, name)
    local value = tostring(xml or ""):match("<" .. name .. ">(.-)</" .. name .. ">")
    return value and unescape(value) or nil
end

local function truthy(value)
    local text = string.lower(tostring(value or ""))
    return text == "true" or text == "1" or text == "yes"
end

local function uiRequest(proxyId, command, params)
    local ok, result = pcall(function()
        return C4:SendUIRequest(proxyId, command, params or {})
    end)
    if ok and type(result) == "string" and result ~= "" then
        return result
    end
    return nil
end

local function md5(text)
    return string.lower(C4:Hash("MD5", text, { return_encoding = "HEX" }))
end

-- Reads the camera's address, login and snapshot path. Returns a source table or nil, reason.
function Camera.source(proxyId, width, height, now)
    local key = tostring(proxyId) .. ":" .. tostring(width) .. "x" .. tostring(height)
    local cached = sources[key]
    if cached and now - cached.at < SOURCE_TTL_SECONDS then
        return cached.source
    end

    local properties = uiRequest(proxyId, "GET_PROPERTIES")
    if not properties then
        return nil, "the camera did not return its properties"
    end
    local address = tag(properties, "address")
    if not address or address == "" then
        return nil, "the camera has no address configured"
    end
    local query = uiRequest(proxyId, "GET_SNAPSHOT_QUERY_STRING", { SIZE_X = width, SIZE_Y = height })
    local path = query and tag(query, "snapshot_query_string")
    if not path or path == "" then
        return nil, "the camera driver has no snapshot URL"
    end

    local https = truthy(tag(properties, "use_https"))
    local port = tonumber(tag(properties, https and "https_port" or "http_port"))
    local source = {
        scheme = https and "https" or "http",
        host = address,
        port = port,
        path = path:sub(1, 1) == "/" and path or ("/" .. path),
        auth = truthy(tag(properties, "authentication_required")),
        authType = string.upper(tag(properties, "authentication_type") or ""),
        username = tag(properties, "username") or "",
        password = tag(properties, "password") or "",
    }
    sources[key] = { at = now, source = source }
    return source
end

function Camera.forget(proxyId)
    for key in pairs(sources) do
        if key:match("^" .. tostring(proxyId) .. ":") then
            sources[key] = nil
        end
    end
end

local function url(source)
    local defaultPort = source.scheme == "https" and 443 or 80
    local hostPort = source.host
    if source.port and source.port ~= defaultPort then
        hostPort = hostPort .. ":" .. tostring(source.port)
    end
    return source.scheme .. "://" .. hostPort .. source.path
end

-- Parses a WWW-Authenticate: Digest challenge into a table (realm, nonce, qop, opaque, algorithm).
function Camera.parseChallenge(header)
    header = tostring(header or "")
    local params = header:match("^%s*[Dd][Ii][Gg][Ee][Ss][Tt]%s+(.*)$")
    if not params then
        return nil
    end
    local challenge = {}
    for name, value in params:gmatch('([%w_-]+)%s*=%s*"([^"]*)"') do
        challenge[string.lower(name)] = value
    end
    for name, value in params:gmatch('([%w_-]+)%s*=%s*([^",%s]+)') do
        name = string.lower(name)
        if challenge[name] == nil then
            challenge[name] = value
        end
    end
    if not challenge.nonce then
        return nil
    end
    return challenge
end

-- Builds the Authorization header answering a digest challenge (RFC 7616, MD5).
function Camera.digestHeader(challenge, username, password, method, uri, cnonce)
    local algorithm = string.upper(challenge.algorithm or "MD5")
    if algorithm ~= "MD5" and algorithm ~= "MD5-SESS" then
        return nil
    end
    local realm = challenge.realm or ""
    local ha1 = md5(username .. ":" .. realm .. ":" .. password)
    if algorithm == "MD5-SESS" then
        ha1 = md5(ha1 .. ":" .. challenge.nonce .. ":" .. cnonce)
    end
    local ha2 = md5(method .. ":" .. uri)
    local nc = "00000001"
    local qop = challenge.qop
    local response, parts
    if qop and qop ~= "" then
        qop = qop:find("auth", 1, true) and "auth" or qop
        response = md5(ha1 .. ":" .. challenge.nonce .. ":" .. nc .. ":" .. cnonce .. ":" .. qop .. ":" .. ha2)
    else
        response = md5(ha1 .. ":" .. challenge.nonce .. ":" .. ha2)
    end
    parts = {
        'username="' .. username .. '"',
        'realm="' .. realm .. '"',
        'nonce="' .. challenge.nonce .. '"',
        'uri="' .. uri .. '"',
        "algorithm=" .. (challenge.algorithm or "MD5"),
        'response="' .. response .. '"',
    }
    if qop and qop ~= "" then
        parts[#parts + 1] = "qop=" .. qop
        parts[#parts + 1] = "nc=" .. nc
        parts[#parts + 1] = 'cnonce="' .. cnonce .. '"'
    end
    if challenge.opaque then
        parts[#parts + 1] = 'opaque="' .. challenge.opaque .. '"'
    end
    return "Digest " .. table.concat(parts, ", ")
end

local function header(headers, name)
    for key, value in pairs(headers or {}) do
        if string.lower(tostring(key)) == name then
            return type(value) == "table" and value[1] or value
        end
    end
    return nil
end

-- One HTTP GET; done(code, body, headers, error) is called exactly once.
local function get(target, headers, done)
    local finished = false
    local guard
    local function finish(...)
        if not finished then
            finished = true
            if guard then
                pcall(function()
                    guard:Cancel()
                end)
            end
            done(...)
        end
    end
    -- In case the transfer never reports back.
    pcall(function()
        guard = C4:SetTimer((Camera.TIMEOUT_SECONDS + 2) * 1000, function()
            finish(nil, nil, nil, "timeout")
        end)
    end)
    local ok, err = pcall(function()
        C4:url()
            :SetOptions({
                timeout = Camera.TIMEOUT_SECONDS,
                connect_timeout = 3,
                fail_on_error = false,
                ssl_verify_host = false,
                ssl_verify_peer = false,
            })
            :OnDone(function(_transfer, responses, errCode, errMsg)
                local last = responses and responses[#responses]
                if errCode and errCode ~= 0 and not last then
                    finish(nil, nil, nil, tostring(errMsg or errCode))
                    return
                end
                finish(last and tonumber(last.code), last and last.body, last and last.headers)
            end)
            :Get(target, headers)
    end)
    if not ok then
        finish(nil, nil, nil, tostring(err))
    end
end

local function contentType(headers)
    local value = header(headers, "content-type")
    return value and value:match("^%s*([^;%s]+)") or "image/jpeg"
end

local function fetch(source, done)
    local target = url(source)
    local headers = { Accept = "image/*" }
    if source.auth and source.authType ~= "DIGEST" and source.username ~= "" then
        headers.Authorization = "Basic " .. C4:Base64Encode(source.username .. ":" .. source.password)
    end
    get(target, headers, function(code, body, responseHeaders, err)
        if code == 401 and source.username ~= "" then
            local challenge = Camera.parseChallenge(header(responseHeaders, "www-authenticate"))
            if challenge then
                cnonceCounter = cnonceCounter + 1
                local cnonce = string.format("%08x%08x", os.time() % 4294967296, cnonceCounter)
                local authorization = Camera.digestHeader(challenge, source.username, source.password, "GET", source.path, cnonce)
                if authorization then
                    get(target, { Accept = "image/*", Authorization = authorization }, function(code2, body2, headers2, err2)
                        done(code2, body2, headers2 and contentType(headers2), err2)
                    end)
                    return
                end
            end
        end
        done(code, body, responseHeaders and contentType(responseHeaders), err)
    end)
end

local function runNext()
    while inFlight < Camera.MAX_IN_FLIGHT and #queue > 0 do
        local job = table.remove(queue, 1)
        inFlight = inFlight + 1
        fetch(job.source, function(code, body, mediaType, err)
            inFlight = inFlight - 1
            job.done(code, body, mediaType, err)
            runNext()
        end)
    end
end

-- Fetches a snapshot. done(result) gets { image = bytes, content_type = ... } or { error = code, message = ... }.
function Camera.snapshot(proxyId, source, done)
    if #queue >= Camera.MAX_QUEUED then
        done({ error = "CAMERA_BUSY", message = "Too many snapshots are being fetched; try again in a moment" })
        return
    end
    queue[#queue + 1] = {
        source = source,
        done = function(code, body, mediaType, err)
            if code == 200 and type(body) == "string" and body ~= "" then
                done({ image = body, content_type = mediaType or "image/jpeg" })
                return
            end
            Camera.forget(proxyId)
            local reason = err or ("HTTP " .. tostring(code))
            Log.warn("camera", "snapshot failed", { device_id = proxyId, host = source.host, reason = reason })
            if code == 401 or code == 403 then
                done({ error = "CAMERA_LOGIN_FAILED", message = "The camera rejected the login stored in Control4" })
            else
                done({ error = "CAMERA_UNREACHABLE", message = "The camera did not return a snapshot (" .. reason .. ")" })
            end
        end,
    }
    runNext()
end

function Camera.reset()
    sources = {}
    queue = {}
    inFlight = 0
end

return Camera
