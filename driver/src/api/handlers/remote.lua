-- Remote access with accounts (docs/ACCOUNTS.md): whether it is on, and the claim token with which
-- the owner links this home to their account.

local Json = require("src.core.json")
local Problem = require("src.api.problem")

local Remote = {}

function Remote.status(ctx)
    local remote = ctx.services.remote
    local enabled = remote.enabled()
    return 200, {
        enabled = enabled,
        connected = enabled and remote.connected() or false,
        lock = remote.available(),
        home_id = enabled and remote.homeId() or Json.null,
    }
end

-- Only on the home network: holding an admin key here is what proves the home is yours.
function Remote.claim(ctx)
    local remote = ctx.services.remote
    if ctx.apiKey.remote then
        return Problem.new(403, "CLAIM_ONLY_ON_HOME_NETWORK", "A home is claimed from its own network, not through remote access")
    end
    if not remote.enabled() then
        return Problem.new(409, "REMOTE_ACCESS_OFF", "Turn on Remote Access in Composer (DirectorLink properties) first")
    end
    if not remote.available() then
        return Problem.new(503, "LOCK_UNAVAILABLE", "This controller cannot seal remote requests (the lock self-test failed; see the log)")
    end
    local claim = remote.createClaim(ctx.apiKey.id)
    ctx.services.log.info("remote", "claim token created", { key_id = ctx.apiKey.id })
    return 201, { home_id = remote.homeId(), claim_token = claim.claim_token, expires_at = claim.expires_at }
end

return Remote
