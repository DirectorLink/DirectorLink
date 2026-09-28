-- Invitations (docs/ACCOUNTS.md, src/auth/invitations.lua): an admin creates one for a role and an
-- email; the controller registers it with the account service itself, over its own connection, so
-- only an admin's request can bind an invitation to an email. The app turns it into a link. The
-- secret is in this answer only.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Roles = require("src.auth.roles")

local Invitations = {}

local ID = "^%x%x%x%x%x%x%x%x$"

function Invitations.create(ctx)
    local body = ctx.body or {}
    local problem = Validate.body(body, { role = true, expires_in = true, for_me = true, email = true })
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
    if body.for_me ~= nil and type(body.for_me) ~= "boolean" then
        return Problem.invalidField("for_me", "for_me must be true or false")
    end
    local email = nil
    if body.email ~= nil then
        email = type(body.email) == "string" and body.email:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
        if #email > 254 or not email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
            return Problem.invalidField("email", "email is the address of the person invited")
        end
    end
    -- For the admin's own other device: the new key joins the admin's profile.
    local profile = nil
    if body.for_me then
        local me = ctx.services.keys.find(ctx.apiKey.id)
        profile = me and me.profile or nil
    end
    local invitation, failure = invitations.create(body.role, seconds, ctx.apiKey.id, profile)
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
    if not email then
        -- Registered by the app (the home's owner only; see docs/ACCOUNTS.md).
        return 201, invitation
    end
    return Response.later(function(respond)
        remote.ask({ type = "invitation", invitation_id = invitation.id, email = email, expires_at = invitation.expires_at }, 10, function(answer, code)
            if answer and answer.ok == true then
                invitation.registered = true
                invitation.email = email
                respond(201, invitation)
                return
            end
            -- Not registered: the link would not work, so the invitation goes.
            invitations.revoke(invitation.id)
            local failure = code or (answer and answer.code) or "REGISTRATION_FAILED"
            ctx.services.log.warn("remote", "invitation not registered", { invitation = invitation.id, code = failure })
            if failure == "REMOTE_OFFLINE" or failure == "RELAY_TIMEOUT" then
                respond(Problem.new(503, "REMOTE_OFFLINE", "The controller is not connected to DirectorLink's servers right now; try again in a minute"))
            else
                respond(Problem.new(502, failure, "DirectorLink's servers did not take the invitation (" .. tostring(failure) .. ")"))
            end
        end)
    end)
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
