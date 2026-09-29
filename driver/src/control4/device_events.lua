-- Device events DirectorLink watches (C4:RegisterDeviceEvent: a relay opened, a DoorBird rang).
-- A project refresh initializes the adapters again, and Director does not say whether a pair
-- registered twice is delivered twice: each pair is registered once per driver run. Events of
-- devices that left the project still arrive; the adapter manager ignores them.

local DeviceEvents = {}

local registered = {}

-- True when the event is watched (now, or already); false and the error when Director refused.
function DeviceEvents.watch(deviceId, eventId)
    local key = tostring(deviceId) .. ":" .. tostring(eventId)
    if registered[key] then
        return true
    end
    local ok, err = pcall(function()
        C4:RegisterDeviceEvent(deviceId, eventId)
    end)
    if not ok then
        return false, err
    end
    registered[key] = true
    return true
end

return DeviceEvents
