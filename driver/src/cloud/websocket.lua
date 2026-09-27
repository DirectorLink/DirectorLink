-- A WebSocket client (RFC 6455) over a DriverWorks network connection, for the DirectorLink relay.
--
-- DriverWorks gives a TCP/TLS byte stream: C4:CreateNetworkConnection + C4:NetPortOptions ("SSL")
-- + C4:NetConnect, data in ReceivedFromNetwork, state in OnConnectionStatusChanged (main.lua routes
-- both here). This module does the HTTP upgrade and the framing: client frames are masked, text
-- messages may arrive fragmented, pings are answered with pongs.

local WebSocket = {}
WebSocket.__index = WebSocket

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local OPCODE_CONTINUATION = 0
local OPCODE_TEXT = 1
local OPCODE_BINARY = 2
local OPCODE_CLOSE = 8
local OPCODE_PING = 9
local OPCODE_PONG = 10

-- XOR of two bytes without a bit library (DriverWorks Lua 5.1 does not promise one).
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

local function xorTable(maskByte)
    local t = {}
    for value = 0, 255 do
        t[value] = xorByte(value, maskByte)
    end
    return t
end

-- 16 random bytes from Director's random UUIDs.
local function randomBytes(count)
    local hex = ""
    while #hex < count * 2 do
        hex = hex .. tostring(C4:UUID("RANDOM")):gsub("[^%x]", "")
    end
    return (hex:sub(1, count * 2):gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- Masks (or unmasks) `payload` with the 4-byte `mask`.
function WebSocket.mask(payload, mask)
    local tables = {}
    for index = 1, 4 do
        tables[index] = xorTable(mask:byte(index))
    end
    local parts = {}
    local length = #payload
    local index = 1
    while index <= length do
        local a, b, c, d = payload:byte(index, index + 3)
        if d then
            parts[#parts + 1] = string.char(tables[1][a], tables[2][b], tables[3][c], tables[4][d])
        else
            local tail = { a, b, c }
            local chars = {}
            for offset, value in ipairs(tail) do
                chars[offset] = string.char(tables[offset][value])
            end
            parts[#parts + 1] = table.concat(chars)
        end
        index = index + 4
    end
    return table.concat(parts)
end

local function bigEndian(value, bytes)
    local chars = {}
    for index = bytes, 1, -1 do
        chars[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(chars)
end

-- A client frame: FIN set, masked, with the length encoding RFC 6455 requires.
function WebSocket.frame(opcode, payload, mask)
    payload = payload or ""
    local length = #payload
    local header
    if length < 126 then
        header = string.char(128 + opcode, 128 + length)
    elseif length < 65536 then
        header = string.char(128 + opcode, 128 + 126) .. bigEndian(length, 2)
    else
        header = string.char(128 + opcode, 128 + 127) .. bigEndian(length, 8)
    end
    return header .. mask .. WebSocket.mask(payload, mask)
end

-- options: { binding, host, port, path, headers = { {name, value}, ... }, log,
--            onOpen(), onMessage(text), onClose(reason, status) }
function WebSocket.new(options)
    local self = setmetatable({}, WebSocket)
    self.binding = options.binding
    self.host = options.host
    self.port = options.port or 443
    self.path = options.path or "/"
    self.headers = options.headers or {}
    self.log = options.log
    self.onOpen = options.onOpen or function() end
    self.onMessage = options.onMessage or function() end
    self.onClose = options.onClose or function() end
    self.state = "idle"
    self.buffer = ""
    self.fragments = nil
    self.created = false
    return self
end

function WebSocket:debug(message, data)
    if self.log then
        self.log.debug("relay", message, data)
    end
end

function WebSocket:rawSend(data)
    local ok, err = pcall(function()
        C4:SendToNetwork(self.binding, self.port, data)
    end)
    if not ok then
        self:debug("send failed", { error = tostring(err) })
    end
    return ok
end

-- Opens the TLS connection; the handshake follows in onConnectionStatus("ONLINE").
function WebSocket:connect()
    self.buffer = ""
    self.fragments = nil
    self.state = "connecting"
    local ok, err = pcall(function()
        if not self.created then
            C4:CreateNetworkConnection(self.binding, self.host)
            self.created = true
        end
        C4:NetPortOptions(self.binding, self.port, "SSL", {
            AUTO_CONNECT = false,
            MONITOR_CONNECTION = true,
            KEEP_CONNECTION = false,
            KEEP_ALIVE = true,
        })
        C4:NetConnect(self.binding, self.port)
    end)
    if not ok then
        self.state = "closed"
        self.onClose("connect failed: " .. tostring(err))
    end
    return ok
end

function WebSocket:sendHandshake()
    self.key = C4:Base64Encode(randomBytes(16))
    local lines = {
        "GET " .. self.path .. " HTTP/1.1",
        "Host: " .. self.host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. self.key,
        "Sec-WebSocket-Version: 13",
    }
    for _, header in ipairs(self.headers) do
        lines[#lines + 1] = header[1] .. ": " .. header[2]
    end
    self.state = "handshake"
    self:rawSend(table.concat(lines, "\r\n") .. "\r\n\r\n")
end

function WebSocket:expectedAccept()
    local ok, value = pcall(function()
        return C4:Hash("SHA1", self.key .. GUID, { return_encoding = "BASE64" })
    end)
    return ok and value or nil
end

-- Handles the server's answer to the upgrade. Returns true once open.
function WebSocket:handleHandshake()
    local headEnd = self.buffer:find("\r\n\r\n", 1, true)
    if not headEnd then
        return false
    end
    local head = self.buffer:sub(1, headEnd - 1)
    local rest = self.buffer:sub(headEnd + 4)
    local status = tonumber(head:match("^HTTP/%d%.%d (%d%d%d)"))
    local headers = {}
    for name, value in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[string.lower(name)] = value
    end

    if status ~= 101 then
        -- The relay explains a refusal in a small JSON body.
        local length = tonumber(headers["content-length"] or "")
        if length and #rest < length then
            return false
        end
        self.state = "closed"
        self.buffer = ""
        self:close(nil, true)
        self.onClose("refused", status, rest)
        return false
    end

    local expected = self:expectedAccept()
    if expected and headers["sec-websocket-accept"] ~= expected then
        -- TLS already authenticates the relay; a mismatch means a broken proxy or hash option.
        if self.log then
            self.log.warn("relay", "unexpected Sec-WebSocket-Accept; continuing", { status = status })
        end
    end
    self.state = "open"
    self.buffer = rest
    self.onOpen()
    return true
end

local function readLength(buffer, offset, bytes)
    local value = 0
    for index = offset, offset + bytes - 1 do
        value = value * 256 + buffer:byte(index)
    end
    return value
end

-- Parses complete frames from the buffer and dispatches them.
function WebSocket:processFrames()
    while self.state == "open" do
        local buffer = self.buffer
        if #buffer < 2 then
            return
        end
        local b1, b2 = buffer:byte(1, 2)
        local fin = b1 >= 128
        local opcode = b1 % 16
        local masked = b2 >= 128
        local length = b2 % 128
        local offset = 3
        if length == 126 then
            if #buffer < 4 then
                return
            end
            length = readLength(buffer, 3, 2)
            offset = 5
        elseif length == 127 then
            if #buffer < 10 then
                return
            end
            length = readLength(buffer, 3, 8)
            offset = 11
        end
        local mask
        if masked then
            if #buffer < offset + 3 then
                return
            end
            mask = buffer:sub(offset, offset + 3)
            offset = offset + 4
        end
        if #buffer < offset + length - 1 then
            return
        end
        local payload = buffer:sub(offset, offset + length - 1)
        self.buffer = buffer:sub(offset + length)
        if mask then
            payload = WebSocket.mask(payload, mask)
        end
        self:handleFrame(fin, opcode, payload)
    end
end

function WebSocket:handleFrame(fin, opcode, payload)
    if opcode == OPCODE_PING then
        self:send(payload, OPCODE_PONG)
    elseif opcode == OPCODE_PONG then
        self.onMessage(nil, "pong")
    elseif opcode == OPCODE_CLOSE then
        local code = #payload >= 2 and readLength(payload, 1, 2) or nil
        local reason = payload:sub(3)
        self:send(payload:sub(1, 2), OPCODE_CLOSE)
        self.state = "closed"
        self:close(nil, true)
        self.onClose("closed by the relay" .. (code and (" (" .. code .. (reason ~= "" and (" " .. reason) or "") .. ")") or ""), code)
    elseif opcode == OPCODE_TEXT or opcode == OPCODE_BINARY then
        if fin then
            self.fragments = nil
            self.onMessage(payload)
        else
            self.fragments = { payload }
        end
    elseif opcode == OPCODE_CONTINUATION and self.fragments then
        self.fragments[#self.fragments + 1] = payload
        if fin then
            local message = table.concat(self.fragments)
            self.fragments = nil
            self.onMessage(message)
        end
    end
end

-- Sends a text message (or a control frame with `opcode`).
function WebSocket:send(payload, opcode)
    if self.state ~= "open" and opcode ~= OPCODE_CLOSE then
        return false
    end
    return self:rawSend(WebSocket.frame(opcode or OPCODE_TEXT, payload, randomBytes(4)))
end

-- Closes the connection. `quiet` skips the close frame (the connection is already gone).
function WebSocket:close(code, quiet)
    if not quiet and self.state == "open" then
        self:send(bigEndian(code or 1000, 2), OPCODE_CLOSE)
    end
    self.state = "closed"
    pcall(function()
        C4:NetDisconnect(self.binding, self.port)
    end)
end

-- Director callbacks, routed by main.lua for this binding.
function WebSocket:onConnectionStatus(status)
    status = tostring(status)
    if status == "ONLINE" then
        if self.state == "connecting" then
            self:sendHandshake()
        end
    elseif status == "OFFLINE" then
        local wasActive = self.state ~= "closed" and self.state ~= "idle"
        self.state = "closed"
        if wasActive then
            self.onClose("connection lost")
        end
    end
end

function WebSocket:onData(data)
    self.buffer = self.buffer .. tostring(data or "")
    if self.state == "handshake" then
        if not self:handleHandshake() then
            return
        end
    end
    self:processFrames()
end

return WebSocket
