local Log = require("src.core.log")

-- KNX Contact/Relay (knx_contact_relay.c4z, a combo driver: the device is its own proxy).
-- Commands are the driver's own device commands "Open Relay" / "Close Relay" {Relay = n}; a pulse
-- is close, then open after PULSE_MS (the driver's default "Close-Open" trigger, as the Relay
-- Door Controllers use it). State comes from the driver's events: relay n opened = 1 + 2n,
-- closed = 2 + 2n. C4Bridge controls relay 1 (every relay device in the test project has one).
local KnxRelay = {}

KnxRelay.RELAY = 1
KnxRelay.PULSE_MS = 500

local OPENED_EVENT = 1 + 2 * KnxRelay.RELAY
local CLOSED_EVENT = 2 + 2 * KnxRelay.RELAY

local tracked = {}

function KnxRelay.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "knx_contact_relay.c4z"
end

function KnxRelay.initialize(device)
    local watching = true
    for _, eventId in ipairs({ OPENED_EVENT, CLOSED_EVENT }) do
        local ok, err = pcall(function()
            C4:RegisterDeviceEvent(device.id, eventId)
        end)
        if not ok then
            watching = false
            Log.warn("relay", "unable to watch relay events", { device_id = device.id, event_id = eventId, error = tostring(err) })
        end
    end

    tracked[device.id] = { watching = watching }
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { pulse = true, set_state = true, state_reported = watching }
    -- The driver does not expose its state; it is known after the first change.
    device.state = { relay = nil }
    device.actions = { "pulse", "open", "close" }
    return true
end

function KnxRelay.onDeviceEvent(device, eventId)
    eventId = tonumber(eventId)
    if eventId == OPENED_EVENT then
        device.state.relay = "open"
    elseif eventId == CLOSED_EVENT then
        device.state.relay = "closed"
    else
        return false
    end
    Log.debug("relay", "relay state changed", { device_id = device.id, state = device.state.relay })
    return true
end

function KnxRelay.onVariableChanged()
    return false
end

local function send(deviceId, command)
    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, command, { Relay = tostring(KnxRelay.RELAY) })
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

function KnxRelay.execute(device, action)
    if not tracked[device.id] or not device.supported then
        return false, { code = "DEVICE_NOT_SUPPORTED", message = "This relay is not initialized" }
    end

    local sent, err
    if action == "pulse" then
        sent, err = send(device.id, "Close Relay")
        if sent then
            local ok, timerError = pcall(function()
                C4:SetTimer(KnxRelay.PULSE_MS, function()
                    local released, releaseError = send(device.id, "Open Relay")
                    if not released then
                        Log.error("relay_command", "could not release the relay after a pulse", { device_id = device.id, error = releaseError })
                    end
                end)
            end)
            if not ok then
                -- Never leave a door relay closed: release it now.
                send(device.id, "Open Relay")
                sent, err = false, tostring(timerError)
            end
        end
    elseif action == "open" then
        sent, err = send(device.id, "Open Relay")
    elseif action == "close" then
        sent, err = send(device.id, "Close Relay")
    else
        return false, { code = "ACTION_NOT_SUPPORTED", message = "Unsupported relay action: " .. tostring(action) }
    end

    if not sent then
        Log.error("relay_command", "Control4 command failed", { device_id = device.id, action = action, error = err })
        return false, { code = "CONTROL4_COMMAND_FAILED", message = "Director rejected the relay command: " .. tostring(err) }
    end
    Log.info("relay_command", "relay command sent", { device_id = device.id, action = action })
    return true, { device_id = device.id, action = action }
end

function KnxRelay.reset()
    tracked = {}
end

return KnxRelay
