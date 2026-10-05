-- Invitations (docs/ACCOUNTS.md): an admin creates one for a person, an admin or a member with the
-- permissions the admin chose (1.8.0, ADR-054: `access`, src/auth/people.lua; `role` is the 1.7.0
-- role it becomes, which DirectorLink 1.7.0 reads), and its secret travels only in the link the
-- admin shares (after "#", so it never reaches a server). Whoever opens the link and
-- signs in sends a request sealed with the invitation's lock key, and gets their own API key back,
-- sealed the same way. The controller keeps each invitation's lock key, never its secret, and an
-- invitation works once.

local Clock = require("src.core.clock")
local Random = require("src.core.random")
local Roles = require("src.auth.roles")
local Store = require("src.core.store")
local Lock = require("src.cloud.lock")

local Invitations = {}

Invitations.MAX_PENDING = 20
Invitations.DEFAULT_SECONDS = 7 * 24 * 3600
Invitations.MIN_SECONDS = 60
Invitations.MAX_SECONDS = 7 * 24 * 3600

local STORE_KEY = "directorlink_invitations"

local state = { items = {} }

local function randomHex(length)
    return Random.hex(length)
end

local function save()
    local items = {}
    for _, item in ipairs(state.items) do
        items[#items + 1] = { id = item.id, role = item.role, lock = item.lock, created_at = item.created_at, expires = item.expires, created_by = item.created_by, profile = item.profile }
        items[#items].access = item.access
        items[#items].for_user = item.for_user
    end
    return Store.write(STORE_KEY, { version = 1, items = items }, false)
end

local function prune(now)
    local kept, changed = {}, false
    for _, item in ipairs(state.items) do
        if item.expires > now then
            kept[#kept + 1] = item
        else
            changed = true
        end
    end
    state.items = kept
    if changed then
        save()
    end
end

function Invitations.load()
    state.items = {}
    local stored = Store.read(STORE_KEY, false)
    for _, item in ipairs(Store.items(stored and stored.items)) do
        if type(item) == "table" and type(item.id) == "string" and Roles.valid(item.role)
            and type(item.lock) == "string" and #item.lock == 64 and type(item.expires) == "number" then
            state.items[#state.items + 1] = {
                id = item.id,
                role = item.role,
                lock = item.lock,
                created_at = type(item.created_at) == "string" and item.created_at or Clock.iso(),
                expires = item.expires,
                created_by = type(item.created_by) == "string" and item.created_by or nil,
                profile = type(item.profile) == "string" and item.profile or nil,
                access = type(item.access) == "table" and item.access or nil,
                for_user = item.for_user == true or nil,
            }
        end
    end
    prune(Clock.now())
    return #state.items
end

local function view(item)
    return { id = item.id, role = item.role, created_at = item.created_at, expires_at = Clock.iso(item.expires), created_by = item.created_by, for_me = item.profile ~= nil and not item.for_user, profile_id = item.for_user and item.profile or nil, access = item.access }
end

-- Returns { id, secret, role, created_at, expires_at } (the secret only here), or nil and
-- INVALID_ROLE, INVALID_DURATION, INVITATION_LIMIT_REACHED or LOCK_UNAVAILABLE. `createdBy` is the
-- key id of the admin who made it: revoking that key revokes its invitations. `profile`: for the
-- admin's own other device, the admin's profile (the new key joins it). `access`: the person the
-- invitation makes (src/auth/people.lua, as People.view shows it), for anyone else. `forUser`
-- (1.9.0, ADR-061): `profile` is an existing user an admin invites another device for, not the
-- inviter's own (DirectorLink 1.8.0 joins it into `profile` all the same).
function Invitations.create(role, seconds, createdBy, profile, access, forUser)
    if not Roles.valid(role) then
        return nil, "INVALID_ROLE"
    end
    seconds = seconds or Invitations.DEFAULT_SECONDS
    if type(seconds) ~= "number" or seconds ~= math.floor(seconds) or seconds < Invitations.MIN_SECONDS or seconds > Invitations.MAX_SECONDS then
        return nil, "INVALID_DURATION"
    end
    local now = Clock.now()
    prune(now)
    if #state.items >= Invitations.MAX_PENDING then
        return nil, "INVITATION_LIMIT_REACHED"
    end
    local secret = randomHex(64)
    local ok, lock = pcall(Lock.invitationKey, secret)
    if not ok then
        return nil, "LOCK_UNAVAILABLE"
    end
    local item = { id = randomHex(8), role = role, lock = lock, created_at = Clock.iso(now), expires = now + seconds, created_by = createdBy, profile = profile, access = access, for_user = (forUser and profile ~= nil) or nil }
    table.insert(state.items, item)
    if not save() then
        table.remove(state.items)
        return nil, "PERSIST_FAILED"
    end
    local result = view(item)
    result.secret = secret
    return result
end

function Invitations.list()
    prune(Clock.now())
    local items = {}
    for _, item in ipairs(state.items) do
        items[#items + 1] = view(item)
    end
    return items
end

function Invitations.revoke(id)
    for index, item in ipairs(state.items) do
        if item.id == id then
            table.remove(state.items, index)
            save()
            return true
        end
    end
    return false
end

-- Revokes every invitation (Composer's Revoke All API Keys); returns how many.
function Invitations.revokeAll()
    local count = #state.items
    state.items = {}
    save()
    return count
end

-- Revokes the invitations into users who are gone (their last device went: ADR-061), which could
-- only make a new user of whoever opened them. `gone`: { { id }, ... } (Profiles.prune).
function Invitations.revokeForUsers(gone)
    local ids = {}
    for _, user in ipairs(gone or {}) do
        ids[user.id] = true
    end
    local kept = {}
    for _, item in ipairs(state.items) do
        if not (item.profile and ids[item.profile]) then
            kept[#kept + 1] = item
        end
    end
    if #kept ~= #state.items then
        state.items = kept
        save()
    end
end

-- Revokes the invitations a key made, when that key is revoked.
function Invitations.revokeCreatedBy(keyId)
    local kept = {}
    for _, item in ipairs(state.items) do
        if item.created_by ~= keyId then
            kept[#kept + 1] = item
        end
    end
    if #kept ~= #state.items then
        state.items = kept
        save()
    end
end

-- The invitations waiting for another device of the user `profileId` itself (`for_me`, made by one
-- of their devices; not an admin's for that user), oldest first: { { id, expires_at } }.
function Invitations.ownPending(profileId)
    prune(Clock.now())
    local items = {}
    for _, item in ipairs(state.items) do
        if profileId ~= nil and item.profile == profileId and not item.for_user then
            items[#items + 1] = { id = item.id, expires_at = Clock.iso(item.expires) }
        end
    end
    return items
end

-- A pending invitation with its lock key, or nil.
function Invitations.find(id)
    prune(Clock.now())
    for _, item in ipairs(state.items) do
        if item.id == id then
            return { id = item.id, role = item.role, lock = item.lock, profile = item.profile, access = item.access, created_by = item.created_by, for_user = item.for_user }
        end
    end
    return nil
end

-- Uses the invitation up.
function Invitations.consume(id)
    return Invitations.revoke(id)
end

return Invitations
