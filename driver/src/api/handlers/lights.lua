local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Lights = {}

local function findLight(ctx)
    local id, problem = Validate.id(ctx.params.lightId, "lightId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "light" or device.supported ~= true then
        return nil, Problem.notFound("Light", id)
    end
    return device
end

function Lights.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.lightList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.light(registry, device)
        end
    end
    return 200, { items = items }
end

function Lights.get(ctx)
    local device, problem = findLight(ctx)
    if not device then
        return problem
    end
    return 200, Views.light(ctx.services.registry, device)
end

function Lights.update(ctx)
    local device, problem = findLight(ctx)
    if not device then
        return problem
    end

    local body = ctx.body
    problem = Validate.body(body, { on = true, brightness = true }, true)
    if problem then
        return problem
    end
    if body.on ~= nil and type(body.on) ~= "boolean" then
        return Problem.invalidField("on", "on must be true or false")
    end

    local action, params
    if body.brightness ~= nil then
        local brightness = body.brightness
        if type(brightness) ~= "number" or brightness ~= math.floor(brightness) or brightness < 0 or brightness > 100 then
            return Problem.invalidField("brightness", "brightness must be a whole number from 0 to 100")
        end
        if body.on == false then
            return Problem.invalidRequest("Send either \"on\": false or a brightness, not both")
        end
        if not (device.capabilities and device.capabilities.brightness) then
            return Problem.new(409, "NOT_SUPPORTED", "This light is on/off only and has no brightness control")
        end
        action, params = "set_brightness", { value = brightness }
    elseif body.on then
        action = "on"
    else
        action = "off"
    end

    local ok, failure = ctx.services.adapters.execute(device.id, action, params)
    if not ok then
        return Problem.fromAdapter(failure)
    end
    return 202, Views.light(ctx.services.registry, device)
end

return Lights
