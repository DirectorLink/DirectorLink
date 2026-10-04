-- Remote access with accounts (docs/ACCOUNTS.md): whether it is on, and the claim token with which
-- the owner links this home to their account.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Access = require("src.auth.access")
local People = require("src.auth.people")

local Remote = {}

-- `update_required` (1.8.0, ADR-059): the account service no longer takes this version, so remote
-- access stays down until DirectorLink is updated; `minimum_version`, the one it named.
function Remote.status(ctx)
    local remote = ctx.services.remote
    local enabled = remote.enabled()
    local updateRequired, minimum = false, nil
    if enabled then
        updateRequired, minimum = remote.updateRequired()
    end
    return 200, {
        enabled = enabled,
        connected = enabled and remote.connected() or false,
        lock = remote.available(),
        home_id = enabled and remote.homeId() or Json.null,
        update_required = updateRequired == true,
        minimum_version = updateRequired and minimum or Json.null,
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
    -- Claiming moves the home to the claiming account and removes everyone else from it: once the
    -- home was claimed with DirectorLink 1.8.0, only the person who claimed it (the owner, while
    -- they are here) claims it again, so that no other admin can take it from them (ADR-054).
    local claimedBy = People.claimedBy()
    if claimedBy and ctx.services.profiles.find(claimedBy) and not Access.isOwner(ctx.apiKey) then
        return Problem.new(403, "OWNER_ONLY", "Only the home's owner claims this home again")
    end
    local claim = remote.createClaim(ctx.apiKey.id)
    ctx.services.log.info("remote", "claim token created", { key_id = ctx.apiKey.id })
    return 201, { home_id = remote.homeId(), claim_token = claim.claim_token, expires_at = claim.expires_at }
end

-- A new secret for the home's relay connection, for the home's owner to approve: the app gives its
-- SHA-256 to the account service, which then accepts only the new secret (docs/RELAY.md). Only on
-- the home network, like a claim, so that whoever holds a copy of this controller's data and
-- connects as the home cannot replace the secret; the same one is given until it is in use.
function Remote.secret(ctx)
    local remote = ctx.services.remote
    if ctx.apiKey.remote then
        return Problem.new(403, "SECRET_ONLY_ON_HOME_NETWORK", "The home's secret is replaced from its own network, not through remote access")
    end
    if not remote.enabled() then
        return Problem.new(409, "REMOTE_ACCESS_OFF", "Turn on Remote Access in Composer (DirectorLink properties) first")
    end
    local hash, failure = remote.prepareSecret()
    if not hash then
        return Problem.internal("A new home secret could not be made (" .. tostring(failure) .. ")")
    end
    ctx.services.log.info("remote", "new home secret given for approval", { key_id = ctx.apiKey.id })
    return 200, { home_id = remote.homeId(), secret_sha256 = hash }
end

return Remote
