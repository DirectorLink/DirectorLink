-- Camera snapshots through the Control4 camera proxy (camera.c4i), the way the Director's own
-- app backend does it: GET_PROPERTIES gives address, ports and login, GET_SNAPSHOT_QUERY_STRING
-- the snapshot path. The image is fetched on the controller, so camera passwords and addresses
-- never leave it. Basic and digest (RFC 7616, MD5, qop=auth) logins are supported.
--
-- Pictures are fetched side by side (1.8.0, ADR-055): at most PER_HOST at once from a camera's
-- address, PER_NVR from an address several cameras use (an NVR's channels), MAX_IN_FLIGHT in all.
-- The others wait in the order they were asked for, and one waiting for a busy address does not
-- hold back another camera's. A picture asked for again while it is on its way, or within SHARE_MS
-- of its arrival, is that one (the same camera and size: the same address), so tiles showing one
-- camera share a fetch. A digest login's challenge is kept for the next pictures from that address,
-- with the nonce count going up, so a picture is one request to the camera instead of two. Each
-- picture on its way to an address has a login of its own (its own nonce, used one request at a
-- time: Hikvision refuses a nonce's counts out of order), and a 401 is answered once with its new
-- challenge. Nothing here waits: Director answers every request later.

local Clock = require("src.core.clock")
local Log = require("src.core.log")

local Camera = {}

Camera.TIMEOUT_SECONDS = 8
-- Pictures fetched at once: in all, from one camera's address, and from an address several cameras
-- use (an NVR). More wait for a free place (lights and blinds keep working).
Camera.MAX_IN_FLIGHT = 8
Camera.PER_HOST = 2
Camera.PER_NVR = 3
-- Pictures waiting beyond this, and requests beyond MAX_WAITERS for one picture, are refused with
-- CAMERA_BUSY.
Camera.MAX_QUEUED = 24
Camera.MAX_WAITERS = 16
-- A picture is given again to whoever asks for it this long after it arrived (milliseconds): less
-- than the app's fastest refresh (a live picture on the home network, asked a second after each
-- answer), so that every ask of one viewer gets a new picture, while tiles and devices that ask in
-- the same moment share one.
Camera.SHARE_MS = 800
-- A login unused this long starts again with a new challenge (seconds).
Camera.LOGIN_IDLE_SECONDS = 60
-- Camera setup (address, login, snapshot path) is cached this long.
local SOURCE_TTL_SECONDS = 300

local sources = {}
-- Address -> { camera proxy id -> true }: the cameras seen at each address (more than one: an NVR).
local cameraHosts = {}
-- Pictures waiting, in order; every picture waiting or on its way, by key; how many are on their
-- way, in all and per address.
local queue = {}
local jobs = {}
local inFlight = 0
local hostBusy = {}
-- Pictures that arrived less than SHARE_MS ago: key -> { at, image, content_type }.
local recent = {}
local sweeper = nil
-- Digest logins per address and user: key -> { { challenge, nc, busy, used }, ... }.
local logins = {}
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

-- The camera's address as one key: scheme, host and port.
local function hostKey(source)
    local port = source.port or (source.scheme == "https" and 443 or 80)
    return source.scheme .. "://" .. string.lower(tostring(source.host)) .. ":" .. tostring(port)
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
    local host = hostKey(source)
    cameraHosts[host] = cameraHosts[host] or {}
    cameraHosts[host][tonumber(proxyId) or proxyId] = true
    return source
end

function Camera.forget(proxyId)
    for key in pairs(sources) do
        if key:match("^" .. tostring(proxyId) .. ":") then
            sources[key] = nil
        end
    end
end

-- Every camera's setup is read again; snapshots waiting or in flight carry on, and pictures that
-- just arrived and logins are kept (they belong to an address, not to the project).
function Camera.forgetAll()
    sources = {}
    cameraHosts = {}
end

local function url(source)
    local defaultPort = source.scheme == "https" and 443 or 80
    local hostPort = source.host
    if source.port and source.port ~= defaultPort then
        hostPort = hostPort .. ":" .. tostring(source.port)
    end
    return source.scheme .. "://" .. hostPort .. source.path
end

-- Parses a WWW-Authenticate: Digest challenge into a table (realm, nonce, qop, opaque, algorithm,
-- stale).
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

-- Builds the Authorization header answering a digest challenge (RFC 7616, MD5); `nc`: how many
-- times this nonce has been used, this time included (1 when left out).
function Camera.digestHeader(challenge, username, password, method, uri, cnonce, nc)
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
    local count = string.format("%08x", tonumber(nc) or 1)
    local qop = challenge.qop
    local response, parts
    if qop and qop ~= "" then
        qop = qop:find("auth", 1, true) and "auth" or qop
        response = md5(ha1 .. ":" .. challenge.nonce .. ":" .. count .. ":" .. cnonce .. ":" .. qop .. ":" .. ha2)
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
        parts[#parts + 1] = "nc=" .. count
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

-- The digest challenge of a 401, also when the camera offers Basic first in another
-- WWW-Authenticate header.
local function digestChallenge(headers)
    for key, value in pairs(headers or {}) do
        if string.lower(tostring(key)) == "www-authenticate" then
            for _, offered in ipairs(type(value) == "table" and value or { value }) do
                local challenge = Camera.parseChallenge(offered)
                if challenge then
                    return challenge
                end
            end
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
    return type(value) == "string" and value:match("^%s*([^;%s]+)") or "image/jpeg"
end

-- A digest login for one picture from `source`'s address: a free one that was used recently, or a
-- new one (no challenge yet); `kept`: only one with a challenge, else nil. Released by the picture
-- when it is done.
local function takeLogin(source, kept)
    local key = hostKey(source) .. "|" .. source.username
    local list = logins[key] or {}
    logins[key] = list
    local now = os.time()
    for index = #list, 1, -1 do
        local login = list[index]
        if not login.busy and (now - login.used > Camera.LOGIN_IDLE_SECONDS or now < login.used) then
            table.remove(list, index)
        end
    end
    for _, login in ipairs(list) do
        if not login.busy and (login.challenge or not kept) then
            login.busy = true
            return login
        end
    end
    if kept then
        return nil
    end
    local login = { busy = true, nc = 0, used = now }
    list[#list + 1] = login
    return login
end

-- The Authorization header for the next request with `login`'s challenge, its count one higher.
local function answer(login, source)
    login.nc = login.nc + 1
    cnonceCounter = cnonceCounter + 1
    local cnonce = string.format("%08x%08x", os.time() % 4294967296, cnonceCounter)
    return Camera.digestHeader(login.challenge, source.username, source.password, "GET", source.path, cnonce, login.nc)
end

-- Fetches the picture: done(code, body, mediaType, error, requests), exactly once. A camera set to
-- Basic login that asks for digest gets digest, kept as for any other. An error while a request is
-- made or its answer read (C4:Hash failing, a header in a shape Director does not usually give)
-- ends the picture as unreachable, its login's challenge dropped: the transfer's guard is already
-- cancelled then, and nothing else would give its place back.
local function fetch(source, done)
    local target = url(source)
    local basic = source.auth and source.authType ~= "DIGEST" and source.username ~= ""
    local login = nil
    local requests = 0
    local over = false
    local function finish(code, body, mediaType, err)
        if over then
            return
        end
        over = true
        if login then
            login.busy, login.used = false, os.time()
        end
        done(code, body, mediaType, err, requests)
    end
    local function failed(problem)
        Log.error("camera", "snapshot request failed", { host = source.host, error = tostring(problem) })
        if not over and login then
            login.challenge, login.nc = nil, 0
        end
        finish(nil, nil, nil, "error")
    end
    local ask
    ask = function(mayRetry)
        local ok, problem = pcall(function()
            local headers = { Accept = "image/*" }
            if login and login.challenge then
                headers.Authorization = answer(login, source)
            elseif basic then
                headers.Authorization = "Basic " .. C4:Base64Encode(source.username .. ":" .. source.password)
            end
            requests = requests + 1
            get(target, headers, function(code, body, responseHeaders, err)
                local handled, failure = pcall(function()
                    if code == 401 and source.username ~= "" then
                        local challenge = digestChallenge(responseHeaders)
                        if challenge and mayRetry then
                            -- The first picture from this address, a stale nonce, or one the camera
                            -- no longer knows: answered once, and kept for the next pictures.
                            login = login or takeLogin(source)
                            login.challenge, login.nc = challenge, 0
                            ask(false)
                            return
                        end
                        -- Refused even so: the next picture starts again without a challenge.
                        if login then
                            login.challenge, login.nc = nil, 0
                        end
                    end
                    finish(code, body, responseHeaders and contentType(responseHeaders), err)
                end)
                if not handled then
                    failed(failure)
                end
            end)
        end)
        if not ok then
            failed(problem)
        end
    end
    if source.username ~= "" then
        login = takeLogin(source, basic)
    end
    ask(true)
end

local function busy()
    return { error = "CAMERA_BUSY", message = "Too many snapshots are being fetched; try again in a moment" }
end

-- Pictures older than SHARE_MS go; a clock that went back drops them all.
local function sweep(now)
    for key, kept in pairs(recent) do
        if now - kept.at >= Camera.SHARE_MS or now < kept.at then
            recent[key] = nil
        end
    end
end

-- The pictures kept are dropped soon after they may no longer be given, even if nobody asks.
local function sweepLater()
    if sweeper then
        return
    end
    pcall(function()
        sweeper = C4:SetTimer(Camera.SHARE_MS + 100, function()
            sweeper = nil
            sweep(Clock.millis())
            if next(recent) then
                sweepLater()
            end
        end)
    end)
end

local function limitOf(host)
    local count = 0
    for _ in pairs(cameraHosts[host] or {}) do
        count = count + 1
        if count > 1 then
            return Camera.PER_NVR
        end
    end
    return Camera.PER_HOST
end

local runNext

-- A picture's fetch is over: everyone who asked for it gets the same answer.
local function complete(job, code, body, mediaType, err, requests)
    jobs[job.key] = nil
    local result
    local firstProxy = job.first
    if code == 200 and type(body) == "string" and body ~= "" then
        result = { image = body, content_type = mediaType or "image/jpeg" }
        recent[job.key] = { at = Clock.millis(), image = result.image, content_type = result.content_type }
        sweepLater()
        Log.debug("camera", "snapshot", {
            device_id = firstProxy,
            ms = Clock.millis() - job.asked,
            requests = requests,
            waiters = #job.waiters,
            in_flight = inFlight,
        })
    else
        for proxyId in pairs(job.proxies) do
            Camera.forget(proxyId)
        end
        local reason = err or ("HTTP " .. tostring(code))
        Log.warn("camera", "snapshot failed", { device_id = firstProxy, host = job.source.host, reason = reason })
        if code == 401 or code == 403 then
            result = { error = "CAMERA_LOGIN_FAILED", message = "The camera rejected the login stored in Control4" }
        else
            result = { error = "CAMERA_UNREACHABLE", message = "The camera did not return a snapshot (" .. reason .. ")" }
        end
    end
    for _, waiter in ipairs(job.waiters) do
        local ok, failure = pcall(waiter, result)
        if not ok then
            Log.error("camera", "snapshot answer failed", { device_id = firstProxy, error = tostring(failure) })
        end
    end
end

local function start(job)
    inFlight = inFlight + 1
    hostBusy[job.host] = (hostBusy[job.host] or 0) + 1
    fetch(job.source, function(code, body, mediaType, err, requests)
        inFlight = inFlight - 1
        hostBusy[job.host] = hostBusy[job.host] - 1
        if hostBusy[job.host] <= 0 then
            hostBusy[job.host] = nil
        end
        complete(job, code, body, mediaType, err, requests)
        runNext()
    end)
end

-- Starts the waiting pictures that may start, oldest first; one whose address is busy waits
-- without holding back the others.
runNext = function()
    local index = 1
    while inFlight < Camera.MAX_IN_FLIGHT and index <= #queue do
        local job = queue[index]
        if (hostBusy[job.host] or 0) < limitOf(job.host) then
            table.remove(queue, index)
            start(job)
        else
            index = index + 1
        end
    end
end

-- Fetches a snapshot. done(result) gets { image = bytes, content_type = ... } or { error = code, message = ... }.
function Camera.snapshot(proxyId, source, done)
    local key = url(source) .. "|" .. source.username
    local now = Clock.millis()
    sweep(now)
    local kept = recent[key]
    if kept then
        done({ image = kept.image, content_type = kept.content_type })
        return
    end
    local job = jobs[key]
    if job then
        if #job.waiters >= Camera.MAX_WAITERS then
            done(busy())
            return
        end
        job.waiters[#job.waiters + 1] = done
        job.proxies[proxyId] = true
        return
    end
    if #queue >= Camera.MAX_QUEUED then
        done(busy())
        return
    end
    job = { key = key, source = source, host = hostKey(source), first = proxyId, proxies = { [proxyId] = true }, waiters = { done }, asked = now }
    jobs[key] = job
    queue[#queue + 1] = job
    runNext()
end

-- What is happening now, for tests and the log: pictures on their way (in all and per address),
-- waiting, and kept.
function Camera.stats()
    local kept = 0
    for _ in pairs(recent) do
        kept = kept + 1
    end
    local perHost = {}
    for host, count in pairs(hostBusy) do
        perHost[host] = count
    end
    return { in_flight = inFlight, waiting = #queue, kept = kept, per_host = perHost }
end

return Camera
