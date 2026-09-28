-- Profiles (docs/PREFERENCES.md): a person's preferences on this controller, shared by all their
-- devices. Every API key belongs to one profile (keys.lua `profile`): pairing and an invitation for
-- someone else make a new one, "Add my other device" puts the new key in the inviter's profile.
-- The preferences are what the app keeps per person: language, theme, palette, favorites and the
-- rooms they hide from their lists.
-- A profile goes when its last key does.

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

local state = { profiles = {} }

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

function Profiles.load()
    state.profiles = {}
    local data, form = Store.read(STORE_KEY, false)
    for _, item in ipairs(Store.items(type(data) == "table" and data.profiles or nil)) do
        if type(item) == "table" and type(item.id) == "string" and item.id:match("^%x+$") then
            local prefs = type(item.prefs) == "table" and item.prefs or {}
            state.profiles[#state.profiles + 1] = {
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
    return #state.profiles, form
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

-- A new, empty profile named `name`; nil and PROFILE_LIMIT_REACHED when there are too many.
function Profiles.create(name)
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

-- Deletes the profiles no key belongs to (`keys`: Keys.list()); returns how many went.
function Profiles.prune(keys)
    local used = {}
    for _, key in ipairs(keys) do
        if key.profile then
            used[key.profile] = true
        end
    end
    local kept = {}
    for _, profile in ipairs(state.profiles) do
        if used[profile.id] then
            kept[#kept + 1] = profile
        end
    end
    local removed = #state.profiles - #kept
    if removed > 0 then
        state.profiles = kept
        save()
    end
    return removed
end

return Profiles
