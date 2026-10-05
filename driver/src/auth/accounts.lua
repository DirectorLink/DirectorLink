-- Which keys share a Google or Apple account (1.9.0, ADR-061), as the account service says: it knows
-- which account uses which key at this home (member_keys: the key an invitation made, and the key
-- of each sealed request the home accepted through it), and sends, in the relay's `accounts`
-- message (docs/RELAY.md), for each key an account uses, an opaque tag per account: 16 hex digits
-- of the SHA-256 of this home's id and the account's id, so never the account's id or email, and
-- not the same tag at another home. src/auth/users.lua brings the devices of one account into one
-- user, never raising anyone's access by itself (ADR-061).
--
-- The tags are kept in a store of their own (DirectorLink 1.8.0 never reads it), so that Settings →
-- Users can say which devices have an account while the relay is away; the account service sends
-- them again at every connection and after every change of keys, so they are not in backups.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local Accounts = {}

local STORE_KEY = "directorlink_accounts"
-- A device used by more accounts than this (a shared tablet) is sent with this many.
Accounts.MAX_TAGS = 4
Accounts.MAX_KEYS = 1000

local TAG = "^%x+$"

-- keys: key id -> sorted list of tags; known: the account service has said (once, ever: a 1.8.0
-- Worker never does); at: when it last did; suggested: tag -> true for the suggestions to bring
-- devices together already in the history (users.lua), so each is recorded once.
local state = { keys = {}, known = false, at = nil, suggested = {} }

local function validTag(value)
    return type(value) == "string" and #value == 16 and value:match(TAG) ~= nil and value == value:lower()
end

local function validKeyId(value)
    return type(value) == "string" and #value == 8 and value:match(TAG) ~= nil
end

local function save()
    local keys = {}
    for id, tags in pairs(state.keys) do
        local list = Json.array()
        for _, tag in ipairs(tags) do
            list[#list + 1] = tag
        end
        keys[id] = list
    end
    local suggested = Json.array()
    for tag in pairs(state.suggested) do
        suggested[#suggested + 1] = tag
    end
    table.sort(suggested)
    if not Store.write(STORE_KEY, { version = 1, keys = keys, known = state.known, at = state.at, suggested = suggested }, false) then
        Log.warn("auth", "could not save which devices share an account")
    end
end

-- Reads the tags of a message's `keys` ({ "<key id>": ["<tag>", ...] }): only what has that
-- shape, each key's tags sorted, without repeats, at most MAX_TAGS. nil when it is not an object.
local function read(value)
    if type(value) ~= "table" or value == Json.null or (Json.isArray(value) and next(value) ~= nil) then
        return nil
    end
    local result, count = {}, 0
    for id, tags in pairs(value) do
        if validKeyId(id) and type(tags) == "table" and count < Accounts.MAX_KEYS then
            local list, seen = {}, {}
            for _, tag in ipairs(tags) do
                if validTag(tag) and not seen[tag] then
                    seen[tag] = true
                    list[#list + 1] = tag
                end
            end
            table.sort(list)
            while #list > Accounts.MAX_TAGS do
                table.remove(list)
            end
            if #list > 0 then
                result[id] = list
                count = count + 1
            end
        end
    end
    return result
end

function Accounts.load()
    local data = Store.read(STORE_KEY, false)
    state.keys, state.known, state.at, state.suggested = {}, false, nil, {}
    if type(data) == "table" then
        state.keys = read(data.keys) or {}
        state.known = data.known == true
        state.at = type(data.at) == "string" and data.at or nil
        for _, tag in ipairs(Store.items(data.suggested)) do
            if validTag(tag) then
                state.suggested[tag] = true
            end
        end
    end
    local count = 0
    for _ in pairs(state.keys) do
        count = count + 1
    end
    return count
end

local function same(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

-- The account service's list (`keys` of an `accounts` message), for the keys there are (`exists(id)`):
-- it replaces what was known. Returns true when it was taken, and whether anything changed; false
-- for a message that is not one.
function Accounts.update(keys, exists)
    local tags = read(keys)
    if not tags then
        return false
    end
    local kept = {}
    for id, list in pairs(tags) do
        if not exists or exists(id) then
            kept[id] = list
        end
    end
    local changed = not state.known
    for id, list in pairs(kept) do
        changed = changed or not (state.keys[id] and same(state.keys[id], list))
    end
    for id in pairs(state.keys) do
        changed = changed or kept[id] == nil
    end
    state.keys, state.known, state.at = kept, true, Clock.iso()
    if changed then
        save()
    end
    return true, changed
end

-- The tags of a key (a list, maybe empty).
function Accounts.tagsOf(keyId)
    return state.keys[keyId] or {}
end

-- The one account a key is used with, or nil (none, or several: a shared device).
function Accounts.single(keyId)
    local tags = state.keys[keyId]
    return tags and #tags == 1 and tags[1] or nil
end

-- Whether the account service has ever said which keys share an account.
function Accounts.known()
    return state.known
end

-- The tags of keys that are gone go (`keys`: Keys.list()).
function Accounts.prune(keys)
    local exists = {}
    for _, key in ipairs(keys) do
        exists[key.id] = true
    end
    local changed = false
    for id in pairs(state.keys) do
        if not exists[id] then
            state.keys[id] = nil
            changed = true
        end
    end
    if changed then
        save()
    end
end

-- The suggestions already in the history: `current` (tag -> true) is what is suggested now; the
-- ones no longer suggested are forgotten (so a suggestion that comes back is recorded again).
-- Returns the tags of `current` that are new.
function Accounts.newSuggestions(current)
    local fresh, changed = {}, false
    for tag in pairs(current) do
        if not state.suggested[tag] then
            fresh[#fresh + 1] = tag
            state.suggested[tag] = true
            changed = true
        end
    end
    for tag in pairs(state.suggested) do
        if not current[tag] then
            state.suggested[tag] = nil
            changed = true
        end
    end
    if changed then
        save()
    end
    table.sort(fresh)
    return fresh
end

-- Revoke All API Keys, Reset Remote Identity: nothing is known any more.
function Accounts.clear()
    state.keys, state.suggested = {}, {}
    save()
end

return Accounts
