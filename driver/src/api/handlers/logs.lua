local Log = require("src.core.log")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")

local Logs = {}

function Logs.list(ctx)
    local query = ctx.query
    if query.level ~= nil and not Log.isLevel(query.level) then
        return Problem.invalidParameter("level", "level must be one of debug, info, warn, error")
    end
    local after, afterProblem = Validate.optionalInteger(query.after, "after", 0)
    if afterProblem then
        return afterProblem
    end
    local limit, limitProblem = Validate.optionalInteger(query.limit, "limit", 1, Log.MAX_ENTRIES)
    if limitProblem then
        return limitProblem
    end

    local category = query.category
    if category == "" then
        category = nil
    end

    local items, lastSeq = Log.query({
        level = query.level,
        category = category,
        after = after,
        limit = limit or 200,
    })
    return 200, {
        items = items,
        last_seq = lastSeq,
        level = Log.getLevel(),
    }
end

function Logs.get_settings(_ctx)
    return 200, { level = Log.getLevel() }
end

function Logs.update_settings(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { level = true }, true)
    if problem then
        return problem
    end
    if not Log.isLevel(body.level) then
        return Problem.invalidField("level", "level must be one of debug, info, warn, error")
    end

    Log.setLevel(body.level)
    ctx.services.onLogLevelChanged(body.level)
    Log.info("logs", "log level changed", { level = body.level, client = ctx.client.ip })
    return 200, { level = Log.getLevel() }
end

return Logs
