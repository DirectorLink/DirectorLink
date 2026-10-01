-- DirectorLink's settings in the app (ADR-043, src/core/settings.lua), for admins:
--   GET   /v1/settings            every setting with its value and whether the app may change it,
--                                 the status properties and the actions, as Composer shows them
--   PATCH /v1/settings            Schedules, Jewish Calendar and Log Level, set as Composer sets them;
--                                 the others are refused for every key (403 SET_IN_COMPOSER)
--   GET   /v1/settings/printout   what the Composer action Print Schedules and Scenes prints
--   POST  /v1/project/refresh     the Composer action Refresh Project

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Problem = require("src.api.problem")
local System = require("src.api.handlers.system")

local Handlers = {}

function Handlers.get(ctx)
    return 200, ctx.services.settings.document()
end

-- The body names settings by key: {"schedules": "paused", "jewish_calendar": "on"}. All of it is
-- checked before anything changes.
function Handlers.update(ctx)
    local settings = ctx.services.settings
    local body = ctx.body
    if type(body) ~= "table" or body == Json.null or Json.isArray(body) then
        return Problem.invalidRequest("The request body must be a JSON object")
    end
    local failure = settings.check(body)
    if failure then
        if failure.code == "SET_IN_COMPOSER" then
            return Problem.new(403, "SET_IN_COMPOSER", failure.detail, { errors = Json.array({ { field = failure.field, message = failure.detail } }) })
        elseif failure.code == "EMPTY" then
            return Problem.invalidRequest(failure.detail)
        end
        return Problem.invalidField(failure.field, failure.detail)
    end
    settings.change(body, ctx.apiKey)
    return 200, settings.document()
end

function Handlers.printout(ctx)
    local ok, lines = pcall(ctx.services.automationPrintout)
    if not ok or type(lines) ~= "table" then
        ctx.services.log.error("settings", "schedules and scenes could not be listed", { error = tostring(lines) })
        return Problem.new(503, "UNAVAILABLE", "DirectorLink could not list its schedules and scenes; see GET /v1/logs")
    end
    return 200, { printed_at = Clock.iso(), lines = Json.array(lines) }
end

-- Reads the Composer project again, as the action Refresh Project does. When Director cannot list
-- it, the project read before stays in use.
function Handlers.refresh_project(ctx)
    local refreshed, changes = ctx.services.refreshProject(ctx.apiKey)
    if not refreshed then
        return Problem.new(503, "PROJECT_REFRESH_FAILED", "Director could not list the project; the project read before stays in use. Try again in a minute")
    end
    changes = changes or {}
    return 200, {
        refreshed_at = Clock.iso(),
        inventory = System.inventory(ctx.services.registry.counts()),
        changes = {
            added = changes.added or 0,
            removed = changes.removed or 0,
            moved = changes.moved or 0,
            renamed = changes.renamed or 0,
            rooms_added = changes.rooms_added or 0,
            rooms_removed = changes.rooms_removed or 0,
            rooms_renamed = changes.rooms_renamed or 0,
        },
    }
end

return Handlers
