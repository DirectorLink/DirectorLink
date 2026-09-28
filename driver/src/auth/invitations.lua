-- Invitations (docs/ACCOUNTS.md): an admin creates one for a role, and its secret travels only in
-- the link the admin shares (after "#", so it never reaches a server). Whoever opens the link and
-- signs in sends a request sealed with the invitation's lock key, and gets their own API key back,
-- sealed the same way. The controller keeps each invitation's lock key, never its secret, and an
-- invitation works once.

local Clock = require("src.core.clock")
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
    local hex = ""
    while #hex < length do
        hex = hex .. tostring(C4:UUID("RANDOM")):gsub("[^%x]", ""):lower()
    end
    return hex:sub(1, length)
end

local function save()
    local items = {}
    for _, item in ipairs(state.items) do
        items[#items + 1] = { id = item.id, role = item.role, lock = item.lock, created_at = item.created_at, expires = item.expires, created_by = item.created_by, profile = item.profile }
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
            }
        end
    end
    prune(Clock.now())
    return #state.items
end

local function view(item)
    return { id = item.id, role = item.role, created_at = item.created_at, expires_at = Clock.iso(item.expires), created_by = item.created_by, for_me = item.profile ~= nil }
end

-- Returns { id, secret, role, created_at, expires_at } (the secret only here), or nil and
-- INVALID_ROLE, INVALID_DURATION, INVITATION_LIMIT_REACHED or LOCK_UNAVAILABLE. `createdBy` is the
-- key id of the admin who made it: revoking that key revokes its invitations. `profile`: for the
-- admin's own other device, the admin's profile (the new key joins it).
function Invitations.create(role, seconds, createdBy, profile)
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
    local item = { id = randomHex(8), role = role, lock = lock, created_at = Clock.iso(now), expires = now + seconds, created_by = createdBy, profile = profile }
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

-- A pending invitation with its lock key, or nil.
function Invitations.find(id)
    prune(Clock.now())
    for _, item in ipairs(state.items) do
        if item.id == id then
            return { id = item.id, role = item.role, lock = item.lock, profile = item.profile }
        end
    end
    return nil
end

-- Uses the invitation up.
function Invitations.consume(id)
    return Invitations.revoke(id)
end

return Invitations
