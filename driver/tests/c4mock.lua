-- A fake Director for running the C4Bridge driver in plain Lua 5.1.
-- Records everything the driver sends so tests can assert on it.

local Mock = {}

-- A small project: two rooms, three lights (KNX dimmer, KNX switch, other dimmer),
-- one thermostat and one unsupported camera.
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
