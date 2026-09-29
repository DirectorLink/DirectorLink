-- API representations. This is the only place internal registry records become public JSON,
-- so Control4 specifics (proxy drivers, command names, variable IDs) stay out of the API.

local Json = require("src.core.json")
local RoomNames = require("src.core.room_names")

local Views = {}

local TYPE_BY_KIND = {
    light = "light",
    climate = "thermostat",
    blind = "blind",
    camera = "camera",
    relay = "relay",
    doorbell = "doorbell",
}

local RESOURCE_PATH = {
    light = "/v1/lights/",
    thermostat = "/v1/thermostats/",
    blind = "/v1/blinds/",
    camera = "/v1/cameras/",
    relay = "/v1/relays/",
    doorbell = "/v1/doorbells/",
}

local SETTABLE_MODES = {
    off = true,
    heat = true,
    cool = true,
    auto = true,
}

-- The FanSpeed values of the API. A thermostat may list others (e.g. "Humidify"); they are not
-- offered, so every fan speed shown can be sent back with PATCH.
local SETTABLE_FAN_SPEEDS = {
    low = true,
    medium = true,
    high = true,
    auto = true,
    on = true,
    circulate = true,
}

local function nullable(value)
    if value == nil or value == "" then
        return Json.null
    end
    return value
end

local function slug(value)
    local text = string.lower(tostring(value or ""))
    text = text:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return text
end

function Views.roomRef(registry, roomId, fallbackName)
    roomId = tonumber(roomId)
    if not roomId then
        return Json.null
    end
    local room = (registry.rooms or {})[roomId] or (registry.locations or {})[roomId]
    return {
        id = roomId,
        name = (room and room.name) or fallbackName or ("Room " .. tostring(roomId)),
        names = RoomNames.get(roomId),
    }
end

function Views.room(registry, room, deviceCounts)
    local floor = Json.null
    local parent = room.parent_id and (registry.locations or {})[room.parent_id]
    if parent and parent.type == "floor" then
        floor = { id = parent.id, name = parent.name }
    end
    return {
        id = room.id,
        name = room.name,
        names = RoomNames.get(room.id),
        floor = floor,
        device_count = deviceCounts[room.id] or 0,
    }
end

function Views.deviceType(device)
    return TYPE_BY_KIND[device.kind] or "other"
end

function Views.device(registry, device)
    local deviceType = Views.deviceType(device)
    local supported = device.supported == true and RESOURCE_PATH[deviceType] ~= nil
    return {
        id = device.id,
        name = device.name,
        type = deviceType,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        supported = supported,
        href = supported and (RESOURCE_PATH[deviceType] .. tostring(device.id)) or Json.null,
    }
end

function Views.light(registry, device)
    local capabilities = device.capabilities or {}
    local state = device.state or {}
    return {
        id = device.id,
        name = device.name,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        on = state.power == true,
        brightness = nullable(state.brightness),
        dimmable = capabilities.brightness == true,
        brightness_reported = capabilities.brightness_feedback == true,
    }
end

-- `capabilities` and the movement fields came in 1.1.0: a shade may only open and close fully
-- (PATCH takes 0 and 100), or not stop; `moving` is null when the controller does not report it.
function Views.blind(registry, device)
    local capabilities = device.capabilities or {}
    local state = device.state or {}
    return {
        id = device.id,
        name = device.name,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        position = nullable(state.position),
        position_reported = capabilities.position_reported == true,
        capabilities = {
            position = capabilities.position ~= false,
            stop = capabilities.stop ~= false,
        },
        moving = state.moving == nil and Json.null or state.moving,
        direction = nullable(state.direction),
        target_position = nullable(state.target_position),
    }
end

function Views.camera(registry, device)
    return {
        id = device.id,
        name = device.name,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        snapshot_href = "/v1/cameras/" .. tostring(device.id) .. "/snapshot",
    }
end

function Views.relay(registry, device)
    local capabilities = device.capabilities or {}
    local state = device.state or {}
    return {
        id = device.id,
        name = device.name,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        state = state.relay or Json.null,
        state_reported = capabilities.state_reported == true,
    }
end

function Views.doorbell(registry, device)
    local capabilities = device.capabilities or {}
    local state = device.state or {}
    local last = state.last or {}
    local camera = Json.null
    local cameraId = device.linked and device.linked.camera
    local cameraDevice = cameraId and registry.getDevice(cameraId)
    if cameraDevice and cameraDevice.supported then
        camera = { id = cameraDevice.id, snapshot_href = "/v1/cameras/" .. tostring(cameraDevice.id) .. "/snapshot" }
    end
    local events = Json.array()
    for index, event in ipairs(state.events or {}) do
        events[index] = { type = event.type, at = event.at }
    end
    return {
        id = device.id,
        name = device.name,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        camera = camera,
        can_open = capabilities.open == true,
        connected = state.connected == nil and Json.null or state.connected,
        last_ring_at = last.doorbell or Json.null,
        last_motion_at = last.motion or Json.null,
        last_opened_at = last.opened or Json.null,
        last_access_at = last.access or Json.null,
        events = events,
    }
end

-- What the zone is doing now, from the thermostat's reported HVAC state.
local function activity(value)
    local text = string.lower(tostring(value or ""))
    if text == "" then
        return Json.null
    elseif text:find("heat") then
        return "heating"
    elseif text:find("cool") then
        return "cooling"
    elseif text:find("dry") then
        return "drying"
    elseif text:find("fan") then
        return "fan"
    elseif text == "off" or text == "idle" then
        return "idle"
    end
    return slug(text)
end

-- Modes and fan speeds that PATCH /v1/thermostats/{id} accepts for this device.
function Views.thermostatOptions(device)
    local capabilities = device.capabilities or {}
    local modes = Json.array()
    for _, mode in ipairs(capabilities.hvac_modes or {}) do
        local name = string.lower(tostring(mode))
        if SETTABLE_MODES[name] then
            modes[#modes + 1] = name
        end
    end
    local fanSpeeds = Json.array()
    for _, speed in ipairs(capabilities.fan_modes or {}) do
        local name = string.lower(tostring(speed))
        if SETTABLE_FAN_SPEEDS[name] then
            fanSpeeds[#fanSpeeds + 1] = name
        end
    end
    return {
        modes = modes,
        fan_speeds = fanSpeeds,
        min = capabilities.target_temperature_min_c or 16,
        max = capabilities.target_temperature_max_c or 32,
    }
end

-- True for thermostats with separate heat and cool setpoints (the Control4 thermostat proxy).
function Views.isDual(device)
    return (device.capabilities or {}).setpoints == "dual"
end

-- On a dual-setpoint thermostat `target_temperature` is the setpoint of the current mode (null in
-- auto and off); the three setpoint keys are null on single-setpoint ones.
function Views.thermostat(registry, device)
    local state = device.state or {}
    local capabilities = device.capabilities or {}
    local options = Views.thermostatOptions(device)
    return {
        id = device.id,
        name = device.name,
        room = Views.roomRef(registry, device.room_id, device.room_name),
        online = state.connected ~= false,
        current_temperature = nullable(state.current_temperature_c),
        target_temperature = nullable(state.target_temperature_c),
        target_temperature_min = options.min,
        target_temperature_max = options.max,
        mode = state.hvac_mode and slug(state.hvac_mode) or Json.null,
        modes = options.modes,
        activity = activity(state.hvac_state),
        fan_speed = state.fan_mode and slug(state.fan_mode) or Json.null,
        fan_speeds = options.fan_speeds,
        setpoints = capabilities.setpoints == "dual" and "dual" or "single",
        heat_setpoint = nullable(state.heat_setpoint_c),
        cool_setpoint = nullable(state.cool_setpoint_c),
        setpoint_deadband = nullable(capabilities.deadband_c),
    }
end

function Views.apiKey(record, currentId)
    return {
        id = record.id,
        name = record.name,
        role = record.role,
        created_at = record.created_at,
        last_used_at = nullable(record.last_used_at),
        current = record.id == currentId,
        profile_id = nullable(record.profile),
    }
end

function Views.newApiKey(record, currentId)
    local view = Views.apiKey(record, currentId)
    view.key = record.secret
    return view
end

return Views
