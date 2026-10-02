-- The only part of DirectorLink that talks to Sonos players (docs/SONOS.md, ADR-044): SSDP to find
-- them, and HTTP GETs and SOAP calls to port 1400. Only to addresses DirectorLink was given by the
-- players' own answers or by the installer (Composer's Sonos Address), each a home network
-- address: never one from an API request, and no other host. Every request is small, has a
-- timeout, and at most MAX_IN_FLIGHT are on their way at once; Lua is never kept waiting.

local Protocol = require("src.sonos.protocol")

local Client = {}

-- A dynamic network binding for the search (no XML needed); the relay uses 6001.
Client.SEARCH_BINDING = 6100
Client.SEARCH_ADDRESS = "239.255.255.250"
Client.SEARCH_PORT = 1900
-- How long players have to answer a search.
Client.SEARCH_SECONDS = 4
-- The answers a search takes (each address once); later ones are ignored. Any one player lists
-- the whole household, and a home has far fewer players: this only bounds what a device on the
-- network that answers for many addresses can add.
Client.MAX_SEARCH_REPLIES = 32
Client.TIMEOUT_SECONDS = 4
Client.MAX_IN_FLIGHT = 4
Client.MAX_QUEUED = 40
Client.MAX_BODY_BYTES = 512 * 1024

local state = {
    allowed = {}, -- address -> { [source] = true }: "search", "property", "topology"
    inFlight = 0,
    queue = {},
    search = nil, -- { onReply, onDone, timers, sent, taken, count }
    bindingCreated = false,
}

local function cancel(timer)
    if timer then
        pcall(function()
            timer:Cancel()
        end)
    end
end

local function setTimer(seconds, callback)
    local ok, timer = pcall(function()
        return C4:SetTimer(math.floor(seconds * 1000), callback)
    end)
    return ok and timer or nil
end

-- An address DirectorLink may contact from now on: the players' answers and the installer's
-- property give them, and only home network addresses are taken.
function Client.allow(address, source)
    local ip = Protocol.lanAddress(address)
    if ip then
        state.allowed[ip] = state.allowed[ip] or {}
        state.allowed[ip][source] = true
    end
    return ip
end

function Client.allowed(address)
    return state.allowed[address] ~= nil
end

-- Forgets the addresses `source` gave, but those in `keep` (address -> true): the last search's
-- when a new one starts, the players no longer in the household when it is read again, the
-- installer's old address. One another source gave too stays.
function Client.forget(source, keep)
    for ip, sources in pairs(state.allowed) do
        if sources[source] and not (keep and keep[ip]) then
            sources[source] = nil
            if not next(sources) then
                state.allowed[ip] = nil
            end
        end
    end
end

local function header(headers, name)
    for key, value in pairs(headers or {}) do
        if string.lower(tostring(key)) == name then
            return type(value) == "table" and value[1] or value
        end
    end
    return nil
end

-- The one final answer to a request to `origin` ("http://<player>:1400/"), or nil and why not.
-- Director hands OnDone one response per hop when it follows a redirect: an answer that sends the
-- controller elsewhere (any 3xx, more than one final response, or one from another address) is a
-- failure, and its body is never used: a "player" must not make the controller fetch another host
-- for the app. A 1xx (100 Continue) is not an answer.
local function finalResponse(origin, responses)
    local finals = {}
    for _, response in ipairs(type(responses) == "table" and responses or {}) do
        local code = tonumber(type(response) == "table" and response.code)
        if not (code and code >= 100 and code < 200) then
            finals[#finals + 1] = response
        end
    end
    local last = finals[#finals]
    if not last then
        return nil
    end
    local code = tonumber(type(last) == "table" and last.code)
    local from = type(last) == "table" and type(last.url) == "string" and last.url or origin
    if #finals > 1 or (code and code >= 300 and code < 400) or from:sub(1, #origin) ~= origin then
        return nil, "redirected"
    end
    return last
end

-- One HTTP request; done(code, body, contentType, failure) is called exactly once.
local function send(job)
    local finished, guard = false, nil
    local function finish(code, body, contentType, failure)
        if finished then
            return
        end
        finished = true
        cancel(guard)
        state.inFlight = state.inFlight - 1
        local ok, err = pcall(job.done, code, body, contentType, failure)
        if not ok then
            pcall(function()
                C4:DebugLog("DirectorLink sonos: answer handler failed: " .. tostring(err))
            end)
        end
        Client.runNext()
    end
    state.inFlight = state.inFlight + 1
    -- In case the transfer never reports back.
    guard = setTimer(Client.TIMEOUT_SECONDS + 2, function()
        finish(nil, nil, nil, "timeout")
    end)
    local url = "http://" .. job.ip .. ":" .. Protocol.PORT .. job.path
    local origin = "http://" .. job.ip .. ":" .. Protocol.PORT .. "/"
    local ok, err = pcall(function()
        local transfer = C4:url()
            :SetOptions({ timeout = Client.TIMEOUT_SECONDS, connect_timeout = 2, fail_on_error = false })
            :OnDone(function(_transfer, responses, errCode, errMsg)
                local last, refused = finalResponse(origin, responses)
                if refused then
                    finish(nil, nil, nil, refused)
                    return
                elseif not last then
                    finish(nil, nil, nil, tostring(errMsg or errCode or "no answer"))
                    return
                end
                local body = type(last.body) == "string" and last.body or ""
                if #body > Client.MAX_BODY_BYTES then
                    finish(tonumber(last.code), nil, nil, "answer too large")
                    return
                end
                finish(tonumber(last.code), body, header(last.headers, "content-type"))
            end)
        if job.body then
            transfer:Post(url, job.body, job.headers)
        else
            transfer:Get(url, job.headers)
        end
    end)
    if not ok then
        finish(nil, nil, nil, tostring(err))
    end
end

function Client.runNext()
    while state.inFlight < Client.MAX_IN_FLIGHT and #state.queue > 0 do
        send(table.remove(state.queue, 1))
    end
end

local function enqueue(job)
    if not state.allowed[job.ip] then
        job.done(nil, nil, nil, "address not allowed")
        return
    end
    if #state.queue >= Client.MAX_QUEUED then
        job.done(nil, nil, nil, "busy")
        return
    end
    state.queue[#state.queue + 1] = job
    Client.runNext()
end

-- Sends `action` to the player at `ip`; done(values) with the answer's values, or done(nil,
-- failure): the UPnP error code ("701"), "timeout", "HTTP 404", ...
function Client.call(ip, action, args, done)
    local request = Protocol.request(action, args)
    if not request then
        done(nil, "unknown action")
        return
    end
    enqueue({
        ip = ip,
        path = request.path,
        body = request.body,
        headers = request.headers,
        done = function(code, body, _contentType, failure)
            if failure then
                done(nil, failure)
            elseif code == 200 or code == 500 then
                local values, why = Protocol.answer(action, body)
                done(values, why)
            else
                done(nil, "HTTP " .. tostring(code))
            end
        end,
    })
end

-- A picture the player serves for a track (a path on it, Protocol.artPath); done(bytes,
-- contentType) or done(nil, failure).
function Client.picture(ip, path, done)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:sub(2, 2) == "/" then
        done(nil, "not a path on the player")
        return
    end
    enqueue({
        ip = ip,
        path = path,
        headers = { Accept = "image/*" },
        done = function(code, body, contentType, failure)
            if failure or code ~= 200 or not body or body == "" then
                done(nil, failure or ("HTTP " .. tostring(code)))
                return
            end
            local mediaType = tostring(contentType or ""):match("^%s*([%w%.%+%-]+/[%w%.%+%-]+)")
            done(body, (mediaType and mediaType:match("^image/")) and mediaType or "image/jpeg")
        end,
    })
end

-- ---- search (SSDP) -------------------------------------------------------------------------

local function sendSearch()
    local search = state.search
    if not search or search.sent then
        return
    end
    search.sent = true
    local message = Protocol.searchRequest()
    pcall(function()
        C4:SendToNetwork(Client.SEARCH_BINDING, Client.SEARCH_PORT, message)
        C4:SendToNetwork(Client.SEARCH_BINDING, Client.SEARCH_PORT, message)
    end)
end

local function endSearch()
    local search = state.search
    if not search then
        return
    end
    state.search = nil
    cancel(search.fallback)
    cancel(search.finish)
    pcall(function()
        C4:NetDisconnect(Client.SEARCH_BINDING, Client.SEARCH_PORT)
    end)
    return search
end

-- Asks the home network for Sonos players (UDP to 239.255.255.250:1900). onReply({ ip, id,
-- household }) once for each address that answers, at most MAX_SEARCH_REPLIES (each is allowed
-- until the next search, or longer if a player lists it); onDone() after SEARCH_SECONDS.
function Client.search(onReply, onDone)
    endSearch()
    Client.forget("search")
    state.search = { onReply = onReply, onDone = onDone, sent = false, taken = {}, count = 0 }
    local ok, err = pcall(function()
        if not state.bindingCreated then
            C4:CreateNetworkConnection(Client.SEARCH_BINDING, Client.SEARCH_ADDRESS)
            state.bindingCreated = true
        end
        C4:NetConnect(Client.SEARCH_BINDING, Client.SEARCH_PORT, "UDP")
    end)
    if not ok then
        endSearch()
        return false, tostring(err)
    end
    -- Sent when Director says the connection is up; a second later in any case.
    state.search.fallback = setTimer(1, sendSearch)
    state.search.finish = setTimer(Client.SEARCH_SECONDS, function()
        local search = endSearch()
        if search and search.onDone then
            search.onDone()
        end
    end)
    return true
end

function Client.stopSearch()
    endSearch()
end

-- main.lua: OnConnectionStatusChanged and ReceivedFromNetwork for every binding; true when it
-- was the search's. These two are all main.lua may use of this file (scripts/check_package.py).
function Client.onConnectionStatus(binding, _port, status)
    if tonumber(binding) ~= Client.SEARCH_BINDING then
        return false
    end
    if status == "ONLINE" then
        sendSearch()
    end
    return true
end

function Client.onData(binding, _port, data)
    if tonumber(binding) ~= Client.SEARCH_BINDING then
        return false
    end
    local search = state.search
    if search and search.count < Client.MAX_SEARCH_REPLIES and type(data) == "string" and not data:find("M-SEARCH", 1, true) then
        for _, reply in ipairs(Protocol.searchReplies(data, Client.MAX_SEARCH_REPLIES)) do
            -- Each player answers each of the two messages: one address is taken once.
            if not search.taken[reply.ip] and search.count < Client.MAX_SEARCH_REPLIES then
                search.taken[reply.ip] = true
                search.count = search.count + 1
                Client.allow(reply.ip, "search")
                pcall(search.onReply, reply)
            end
        end
    end
    return true
end

-- Everything waiting is dropped (Sonos turned off); requests on their way finish unanswered.
function Client.reset()
    endSearch()
    for _, job in ipairs(state.queue) do
        pcall(job.done, nil, nil, nil, "stopped")
    end
    state.queue = {}
    state.allowed = {}
end

return Client
