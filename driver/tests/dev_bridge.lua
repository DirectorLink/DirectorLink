-- Runs the real driver against the fake Director for scripts/dev_server.py.
-- Protocol (hex keeps it binary-safe through text-mode pipes on Windows):
--   in:  "<handle> <hex bytes>\n"   (empty hex = the client disconnected)
--   out: "<closed 0|1> <hex response bytes>\n"
--   in:  "press\n" presses the C4Bridge Access button; out: "0 \n"

package.path = "./driver/?.lua;./driver/tests/?.lua;" .. package.path

local Mock = require("c4mock")

local specText
local specPath = arg and arg[1]
if specPath and specPath ~= "" then
    local file = io.open(specPath, "rb")
    if file then
        specText = file:read("*a")
        file:close()
    end
end

local mock = Mock.startDriver(nil, specText)
-- The fake home lets the API open its (fake) doors.
Properties["Door Control"] = "Enabled"

local function fromHex(text)
    return (text:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function toHex(text)
    return (text:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

io.write("READY " .. tostring(mock.properties["Pairing Code"]) .. "\n")
io.flush()

local offsets = {}
for line in io.lines() do
    if line:match("^press") then
        ReceivedFromProxy(5001, "SELECT", {})
        io.write("0 \n")
        io.flush()
    end
    local handle, hex = line:match("^(%d+) ?(%x*)$")
    if handle then
        handle = tonumber(handle)
        if hex == "" then
            OnServerConnectionStatusChanged(handle, 41999, "OFFLINE")
        else
            OnServerDataIn(handle, fromHex(hex), "127.0.0.1", "0")
        end
        local sent = mock.sent[handle] or ""
        local start = (offsets[handle] or 0) + 1
        offsets[handle] = #sent
        io.write((mock.closed[handle] and "1" or "0") .. " " .. toHex(sent:sub(start)) .. "\n")
        io.flush()
    end
end
