-- Remote access (docs/RELAY.md): the driver's WebSocket client and relay module against a fake
-- relay that speaks the protocol at the byte level.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local sha1 = require("sha1")

local tests = {}

local BINDING = 6001
local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function bigEndian(value, bytes)
    local chars = {}
    for index = bytes, 1, -1 do
        chars[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(chars)
end

-- A server frame (never masked).
local function serverFrame(opcode, payload, fin)
    local b1 = (fin == false and 0 or 128) + opcode
    local length = #payload
    if length < 126 then
        return string.char(b1, length) .. payload
    elseif length < 65536 then
        return string.char(b1, 126) .. bigEndian(length, 2) .. payload
    end
    return string.char(b1, 127) .. bigEndian(length, 8) .. payload
end

local function xorByte(a, b)
    local result, bit = 0, 1
    for _ = 1, 8 do
        if a % 2 ~= b % 2 then
            result = result + bit
        end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end

-- Parses the client frames in `data`; every one must be masked.
local function clientFrames(data)
    local frames = {}
    local offset = 1
    while offset <= #data do
        local b1, b2 = data:byte(offset, offset + 1)
        T.truthy(b2 >= 128, "client frames are masked")
        local length = b2 % 128
        local header = 2
        if length == 126 then
            length = data:byte(offset + 2) * 256 + data:byte(offset + 3)
            header = 4
        elseif length == 127 then
            length = 0
            for index = offset + 2, offset + 9 do
                length = length * 256 + data:byte(index)
            end
            header = 10
        end
        local mask = { data:byte(offset + header, offset + header + 3) }
        local start = offset + header + 4
        local chars = {}
        for index = 0, length - 1 do
            chars[#chars + 1] = string.char(xorByte(data:byte(start + index), mask[index % 4 + 1]))
        end
        frames[#frames + 1] = { fin = b1 >= 128, opcode = b1 % 16, payload = table.concat(chars), header = header }
        offset = start + length
    end
    return frames
end

-- Starts the driver, switches Remote Access on and completes the connection.
local function connected(options)
    options = options or {}
    local mock = options.mock or Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local connection = mock.network[BINDING]
    T.truthy(connection, "a network connection is created")
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    local request = connection.sent
    connection.sent = ""
    local key = request:match("\r\nSec%-WebSocket%-Key: ([^\r\n]+)")
    local accept = C4:Base64Encode(sha1(key .. GUID))
    ReceivedFromNetwork(BINDING, 443, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Accept: " .. accept .. "\r\n\r\n")
    local hello = clientFrames(connection.sent)
    connection.sent = ""
    return mock, connection, request, hello
end

local function relayRequest(mock, connection, message)
    connection.sent = ""
    ReceivedFromNetwork(BINDING, 443, serverFrame(1, Json.encode(message)))
    local frames = clientFrames(connection.sent)
    connection.sent = ""
    T.eq(#frames, 1, "one response frame")
    return Json.decode(frames[1].payload), frames[1]
end

local function lastTimer(mock, delay)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if timer.delay == delay and not timer.cancelled and not timer.fired then
            return timer
        end
    end
end

function tests.remote_access_is_off_by_default()
    local mock = Mock.startDriver()
    T.eq(next(mock.network), nil, "no outgoing connection")
    T.eq(mock.properties["Remote Status"], "Off")
end

function tests.switching_on_opens_a_tls_connection_to_the_relay()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local connection = mock.network[BINDING]
    T.eq(connection.host, "api.directorlink.io")
    T.eq(connection.port, 443)
    T.eq(connection.kind, "SSL")
    T.eq(connection.connects, 1)
    T.eq(mock.properties["Remote Status"], "Connecting...")
    T.eq(mock.persistEncrypted["directorlink_remote_identity"], false, "plain storage survives updates")
end

function tests.handshake_sends_the_home_identity_and_hello_follows()
    local mock, _, request, hello = connected()
    T.truthy(request:match("^GET /relay/connect HTTP/1%.1\r\n"), "request line")
    T.contains(request, "\r\nHost: api.directorlink.io\r\n")
    T.contains(request, "\r\nUpgrade: websocket\r\n")
    T.contains(request, "\r\nSec-WebSocket-Version: 13\r\n")
    T.truthy(request:match("\r\nSec%-WebSocket%-Key: [%w+/]+==\r\n"), "a base64 key of 16 bytes")
    local secret = request:match("\r\nAuthorization: Bearer (%x+)\r\n")
    local home = request:match("\r\nX%-DirectorLink%-Home: (%x+)\r\n")
    T.eq(#secret, 64)
    T.eq(#home, 32)
    T.truthy(request:match("\r\n\r\n$"), "headers end the request")

    T.eq(#hello, 1)
    T.eq(hello[1].opcode, 1, "text frame")
    local message = Json.decode(hello[1].payload)
    T.eq(message.type, "hello")
    T.eq(message.home, home)
    T.truthy(message.version, "driver version")
    T.contains(mock.properties["Remote Status"], "Connected since")
    T.contains(mock.properties["Remote Status"], home:sub(1, 8))
end

function tests.relayed_reads_use_the_lan_api()
    local mock, connection = connected()
    local response = relayRequest(mock, connection, { type = "request", id = "r1", method = "GET", path = "/v1/lights?room_id=11", body = Json.null })
    T.eq(response.type, "response")
    T.eq(response.id, "r1")
    T.eq(response.status, 200)
    T.contains(response.content_type, "application/json")
    local body = Json.decode(response.body)
    T.eq(#body.items, 2, "the query string reaches the API")
end

function tests.relayed_requests_are_read_only()
    local mock, connection = connected()
    local before = #mock.commands
    local logs = relayRequest(mock, connection, { type = "request", id = "r2", method = "GET", path = "/v1/logs" })
    T.eq(logs.status, 403, "viewer cannot read the log")
    T.eq(Json.decode(logs.body).required_role, "admin")
    local patch = relayRequest(mock, connection, { type = "request", id = "r3", method = "PATCH", path = "/v1/lights/21", body = '{"on":true}' })
    T.eq(patch.status, 405)
    T.eq(Json.decode(patch.body).code, "RELAY_READ_ONLY")
    local outside = relayRequest(mock, connection, { type = "request", id = "r4", method = "GET", path = "/health" })
    T.eq(outside.status, 405, "only /v1/ paths")
    T.eq(#mock.commands, before, "nothing reaches a device")
end

function tests.binary_answers_are_base64()
    local mock, connection = connected()
    local response = relayRequest(mock, connection, { type = "request", id = "p1", method = "GET", path = "/v1/cameras/61/snapshot" })
    T.eq(response.status, 200)
    T.eq(response.content_type, "image/jpeg")
    T.eq(response.body, nil)
    T.truthy(#response.body_base64 > 0, "picture sent as base64")
end

function tests.pings_are_answered_and_fragments_joined()
    local _, connection = connected()
    ReceivedFromNetwork(BINDING, 443, serverFrame(9, "x"))
    local pong = clientFrames(connection.sent)
    connection.sent = ""
    T.eq(pong[1].opcode, 10)
    T.eq(pong[1].payload, "x")

    local message = Json.encode({ type = "request", id = "f1", method = "GET", path = "/v1/system" })
    local split = 20
    -- Two network chunks, and the message in two frames: data arrives however TCP delivers it.
    local wire = serverFrame(1, message:sub(1, split), false) .. serverFrame(0, message:sub(split + 1))
    ReceivedFromNetwork(BINDING, 443, wire:sub(1, 7))
    ReceivedFromNetwork(BINDING, 443, wire:sub(8))
    local frames = clientFrames(connection.sent)
    T.eq(Json.decode(frames[1].payload).id, "f1")
    T.eq(frames[1].header, 4, "a response longer than 125 bytes uses the 16-bit length")
end

function tests.large_frames_use_64_bit_lengths()
    local WebSocket = require("src.cloud.websocket")
    local payload = string.rep("a", 70000)
    local frames = clientFrames(WebSocket.frame(1, payload, "\1\2\3\4"))
    T.eq(frames[1].header, 10)
    T.eq(frames[1].payload, payload, "mask round trip")
end

function tests.keepalive_pings_and_silence_reconnects()
    local mock, connection = connected()
    local keepalive = lastTimer(mock, 25000)
    T.truthy(keepalive and keepalive.repeating, "a repeating 25 s keep-alive")
    keepalive.callback()
    T.eq(clientFrames(connection.sent)[1].payload, "ping")
    connection.sent = ""

    local realTime = os.time
    os.time = function()
        return realTime() + 120
    end
    keepalive.callback()
    os.time = realTime
    T.eq(connection.disconnects >= 1, true, "a silent connection is dropped")
    T.contains(mock.properties["Remote Status"], "Reconnecting in 5 s")
end

function tests.lost_connections_reconnect_with_backoff()
    local mock, connection = connected()
    local delays = {}
    for _ = 1, 5 do
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        local retry
        for index = #mock.timers, 1, -1 do
            local timer = mock.timers[index]
            if not timer.fired and not timer.cancelled and not timer.repeating then
                retry = timer
                break
            end
        end
        delays[#delays + 1] = retry.delay / 1000
        retry.fired = true
        retry.callback()
    end
    T.same(delays, { 5, 10, 30, 60, 60 })
    T.eq(connection.connects, 6)
end

function tests.refusals_wait_longer_and_say_why()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    local body = '{"type":"about:blank","title":"Unauthorized","status":401,"code":"HOME_SECRET_MISMATCH"}'
    ReceivedFromNetwork(BINDING, 443, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\n"
        .. "Content-Length: " .. #body .. "\r\n\r\n" .. body)
    T.contains(mock.properties["Remote Status"], "Reconnecting in 300 s")
    T.contains(mock.properties["Remote Status"], "HOME_SECRET_MISMATCH")
end

function tests.a_close_from_the_relay_is_answered_then_retried()
    local mock, connection = connected()
    ReceivedFromNetwork(BINDING, 443, serverFrame(8, bigEndian(4000, 2) .. "replaced"))
    local frames = clientFrames(connection.sent)
    T.eq(frames[1].opcode, 8, "close echoed")
    T.contains(mock.properties["Remote Status"], "closed by the relay (4000 replaced)")
end

function tests.switching_off_closes_and_stays_off()
    local mock, connection = connected()
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    T.eq(clientFrames(connection.sent)[1].opcode, 8, "a close frame")
    T.eq(connection.disconnects, 1)
    T.eq(mock.properties["Remote Status"], "Off")
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    T.eq(mock.properties["Remote Status"], "Off", "no reconnect after switching off")
end

function tests.the_identity_survives_updates_and_the_secret_is_never_logged()
    local mock, _, request = connected()
    local home = request:match("X%-DirectorLink%-Home: (%x+)")
    local secret = request:match("Authorization: Bearer (%x+)")

    local updated = Mock.updateDriver(mock)
    local _, _, again = connected({ mock = updated })
    T.eq(again:match("X%-DirectorLink%-Home: (%x+)"), home, "same home id after an update")
    T.eq(again:match("Authorization: Bearer (%x+)"), secret, "and the same secret")

    for _, logMock in ipairs({ mock, updated }) do
        for _, line in ipairs(logMock.debugLog) do
            T.truthy(not line:find(secret, 1, true), "the home secret never reaches the log")
        end
    end
end

function tests.an_identity_kept_encrypted_by_0_9_0_is_moved_to_plain_storage()
    local old = { home_id = string.rep("ab", 16), home_secret = string.rep("cd", 32) }
    local mock = Mock.startDriver(nil, nil, "DIT_UPDATING", function(fresh)
        fresh.persist["DIRECTORLINK_REMOTE_IDENTITY"] = Json.encode(old)
        fresh.persistEncrypted["DIRECTORLINK_REMOTE_IDENTITY"] = true
    end)
    local _, _, request = connected({ mock = mock })
    T.eq(request:match("X%-DirectorLink%-Home: (%x+)"), old.home_id, "the home keeps its id")
    T.eq(mock.persist["DIRECTORLINK_REMOTE_IDENTITY"], "", "the encrypted copy is emptied")
    T.eq(mock.persistEncrypted["directorlink_remote_identity"], false)
    local _, _, again = connected({ mock = Mock.updateDriver(mock) })
    T.eq(again:match("X%-DirectorLink%-Home: (%x+)"), old.home_id, "and keeps it through the next update")
end

return tests
