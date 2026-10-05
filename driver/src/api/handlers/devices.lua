local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local Access = require("src.auth.access")

local Devices = {}

local TYPES = {
    light = true,
    thermostat = true,
    fan = true,
    blind = true,
    camera = true,
    relay = true,
    doorbell = true,
    refrigerator = true,
    other = true,
}

function Devices.list(ctx)
    local query = ctx.query
    local roomId, roomProblem = Validate.optionalInteger(query.room_id, "room_id", 1)
    if roomProblem then
        return roomProblem
    end
    if query.type ~= nil and not TYPES[query.type] then
        return Problem.invalidParameter("type", "type must be one of light, thermostat, fan, blind, camera, relay, doorbell, refrigerator, other")
    end
    local supported, supportedProblem = Validate.optionalBoolean(query.supported, "supported")
    if supportedProblem then
        return supportedProblem
    end

    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(Access.filter(ctx.apiKey, registry.deviceList())) do
        local view = Views.device(registry, device)
        if (roomId == nil or tonumber(device.room_id) == roomId)
            and (query.type == nil or view.type == query.type)
            and (supported == nil or view.supported == supported) then
            items[#items + 1] = view
        end
    end
    return 200, { items = items }
end

function Devices.get(ctx)
    local id, problem = Validate.id(ctx.params.deviceId, "deviceId")
    if not id then
        return problem
    end
    local registry = ctx.services.registry
    local device = registry.getDevice(id)
    -- A device the caller may not see is, for them, one that does not exist (ADR-054).
    if not device or not Access.canSee(ctx.apiKey, device) then
        return Problem.notFound("Device", id)
    end
    return 200, Views.device(registry, device)
end

return Devices
