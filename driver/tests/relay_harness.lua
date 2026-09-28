-- A fake relay for the driver tests: completes the driver's WebSocket handshake and exchanges
-- frames with it at the byte level (docs/RELAY.md).

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local sha1 = require("sha1")

local Harness = {}

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

-- The driver's frames other than its announcements of key ids ({"type":"keys"}), which follow
-- any change of keys; `keys` gets those.
local function answers(frames, keys)
    local kept = {}
    for _, frame in ipairs(frames) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" and message.type == "keys" then
            if keys then
                keys[#keys + 1] = message.ids
            end
        else
            kept[#kept + 1] = frame
        end
    end
    return kept
end

-- Sends `message` from the relay; returns the driver's answer, its frame, and the key id lists it
-- announced meanwhile.
local function relayRequest(mock, connection, message)
    connection.sent = ""
    ReceivedFromNetwork(BINDING, 443, serverFrame(1, Json.encode(message)))
    local keys = {}
    local frames = answers(clientFrames(connection.sent), keys)
    connection.sent = ""
    T.eq(#frames, 1, "one response frame")
    return Json.decode(frames[1].payload), frames[1], keys
end

-- Accepts the upgrade `request` the driver sent (a reconnect).
local function accept(request)
    local key = request:match("\r\nSec%-WebSocket%-Key: ([^\r\n]+)")
    T.truthy(key, "an upgrade request")
    ReceivedFromNetwork(BINDING, 443, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Accept: " .. C4:Base64Encode(sha1(key .. GUID)) .. "\r\n\r\n")
end

Harness.BINDING = BINDING
Harness.accept = accept
Harness.bigEndian = bigEndian
Harness.serverFrame = serverFrame
Harness.clientFrames = clientFrames
Harness.connected = connected
Harness.answers = answers
Harness.relayRequest = relayRequest

return Harness
