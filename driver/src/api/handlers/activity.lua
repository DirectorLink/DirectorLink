-- The controller's activity history (ADR-046, docs/HISTORY.md, src/core/activity.lua), for admins:
-- GET /v1/activity?kind=scene,schedule&before=<id>&limit=50, newest first. Like the log, it may be
-- read in the clear (the API console); the app's requests are sealed, at home and through the account.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Activity = require("src.core.activity")

local Handlers = {}

Handlers.DEFAULT_LIMIT = 50
Handlers.MAX_LIMIT = 200

function Handlers.list(ctx)
    local query = ctx.query
    local before, problem = Validate.optionalInteger(query.before, "before", 1)
    if problem then
        return problem
    end
    local limit
    limit, problem = Validate.optionalInteger(query.limit, "limit", 1, Handlers.MAX_LIMIT)
    if problem then
        return problem
    end
    local kinds = nil
    if query.kind ~= nil and query.kind ~= "" then
        kinds = {}
        for kind in tostring(query.kind):gmatch("[^,]+") do
            if not Activity.KINDS[kind] then
                return Problem.invalidParameter("kind", "kind is one or more of scene, schedule, door, composer, access, system, separated by commas")
            end
            kinds[kind] = true
        end
    end
    local items, nextBefore = Activity.list({ kinds = kinds, before = before, limit = limit or Handlers.DEFAULT_LIMIT })
    return 200, { items = items, next_before = nextBefore or Json.null }
end

return Handlers
