-- Users and their devices (1.9.0, ADR-061, docs/PREFERENCES.md). A user is a profile
-- (src/auth/profiles.lua) with one set of permissions (src/auth/people.lua, ADR-054); each of their
-- devices is an API key. This module keeps the two rules that are about devices:
--
-- * Up to DEVICE_LIMIT (5) devices a user: keys that are not revoked or expired (revoked and
--   expired keys are gone from the keys' store). Every way a key gets into a user asks Users.full
--   first (pairing with a code made for them, an invitation and its join, POST /v1/api-keys with
--   profile_id, moving a key, bringing an account's devices together). A user who had more before
--   1.9.0 keeps them, and gets none until they have fewer than five.
-- * The devices of one Google or Apple account may become one user. The account service says which
--   keys share an account (src/auth/accounts.lua: an opaque tag per account and home); the
--   controller decides. A device used by several accounts (a shared tablet) stays where it is.
--   When an account's devices are in two users or more, that is a suggestion, never a merge by
--   itself: an admin confirms it in Settings → Users, choosing whose permissions stay; one with the
--   owner's user, only the owner, keeping theirs (Access.mayMerge). The confirmation names the
--   suggestion's revision, a digest of what the admin was shown (its devices, in which users, with
--   which roles and permissions): when the account service changed the group meanwhile, or anyone
--   changed those users, it is refused and shown again. So nothing the account service says moves a
--   device, and nothing an admin did not see is confirmed. There is always an admin. Every merge,
--   and every new suggestion (a few a day at most), is logged and in the history. A user whose
--   devices all moved goes (as a user goes with their last device), and the favorites they had are
--   added to the user who stays; a device that is no longer an admin's loses the invitations it made.

local Access = require("src.auth.access")
local Accounts = require("src.auth.accounts")
local Activity = require("src.core.activity")
local Clock = require("src.core.clock")
local Invitations = require("src.auth.invitations")
local Json = require("src.core.json")
local Keys = require("src.auth.keys")
local Log = require("src.core.log")
local People = require("src.auth.people")
local Profiles = require("src.auth.profiles")
local Sha512 = require("src.core.sha512")

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

-- The Google or Apple account the home's account moves to when the user `profileId` is made the
-- owner (ADR-064): its tag (src/auth/accounts.lua), only when it is not in doubt. Their devices that
-- have exactly one account must all have the same one (a shared device says nothing about whose it
-- is), and no device of the current owner's user (`ownerId`) may use it: the home's account would
-- then stay the owner's, or become someone else's. Returns the tag; nil when none of their devices
-- has one; or nil, OWNER_ACCOUNT_UNCLEAR (several accounts) or OWNER_ACCOUNT_SHARED (the owner's
-- account too), and the names of the devices in question.
function Users.ownerAccount(profileId, ownerId, keys)
    keys = keys or Keys.list()
    local tags, order, byTag = {}, {}, {}
    for _, key in ipairs(Users.devices(profileId, keys)) do
        local single = Accounts.single(key.id)
        if single then
            if not tags[single] then
                tags[single] = true
                order[#order + 1] = single
                byTag[single] = {}
            end
            byTag[single][#byTag[single] + 1] = key.name
        end
    end
    if #order == 0 then
        return nil
    end
    if #order > 1 then
        local names = {}
        for _, tag in ipairs(order) do
            for _, name in ipairs(byTag[tag]) do
                names[#names + 1] = name
            end
        end
        return nil, "OWNER_ACCOUNT_UNCLEAR", names
    end
    local tag = order[1]
    if ownerId ~= nil and ownerId ~= profileId then
        for _, key in ipairs(Users.devices(ownerId, keys)) do
            for _, other in ipairs(Accounts.tagsOf(key.id)) do
                if other == tag then
                    return nil, "OWNER_ACCOUNT_SHARED", byTag[tag]
                end
            end
        end
    end
    return tag
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

-- The user whose access the suggestion offers to keep, or nil when the admin must choose: the
-- owner's, when the owner's user is one of them (it is the one that stays); otherwise the oldest
-- whose access is within every other's (Access.within), so that no device gains anything; never
-- one with more access than another (an admin over a member) by default.
function Users.offered(group)
    local owner = Access.owner()
    for _, id in ipairs(group.users) do
        if owner ~= nil and id == owner then
            return owner
        end
    end
    for _, id in ipairs(group.users) do
        local least = true
        for _, other in ipairs(group.users) do
            if other ~= id and not Access.within(id, other) then
                least = false
                break
            end
        end
        if least then
            return id
        end
    end
    return nil
end

-- A digest of `text`, 16 hex digits: SHA-256 where Director has it (as the keys' hashes), else
-- SHA-1, else SHA-512 in Lua.
local function digest(text)
    for _, algorithm in ipairs({ "SHA256", "SHA1" }) do
        local ok, hash = pcall(function()
            return C4:Hash(algorithm, text, { return_encoding = "HEX" })
        end)
        if ok and type(hash) == "string" and #hash >= 16 and hash:match("^%x+$") then
            return hash:sub(1, 16):lower()
        end
    end
    return (Sha512.digest(text):sub(1, 8):gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

-- What the admin is shown of a user in a suggestion, as text: their role, whether they are the
-- owner, and a member's permissions, in a fixed order.
local function accessText(profileId, owner)
    local record = People.peek(profileId)
    if not record then
        return "?"
    end
    local view = People.view(record)
    local parts = { view.role, profileId == owner and "owner" or "-" }
    if view.role ~= "admin" then
        local rooms, scenes, kinds = {}, {}, {}
        for _, id in ipairs(view.rooms) do
            rooms[#rooms + 1] = tostring(id)
        end
        for _, id in ipairs(view.scenes) do
            scenes[#scenes + 1] = id
        end
        table.sort(rooms)
        table.sort(scenes)
        for _, kind in ipairs(People.KINDS) do
            kinds[#kinds + 1] = view.kinds[kind] and "1" or "0"
        end
        parts[#parts + 1] = view.all_rooms and "all" or table.concat(rooms, ",")
        parts[#parts + 1] = table.concat(kinds)
        parts[#parts + 1] = (view.cameras and "1" or "0") .. (view.doors and "1" or "0") .. (view.alarm and "1" or "0")
        parts[#parts + 1] = table.concat(scenes, ",")
    end
    return table.concat(parts, ";")
end

-- The suggestion's revision: a digest of everything the admin is shown and confirms, the account,
-- its devices in each of its users, and each user's role, ownership and permissions. A confirmation
-- with another revision is refused (POST /v1/users/merge: 409 SUGGESTION_CHANGED).
function Users.revision(group, keys)
    keys = keys or Keys.list()
    local owner = Access.owner()
    local profileOf = {}
    for _, key in ipairs(keys) do
        profileOf[key.id] = key.profile
    end
    local parts = { "v1", group.id }
    for _, id in ipairs(group.users) do
        local theirs = {}
        for _, keyId in ipairs(group.keys) do
            if profileOf[keyId] == id then
                theirs[#theirs + 1] = keyId
            end
        end
        table.sort(theirs)
        parts[#parts + 1] = id .. "=" .. accessText(id, owner) .. "=" .. table.concat(theirs, ",")
    end
    return digest(table.concat(parts, "|"))
end

local function names(ids)
    local list = {}
    for _, id in ipairs(ids) do
        local profile = Profiles.find(id)
        list[#list + 1] = profile and profile.name or id
    end
    return table.concat(list, ", ")
end

-- Brings the group's devices into `keepId`, as the admin `by` (ctx.apiKey) confirmed it (checked by
-- the caller: Access.mayMerge, and the revision). Returns the users who went (their devices all
-- moved), or nil and USER_DEVICE_LIMIT, LAST_ADMIN, UNAVAILABLE or PERSIST_FAILED. The caller then
-- tells the driver the keys changed.
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
    -- Only admins make invitations for others: a device that is no longer an admin's keeps none of
    -- its invitations, as when its user is made a member or it is moved (handlers/profiles.lua, auth.lua).
    if not Access.isAdminPerson(keepId) then
        for _, id in ipairs(ids) do
            Invitations.revokeCreatedBy(id)
        end
    end
    Profiles.mergeFavorites(keepId, emptied)
    local kept = Profiles.find(keepId)
    Log.info("auth", "an account's devices were brought into one user", { user = keepId, from = others, devices = #ids, by = by and by.id or nil })
    Activity.record("access", "users_merged", {
        by = by,
        what = kept and kept.name or keepId,
        from = from,
        count = #ids,
    })
    return emptied
end

-- At most this many new suggestions a day go into the history and the log: the account service
-- could otherwise fill both by changing which keys share an account.
Users.SUGGESTED_A_DAY = 10
local DAY = 24 * 3600
local suggestedAt = {}
local quietSince = nil

-- The devices of a group, as the history remembers a suggestion: the same devices are the same
-- suggestion, whatever tag the account service gives their account.
local function devicesText(group)
    return table.concat(group.keys, ",")
end

-- After the account service said which keys share an account differently: each new suggestion is
-- recorded once in the history (again only if it went and came back), at most SUGGESTED_A_DAY.
-- Nothing moves: an admin confirms each one. Returns how many were recorded.
function Users.suggest()
    if not (Keys.complete() and Profiles.complete() and People.complete()) or not Accounts.known() then
        return 0
    end
    local current, present = {}, {}
    for _, group in ipairs(Users.groups()) do
        current[devicesText(group)] = group
        present[devicesText(group)] = true
    end
    local now = Clock.now()
    local recent = {}
    for _, at in ipairs(suggestedAt) do
        if at <= now and now - at < DAY then
            recent[#recent + 1] = at
        end
    end
    suggestedAt = recent
    local recorded, skipped = 0, 0
    for _, devices in ipairs(Accounts.newSuggestions(present)) do
        local group = current[devices]
        if #suggestedAt < Users.SUGGESTED_A_DAY then
            suggestedAt[#suggestedAt + 1] = now
            recorded = recorded + 1
            Log.info("auth", "DirectorLink's servers say devices of one account are in several users: an admin may make them one user in Settings → Users", { users = group.users, devices = #group.keys })
            Activity.record("access", "merge_suggested", { who = { type = "controller" }, what = names(group.users), count = #group.keys })
        else
            skipped = skipped + 1
        end
    end
    if skipped > 0 and (quietSince == nil or now < quietSince or now - quietSince >= DAY) then
        quietSince = now
        Log.warn("auth", "DirectorLink's servers changed which devices share an account too often: not every suggestion is in the history", { skipped = skipped })
    end
    return recorded
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
-- admins, the suggestions to bring an account's devices together: each with its users (their role,
-- whether one is the owner, their devices of that account), the user offered to keep (or none) and
-- its revision, which the confirmation names.
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
                users[#users + 1] = {
                    id = id,
                    name = profile and profile.name or id,
                    role = Access.isAdminPerson(id, keys) and "admin" or "member",
                    owner = id == owner,
                    devices = theirs,
                    devices_after = Users.after(group, id, keys),
                }
            end
            local offered = Users.offered(group)
            suggestions[#suggestions + 1] = {
                id = group.id,
                revision = Users.revision(group, keys),
                owner = involvesOwner,
                keep = nullable(offered),
                may_confirm = (Access.mayMerge(actor, group.users, involvesOwner and owner or group.users[1])) == true,
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
