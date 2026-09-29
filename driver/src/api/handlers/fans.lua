local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

-- Fans (the Fan proxy, src/adapters/fan.lua): on, off and a speed from 1 (low) to 4 (high).
local Fans = {}

local function findFan(ctx)
    local id, problem = Validate.id(ctx.params.fanId, "fanId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "fan" or device.supported ~= true then
        return nil, Problem.notFound("Fan", id)
    end
    return device
end

function Fans.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.fanList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.fan(registry, device)
        end
    end
    return 200, { items = items }
end

function Fans.get(ctx)
    local device, problem = findFan(ctx)
    if not device then
        return problem
    end
    return 200, Views.fan(ctx.services.registry, device)
end

-- PATCH {"on": true} turns the fan on at the speed it chooses (its preset, or its last one),
-- {"on": false} turns it off, and {"speed": 1-4} sets the speed, turning it on if it is off.
function Fans.update(ctx)
    local device, problem = findFan(ctx)
    if not device then
        return problem
    end

    local body = ctx.body
    problem = Validate.body(body, { on = true, speed = true }, true)
    if problem then
        return problem
    end
    if body.on ~= nil and type(body.on) ~= "boolean" then
        return Problem.invalidField("on", "on must be true or false")
    end

    local action, params
    if body.speed ~= nil then
        local speed = body.speed
        local top = tonumber((device.capabilities or {}).speeds) or 0
        if type(speed) ~= "number" or speed ~= math.floor(speed) or speed < 1 or speed > top then
            return Problem.invalidField("speed", "speed must be a whole number from 1 (low) to " .. top .. " (high); turn the fan off with \"on\": false")
        end
        if body.on == false then
            return Problem.invalidRequest("Send either \"on\": false or a speed, not both")
        end
        action, params = "set_speed", { speed = speed }
    elseif body.on then
        action = "on"
    else
        action = "off"
    end

    local ok, failure = ctx.services.adapters.execute(device.id, action, params)
    if not ok then
        return Problem.fromAdapter(failure)
    end
    return 202, Views.fan(ctx.services.registry, device)
end

return Fans
