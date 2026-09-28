-- Invitations (docs/ACCOUNTS.md, src/auth/invitations.lua): an admin creates one for a role; the
-- app turns it into a link. The secret is in this answer only.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Roles = require("src.auth.roles")

local Invitations = {}

local ID = "^%x%x%x%x%x%x%x%x$"

function Invitations.create(ctx)
    local body = ctx.body or {}
    local problem = Validate.body(body, { role = true, expires_in = true })
    if problem then
        return problem
    end
    if not Roles.valid(body.role) then
        return Problem.invalidField("role", "role must be one of " .. Roles.list())
    end
    local invitations = ctx.services.invitations
    local seconds = body.expires_in
    if seconds ~= nil and (type(seconds) ~= "number" or seconds ~= math.floor(seconds)
        or seconds < invitations.MIN_SECONDS or seconds > invitations.MAX_SECONDS) then
        return Problem.invalidField("expires_in", "expires_in must be whole seconds from " .. invitations.MIN_SECONDS .. " to " .. invitations.MAX_SECONDS)
    end
    local remote = ctx.services.remote
    if not remote.enabled() then
        return Problem.new(409, "REMOTE_ACCESS_OFF", "Invitations work through remote access: turn on Remote Access in Composer first")
    end
    if not remote.available() then
        return Problem.new(503, "LOCK_UNAVAILABLE", "This controller cannot seal remote requests (the lock self-test failed; see the log)")
    end
    local invitation, failure = invitations.create(body.role, seconds, ctx.apiKey.id)
    if not invitation then
        if failure == "INVITATION_LIMIT_REACHED" then
            return Problem.new(409, failure, "There are already " .. invitations.MAX_PENDING .. " pending invitations; revoke one first")
        end
        if failure == "LOCK_UNAVAILABLE" then
            return Problem.new(503, failure, "This controller cannot seal remote requests (see the log)")
        end
        return Problem.internal("The invitation could not be created (" .. tostring(failure) .. ")")
    end
    ctx.services.log.info("remote", "invitation created", { invitation = invitation.id, role = invitation.role, key_id = ctx.apiKey.id })
    invitation.home_id = remote.homeId()
    return 201, invitation
end

function Invitations.list(ctx)
    local items = Json.array()
    for _, item in ipairs(ctx.services.invitations.list()) do
        items[#items + 1] = item
    end
    return 200, { items = items }
end

function Invitations.delete(ctx)
    local id = tostring(ctx.params.invitationId or "")
    if not id:match(ID) then
        return Problem.invalidParameter("invitationId", "invitationId is 8 hex characters")
    end
    if not ctx.services.invitations.revoke(id) then
        return Problem.notFound("Invitation", id)
    end
    ctx.services.log.info("remote", "invitation revoked", { invitation = id, key_id = ctx.apiKey.id })
    return 204
end

return Invitations
