-- API representations. This is the only place internal registry records become public JSON,
-- so Control4 specifics (proxy drivers, command names, variable IDs) stay out of the API.

local Json = require("src.core.json")

local Views = {}

local TYPE_BY_KIND = {
    light = "light",
    climate = "thermostat",
    cover = "cover",
}

local RESOURCE_PATH = {
    light = "/v1/lights/",
    thermostat = "/v1/thermostats/",
}

local SETTABLE_MODES = {
    off = true,
    heat = true,
    cool = true,
    auto = true,
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
        fanSpeeds[#fanSpeeds + 1] = string.lower(tostring(speed))
    end
    return {
        modes = modes,
        fan_speeds = fanSpeeds,
        min = capabilities.target_temperature_min_c or 16,
        max = capabilities.target_temperature_max_c or 32,
    }
end

function Views.thermostat(registry, device)
    local state = device.state or {}
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
    }
end

function Views.apiKey(record, currentId)
    return {
        id = record.id,
        name = record.name,
        created_at = record.created_at,
        last_used_at = nullable(record.last_used_at),
        current = record.id == currentId,
    }
end

function Views.newApiKey(record, currentId)
    local view = Views.apiKey(record, currentId)
    view.key = record.secret
    return view
end

return Views
