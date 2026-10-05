-- Users and their devices (1.9.0, ADR-061, src/auth/users.lua): Settings → Users. Each user with
-- their role and permissions (ADR-054), whether their devices have an account, and every device
-- with when it was last used and whether the caller may remove it; admins see every user and the
-- suggestions to bring an account's devices together, anyone else only their own user. A pairing
-- code an admin makes in the app is for a user they choose, or a new one: the device that pairs
-- with it never chooses (Composer's New Pairing Code still makes a new admin user).
--
--   GET    /v1/users          (members: their own user)
--   POST   /v1/users/merge    {"account", "keep"}: a suggestion confirmed (admins)
--   POST   /v1/users/owner    {"profile_id"}: the owner makes another admin the owner (1.9.0, ADR-064)
--   POST   /v1/pairing-code   {"profile_id"} or {"name", "role", "access"} (admins)
--   DELETE /v1/pairing-code   (admins)

local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Access = require("src.auth.access")
local Activity = require("src.core.activity")
local People = require("src.auth.people")
local Users = require("src.auth.users")
local ProfileHandlers = require("src.api.handlers.profiles")

local Handlers = {}

local nullable = function(value)
    if value == nil then
        return Json.null
    end
    return value
end

-- 409 USER_DEVICE_LIMIT: the user `profileId` has DEVICE_LIMIT devices already. For a caller who
-- sees that user (an admin, or the user themself: Access.seesUser), with their devices, when each
-- was last used and whether the caller may remove it, so that the app says "Remove a device
-- first" with the list; for anyone else (a new device pairing) without them.
function Handlers.limitProblem(ctx, profileId)
    local services = ctx.services
    local profile = services.profiles.find(profileId)
    local name = profile and profile.name or "This user"
    local extra = { limit = Users.DEVICE_LIMIT, user = { id = profileId, name = name } }
    local actor = ctx.apiKey
    if actor and Access.seesUser(actor, profileId) then
        local devices = Json.array()
        for _, key in ipairs(Users.devices(profileId)) do
            devices[#devices + 1] = {
                id = key.id,
                name = key.name,
                created_at = key.created_at,
                last_used_at = nullable(key.last_used_at),
                current = key.id == actor.id,
                removable = key.id ~= actor.id and (Access.mayRemoveDevice(actor, key)) == true,
            }
        end
        extra.devices = devices
    end
    return Problem.new(409, "USER_DEVICE_LIMIT", name .. " already has " .. Users.DEVICE_LIMIT .. " devices: remove one of them first", extra)
end

-- nil, or the problem when the user is full.
function Handlers.refuseWhenFull(ctx, profileId)
    if profileId and Users.full(profileId) then
        return Handlers.limitProblem(ctx, profileId)
    end
    return nil
end

local function accessView(services)
    return function(profileId, owner)
        return ProfileHandlers.accessView(services, profileId, owner)
    end
end

function Handlers.list(ctx)
    return 200, Users.view(ctx.apiKey, accessView(ctx.services))
end

local TAG = "^%x+$"

-- POST /v1/users/merge {"account": "<suggestion id>", "keep": "<profile id>"}: the devices of that
-- account are brought into `keep`, whose role and permissions they then have.
function Handlers.merge(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { account = true, keep = true })
    if problem then
        return problem
    end
    if not (type(body.account) == "string" and #body.account == 16 and body.account:match(TAG)) then
        return Problem.invalidField("account", "account is the id of a suggestion in GET /v1/users")
    end
    if not (type(body.keep) == "string" and body.keep:match("^%x%x%x%x%x%x%x%x$")) then
        return Problem.invalidField("keep", "keep is the id of the user whose permissions stay")
    end
    local group = Users.group(body.account)
    if not group then
        return Problem.new(404, "NOT_FOUND", "No such suggestion: the devices of that account are in one user already, or gone")
    end
    local listed = false
    for _, id in ipairs(group.users) do
        listed = listed or id == body.keep
    end
    if not listed then
        return Problem.invalidField("keep", "keep is one of the suggestion's users")
    end
    local allowed, refusal = Access.mayMerge(ctx.apiKey, group.users, body.keep)
    if not allowed then
        if refusal == "OWNER_KEEPS" then
            return Problem.invalidField("keep", "The home's owner stays the owner: keep the owner's permissions")
        end
        return ProfileHandlers.refused(refusal, "These devices are in the home's owner's user: only the owner brings them together")
    end
    local emptied, failure = Users.merge(group, body.keep, ctx.apiKey)
    if not emptied then
        if failure == "USER_DEVICE_LIMIT" then
            local limit = Handlers.limitProblem(ctx, body.keep)
            limit.detail = "Together they would have more than " .. Users.DEVICE_LIMIT .. " devices: remove one of them first"
            return limit
        elseif failure == "LAST_ADMIN" then
            return Problem.new(409, "LAST_ADMIN", "No admin would be left: make someone else an admin first")
        elseif failure == "UNAVAILABLE" then
            return Problem.new(503, "UNAVAILABLE", "The users could not be read when DirectorLink started; restart the driver and try again")
        end
        return Problem.internal("The devices could not be moved (" .. tostring(failure) .. ")")
    end
    ctx.services.onKeysChanged()
    for _, item in ipairs(Users.view(ctx.apiKey, accessView(ctx.services)).items) do
        if item.id == body.keep then
            return 200, item
        end
    end
    return Problem.notFound("User", body.keep)
end

-- ---- handing the home to another admin (1.9.0, ADR-064) -----------------------------------------

-- How long the account service has to answer, as for an invitation it registers.
local OWNER_ANSWER_SECONDS = 10

local function userRef(services, profileId)
    local profile = services.profiles.find(profileId)
    return { id = profileId, name = profile and profile.name or profileId }
end

-- The problem for a refusal of Access.mayMakeOwner or of the account service; `user`: { id, name }.
local function ownerRefused(code, user)
    if code == "UNAVAILABLE" then
        return Problem.new(503, "UNAVAILABLE", "Who the home's owner is could not be read when DirectorLink started; restart the driver and try again")
    elseif code == "OWNER_ONLY" then
        return Problem.new(403, "OWNER_ONLY", "Only the home's owner makes another admin the owner")
    elseif code == "NOT_FOUND" then
        return Problem.notFound("User", user.id)
    elseif code == "ALREADY_OWNER" then
        return Problem.new(409, "ALREADY_OWNER", user.name .. " is the home's owner already", { user = user })
    elseif code == "NOT_AN_ADMIN" then
        return Problem.new(409, "NOT_AN_ADMIN", "Make " .. user.name .. " an admin first: only an admin becomes the home's owner", { user = user })
    elseif code == "OWNER_NEEDS_ACCOUNT" then
        return Problem.new(409, "OWNER_NEEDS_ACCOUNT", user.name .. " needs to sign in to DirectorLink with their Google or Apple account on one of their devices first: the home's account moves to theirs", { user = user })
    elseif code == "REMOTE_OFFLINE" or code == "RELAY_TIMEOUT" then
        return Problem.new(503, "REMOTE_OFFLINE", "The controller is not connected to DirectorLink's servers right now, so nothing was changed; try again in a minute")
    end
    return Problem.new(502, tostring(code), "DirectorLink's servers did not move the home's account (" .. tostring(code) .. "), so nothing was changed")
end

-- The account service moved the home's owner account but the controller did not follow (the user
-- changed meanwhile, or the store could not be written): it is told to move it back, to the account
-- it named (`previous`, a tag). Best effort; it is logged.
local function moveBack(ctx, previous)
    local remote = ctx.services.remote
    if type(previous) == "string" and remote and remote.tell then
        remote.tell({ type = "owner", id = "owner-back-" .. tostring(os.time()), account = previous })
    end
    ctx.services.log.warn("auth", "the home's owner did not change here; DirectorLink's servers were told to move its account back", { told = type(previous) == "string" })
end

-- Records the new owner on the controller, once the account service has agreed (`outcome` moved), or
-- has nothing to move (not_claimed, not_linked). Returns the answer, or a problem.
local function makeOwner(ctx, target, previous, outcome, previousTag)
    local services = ctx.services
    if not People.setOwner(target) then
        if outcome == "moved" then
            moveBack(ctx, previousTag)
        end
        return Problem.internal("The new owner could not be saved, so nothing was changed")
    end
    local to, from = userRef(services, target), userRef(services, previous)
    services.log.info("auth", "the home's owner changed", { from = previous, to = target, by = ctx.apiKey.id, account_service = outcome })
    Activity.record("access", "owner_changed", { by = ctx.apiKey, what = to.name, from = from.name })
    -- The old owner is an admin like any other now: users alike with theirs come together (ADR-061).
    Users.reconcile(services.onKeysChanged)
    return 200, { owner = to, previous = from, account_service = outcome }
end

-- POST /v1/users/owner {"profile_id": "…"}: the owner makes another admin user the home's owner.
-- The owner's rules (ADR-054) follow them: only they change their own access and devices, claim the
-- home again and confirm bringing the owner's devices together; the old owner stays an admin, and
-- nobody is removed. A home the account service knows (its relay accepted this home once) moves
-- there too: the controller asks it, over its own connection, to move the home's owner account to
-- the new owner's (Users.accountOf), and records the new owner only once it has, or when no account
-- owns the home there; otherwise nothing moves (docs/ACCOUNTS.md). The account service's word never
-- makes anyone the owner here: it can only refuse.
function Handlers.make_owner(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { profile_id = true })
    if problem then
        return problem
    end
    if not (type(body.profile_id) == "string" and body.profile_id:match("^%x%x%x%x%x%x%x%x$")) then
        return Problem.invalidField("profile_id", "profile_id is the id of the admin user who becomes the owner")
    end
    local services = ctx.services
    local target = body.profile_id
    local allowed, refusal = Access.mayMakeOwner(ctx.apiKey, target)
    if allowed and not services.keys.complete() then
        allowed, refusal = false, "UNAVAILABLE"
    end
    if not allowed then
        return ownerRefused(refusal, userRef(services, target))
    end
    local previous = Access.owner()
    local remote = services.remote
    if not (remote and remote.linked and remote.linked()) then
        -- Never in the account service: nothing to move there.
        return makeOwner(ctx, target, previous, "not_linked")
    end
    if not remote.enabled() then
        return Problem.new(409, "REMOTE_ACCESS_OFF", "Turn on Remote Access in Composer first: DirectorLink's servers move the home's account to the new owner's too")
    end
    local tag = Users.accountOf(target)
    return Response.later(function(respond)
        remote.ask({ type = "owner", account = tag or Json.null }, OWNER_ANSWER_SECONDS, function(answer, code)
            local outcome
            if answer and answer.ok == true then
                outcome = "moved"
            elseif answer and answer.code == "NOT_CLAIMED" then
                -- No account owns the home there: the controller's alone.
                outcome = "not_claimed"
            else
                local failure = code or (answer and answer.code) or "REFUSED"
                services.log.warn("auth", "the home's owner did not change: DirectorLink's servers did not move its account", { code = failure, account = tag ~= nil })
                respond(ownerRefused(failure, userRef(services, target)))
                return
            end
            -- Asked again: other requests ran while the account service answered.
            local still, again = Access.mayMakeOwner(ctx.apiKey, target)
            if still and not services.keys.find(ctx.apiKey.id) then
                still, again = false, "OWNER_ONLY"
            end
            if not still then
                if outcome == "moved" then
                    moveBack(ctx, answer.previous)
                end
                respond(ownerRefused(again, userRef(services, target)))
                return
            end
            respond(makeOwner(ctx, target, previous, outcome, answer.previous))
        end)
    end)
end

-- ---- pairing at home for a chosen user ---------------------------------------------------------

-- POST /v1/pairing-code {"profile_id": "…"} or {"name": "Kitchen tablet", "role": "member",
-- "access": {…}}: a code for the home network (as Composer's, 15 minutes, works once) whose device
-- joins that user, or a new user with that name and access. One code at a time: it replaces the
-- one shown in Composer, and Composer's next one replaces it.
function Handlers.create_code(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { profile_id = true, name = true, role = true, access = true })
    if problem then
        return problem
    end
    local services = ctx.services
    local target
    if body.profile_id ~= nil then
        if body.name ~= nil or body.role ~= nil or body.access ~= nil then
            return Problem.invalidField("profile_id", "A device for an existing user has that user's name and permissions: send only profile_id")
        end
        local profile = type(body.profile_id) == "string" and services.profiles.find(body.profile_id) or nil
        if not profile then
            return Problem.invalidField("profile_id", "profile_id must be the id of an existing user")
        end
        local allowed, refusal = Access.mayChangePerson(ctx.apiKey, profile.id)
        if not allowed then
            return ProfileHandlers.refused(refusal, "This is the home's owner: only the owner pairs a device of theirs")
        end
        problem = Handlers.refuseWhenFull(ctx, profile.id)
        if problem then
            return problem
        end
        target = { profile = profile.id, name = profile.name, by = ctx.apiKey.id }
    else
        local name, nameProblem = Validate.name(body.name, "name")
        if nameProblem then
            return nameProblem
        end
        if not name then
            return Problem.invalidField("name", "Send profile_id, or the new user's name")
        end
        local role = body.role or "member"
        if role ~= "admin" and role ~= "member" then
            return Problem.invalidField("role", "role must be admin or member")
        end
        local person
        person, problem = ProfileHandlers.readAccess(services, body.access or {}, People.defaults(role), "access")
        if not person then
            return problem
        end
        person.role = role
        target = { name = name, person = person, by = ctx.apiKey.id }
    end
    local ok, failure = services.pairing.open(target)
    if not ok then
        return Problem.new(503, "PAIRING_UNAVAILABLE", "No pairing code could be made (" .. tostring(failure) .. ")")
    end
    local status = services.pairing.status()
    services.log.info("auth", "pairing code made in the app", { for_user = target.profile, new_user = target.profile == nil, by = ctx.apiKey.id })
    Activity.record("access", "pairing_code", { by = ctx.apiKey, what = target.name, to = target.person and target.person.role or nil })
    return 201, {
        code = services.pairing.format(services.pairing.code()),
        expires_at = Clock.iso(status.code_expires_at),
        user = { id = nullable(target.profile), name = target.name, role = target.person and target.person.role or ProfileHandlers.accessView(services, target.profile).role },
    }
end

-- DELETE /v1/pairing-code: the code in use stops working (the app's, or Composer's).
function Handlers.delete_code(ctx)
    if not ctx.services.pairing.isActive() then
        return Problem.new(404, "NOT_FOUND", "No pairing code is active")
    end
    ctx.services.pairing.cancel()
    ctx.services.log.info("auth", "pairing code closed from the app", { by = ctx.apiKey.id })
    return 204, nil
end

return Handlers
