local Clock = require("src.core.clock")
local DeviceEvents = require("src.control4.device_events")
local Json = require("src.core.json")
local Log = require("src.core.log")

-- DoorBird (doorbird_doorstation.c4z). Its doorstation proxy is the doorbell; the driver's other
-- proxies are a button (uibutton: a single tap runs the installer's choice, by default "Trigger
-- Relay 1" — the gate or door wired to the DoorBird), a camera (handled by the camera adapter) and
-- an intercom. The driver fires numbered events, as seen on a real controller's event log:
-- 100 driver communication failed, 102 doorbell pressed, 103 motion detected, 104 relay triggered,
-- 106 keypad access granted. They are watched on the DoorBird driver itself, not on the proxy.
local DoorBird = {}

DoorBird.PROTOCOL_DRIVER = "doorbird_doorstation.c4z"
DoorBird.EVENTS = {
    [100] = "communication_failed",
    [102] = "doorbell",
    [103] = "motion",
    [104] = "opened",
    [106] = "access",
}
DoorBird.MAX_EVENTS = 20

local tracked = {}

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function doorbirdProtocol(device)
    for _, protocol in ipairs(device.protocols or {}) do
        if lower(protocol.driver) == DoorBird.PROTOCOL_DRIVER then
            return tonumber(protocol.id)
        end
    end
    return nil
end

function DoorBird.matches(device)
    local driver = lower(device and device.proxy and device.proxy.driver)
    return (driver == "doorstation.c4i" or driver == "doorstation.c4z") and doorbirdProtocol(device) ~= nil
end

local function sibling(registry, protocolId, driverName)
    local protocol = registry and registry.protocols and registry.protocols[protocolId]
    for _, proxy in ipairs(protocol and protocol.proxies or {}) do
        if lower(proxy.driver) == driverName then
            return tonumber(proxy.id)
        end
    end
    return nil
end

-- before: this doorbell as it was before a project refresh, if it was one.
function DoorBird.initialize(device, registry, before)
    local protocolId = doorbirdProtocol(device)
    if not protocolId then
        return false, "no DoorBird driver behind this doorstation"
    end
    local watched = {}
    for eventId in pairs(DoorBird.EVENTS) do
        local ok, err = DeviceEvents.watch(protocolId, eventId)
        if ok then
            watched[#watched + 1] = eventId
        else
            Log.warn("doorbell", "unable to watch a DoorBird event", { device_id = protocolId, event_id = eventId, error = tostring(err) })
        end
    end

    local info = {
        protocol = protocolId,
        button = sibling(registry, protocolId, "uibutton.c4i"),
        camera = sibling(registry, protocolId, "camera.c4i"),
    }
    tracked[device.id] = info
    -- The driver's other proxies (its button, intercom and camera) are parts of this doorbell, not
    -- devices of their own (/v1/devices: part_of, 1.10.1); another doorstation stays a doorbell.
    local protocol = registry and registry.protocols and registry.protocols[protocolId]
    for _, proxy in ipairs(protocol and protocol.proxies or {}) do
        local part = tonumber(proxy.id) ~= tonumber(device.id) and registry.devices and registry.devices[tonumber(proxy.id)]
        if part and part.kind ~= "doorbell" and (part.part_of == nil or tonumber(device.id) < tonumber(part.part_of)) then
            part.part_of = device.id
        end
    end

    device.supported = true
    device.adapter_error = nil
    -- Events come from the DoorBird driver; the manager routes them to this doorbell.
    device.event_source_id = protocolId
    device.linked = { camera = info.camera }
    device.capabilities = { open = info.button ~= nil, events = #watched > 0 }
    -- Rings and the rest cannot be read back from the DoorBird: a project refresh keeps them, so
    -- a ring a moment ago still shows at the door.
    local kept = before and before.state
    device.state = { connected = Json.null, last = kept and kept.last or {}, events = kept and kept.events or {} }
    if kept and kept.connected ~= nil then
        device.state.connected = kept.connected
    end
    device.actions = info.button and { "open" } or {}
    return true
end

function DoorBird.cameraId(device)
    local info = tracked[device.id]
    return info and info.camera or nil
end

function DoorBird.onDeviceEvent(device, eventId)
    local kind = DoorBird.EVENTS[tonumber(eventId)]
    if not kind or not device.state then
        return false
    end
    local at = Clock.iso(os.time())
    device.state.last[kind] = at
    device.state.connected = kind ~= "communication_failed"
    table.insert(device.state.events, 1, { type = kind, at = at })
    while #device.state.events > DoorBird.MAX_EVENTS do
        table.remove(device.state.events)
    end
    if kind == "motion" then
        Log.debug("doorbell", "motion at the door", { device_id = device.id })
    else
        Log.info("doorbell", kind == "doorbell" and "the doorbell rang" or ("doorbell event: " .. kind), { device_id = device.id })
    end
    return true
end

function DoorBird.onVariableChanged()
    return false
end

function DoorBird.execute(device, action)
    local info = tracked[device.id]
    if not info or not device.supported then
        return false, { code = "DEVICE_NOT_SUPPORTED", message = "This doorbell is not initialized" }
    end
    if action ~= "open" then
        return false, { code = "ACTION_NOT_SUPPORTED", message = "Unsupported doorbell action: " .. tostring(action) }
    end
    if not info.button then
        return false, { code = "ACTION_NOT_SUPPORTED", message = "This DoorBird has no button to open with" }
    end
    -- Exactly what pressing the DoorBird button in the Control4 app does.
    local ok, err = pcall(function()
        C4:SendToDevice(info.button, "SELECT", {})
    end)
    if not ok then
        Log.error("doorbell_command", "Control4 command failed", { device_id = device.id, error = tostring(err) })
        return false, { code = "CONTROL4_COMMAND_FAILED", message = "Director rejected the command: " .. tostring(err) }
    end
    Log.info("doorbell_command", "DoorBird button pressed to open", { device_id = device.id, button_id = info.button })
    return true, { device_id = device.id, action = action }
end

function DoorBird.reset()
    tracked = {}
end

return DoorBird
