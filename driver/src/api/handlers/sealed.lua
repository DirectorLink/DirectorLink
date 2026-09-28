-- Sealed requests on the home network (docs/ACCOUNTS.md): the app locks every request with its
-- device's lock key, exactly as it does through the account, and sends it here instead of an
-- Authorization header, so its API key never crosses the network after pairing. The answer comes
-- back sealed too. API scripts can still use their key directly (Authorization: Bearer).

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Remote = require("src.cloud.remote")

local Sealed = {}

local STATUS = {
    UNKNOWN_KEY = 401,
    BAD_MAC = 401,
    BAD_ENVELOPE = 400,
    BAD_REQUEST = 400,
    BAD_CIPHERTEXT = 400,
    TOO_LARGE = 413,
    STALE = 400,
    REPLAYED = 400,
    LOCK_UNAVAILABLE = 503,
}

local function lockProblem()
    return Problem.new(503, "LOCK_UNAVAILABLE", "This controller cannot seal requests (the lock self-test failed; see the log)", { time = Clock.now() })
end

-- GET /v1/sealed: what an app needs to seal for this controller: its clock (a request must be
-- sealed within two minutes of it). Envelopes on the home network name the home "lan"
-- (Remote.LAN_HOME); the remote-access home id is not given out without a key.
function Sealed.info(ctx)
    if not ctx.services.remote.available() then
        return lockProblem()
    end
    return 200, { home = Remote.LAN_HOME, time = Clock.now(), window_seconds = Remote.windowSeconds() }
end

-- POST /v1/sealed {"envelope": {...}} -> 200 {"envelope": {...}} (the API's answer, sealed), or a
-- problem when the envelope is refused.
function Sealed.request(ctx)
    -- Only straight from the home network: a sealed request (one through the relay, say) cannot
    -- carry another, which would run as if it came from here.
    if ctx.request and ctx.request.principal then
        return Problem.new(400, "BAD_REQUEST", "A sealed request cannot carry another sealed request")
    end
    local problem = Validate.body(ctx.body, { envelope = true }, true)
    if problem then
        return problem
    end
    if not ctx.services.remote.available() then
        return lockProblem()
    end
    return Response.later(function(respond)
        Remote.handleLocal(ctx.body.envelope, ctx.client, function(envelope, code)
            if envelope then
                respond(200, { envelope = envelope })
                return
            end
            local status = STATUS[code] or 400
            respond(Problem.new(status, code, "The sealed request was refused (" .. tostring(code) .. ")", { time = Clock.now() }))
        end)
    end)
end

return Sealed
