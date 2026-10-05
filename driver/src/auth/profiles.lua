-- Profiles (docs/PREFERENCES.md): a person's preferences on this controller, shared by all their
-- devices. Every API key belongs to one profile (keys.lua `profile`): pairing and an invitation for
-- someone else make a new one, "Add my other device" puts the new key in the inviter's profile.
-- The preferences are what the app keeps per person: language, theme, palette, favorites and the
-- rooms they hide from their lists.
-- A profile goes when its last key does.
--
-- A store Director could not read at start may still hold the profiles (they come back at the
-- next start): until then nothing is written over it, no profile is made or removed, and keys keep
-- the profile ids they name (Profiles.complete), so that the people (src/auth/people.lua), kept by
-- those ids, are not worked out again from their keys.

local Clock = require("src.core.clock")
local Random = require("src.core.random")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local Profiles = {}

local STORE_KEY = "directorlink_profiles"
Profiles.MAX_PROFILES = 100
Profiles.MAX_FAVORITES = 200
Profiles.THEMES = { auto = true, light = true, dark = true }

-- `complete` is false after the store could not be read at start.
local state = { profiles = {}, complete = true }

local function randomHex(length)
    return Random.hex(length)
end

-- The stored preferences, as the API shows them (favorites always a list).
local function copyPrefs(prefs)
    prefs = prefs or {}
    local favorites = Json.array()
    for _, entry in ipairs(prefs.favorites or {}) do
        favorites[#favorites + 1] = entry
    end
    local hidden = Json.array()
    for _, id in ipairs(prefs.hidden_rooms or {}) do
        hidden[#hidden + 1] = id
    end
    return { language = prefs.language, theme = prefs.theme, palette = prefs.palette, favorites = favorites, hidden_rooms = hidden }
end

local function copy(profile)
    return { id = profile.id, name = profile.name, created_at = profile.created_at, version = profile.version, prefs = copyPrefs(profile.prefs) }
end

local function save()
    if not state.complete then
        Log.error("profiles", "profiles not saved: their store could not be read at start")
        return false
    end
    local records = Json.array()
    for _, profile in ipairs(state.profiles) do
        records[#records + 1] = copy(profile)
    end
    local ok = Store.write(STORE_KEY, { version = 1, profiles = records }, false)
    if not ok then
        Log.error("profiles", "could not save profiles")
    end
    return ok
end

-- The profiles of a stored record ({ version, profiles }, as the store or a backup holds them);
-- the ones that cannot be read are left out. Returns them and how many were left out.
function Profiles.read(data)
    local profiles, dropped = {}, 0
    for _, item in ipairs(Store.items(type(data) == "table" and data.profiles or nil)) do
        if type(item) ~= "table" or type(item.id) ~= "string" or not item.id:match("^%x+$") then
            dropped = dropped + 1
        else
            local prefs = type(item.prefs) == "table" and item.prefs or {}
            profiles[#profiles + 1] = {
                id = item.id,
                name = type(item.name) == "string" and item.name or "Profile",
                created_at = type(item.created_at) == "string" and item.created_at or Clock.iso(),
                version = tonumber(item.version) or 0,
                prefs = {
                    language = type(prefs.language) == "string" and prefs.language or nil,
                    theme = type(prefs.theme) == "string" and prefs.theme or nil,
                    palette = type(prefs.palette) == "string" and prefs.palette or nil,
                    favorites = Store.items(prefs.favorites),
                    hidden_rooms = Store.items(prefs.hidden_rooms),
                },
            }
        end
    end
    return profiles, dropped
end

function Profiles.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    state.profiles = Profiles.read(data)
    if not state.complete then
        Log.error("profiles", "the profiles could not be read; nothing is changed in them until the next start")
    end
    return #state.profiles, form
end

-- False after a load that could not read the store: nothing is written over it.
function Profiles.complete()
    return state.complete
end

-- Backups (ADR-042, src/core/backup.lua): the profiles as the store keeps them.
function Profiles.backup()
    local records = Json.array()
    for _, profile in ipairs(state.profiles) do
        records[#records + 1] = copy(profile)
    end
    return { version = 1, profiles = records }
end

-- Replaces every profile with the ones of `data`, read as the store's are. Returns true once saved.
function Profiles.restore(data)
    state.profiles = Profiles.read(data)
    state.complete = true
    return save()
end

local function findRecord(id)
    for _, profile in ipairs(state.profiles) do
        if profile.id == id then
            return profile
        end
    end
    return nil
end

function Profiles.find(id)
    local profile = type(id) == "string" and findRecord(id) or nil
    return profile and copy(profile) or nil
end

function Profiles.list()
    local items = {}
    for _, profile in ipairs(state.profiles) do
        items[#items + 1] = copy(profile)
    end
    return items
end

-- A new, empty profile named `name`; nil and PROFILE_LIMIT_REACHED when there are too many, or
-- UNAVAILABLE when the store could not be read at start.
function Profiles.create(name)
    if not state.complete then
        return nil, "UNAVAILABLE"
    end
    if #state.profiles >= Profiles.MAX_PROFILES then
        return nil, "PROFILE_LIMIT_REACHED"
    end
    local id = randomHex(8)
    while findRecord(id) do
        id = randomHex(8)
    end
    local profile = { id = id, name = tostring(name or "Profile"), created_at = Clock.iso(), version = 0, prefs = { favorites = {}, hidden_rooms = {} } }
    state.profiles[#state.profiles + 1] = profile
    save()
    return copy(profile)
end

function Profiles.rename(id, name)
    local profile = findRecord(id)
    if not profile then
        return nil, "NOT_FOUND"
    end
    profile.name = name
    profile.version = profile.version + 1
    save()
    return copy(profile)
end

-- Applies `changes` (validated by the API: language, theme, palette, favorites; false clears a
-- field) to the profile's preferences. `expected`: the version the caller saw, or nil to not check.
-- Returns the profile, or nil and NOT_FOUND / VERSION_CONFLICT.
function Profiles.updatePrefs(id, changes, expected)
    local profile = findRecord(id)
    if not profile then
        return nil, "NOT_FOUND"
    end
    if expected ~= nil and expected ~= profile.version then
        return nil, "VERSION_CONFLICT"
    end
    for _, field in ipairs({ "language", "theme", "palette" }) do
        if changes[field] ~= nil then
            profile.prefs[field] = changes[field] ~= false and changes[field] or nil
        end
    end
    if changes.favorites ~= nil then
        profile.prefs.favorites = changes.favorites
    end
    if changes.hidden_rooms ~= nil then
        profile.prefs.hidden_rooms = changes.hidden_rooms
    end
    profile.version = profile.version + 1
    save()
    return copy(profile)
end

-- Deletes the profiles no key belongs to (`keys`: Keys.list()): a user goes with their last device
-- (ADR-061). Returns how many went, and which ({ id, name }). None while the store could not be
-- read.
function Profiles.prune(keys)
    if not state.complete then
        return 0, {}
    end
    local used = {}
    for _, key in ipairs(keys) do
        if key.profile then
            used[key.profile] = true
        end
    end
    local kept, gone = {}, {}
    for _, profile in ipairs(state.profiles) do
        if used[profile.id] then
            kept[#kept + 1] = profile
        else
            gone[#gone + 1] = { id = profile.id, name = profile.name }
        end
    end
    if #gone > 0 then
        state.profiles = kept
        save()
    end
    return #gone, gone
end

-- The favorites of the profiles `fromIds` that `intoId` does not have, added after its own (up to
-- MAX_FAVORITES): the devices of one account brought into one user keep what the other user had
-- on Home (1.9.0, ADR-061). The rest of `intoId`'s preferences stay. Returns true when it changed.
function Profiles.mergeFavorites(intoId, fromIds)
    local into = findRecord(intoId)
    if not into or not state.complete then
        return false
    end
    local have, added = {}, 0
    for _, entry in ipairs(into.prefs.favorites or {}) do
        have[entry] = true
    end
    into.prefs.favorites = into.prefs.favorites or {}
    for _, id in ipairs(fromIds) do
        local from = findRecord(id)
        for _, entry in ipairs(from and from.prefs.favorites or {}) do
            if not have[entry] and #into.prefs.favorites < Profiles.MAX_FAVORITES then
                have[entry] = true
                into.prefs.favorites[#into.prefs.favorites + 1] = entry
                added = added + 1
            end
        end
    end
    if added == 0 then
        return false
    end
    into.version = into.version + 1
    save()
    return true
end

return Profiles
