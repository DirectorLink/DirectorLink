-- Invitations (docs/ACCOUNTS.md, src/auth/invitations.lua): an admin creates one for a person (an
-- admin, or a member with the permissions the admin chose: ADR-054) and an email; the controller registers it with the account service itself, over its own connection, so
-- only an admin's request can bind an invitation to an email. The app turns it into a link. The
-- secret is in this answer only.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Roles = require("src.auth.roles")
local Access = require("src.auth.access")
local People = require("src.auth.people")
local Scenes = require("src.core.scenes")
local ProfileHandlers = require("src.api.handlers.profiles")
local UserHandlers = require("src.api.handlers.users")

local Invitations = {}

local ID = "^%x%x%x%x%x%x%x%x$"

-- Since 1.9.0 (ADR-061) every user may invite their own other device (`for_me`: Add my other
-- device, and a device of their account that asks to join, approved): it joins their user, within
-- five devices. Only admins invite anyone else: a new user, or (`profile_id`) another device of an
-- existing user, such as their Google or Apple account for a user paired at home.
function Invitations.create(ctx)
    local body = ctx.body or {}
    local problem = Validate.body(body, { role = true, expires_in = true, for_me = true, email = true, access = true, profile_id = true })
    if problem then
        return problem
    end
    if body.for_me ~= true and not Access.isAdmin(ctx.apiKey) then
        return Problem.new(403, "FORBIDDEN", "Only admins invite other users; invite your own other device with for_me")
    end
    -- admin or member; the roles of 1.7.0 (viewer, member without access, doors) become what they
    -- did then (ADR-054), so that a 1.7.0 app invites as before. Not needed for one's own device.
    if body.role == nil and body.for_me == true then
        body.role = "member"
    end
    if not Roles.valid(body.role) then
        return Problem.invalidField("role", "role must be admin or member")
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
    -- For the admin's own other device: the new key joins the admin's profile, with its permissions.
    -- For anyone else: a new person, as the admin chose (`access`), or as the 1.7.0 role became.
    local profile, person, role = nil, nil, body.role
    if body.profile_id ~= nil and body.for_me then
        return Problem.invalidField("profile_id", "for_me is your own user: leave out profile_id")
    end
    if body.for_me then
        if body.access ~= nil then
            return Problem.invalidField("access", "Your own other device has your permissions: leave out access")
        end
        local me = ctx.services.keys.find(ctx.apiKey.id)
        profile = me and me.profile or nil
        role = me and me.role or role
        if not (profile and Access.mayAddOwnDevice(ctx.apiKey)) then
            return Problem.new(409, "NO_USER", "This key belongs to no user")
        end
        -- A device put into a person (ADR-054: Access.mayChangePerson), here the caller's own.
        local allowed, refusal = Access.mayChangePerson(ctx.apiKey, profile)
        if not allowed then
            return ProfileHandlers.refused(refusal)
        end
    elseif body.profile_id ~= nil then
        -- Another device of an existing user (1.9.0): it joins them, with their permissions.
        if body.access ~= nil then
            return Problem.invalidField("access", "A device of an existing user has that user's permissions: leave out access")
        end
        local existing = type(body.profile_id) == "string" and ctx.services.profiles.find(body.profile_id) or nil
        if not existing then
            return Problem.invalidField("profile_id", "profile_id must be the id of an existing user")
        end
        local allowed, refusal = Access.mayChangePerson(ctx.apiKey, existing.id)
        if not allowed then
            return ProfileHandlers.refused(refusal, "This is the home's owner: only the owner adds a device of theirs")
        end
        profile = existing.id
        role = People.legacyRole(People.peek(profile)) or role
    elseif body.access ~= nil then
        if role ~= "admin" and role ~= "member" then
            return Problem.invalidField("role", "With access, role is admin or member")
        end
        person, problem = ProfileHandlers.readAccess(ctx.services, body.access, People.defaults(role), "access")
        if not person then
            return problem
        end
        person.role = role
    else
        person = People.fromLegacy(role, Scenes.list())
    end
    if person then
        role = People.legacyRole(person)
        person = People.view(person)
    end
    -- Up to five devices a user (1.9.0, ADR-061): checked again when the invitation is used.
    problem = UserHandlers.refuseWhenFull(ctx, profile)
    if problem then
        return problem
    end
    local invitation, failure = invitations.create(role, seconds, ctx.apiKey.id, profile, person, body.profile_id ~= nil)
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
    -- With the ids of every invitation still waiting here: the account service forgets the ones
    -- this controller revoked meanwhile (which would count against its limit).
    local pending = Json.array()
    for _, item in ipairs(invitations.list()) do
        pending[#pending + 1] = item.id
    end
    return Response.later(function(respond)
        remote.ask({ type = "invitation", invitation_id = invitation.id, email = email, expires_at = invitation.expires_at, pending = pending }, 10, function(answer, code)
            if answer and answer.ok == true then
                invitation.registered = true
                invitation.email = email
                respond(201, invitation)
                return
            end
            -- Not registered: the link would not work, so the invitation goes.
            invitations.revoke(invitation.id)
            local failure = code or (answer and answer.code) or "REGISTRATION_FAILED"
            if code == "RELAY_TIMEOUT" and remote.tell then
                -- The account service may still have taken it: it is to forget it.
                remote.tell({ type = "invitation_cancel", invitation_id = invitation.id })
            end
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

-- An admin revokes any invitation; anyone else (1.9.0, ADR-061) those their own user's devices made
-- (an Add my other device that is no longer needed, or one the account service did not take): any
-- other is, for them, one that does not exist.
function Invitations.delete(ctx)
    local id = tostring(ctx.params.invitationId or "")
    if not id:match(ID) then
        return Problem.invalidParameter("invitationId", "invitationId is 8 hex characters")
    end
    if not Access.isAdmin(ctx.apiKey) then
        local item = ctx.services.invitations.find(id)
        local maker = item and type(item.created_by) == "string" and ctx.services.keys.find(item.created_by) or nil
        if not (maker and maker.profile and Access.seesUser(ctx.apiKey, maker.profile)) then
            return Problem.notFound("Invitation", id)
        end
    end
    if not ctx.services.invitations.revoke(id) then
        return Problem.notFound("Invitation", id)
    end
    -- The account service may know it (it was registered with an email): it is to forget it.
    if ctx.services.remote and ctx.services.remote.tell then
        ctx.services.remote.tell({ type = "invitation_cancel", invitation_id = id })
    end
    ctx.services.log.info("remote", "invitation revoked", { invitation = id, key_id = ctx.apiKey.id })
    return 204
end

return Invitations
