-- Users and their devices (1.9.0, ADR-061, src/auth/users.lua): Settings → Users. Each user with
-- their role and permissions (ADR-054), whether their devices have an account, and every device
-- with when it was last used and whether the caller may remove it; admins see every user and the
-- suggestions to bring an account's devices together, anyone else only their own user. A pairing
-- code an admin makes in the app is for a user they choose, or a new one: the device that pairs
-- with it never chooses (Composer's New Pairing Code still makes a new admin user).
--
--   GET    /v1/users          (members: their own user)
--   POST   /v1/users/merge    {"account", "keep", "revision"}: a suggestion confirmed (admins)
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
-- first" with the list; for another key without them; for a caller without a key (a device
-- pairing, before its code is checked) without the user's name or id either.
function Handlers.limitProblem(ctx, profileId)
    local services = ctx.services
    local actor = ctx.apiKey
    if not actor then
        return Problem.new(409, "USER_DEVICE_LIMIT", "This user already has " .. Users.DEVICE_LIMIT .. " devices: remove one of them first", { limit = Users.DEVICE_LIMIT })
    end
    local profile = services.profiles.find(profileId)
    local name = profile and profile.name or "This user"
    local extra = { limit = Users.DEVICE_LIMIT, user = { id = profileId, name = name } }
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

-- GET /v1/users. `linked`: the account service knows this home (its relay accepted it once), so
-- that handing the home to another admin moves the home's Google or Apple account too (ADR-064).
function Handlers.list(ctx)
    local answer = Users.view(ctx.apiKey, accessView(ctx.services))
    local remote = ctx.services.remote
    answer.linked = (remote and remote.linked and remote.linked()) == true
    return 200, answer
end

local TAG = "^%x+$"

-- POST /v1/users/merge {"account": "<suggestion id>", "keep": "<profile id>", "revision": "…"}: the
-- devices of that account are brought into `keep`, whose role and permissions they then have. Only
-- the suggestion as the admin saw it (its revision, GET /v1/users): when the account service has
-- changed which devices share that account since, or someone changed those users, nothing moves
-- (409 SUGGESTION_CHANGED) and the app shows it again. Every rule is asked again here.
function Handlers.merge(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { account = true, keep = true, revision = true })
    if problem then
        return problem
    end
    if not (type(body.account) == "string" and #body.account == 16 and body.account:match(TAG)) then
        return Problem.invalidField("account", "account is the id of a suggestion in GET /v1/users")
    end
    if not (type(body.keep) == "string" and body.keep:match("^%x%x%x%x%x%x%x%x$")) then
        return Problem.invalidField("keep", "keep is the id of the user whose permissions stay")
    end
    if not (type(body.revision) == "string" and #body.revision == 16 and body.revision:match(TAG)) then
        return Problem.invalidField("revision", "revision is the suggestion's revision in GET /v1/users, as it was shown")
    end
    local group = Users.group(body.account)
    if not group then
        return Problem.new(404, "NOT_FOUND", "No such suggestion: the devices of that account are in one user already, or gone")
    end
    if Users.revision(group) ~= body.revision:lower() then
        ctx.services.log.warn("auth", "a suggestion to bring an account's devices together changed before it was confirmed: nothing moved", { by = ctx.apiKey.id, devices = #group.keys })
        return Problem.new(409, "SUGGESTION_CHANGED", "These devices or their users changed since you looked: nothing was moved. Look at the suggestion again")
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

-- How long the account service has to answer, as for an invitation it registers. The app waits
-- longer (15 s) for the controller's answer.
local OWNER_ANSWER_SECONDS = 10

local function userRef(services, profileId)
    local profile = services.profiles.find(profileId)
    return { id = profileId, name = profile and profile.name or profileId }
end

-- The problem for a refusal of Access.mayMakeOwner, of Users.ownerAccount or of the account service;
-- `user`: { id, name }; `devices`: the names of the devices in question, for OWNER_ACCOUNT_*.
local function ownerRefused(code, user, devices)
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
        return Problem.new(409, "OWNER_NEEDS_ACCOUNT", "Invite " .. user.name .. "'s Google or Apple account first (Invite their account, in Settings → Users), and have them accept it on one of their devices: the home's account moves to theirs", { user = user })
    elseif code == "OWNER_ACCOUNT_UNCLEAR" then
        return Problem.new(409, "OWNER_ACCOUNT_UNCLEAR", user.name .. "'s devices use more than one Google or Apple account (" .. table.concat(devices or {}, ", ") .. "): it is not clear which becomes the home's account. Remove the devices of the other account from " .. user.name .. " first", { user = user, device_names = devices or Json.array() })
    elseif code == "OWNER_ACCOUNT_SHARED" then
        return Problem.new(409, "OWNER_ACCOUNT_SHARED", user.name .. "'s devices (" .. table.concat(devices or {}, ", ") .. ") use your own Google or Apple account: the home's account would stay yours. Sign out of it there, or remove those devices from " .. user.name .. ", first", { user = user, device_names = devices or Json.array() })
    elseif code == "REMOTE_OFFLINE" then
        return Problem.new(503, "REMOTE_OFFLINE", "The controller is not connected to DirectorLink's servers right now, so nothing was changed; try again in a minute")
    elseif code == "RELAY_TIMEOUT" then
        return Problem.new(503, "REMOTE_TIMEOUT", "DirectorLink's servers did not answer in time, so the hand-over may not have finished: " .. user.name .. " is not the owner here, and the servers are told to undo it. Try again")
    end
    return Problem.new(502, tostring(code), "DirectorLink's servers did not move the home's account (" .. tostring(code) .. "), so nothing was changed")
end

-- The account service may have moved the home's owner account for the `owner` message `id` while the
-- controller did not follow (no answer in time, the user changed meanwhile, or the store could not
-- be written): it is told to undo exactly that move (`owner_cancel`, docs/RELAY.md), at once or as
-- soon as the controller is connected again, before anything else it asks. Logged.
local function cancelMove(ctx, id, why)
    local remote = ctx.services.remote
    local queued = false
    if type(id) == "string" and remote then
        if remote.tellSoon then
            queued = remote.tellSoon({ type = "owner_cancel", id = id })
        elseif remote.tell then
            queued = remote.tell({ type = "owner_cancel", id = id })
        end
    end
    ctx.services.log.warn("auth", "the home's owner did not change here; DirectorLink's servers are told to undo their part", { why = why, told = queued == true })
end

-- Records the new owner on the controller, once the account service has agreed (`outcome` moved), or
-- has nothing to move (not_claimed, not_linked). `asked`: the id of the `owner` message, to undo
-- the account service's move if the controller cannot follow. Returns the answer, or a problem.
local function makeOwner(ctx, target, previous, outcome, asked)
    local services = ctx.services
    if not People.setOwner(target) then
        if outcome == "moved" then
            cancelMove(ctx, asked, "not_saved")
        end
        return Problem.internal("The new owner could not be saved, so nothing was changed")
    end
    local to, from = userRef(services, target), userRef(services, previous)
    services.log.info("auth", "the home's owner changed", { from = previous, to = target, by = ctx.apiKey.id, account_service = outcome })
    Activity.record("access", "owner_changed", { by = ctx.apiKey, what = to.name, from = from.name })
    -- The old owner is an admin like any other now. Nothing else moves: a suggestion to bring
    -- devices of one account together (ADR-061) with their user is still a suggestion, which any
    -- admin who may change both users confirms now (the new owner, for one with theirs).
    return 200, { owner = to, previous = from, account_service = outcome }
end

-- POST /v1/users/owner {"profile_id": "…"}: the owner makes another admin user the home's owner.
-- The owner's rules (ADR-054) follow them: only they change their own access and devices, claim the
-- home again and confirm bringing the owner's devices together; the old owner stays an admin, and
-- nobody is removed. A home the account service knows (its relay accepted this home once) moves
-- there too: the controller asks it, over its own connection, to move the home's owner account to
-- the new owner's (Users.ownerAccount: one account, not in doubt, and not the owner's own), and
-- records the new owner only once it has, or when no account owns the home there. When the
-- controller cannot follow, or hears no answer in time, it tells the account service to undo that
-- move (owner_cancel); trying again then finishes it (docs/ACCOUNTS.md). The account service's word
-- never makes anyone the owner here: it can only refuse.
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
    local tag, unclear, devices = Users.ownerAccount(target, previous)
    if unclear then
        services.log.info("auth", "the home's owner did not change: which account becomes the home's is in doubt", { code = unclear })
        return ownerRefused(unclear, userRef(services, target), devices)
    end
    local message = { type = "owner", account = tag or Json.null }
    return Response.later(function(respond)
        remote.ask(message, OWNER_ANSWER_SECONDS, function(answer, code)
            local outcome
            if answer and answer.ok == true then
                outcome = "moved"
            elseif answer and answer.code == "NOT_CLAIMED" then
                -- No account owns the home there: the controller's alone.
                outcome = "not_claimed"
            else
                local failure = code or (answer and answer.code) or "REFUSED"
                services.log.warn("auth", "the home's owner did not change: DirectorLink's servers did not move its account", { code = failure, account = tag ~= nil })
                if code == "RELAY_TIMEOUT" then
                    -- It may have moved it and the answer is late or lost.
                    cancelMove(ctx, message.id, "no_answer")
                end
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
                    cancelMove(ctx, message.id, "changed_meanwhile")
                end
                respond(ownerRefused(again, userRef(services, target)))
                return
            end
            respond(makeOwner(ctx, target, previous, outcome, message.id))
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
