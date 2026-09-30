local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local Roles = require("src.auth.roles")
local Base64 = require("src.core.base64")
local Lock = require("src.cloud.lock")
local Random = require("src.core.random")
local X25519 = require("src.core.x25519")
local CpacePairing = require("src.auth.cpace_pairing")
local Keys = require("src.auth.keys")

local Auth = {}

local function keyLimitProblem(keys)
    return Problem.new(409, "KEY_LIMIT_REACHED",
        "The bridge already has " .. keys.MAX_KEYS .. " API keys; revoke one first")
end

local function roleProblem()
    return Problem.invalidField("role", "role must be one of " .. Roles.list())
end

-- `profileId`: the profile the key joins; without one, it gets a new profile of its own.
-- `expiresAt` (os.time): when the key stops working (ADR-040); nil for never.
local function createKey(ctx, name, role, profileId, expiresAt)
    local keys = ctx.services.keys
    local profiles = ctx.services.profiles
    if not profileId and profiles then
        local profile, profileFailure = profiles.create(name)
        if not profile then
            return nil, Problem.new(409, profileFailure, "This controller has as many profiles as it allows")
        end
        profileId = profile.id
    end
    local record, failure = keys.create(name, role, profileId, expiresAt)
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

-- A key asked for with expires_in (ADR-040; the console asks for a day) lasts from 60 seconds to
-- 30 days.
Auth.EXPIRES_IN_MIN = 60
Auth.EXPIRES_IN_MAX = Keys.LONGEST_LIFE

local function expiresIn(value)
    if value == nil then
        return nil
    end
    if type(value) ~= "number" or value % 1 ~= 0 or value < Auth.EXPIRES_IN_MIN or value > Auth.EXPIRES_IN_MAX then
        return nil, Problem.invalidField("expires_in", "expires_in must be a whole number of seconds from "
            .. Auth.EXPIRES_IN_MIN .. " to " .. Auth.EXPIRES_IN_MAX .. " (30 days)")
    end
    return value
end

local function pairingFailure(ctx, failure)
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

local function decoded(value, length)
    local raw = type(value) == "string" and Base64.decode(value) or nil
    if raw and #raw == length then
        return raw
    end
    return nil
end

local function onlyFields(value, field, allowed)
    if type(value) ~= "table" or value == Json.null or Json.isArray(value) then
        return Problem.invalidField(field, field .. " must be an object")
    end
    for key in pairs(value) do
        if not allowed[key] then
            return Problem.invalidField(field .. "." .. tostring(key), "Unknown field: " .. field .. "." .. tostring(key))
        end
    end
    return nil
end

-- CPace (ADR-039, src/auth/cpace_pairing.lua), first request: the app's nonce, the controller's
-- share. The code is not sent; the attempt counts as a wrong one until it succeeds.
local function cpaceStart(ctx, body)
    local problem = Validate.body(body, { name = true, expires_in = true, cpace = true })
        or onlyFields(body.cpace, "cpace", { nonce = true })
    if problem then
        return problem
    end
    local nonce = decoded(body.cpace.nonce, CpacePairing.NONCE_BYTES)
    if not nonce then
        return Problem.invalidField("cpace.nonce", "cpace.nonce is " .. CpacePairing.NONCE_BYTES .. " random bytes, base64")
    end
    -- The answer comes sealed: a controller whose lock failed its self-test cannot pair this way.
    -- Its own code, so the app can tell it from DirectorLink before 1.3.0 (which refuses the field
    -- cpace): updating would not help here.
    if not ctx.services.remote.available() then
        return Problem.new(503, "LOCK_UNAVAILABLE", "This controller cannot seal the answer (the lock self-test failed; see the log); pair with pairing_code")
    end
    local _, nameProblem = Validate.name(body.name, "name", "Paired client")
    if nameProblem then
        return nameProblem
    end
    local expires, expiresProblem = expiresIn(body.expires_in)
    if expiresProblem then
        return expiresProblem
    end
    local keys = ctx.services.keys
    if keys.count() >= keys.MAX_KEYS then
        return keyLimitProblem(keys)
    end
    local ip = ctx.client and ctx.client.ip
    local attempt, failure = ctx.services.pairing.begin(ip)
    if not attempt then
        return pairingFailure(ctx, failure)
    end
    local ok, answer = pcall(CpacePairing.open, attempt, ip, nonce, body.name, expires)
    if not ok then
        ctx.services.log.error("auth", "could not start a pairing exchange", { error = tostring(answer) })
        return Problem.internal("The pairing exchange could not start; pair again")
    end
    return 200, { cpace = answer }
end

-- CPace, second request: the app's share and its tag, which proves it knew the code; then the
-- key, sealed for this exchange, and the controller's tag.
local function cpaceFinish(ctx, body)
    local problem = Validate.body(body, { cpace = true })
        or onlyFields(body.cpace, "cpace", { session = true, share = true, confirm = true })
    if problem then
        return problem
    end
    local ip = ctx.client and ctx.client.ip
    local session = CpacePairing.take(body.cpace.session, ip)
    if not session then
        return Problem.new(409, "PAIRING_SESSION_EXPIRED", "This pairing exchange is not open (it lasts "
            .. CpacePairing.SESSION_SECONDS .. " seconds and works once); start again")
    end
    local share, tag = decoded(body.cpace.share, 32), decoded(body.cpace.confirm, 64)
    if not share then
        return Problem.invalidField("cpace.share", "cpace.share is a 32-byte X25519 point, base64")
    elseif not tag then
        return Problem.invalidField("cpace.confirm", "cpace.confirm is a 64-byte HMAC-SHA512 tag, base64")
    end
    local keys = ctx.services.keys
    if keys.count() >= keys.MAX_KEYS then
        return keyLimitProblem(keys)
    end
    local ok, isk, answerTag = pcall(CpacePairing.confirm, session, share, tag)
    if not ok then
        ctx.services.log.error("auth", "could not finish a pairing exchange", { error = tostring(isk) })
        return Problem.internal("The pairing exchange failed; pair again")
    end
    if not isk and answerTag == "INVALID_SHARE" then
        return Problem.invalidField("cpace.share", "cpace.share is a point of low order; pair again")
    end
    local paired, failure = ctx.services.pairing.conclude(session.attempt, isk ~= nil)
    if not paired then
        return pairingFailure(ctx, failure)
    end

    -- It proved it knew the code from Composer: the key gets full access.
    local name = Validate.name(session.name, "name", "Paired client")
    local record, createProblem = createKey(ctx, name, "admin", nil, session.expiresIn and os.time() + session.expiresIn)
    if not record then
        return createProblem
    end
    ctx.services.log.info("auth", "paired a new client", { key_id = record.id, name = record.name, role = record.role, client = ip, cpace = true })
    ctx.services.onKeysChanged()
    local sealedOk, sealed = pcall(Lock.seal, Lock.cpaceKey(Base64.toHex(isk)), "pair", "pair", "res", Json.encode(Views.newApiKey(record)))
    if not sealedOk then
        ctx.services.keys.revoke(record.id)
        ctx.services.onKeysChanged()
        ctx.services.log.error("auth", "could not seal the pairing answer", { error = tostring(sealed) })
        return Problem.internal("The pairing answer could not be sealed; pair again")
    end
    return 201, { cpace = { confirm = Base64.encode(answerTag) }, sealed = sealed }
end

function Auth.pair(ctx)
    -- A code is for the home network: a sealed remote request (any member, from anywhere) never
    -- gets to guess it.
    if ctx.request and ctx.request.principal then
        return Problem.new(403, "PAIRING_ONLY_ON_HOME_NETWORK", "Pair on the home network, with the code from Composer")
    end
    local body = ctx.body
    if type(body) == "table" and body ~= Json.null and body.cpace ~= nil then
        if type(body.cpace) == "table" and body.cpace.session ~= nil then
            return cpaceFinish(ctx, body)
        end
        return cpaceStart(ctx, body)
    end
    -- With the code itself (scripts; the app only after warning that it travels unprotected).
    local problem = Validate.body(body, { pairing_code = true, name = true, exchange = true, expires_in = true })
    if problem then
        return problem
    end
    -- The app's half of a key exchange: the answer is then sealed, and the new key never crosses
    -- the network in the clear (docs/ACCOUNTS.md). Without it (a script), the key comes back as is.
    local appPublic
    if body.exchange ~= nil then
        local exchange = body.exchange
        local raw = type(exchange) == "table" and type(exchange.public_key) == "string" and Base64.decode(exchange.public_key) or nil
        if not raw or #raw ~= 32 or X25519.smallOrder(raw) then
            return Problem.invalidField("exchange.public_key", "exchange.public_key is a 32-byte X25519 public key, base64")
        end
        -- A controller whose lock failed its self-test cannot seal: the app pairs without the
        -- exchange (it does so when the field "exchange" is refused), and the code is kept.
        if not ctx.services.remote.available() then
            return Problem.invalidField("exchange", "This controller cannot seal the answer (the lock self-test failed); pair without exchange")
        end
        appPublic = { raw = raw, text = exchange.public_key }
    end

    local code = ctx.services.pairing.normalize(body.pairing_code)
    if not code then
        return Problem.invalidField("pairing_code", "pairing_code must be the 8-digit code shown in Composer, e.g. 1234 5678")
    end
    local name, nameProblem = Validate.name(body.name, "name", "Paired client")
    if nameProblem then
        return nameProblem
    end
    local expires, expiresProblem = expiresIn(body.expires_in)
    if expiresProblem then
        return expiresProblem
    end

    local keys = ctx.services.keys
    if keys.count() >= keys.MAX_KEYS then
        return keyLimitProblem(keys)
    end

    local paired, failure = ctx.services.pairing.verify(code, ctx.client and ctx.client.ip)
    if not paired then
        return pairingFailure(ctx, failure)
    end

    -- The Composer pairing code proves access to the project: the key gets full access.
    local record, createProblem = createKey(ctx, name, "admin", nil, expires and os.time() + expires)
    if not record then
        return createProblem
    end
    ctx.services.log.info("auth", "paired a new client", { key_id = record.id, name = record.name, role = record.role, client = ctx.client.ip, sealed = appPublic ~= nil })
    ctx.services.onKeysChanged()
    if not appPublic then
        return 201, Views.newApiKey(record)
    end
    local ok, sealed = pcall(function()
        local private = Random.bytes(32)
        local driverPublic = Base64.encode(X25519.publicKey(private))
        local shared = X25519.shared(private, appPublic.raw)
        if not shared then
            error("the app's public key is not usable", 0)
        end
        local lockKey = Lock.pairingKey(Base64.toHex(shared), code, appPublic.text, driverPublic)
        return { exchange = { public_key = driverPublic }, sealed = Lock.seal(lockKey, "pair", "pair", "res", Json.encode(Views.newApiKey(record))) }
    end)
    if not ok then
        -- Nobody can use a key they never got: take it back.
        ctx.services.keys.revoke(record.id)
        ctx.services.onKeysChanged()
        ctx.services.log.error("auth", "could not seal the pairing answer", { error = tostring(sealed) })
        return Problem.invalidField("exchange.public_key", "The key exchange failed; pair again")
    end
    return 201, sealed
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
