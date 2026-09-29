-- The home's alarm, read-only (ADR-038): GET /v1/alarm lists its partitions for members and admins
-- (the route's role; viewers get 403). Off by default: until an installer sets the Composer property
-- Alarm Status to On, the answer says only that, and DirectorLink does not watch the partitions.
-- While it is on, the partitions go only into sealed answers, the app's way at home and through the
-- account: whether a home is armed never crosses a network in the clear. Nothing here, or anywhere
-- in DirectorLink, arms or disarms.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Views = require("src.api.views")

local Alarm = {}

function Alarm.status(ctx)
    local services = ctx.services
    if not services.alarmStatusEnabled() then
        return 200, { enabled = false, partitions = Json.array() }
    end
    -- Sealed requests carry their key as principal (src/cloud/remote.lua); a request with an
    -- Authorization header came as plain HTTP.
    if not (ctx.request and ctx.request.principal) then
        return Problem.new(403, "SEALED_REQUEST_REQUIRED",
            "The alarm status is sent only in sealed requests, as the DirectorLink app sends them; this request came in the clear")
    end
    local registry = services.registry
    local partitions = Json.array()
    for _, device in ipairs(registry.alarmList()) do
        partitions[#partitions + 1] = Views.alarmPartition(registry, device)
    end
    return 200, { enabled = true, partitions = partitions }
end

return Alarm
