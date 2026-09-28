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

-- `profileId`: the profile the key joins; without one, it gets a new profile of its own.
local function createKey(ctx, name, role, profileId)
    local keys = ctx.services.keys
    local profiles = ctx.services.profiles
    if not profileId and profiles then
        local profile, profileFailure = profiles.create(name)
        if not profile then
            return nil, Problem.new(409, profileFailure, "This controller has as many profiles as it allows")
        end
        profileId = profile.id
    end
    local record, failure = keys.create(name, role, profileId)
    if not record and profiles then
        profiles.prune(keys.list())
    end
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

    local code = ctx.services.pairing.normalize(body.pairing_code)
    if not code then
        return Problem.invalidField("pairing_code", "pairing_code must be the 8-digit code shown in Composer, e.g. 1234 5678")
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
            retry_after = failure.retry_after,
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
    local problem = Validate.body(body, { name = true, role = true, profile_id = true })
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
    -- Another device of an existing person: it joins their profile.
    if body.profile_id ~= nil and not (type(body.profile_id) == "string" and ctx.services.profiles.find(body.profile_id)) then
        return Problem.invalidField("profile_id", "profile_id must be the id of an existing profile")
    end

    local record, createProblem = createKey(ctx, name, role, body.profile_id)
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
    if ctx.services.invitations then
        ctx.services.invitations.revokeCreatedBy(id)
    end
    ctx.services.log.info("auth", "API key revoked by its own client", { key_id = id })
    ctx.services.onKeysChanged()
    return 204, nil
end

function Auth.update_key(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { name = true, role = true, profile_id = true }, true)
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
    -- Moving a key to another person's profile (e.g. two devices of one person paired apart).
    if body.profile_id ~= nil then
        if not (type(body.profile_id) == "string" and ctx.services.profiles.find(body.profile_id)) then
            return Problem.invalidField("profile_id", "profile_id must be the id of an existing profile")
        end
        changes.profile = body.profile_id
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
    -- Only admins make invitations: a key that is no longer admin keeps none (its claim token
    -- stops working too, src/cloud/remote.lua).
    if record.role ~= "admin" and ctx.services.invitations then
        ctx.services.invitations.revokeCreatedBy(id)
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
    if ctx.services.invitations then
        ctx.services.invitations.revokeCreatedBy(id)
    end
    ctx.services.log.info("auth", "API key revoked", { key_id = id, by = ctx.apiKey.id })
    ctx.services.onKeysChanged()
    return 204, nil
end

return Auth
