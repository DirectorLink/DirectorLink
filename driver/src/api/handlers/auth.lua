local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local Roles = require("src.auth.roles")

local Auth = {}

local function keyLimitProblem(keys)
    return Problem.new(409, "KEY_LIMIT_REACHED",
        "The bridge already has " .. keys.MAX_KEYS .. " API keys; revoke one first")
end

local function roleProblem()
    return Problem.invalidField("role", "role must be one of " .. Roles.list())
end

local function createKey(ctx, name, role)
    local keys = ctx.services.keys
    local record, failure = keys.create(name, role)
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

    -- The Composer pairing code proves access to the project: the key gets full access.
    local record, createProblem = createKey(ctx, name, "admin")
    if not record then
        return createProblem
    end
    ctx.services.log.info("auth", "paired a new client", { key_id = record.id, name = record.name, role = record.role, client = ctx.client.ip })
    ctx.services.onKeysChanged()
    return 201, Views.newApiKey(record)
end

local function requestView(request, apiKey)
    return {
        id = request.id,
        name = request.name,
        role = request.role,
        status = request.status,
        expires_at = Clock.iso(request.expires_at),
        api_key = apiKey or Json.null,
    }
end

function Auth.create_request(ctx)
    local body = ctx.body
    if body == nil then
        body = {}
    end
    local problem = Validate.body(body, { name = true, role = true })
    if problem then
        return problem
    end
    local name, nameProblem = Validate.name(body.name, "name", "Approved client")
    if nameProblem then
        return nameProblem
    end

    local keys = ctx.services.keys
    if keys.count() >= keys.MAX_KEYS then
        return keyLimitProblem(keys)
    end

    -- The first key of a home is its owner's; later devices get member unless they ask otherwise.
    -- The homeowner sees the requested role in Composer before pressing the button.
    local role = body.role
    if role == nil then
        role = keys.adminCount() == 0 and "admin" or "member"
    elseif not Roles.valid(role) then
        return roleProblem()
    end

    local request, failure = ctx.services.approvals.create(name, ctx.client.ip, role)
    if not request then
        local status = 503
        if failure.code == "REQUEST_PENDING" then
            status = 409
        elseif failure.code == "RATE_LIMITED" then
            status = 429
        end
        local headers
        if failure.retry_after then
            headers = { { "Retry-After", tostring(failure.retry_after) } }
        end
        return Problem.new(status, failure.code, failure.message), headers
    end
    return 201, requestView(request), { { "Location", "/v1/auth/requests/" .. request.id } }
end

function Auth.get_request(ctx)
    local approvals = ctx.services.approvals
    local request = approvals.get(ctx.params.requestId)
    if not request then
        return Problem.new(404, "NOT_FOUND", "This access request does not exist, expired or was already used")
    end
    if request.status ~= "approved" then
        return 200, requestView(request)
    end

    local record, createProblem = createKey(ctx, request.name, request.role)
    if not record then
        return createProblem
    end
    local view = requestView(request, Views.newApiKey(record))
    approvals.complete(request.id)
    ctx.services.log.info("auth", "API key issued after approval in the Control4 app", {
        key_id = record.id,
        name = record.name,
        role = record.role,
        client = ctx.client.ip,
    })
    ctx.services.onKeysChanged()
    return 200, view
end

function Auth.delete_request(ctx)
    if not ctx.services.approvals.cancel(ctx.params.requestId) then
        return Problem.new(404, "NOT_FOUND", "This access request does not exist, expired or was already used")
    end
    return 204, nil
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
    local problem = Validate.body(body, { name = true, role = true })
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
    local role = body.role or "member"
    if not Roles.valid(role) then
        return roleProblem()
    end

    local record, createProblem = createKey(ctx, name, role)
    if not record then
        return createProblem
    end
    ctx.services.log.info("auth", "API key created", { key_id = record.id, name = record.name, role = record.role, by = ctx.apiKey.id })
    ctx.services.onKeysChanged()
    return 201, Views.newApiKey(record, ctx.apiKey.id)
end

function Auth.current_key(ctx)
    local record = ctx.services.keys.find(ctx.apiKey.id)
    if not record then
        return Problem.unauthorized()
    end
    return 200, Views.apiKey(record, ctx.apiKey.id)
end

-- Any key may revoke itself ("forget this device"), whatever its role.
function Auth.revoke_current_key(ctx)
    local id = ctx.apiKey.id
    ctx.services.keys.revoke(id)
    ctx.services.log.info("auth", "API key revoked by its own client", { key_id = id })
    ctx.services.onKeysChanged()
    return 204, nil
end

function Auth.update_key(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { name = true, role = true }, true)
    if problem then
        return problem
    end
    local changes = {}
    if body.name ~= nil then
        local name, nameProblem = Validate.name(body.name, "name")
        if nameProblem then
            return nameProblem
        end
        changes.name = name
    end
    if body.role ~= nil then
        if not Roles.valid(body.role) then
            return roleProblem()
        end
        changes.role = body.role
    end

    local id = ctx.params.keyId
    local record, failure = ctx.services.keys.update(id, changes)
    if not record then
        if failure == "NOT_FOUND" then
            return Problem.notFound("API key", id)
        elseif failure == "LAST_ADMIN" then
            return Problem.new(409, "LAST_ADMIN", "This is the only admin key; make another key admin first")
        end
        return Problem.internal("The API key could not be changed (" .. tostring(failure) .. ")")
    end
    ctx.services.log.info("auth", "API key changed", { key_id = id, name = record.name, role = record.role, by = ctx.apiKey.id })
    ctx.services.onKeysChanged()
    return 200, Views.apiKey(record, ctx.apiKey.id)
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
