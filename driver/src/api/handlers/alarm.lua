-- The home's alarm, read-only (ADR-038): GET /v1/alarm lists its partitions for admins and the
-- members given the alarm's status (ADR-054; others get 403). Off by default: until an installer sets the Composer property
-- Alarm Status to On, the answer says only that, and DirectorLink does not watch the partitions.
-- While it is on, the partitions go only into sealed answers, the app's way at home and through the
-- account: whether a home is armed never crosses a network in the clear. Nor does the size of the
-- sealed answer tell it: the answer is padded with spaces to the size it would have with every
-- partition at its longest. Nothing here, or anywhere in DirectorLink, arms or disarms.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Views = require("src.api.views")
local Access = require("src.auth.access")

local Alarm = {}

-- How long `body` is inside a sealed answer, which carries it as a JSON string (src/cloud/remote.lua):
-- a quote or a backslash takes two bytes there.
local function sealedLength(body)
    return #Json.encode(body) - 2
end

function Alarm.status(ctx)
    local services = ctx.services
    if not services.alarmStatusEnabled() then
        return 200, { enabled = false, partitions = Json.array() }
    end
    -- Only for those who see the alarm's status (ADR-054: admins, members given it).
    if not Access.canSeeAlarm(ctx.apiKey) then
        return Problem.new(403, "FORBIDDEN", "The alarm's status is not among this person's permissions")
    end
    -- Sealed requests carry their key as principal (src/cloud/remote.lua); a request with an
    -- Authorization header came as plain HTTP.
    if not (ctx.request and ctx.request.principal) then
        return Problem.new(403, "SEALED_REQUEST_REQUIRED",
            "The alarm status is sent only in sealed requests, as the DirectorLink app sends them; this request came in the clear")
    end
    local registry = services.registry
    local partitions, longest = Json.array(), Json.array()
    for _, device in ipairs(registry.alarmList()) do
        local view = Views.alarmPartition(registry, device)
        -- The alarm is the home's; a partition's room only when the caller sees that room (ADR-054).
        if not Access.seesRoom(ctx.apiKey, device.room_id) then
            view.room = Json.null
        end
        partitions[#partitions + 1] = view
        longest[#longest + 1] = Views.alarmPartitionLongest(view)
    end
    -- The same size, sealed, in every state: it depends only on the partitions there are (their
    -- names and rooms), never on whether they are armed. JSON allows the spaces after the value.
    local body = Json.encode({ enabled = true, partitions = partitions })
    local size = sealedLength(Json.encode({ enabled = true, partitions = longest }))
    return 200, body .. string.rep(" ", size - sealedLength(body))
end

return Alarm
