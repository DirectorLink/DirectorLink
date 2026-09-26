local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")

local Auth = {}

local function keyLimitProblem(keys)
    return Problem.new(409, "KEY_LIMIT_REACHED",
        "The bridge already has " .. keys.MAX_KEYS .. " API keys; revoke one first")
end

local function createKey(ctx, name)
    local keys = ctx.services.keys
    local record, failure = keys.create(name)
    if not record then
        if failure == "KEY_LIMIT_REACHED" then
            return nil, keyLimitProblem(keys)
        end
        return nil, Problem.internal("The API key could not be created (" .. tostring(failure) .. ")")
    end
    return record
end

function Auth.pair(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { pairing_code = true, name = true })
    if problem then
        return problem
    end

    local code = body.pairing_code
    if type(code) ~= "string" or not code:match("^%d%d%d%d%d%d%d%d$") then
        return Problem.invalidField("pairing_code", "pairing_code must be the 8-digit code shown in Composer")
    end
    local name, nameProblem = Validate.name(body.name, "name", "Paired client")
    if nameProblem then
        return nameProblem
    end

    local keys = ctx.services.keys
    if keys.count() >= keys.MAX_KEYS then
        return keyLimitProblem(keys)
    end

    local paired, failure = ctx.services.pairing.verify(code)
    if not paired then
        local status = 403
        local headers
        if failure.code == "PAIRING_RATE_LIMITED" then
            status = 429
            headers = { { "Retry-After", tostring(failure.retry_after or 60) } }
        elseif failure.code == "PAIRING_UNAVAILABLE" then
            status = 503
        end
        ctx.services.log.info("auth", "pairing rejected", { reason = failure.code, client = ctx.client.ip })
        return Problem.new(status, failure.code, failure.message, {
            attempts_remaining = failure.attempts_remaining,
        }), headers
    end

    local record, createProblem = createKey(ctx, name)
    if not record then
        return createProblem
    end
    ctx.services.log.info("auth", "paired a new client", { key_id = record.id, name = record.name, client = ctx.client.ip })
    ctx.services.onKeysChanged()
    return 201, Views.newApiKey(record)
end

function Auth.list_keys(ctx)
    local currentId = ctx.apiKey and ctx.apiKey.id
    local items = Json.array()
    for _, record in ipairs(ctx.services.keys.list()) do
        items[#items + 1] = Views.apiKey(record, currentId)
    end
    return 200, { items = items }
end

function Auth.create_key(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { name = true })
    if problem then
        return problem
    end
    if body.name == nil then
        return Problem.invalidField("name", "name is required")
    end
    local name, nameProblem = Validate.name(body.name, "name")
    if nameProblem then
        return nameProblem
    end

    local record, createProblem = createKey(ctx, name)
    if not record then
        return createProblem
    end
    ctx.services.log.info("auth", "API key created", { key_id = record.id, name = record.name, by = ctx.apiKey.id })
    ctx.services.onKeysChanged()
    return 201, Views.newApiKey(record, ctx.apiKey.id)
end

function Auth.delete_key(ctx)
    local id = ctx.params.keyId
    if not ctx.services.keys.revoke(id) then
        return Problem.notFound("API key", id)
    end
    ctx.services.log.info("auth", "API key revoked", { key_id = id, by = ctx.apiKey.id })
    ctx.services.onKeysChanged()
    return 204, nil
end

return Auth
