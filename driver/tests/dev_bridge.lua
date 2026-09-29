-- Runs the real driver against the fake Director for scripts/dev_server.py.
-- Protocol (hex keeps it binary-safe through text-mode pipes on Windows):
--   in:  "<handle> <hex bytes>\n"   (empty hex = the client disconnected)
--   out: "<closed 0|1> <hex response bytes>\n"
--   in:  "code\n" runs the Composer action New Pairing Code; out: "CODE <code>\n"

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

-- The default project plus the device families of 1.1.0 (older lights, a thermostat with heat and
-- cool setpoints, floor heating on its heat setpoint), so the app preview shows them all.
local mock = Mock.startDriver(Mock.demoProject(), specText)
-- The fake home lets the API open its (fake) doors.
Properties["Door Control"] = "Enabled"
-- The app and console served from this PC (python -m http.server) may call this test bridge. The
-- driver itself answers only DirectorLink's own sites; this is the test harness, never packaged.
local Server = require("src.api.server")
local driverOrigins = Server.originAllowed
Server.originAllowed = function(origin)
    if type(origin) ~= "string" then
        return driverOrigins(origin)
    end
    return driverOrigins(origin) or origin:match("^http://localhost:%d+$") ~= nil or origin:match("^http://127%.0%.0%.1:%d+$") ~= nil
end
-- And a fake Open-Meteo answers for its weather.
local Json = require("src.core.json")
mock.weather = {
    current = { temperature_2m = 27, precipitation = 0, weather_code = 1, wind_speed_10m = 12, wind_gusts_10m = 20 },
    daily = {
        temperature_2m_max = Json.array({ 31 }),
        temperature_2m_min = Json.array({ 22 }),
        precipitation_probability_max = Json.array({ 10 }),
    },
}

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
    if line:match("^code") then
        ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
        io.write("CODE " .. tostring(mock.properties["Pairing Code"]) .. "\n")
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
