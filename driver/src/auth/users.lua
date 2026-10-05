-- Users and their devices (1.9.0, ADR-061, docs/PREFERENCES.md). A user is a profile
-- (src/auth/profiles.lua) with one set of permissions (src/auth/people.lua, ADR-054); each of their
-- devices is an API key. This module keeps the two rules that are about devices:
--
-- * Up to DEVICE_LIMIT (5) devices a user: keys that are not revoked or expired (revoked and
--   expired keys are gone from the keys' store). Every way a key gets into a user asks Users.full
--   first (pairing with a code made for them, an invitation and its join, POST /v1/api-keys with
--   profile_id, moving a key, bringing an account's devices together). A user who had more before
--   1.9.0 keeps them, and gets none until they have fewer than five.
-- * The devices of one Google or Apple account become one user. The account service says which
--   keys share an account (src/auth/accounts.lua: an opaque tag per account and home); the
--   controller decides. A device used by several accounts (a shared tablet) stays where it is.
--   When an account's devices are in two users or more, they are brought into one by DirectorLink
--   itself only when no device would gain anything: the users have the same role, none of them is
--   the owner, and they have the same permissions (Access.alike), and the user they go to stays
--   within five devices. Otherwise it is a suggestion, which an admin confirms in Settings → Users,
--   choosing whose permissions stay; one with the owner's user, only the owner, keeping theirs
--   (Access.mayMerge). So nothing the account service says can raise anyone's access on its own.
--   There is always an admin. Every merge, and every new suggestion, is logged and in the history.
--   A user whose devices all moved goes (as a user goes with their last device), and the
--   favorites they had are added to the user who stays.

local Access = require("src.auth.access")
local Accounts = require("src.auth.accounts")
local Activity = require("src.core.activity")
local Json = require("src.core.json")
local Keys = require("src.auth.keys")
local Log = require("src.core.log")
local People = require("src.auth.people")
local Profiles = require("src.auth.profiles")

local Users = {}

Users.DEVICE_LIMIT = 5

-- The devices (keys, as Keys.list() has them, oldest first) of the user `profileId`.
function Users.devices(profileId, keys)
    local list = {}
    for _, key in ipairs(keys or Keys.list()) do
        if profileId ~= nil and key.profile == profileId then
            list[#list + 1] = key
        end
    end
    return list
end

-- Whether the user has DEVICE_LIMIT devices or more: they get no other until one is removed.
function Users.full(profileId, keys)
    return profileId ~= nil and #Users.devices(profileId, keys) >= Users.DEVICE_LIMIT
end

-- The Google or Apple account of the user `profileId` (its tag, src/auth/accounts.lua), as the
-- account service said: that of their most recently used device that has exactly one account (a
-- shared device says nothing about whose it is). Returns the tag and that device, or nil when none
-- of their devices has one. Handing the home to them (ADR-064) moves the home's owner account in
-- the account service to it.
function Users.accountOf(profileId, keys)
    local tag, device, at = nil, nil, nil
    for _, key in ipairs(Users.devices(profileId, keys)) do
        local single = Accounts.single(key.id)
        local used = tostring(key.last_used_at or key.created_at or "")
        if single and (tag == nil or used > at) then
            tag, device, at = single, key, used
        end
    end
    return tag, device
end

-- ---- the devices of one account ----------------------------------------------------------------

-- The accounts whose devices are in more than one user: { id = tag, keys = { key ids }, users =
-- { profile ids, oldest first } }, by tag. Only devices with that one account count.
function Users.groups(keys)
    keys = keys or Keys.list()
    -- Oldest first: by when each was made, then as the profiles' store keeps them (in the order made).
    local made, position = {}, {}
    for index, profile in ipairs(Profiles.list()) do
        made[profile.id] = tostring(profile.created_at or "")
        position[profile.id] = index
    end
    local byTag = {}
    for _, key in ipairs(keys) do
        local tag = key.profile and Accounts.single(key.id)
        if tag then
            local group = byTag[tag] or { id = tag, keys = {}, users = {}, seen = {} }
            byTag[tag] = group
            group.keys[#group.keys + 1] = key.id
            if not group.seen[key.profile] then
                group.seen[key.profile] = true
                group.users[#group.users + 1] = key.profile
            end
        end
    end
    local groups = {}
    for _, group in pairs(byTag) do
        if #group.users > 1 then
            group.seen = nil
            table.sort(group.users, function(a, b)
                local ca, cb = made[a] or "", made[b] or ""
                if ca ~= cb then
                    return ca < cb
                end
                return (position[a] or 0) < (position[b] or 0)
            end)
            table.sort(group.keys)
            groups[#groups + 1] = group
        end
    end
    table.sort(groups, function(a, b)
        return a.id < b.id
    end)
    return groups
end

function Users.group(tag, keys)
    for _, group in ipairs(Users.groups(keys)) do
        if group.id == tag then
            return group
        end
    end
    return nil
end

-- The keys of `group` that move when `keepId` stays: its devices in the other users.
function Users.moving(group, keepId, keys)
    local profileOf = {}
    for _, key in ipairs(keys or Keys.list()) do
        profileOf[key.id] = key.profile
    end
    local ids = {}
    for _, id in ipairs(group.keys) do
        if profileOf[id] ~= keepId then
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- How many devices `keepId` has once the group's devices are brought into it.
function Users.after(group, keepId, keys)
    keys = keys or Keys.list()
    return #Users.devices(keepId, keys) + #Users.moving(group, keepId, keys)
end

-- Whether some user would still be an admin, with a device, after the keys `ids` moved to `keepId`.
local function adminLeft(ids, keepId, keys)
    local moving = {}
    for _, id in ipairs(ids) do
        moving[id] = true
    end
    for _, key in ipairs(keys) do
        if Access.isAdminPerson(moving[key.id] and keepId or key.profile, keys) then
            return true
        end
    end
    return false
end

-- Whether DirectorLink brings the group together by itself, and into whom: only when the stores
-- were all read, every user of it is alike (Access.alike: no device gains anything), and the
-- oldest of them stays within the device limit. Returns the user who stays, or nil and why.
function Users.automatic(group, keys)
    keys = keys or Keys.list()
    if not (Keys.complete() and Profiles.complete() and People.complete()) then
        return nil, "unavailable"
    end
    for index = 2, #group.users do
        if not Access.alike(group.users[1], group.users[index]) then
            return nil, "different_access"
        end
    end
    local keep = group.users[1]
    if Users.after(group, keep, keys) > Users.DEVICE_LIMIT then
        return nil, "device_limit"
    end
    return keep
end

local function names(ids)
    local list = {}
    for _, id in ipairs(ids) do
        local profile = Profiles.find(id)
        list[#list + 1] = profile and profile.name or id
    end
    return table.concat(list, ", ")
end

-- Brings the group's devices into `keepId` (checked by the caller: Users.automatic, or the API
-- with Access.mayMerge). `by`: the key that confirmed it (ctx.apiKey), or nil for DirectorLink
-- itself. Returns the users who went (their devices all moved), or nil and USER_DEVICE_LIMIT,
-- LAST_ADMIN, UNAVAILABLE or PERSIST_FAILED. The caller then tells the driver the keys changed.
function Users.merge(group, keepId, by)
    if not (Keys.complete() and Profiles.complete() and People.complete()) then
        return nil, "UNAVAILABLE"
    end
    local keys = Keys.list()
    local ids = Users.moving(group, keepId, keys)
    if #ids == 0 then
        return {}
    end
    if Users.after(group, keepId, keys) > Users.DEVICE_LIMIT then
        return nil, "USER_DEVICE_LIMIT"
    end
    if not adminLeft(ids, keepId, keys) then
        return nil, "LAST_ADMIN"
    end
    local others = {}
    for _, id in ipairs(group.users) do
        if id ~= keepId then
            others[#others + 1] = id
        end
    end
    -- Who goes: the other users whose every device moves.
    local moving, emptied = {}, {}
    for _, id in ipairs(ids) do
        moving[id] = true
    end
    for _, id in ipairs(others) do
        local left = false
        for _, key in ipairs(Users.devices(id, keys)) do
            left = left or not moving[key.id]
        end
        if not left then
            emptied[#emptied + 1] = id
        end
    end
    local from = names(others)
    local ok, failure = Keys.move(ids, keepId, People.legacyRole(People.peek(keepId)))
    if not ok then
        return nil, failure
    end
    Profiles.mergeFavorites(keepId, emptied)
    local kept = Profiles.find(keepId)
    Log.info("auth", by and "an account's devices were brought into one user" or "an account's devices were brought into one user by themselves", {
        user = keepId, from = others, devices = #ids, by = by and by.id or nil,
    })
    Activity.record("access", "users_merged", {
        by = by,
        who = not by and { type = "controller" } or nil,
        what = kept and kept.name or keepId,
        from = from,
        count = #ids,
        note = not by and "automatic" or nil,
    })
    return emptied
end

-- After the account service said which keys share an account (or the keys changed): the groups
-- that are alike are brought together by DirectorLink, and each new suggestion is recorded once
-- in the history. `changed()`: tells the driver the keys changed (main.lua). Returns how many
-- groups were brought together.
function Users.reconcile(changed)
    if not (Keys.complete() and Profiles.complete() and People.complete()) or not Accounts.known() then
        return 0
    end
    local merged = 0
    -- One at a time: a merge changes the users the next group is in.
    for _ = 1, 20 do
        local done = false
        for _, group in ipairs(Users.groups()) do
            local keep = Users.automatic(group)
            if keep then
                local ok, failure = Users.merge(group, keep, nil)
                if ok then
                    merged = merged + 1
                    done = true
                    if changed then
                        changed()
                    end
                    break
                end
                Log.warn("auth", "an account's devices could not be brought into one user", { reason = failure })
            end
        end
        if not done then
            break
        end
    end
    local current = {}
    local groups = Users.groups()
    for _, group in ipairs(groups) do
        current[group.id] = group
    end
    local present = {}
    for tag in pairs(current) do
        present[tag] = true
    end
    for _, tag in ipairs(Accounts.newSuggestions(present)) do
        local group = current[tag]
        Log.info("auth", "devices of one account are in several users: an admin may bring them together in Settings → Users", { users = group.users, devices = #group.keys })
        Activity.record("access", "merge_suggested", { who = { type = "controller" }, what = names(group.users), count = #group.keys })
    end
    return merged
end

-- ---- what Settings → Users shows (GET /v1/users) ------------------------------------------------

local function nullable(value)
    if value == nil then
        return Json.null
    end
    return value
end

-- `accessView(profileId, owner)`: a user's role and permissions as GET /v1/profiles/{id}/access
-- answers (src/api/handlers/profiles.lua). The caller's own user, and for an admin every user;
-- the devices of each, with when each was last used and whether the caller may remove it; for
-- admins, the suggestions to bring an account's devices together.
function Users.view(actor, accessView)
    local keys = Keys.list()
    local owner = Access.owner()
    local items = Json.array()
    local own = actor and (actor.profile or Keys.profileOf(actor.id)) or nil
    for _, profile in ipairs(Profiles.list()) do
        if Access.seesUser(actor, profile.id) then
            local devices, tags = Json.array(), {}
            for _, key in ipairs(Users.devices(profile.id, keys)) do
                local accounts = Accounts.tagsOf(key.id)
                for _, tag in ipairs(accounts) do
                    tags[tag] = true
                end
                local current = actor ~= nil and key.id == actor.id
                devices[#devices + 1] = {
                    id = key.id,
                    name = key.name,
                    created_at = key.created_at,
                    last_used_at = nullable(key.last_used_at),
                    expires_at = nullable(key.expires_at),
                    current = current,
                    accounts = #accounts,
                    removable = not current and (Access.mayRemoveDevice(actor, key)) == true,
                }
            end
            local count = 0
            for _ in pairs(tags) do
                count = count + 1
            end
            items[#items + 1] = {
                id = profile.id,
                name = profile.name,
                created_at = profile.created_at,
                you = profile.id == own,
                access = accessView(profile.id, owner),
                accounts = count,
                devices = devices,
            }
        end
    end
    local suggestions = Json.array()
    if Access.isAdmin(actor) then
        for _, group in ipairs(Users.groups(keys)) do
            local users, involvesOwner = Json.array(), false
            for _, id in ipairs(group.users) do
                involvesOwner = involvesOwner or id == owner
                local theirs = Json.array()
                for _, keyId in ipairs(group.keys) do
                    if Keys.profileOf(keyId) == id then
                        theirs[#theirs + 1] = keyId
                    end
                end
                local profile = Profiles.find(id)
                users[#users + 1] = { id = id, name = profile and profile.name or id, devices = theirs, devices_after = Users.after(group, id, keys) }
            end
            local keep = group.users[1]
            if involvesOwner then
                keep = owner
            end
            suggestions[#suggestions + 1] = {
                id = group.id,
                owner = involvesOwner,
                may_confirm = (Access.mayMerge(actor, group.users, keep)) == true,
                users = users,
            }
        end
    end
    return {
        device_limit = Users.DEVICE_LIMIT,
        accounts_known = Accounts.known(),
        items = items,
        suggestions = suggestions,
    }
end

return Users
