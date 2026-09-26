-- A fake Director for running the C4Bridge driver in plain Lua 5.1.
-- Records everything the driver sends so tests can assert on it.

local Mock = {}

local md5 = require("md5")

-- A small project: two rooms, three lights (KNX dimmer, KNX switch, other dimmer),
-- one thermostat, two blinds (one without a known level), two cameras (digest and basic login)
-- and one unsupported device.
function Mock.project()
    return {
        osVersion = "3.4.3.727848-res",
        bridgeId = 572,
        projectProperties = {
            CityName = "Tel Aviv",
            CountryCode = "IL",
            CountryName = "Israel",
            Latitude = "32.08",
            Longitude = "34.78",
        },
        hierarchy = {
            id = 1, name = "Home", type = 2,
            {
                id = 2, name = "House", type = 3,
                {
                    id = 3, name = "Ground Floor", type = 4,
                    { id = 10, name = "Kitchen", type = 8 },
                    { id = 11, name = "Living Room", type = 8 },
                },
            },
        },
        devices = {
            [101] = {
                deviceName = "KNX Dimmer", driverFileName = "knx_dimmer.c4i", roomId = 10, roomName = "Kitchen",
                proxies = { [20] = { deviceName = "Kitchen Island", driverFileName = "light_v2.c4i" } },
            },
            [20] = {
                deviceName = "Kitchen Island", driverFileName = "light_v2.c4i", roomId = 10, roomName = "Kitchen",
                protocol = { [101] = { deviceName = "KNX Dimmer", driverFileName = "knx_dimmer.c4i" } },
            },
            [102] = {
                deviceName = "KNX Switch", driverFileName = "knx_switch.c4i", roomId = 11, roomName = "Living Room",
                proxies = { [21] = { deviceName = "Hall Light", driverFileName = "light_v2.c4i" } },
            },
            [21] = {
                deviceName = "Hall Light", driverFileName = "light_v2.c4i", roomId = 11, roomName = "Living Room",
                protocol = { [102] = { deviceName = "KNX Switch", driverFileName = "knx_switch.c4i" } },
            },
            [103] = {
                deviceName = "Dimmer Module", driverFileName = "zigbee_dimmer.c4i", roomId = 11, roomName = "Living Room",
                proxies = { [22] = { deviceName = "Desk Lamp", driverFileName = "light_v2.c4i" } },
            },
            [22] = {
                deviceName = "Desk Lamp", driverFileName = "light_v2.c4i", roomId = 11, roomName = "Living Room",
                protocol = { [103] = { deviceName = "Dimmer Module", driverFileName = "zigbee_dimmer.c4i" } },
            },
            [104] = {
                deviceName = "AC Zone", driverFileName = "coolautomation_cmnet_zone.c4z", roomId = 11, roomName = "Living Room",
                proxies = { [30] = { deviceName = "Parents", driverFileName = "thermostatV2.c4i" } },
            },
            [30] = {
                deviceName = "Parents", driverFileName = "thermostatV2.c4i", roomId = 11, roomName = "Living Room",
                protocol = { [104] = { deviceName = "AC Zone", driverFileName = "coolautomation_cmnet_zone.c4z" } },
            },
            [105] = {
                deviceName = "KNX Blinds (2.9+)", driverFileName = "knx_blind.c4z", roomId = 11, roomName = "Living Room",
                proxies = { [50] = { deviceName = "Window Blind", driverFileName = "blind.c4i" } },
            },
            [50] = {
                deviceName = "Window Blind", driverFileName = "blind.c4i", roomId = 11, roomName = "Living Room",
                protocol = { [105] = { deviceName = "KNX Blinds (2.9+)", driverFileName = "knx_blind.c4z" } },
            },
            [106] = {
                deviceName = "KNX Blinds (2.9+)", driverFileName = "knx_blind.c4z", roomId = 10, roomName = "Kitchen",
                proxies = { [51] = { deviceName = "Kitchen Shutter", driverFileName = "blind.c4i" } },
            },
            [51] = {
                deviceName = "Kitchen Shutter", driverFileName = "blind.c4i", roomId = 10, roomName = "Kitchen",
                protocol = { [106] = { deviceName = "KNX Blinds (2.9+)", driverFileName = "knx_blind.c4z" } },
            },
            [107] = {
                deviceName = "Hikvision IPC Camera (Static)", driverFileName = "camera_ip_hik_ipc_static.c4z", roomId = 10, roomName = "Kitchen",
                proxies = { [60] = { deviceName = "Driveway", driverFileName = "camera.c4i" } },
            },
            [60] = {
                deviceName = "Driveway", driverFileName = "camera.c4i", roomId = 10, roomName = "Kitchen",
                protocol = { [107] = { deviceName = "Hikvision IPC Camera (Static)", driverFileName = "camera_ip_hik_ipc_static.c4z" } },
            },
            [108] = {
                deviceName = "DoorBird", driverFileName = "doorbird_doorstation.c4z", roomId = 11, roomName = "Living Room",
                proxies = { [61] = { deviceName = "Gate", driverFileName = "camera.c4i" } },
            },
            [61] = {
                deviceName = "Gate", driverFileName = "camera.c4i", roomId = 11, roomName = "Living Room",
                protocol = { [108] = { deviceName = "DoorBird", driverFileName = "doorbird_doorstation.c4z" } },
            },
            -- A combo driver: the relay device is its own proxy.
            [70] = {
                deviceName = "Main Door", driverFileName = "knx_contact_relay.c4z", roomId = 10, roomName = "Kitchen",
            },
            [40] = {
                deviceName = "Front Door", driverFileName = "camera_ip_hik_ipc_static.c4z", roomId = 10, roomName = "Kitchen",
            },
            [572] = {
                deviceName = "C4Bridge", driverFileName = "C4Bridge.c4z", roomId = 10, roomName = "Kitchen",
                proxies = { [574] = { deviceName = "C4Bridge Access", driverFileName = "uibutton.c4i" } },
            },
            [574] = {
                deviceName = "C4Bridge Access", driverFileName = "uibutton.c4i", roomId = 10, roomName = "Kitchen",
                protocol = { [572] = { deviceName = "C4Bridge", driverFileName = "C4Bridge.c4z" } },
            },
        },
        variables = {
            [20] = { [1000] = "1", [1001] = "80" },
            [21] = { [1000] = "0" },
            [22] = { [1000] = "1", [1001] = "40" },
            [30] = {
                [1100] = "CELSIUS",
                [1104] = "Cool",
                [1105] = "Low",
                [1107] = "Cool",
                [1112] = "1",
                [1120] = "Off,Heat,Cool",
                [1131] = "26",
                [1149] = "71.6",
            },
            [50] = { [1000] = "40", [1001] = "40" },
            [51] = { [1000] = "-255", [1001] = "-255" },
        },
        -- Camera proxies: what GET_PROPERTIES / GET_SNAPSHOT_QUERY_STRING return, and the fake camera.
        cameras = {
            [60] = {
                address = "192.168.1.81", http_port = 80, auth_type = "DIGEST", username = "admin", password = "s3cret&pw",
                query = "ISAPI/Streaming/channels/101/picture?snapShotImageType=JPEG&amp;size=%dx%d",
            },
            [61] = {
                address = "192.168.1.117", http_port = 8080, auth_type = "BASIC", username = "user", password = "door",
                query = "/bha-api/image.cgi",
            },
        },
        -- Names for C4:GetDeviceVariables (blind proxies are looked up by variable name).
        variableNames = {
            [50] = { [1000] = "Level", [1001] = "Target Level" },
            [51] = { [1000] = "Level", [1001] = "Target Level" },
        },
    }
end

-- Installs global C4 and Properties objects backed by `project`.
function Mock.install(project)
    project = project or Mock.project()
    local mock = {
        persist = {},
        properties = {},
        debugLog = {},
        sent = {},
        closed = {},
        commands = {},
        proxy = {},
        -- Security lists of room 10 (Kitchen): a cameras shortcut and a gate button are visible,
        -- the C4Bridge Access button (574) was added hidden next to another hidden button.
        security = { [10] = { visible = { 4294966301, 531 }, hidden = { 541, 574, 483 } } },
        listeners = {},
        urlRequests = {},
        deviceEvents = {},
        servers = {},
        timers = {},
        uuidCount = 0,
        clock = 5000,
    }

    local C4 = {}

    function C4:UUID(_kind)
        mock.uuidCount = mock.uuidCount + 1
        local n = mock.uuidCount
        return string.format("%08x-%04x-4%03x-8%03x-%012x", (n * 2654435761) % 4294967296, n % 65536, n % 4096, (n * 7) % 4096, n * 97)
    end

    function C4:PersistGetValue(key, _encrypted)
        return mock.persist[key]
    end

    function C4:PersistSetValue(key, value, _encrypted)
        mock.persist[key] = value
    end

    function C4:UpdateProperty(name, value)
        mock.properties[name] = value
    end

    function C4:DebugLog(message)
        mock.debugLog[#mock.debugLog + 1] = message
    end

    function C4:GetTime()
        mock.clock = mock.clock + 3
        return mock.clock
    end

    function C4:GetVersionInfo()
        return { version = project.osVersion }
    end

    function C4:GetSystemType()
        return "XDT_CORE1"
    end

    function C4:GetTimeZone()
        return "Asia/Jerusalem"
    end

    function C4:GetBootID()
        return "boot-1"
    end

    function C4:GetDeviceID()
        return project.bridgeId
    end

    function C4:GetProjectProperty(name)
        return project.projectProperties[name]
    end

    function C4:GetProjectHierarchy()
        return project.hierarchy
    end

    function C4:GetDevices(_filter)
        return project.devices
    end

    function C4:GetVariable(deviceId, variableId)
        local values = project.variables[deviceId]
        return values and values[variableId]
    end

    function C4:GetDeviceVariables(deviceId)
        local result = {}
        local names = (project.variableNames or {})[deviceId] or {}
        for id, value in pairs(project.variables[deviceId] or {}) do
            result[id] = { name = names[id] or tostring(id), value = value }
        end
        return result
    end

    function C4:RegisterDeviceEvent(deviceId, eventId)
        mock.deviceEvents[#mock.deviceEvents + 1] = { deviceId, eventId }
    end

    function C4:RegisterVariableListener(deviceId, variableId)
        mock.listeners[#mock.listeners + 1] = { deviceId, variableId }
    end

    function C4:UnregisterVariableListener(_deviceId, _variableId)
    end

    function C4:UnregisterAllVariableListeners()
        mock.listeners = {}
    end

    function C4:SendToDevice(deviceId, command, params)
        mock.commands[#mock.commands + 1] = { device = deviceId, command = command, params = params }
        local room = mock.security[deviceId]
        if room and command == "SET_SECURITY_DEVICE_ORDER" then
            room.visible, room.hidden = {}, {}
            for id, hidden in tostring(params.DEVICE_DATA_XML):gmatch("<deviceid>(%-?%d+)</deviceid><order>%d+</order><hidden>(%d)</hidden>") do
                local unsigned = tonumber(id) < 0 and tonumber(id) + 4294967296 or tonumber(id)
                table.insert(hidden == "1" and room.hidden or room.visible, unsigned)
            end
        end
    end

    function C4:SendUIRequest(deviceId, request, params)
        local camera = project.cameras and project.cameras[deviceId]
        if camera and request == "GET_PROPERTIES" then
            return string.format(
                "<camera_properties><address>%s</address><http_port>%d</http_port><https_port>443</https_port>"
                    .. "<use_https>false</use_https><authentication_required>true</authentication_required>"
                    .. "<authentication_type>%s</authentication_type><username>%s</username><password>%s</password>"
                    .. "</camera_properties>",
                camera.address, camera.http_port, camera.auth_type, camera.username, camera.password:gsub("&", "&amp;")
            )
        elseif camera and request == "GET_SNAPSHOT_QUERY_STRING" then
            local query = camera.query:find("%%d") and string.format(camera.query, params.SIZE_X, params.SIZE_Y) or camera.query
            return "<snapshot_query_string>" .. query .. "</snapshot_query_string>"
        end
        local room = mock.security[deviceId]
        if not room or request ~= "GET_SECURITY_DEVICES" or mock.uiRequestsFail then
            error("UI request failed")
        end
        local list = (params and params.hidden == 1) and room.hidden or room.visible
        local parts = {}
        for _, id in ipairs(list) do
            parts[#parts + 1] = string.format("<source><id>%.0f</id><type>UIButton</type></source>", id)
        end
        return "<sources>" .. table.concat(parts) .. "</sources>"
    end

    function C4:Hash(algorithm, data, _options)
        assert(algorithm == "MD5", "only MD5 is faked")
        return string.upper(md5(data))
    end

    function C4:Base64Encode(data)
        local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        return ((data:gsub(".", function(c)
            local bits, byte = "", c:byte()
            for i = 8, 1, -1 do
                bits = bits .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
            end
            return bits
        end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
            if #bits < 6 then
                return ""
            end
            local n = 0
            for i = 1, 6 do
                n = n + (bits:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
            end
            return chars:sub(n + 1, n + 1)
        end) .. ({ "", "==", "=" })[#data % 3 + 1])
    end

    -- A fake camera web server: digest (qop=auth) or basic login, answers with a tiny "JPEG".
    local function cameraAnswer(url, headers)
        mock.urlRequests[#mock.urlRequests + 1] = { url = url, headers = headers }
        if mock.camerasOffline then
            return nil, "Couldn't connect to server"
        end
        local host, path = url:match("^https?://([^/:]+)[^/]*(/.*)$")
        for _, camera in pairs(project.cameras or {}) do
            if camera.address == host then
                local authorization = headers and headers.Authorization or ""
                local ok = false
                if camera.auth_type == "BASIC" then
                    ok = authorization == "Basic " .. C4:Base64Encode(camera.username .. ":" .. (camera.camera_password or camera.password))
                else
                    local fields = {}
                    for name, value in authorization:gmatch('([%w_-]+)="([^"]*)"') do
                        fields[name] = value
                    end
                    for name, value in authorization:gmatch("([%w_-]+)=([^\",%s]+)") do
                        fields[name] = fields[name] or value
                    end
                    if fields.nonce == "abc123" and fields.uri == path then
                        local ha1 = md5(camera.username .. ":Camera:" .. (camera.camera_password or camera.password))
                        local ha2 = md5("GET:" .. path)
                        local expected = md5(ha1 .. ":abc123:" .. fields.nc .. ":" .. fields.cnonce .. ":auth:" .. ha2)
                        ok = fields.response == expected and fields.opaque == "op1"
                    end
                end
                if ok then
                    return { code = 200, headers = { ["Content-Type"] = "image/jpeg" }, body = "\255\216JPEG-" .. path .. "\255\217" }
                end
                local challenge = camera.auth_type == "BASIC" and 'Basic realm="Camera"'
                    or 'Digest realm="Camera", qop="auth", nonce="abc123", opaque="op1", algorithm=MD5'
                return { code = 401, headers = { ["WWW-Authenticate"] = challenge }, body = "" }
            end
        end
        return nil, "Couldn't resolve host"
    end

    function C4:url()
        local transfer = { options = {} }
        function transfer:SetOptions(options)
            for name, value in pairs(options) do
                self.options[name] = value
            end
            return self
        end
        function transfer:OnDone(callback)
            self.callback = callback
            return self
        end
        function transfer:Get(url, headers)
            local response, err = cameraAnswer(url, headers)
            if response then
                self.callback(self, { { url = url, code = response.code, headers = response.headers, body = response.body } }, 0, nil)
            else
                self.callback(self, {}, 7, err)
            end
            return self
        end
        return transfer
    end

    function C4:SendToProxy(binding, command, params)
        mock.proxy[#mock.proxy + 1] = { binding = binding, command = command, params = params }
    end

    function C4:CreateServer(port, delimiter, udp)
        mock.servers[port] = { delimiter = delimiter, udp = udp }
    end

    function C4:DestroyServer(port)
        mock.servers[port] = nil
    end

    function C4:ServerSend(handle, data)
        mock.sent[handle] = (mock.sent[handle] or "") .. data
    end

    function C4:ServerCloseClient(handle)
        mock.closed[handle] = true
    end

    function C4:SetTimer(delay, callback, repeating)
        local timer = { delay = delay, callback = callback, repeating = repeating, cancelled = false, fired = false }
        function timer:Cancel()
            self.cancelled = true
        end
        mock.timers[#mock.timers + 1] = timer
        return timer
    end

    _G.C4 = C4
    _G.Properties = { ["Log Level"] = "Info" }
    return mock
end

-- Runs timers that have not fired yet, including ones they schedule (up to `rounds` passes).
function Mock.fireTimers(mock, rounds)
    for _ = 1, rounds or 10 do
        local pending = {}
        for _, timer in ipairs(mock.timers) do
            if not timer.fired and not timer.cancelled then
                pending[#pending + 1] = timer
            end
        end
        if #pending == 0 then
            return
        end
        for _, timer in ipairs(pending) do
            timer.fired = true
            timer.callback()
        end
    end
end

-- Loads a fresh copy of the driver (all src.* modules) and runs its init callbacks.
-- specText replaces the stub API description (the dev server passes the built one).
function Mock.startDriver(project, specText, initType)
    -- The JSON module is stateless; keep it shared so tests and driver agree on Json.null.
    for name in pairs(package.loaded) do
        if name:sub(1, 4) == "src." and name ~= "src.core.json" then
            package.loaded[name] = nil
        end
    end
    package.preload["src.api.openapi_spec"] = function()
        return specText or '{"openapi":"3.1.0","info":{"title":"test"}}'
    end

    local mock = Mock.install(project)
    require("src.main")
    OnDriverInit(initType or "DIT_STARTUP")
    OnDriverLateInit(initType or "DIT_STARTUP")
    OnServerStatusChanged(41999, "ONLINE")
    return mock
end

return Mock
