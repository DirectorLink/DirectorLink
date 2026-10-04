-- Profiles (docs/PREFERENCES.md, src/auth/profiles.lua): each person's preferences, shared by their
-- devices. /v1/profile is the caller's own (any key); /v1/profiles lists them for admins, who can
-- rename them and move a key to another (PATCH /v1/api-keys/{keyId} profile_id).

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local RoomNames = require("src.core.room_names")
local FavoritesGone = require("src.core.favorites_gone")

local Profiles = {}

local PALETTE = "^%l[%l%d%-]*$"
local FAVORITE = "^%l+:%d+$"

local function nullable(value)
    if value == nil then
        return Json.null
    end
    return value
end

local function view(profile, keyIds)
    local prefs = profile.prefs or {}
    local result = {
        id = profile.id,
        name = profile.name,
        created_at = profile.created_at,
        version = profile.version,
        prefs = {
            language = nullable(prefs.language),
            theme = nullable(prefs.theme),
            palette = nullable(prefs.palette),
            favorites = prefs.favorites or Json.array(),
            hidden_rooms = prefs.hidden_rooms or Json.array(),
        },
    }
    if keyIds then
        result.key_ids = keyIds
    end
    return result
end

local function keyIdsByProfile(keys)
    local byProfile = {}
    for _, key in ipairs(keys.list()) do
        if key.profile then
            byProfile[key.profile] = byProfile[key.profile] or Json.array()
            local list = byProfile[key.profile]
            list[#list + 1] = key.id
        end
    end
    return byProfile
end

-- The caller's profile; a key without one (it should not happen) gets one now.
local function ownProfile(ctx)
    local services = ctx.services
    local key = services.keys.find(ctx.apiKey.id)
    if not key then
        return nil, Problem.new(401, "UNAUTHORIZED", "This API key is no longer valid")
    end
    local profile = key.profile and services.profiles.find(key.profile)
    if profile then
        return profile
    end
    local created, failure = services.profiles.create(key.name)
    if not created then
        return nil, Problem.new(409, failure, "This controller has as many profiles as it allows")
    end
    services.keys.update(key.id, { profile = created.id })
    return created
end

-- Checks the fields of `prefs`; returns the changes for Profiles.updatePrefs (false clears a
-- field), or nil and a problem.
local function validatePrefs(prefs, maxFavorites)
    if type(prefs) ~= "table" or prefs == Json.null or Json.isArray(prefs) then
        return nil, Problem.invalidField("prefs", "prefs must be an object")
    end
    local changes = {}
    for field, value in pairs(prefs) do
        if field == "language" then
            if value == Json.null then
                changes.language = false
            elseif value == "auto" or RoomNames.validLanguage(value) then
                changes.language = value
            else
                return nil, Problem.invalidField("prefs.language", 'language must be "auto" or a language tag such as "en" or "he"')
            end
        elseif field == "theme" then
            if value == Json.null then
                changes.theme = false
            elseif type(value) == "string" and (value == "auto" or value == "light" or value == "dark") then
                changes.theme = value
            else
                return nil, Problem.invalidField("prefs.theme", "theme must be auto, light or dark")
            end
        elseif field == "palette" then
            if value == Json.null then
                changes.palette = false
            elseif type(value) == "string" and #value <= 20 and value:match(PALETTE) then
                changes.palette = value
            else
                return nil, Problem.invalidField("prefs.palette", "palette must be a short name such as graphite or ocean")
            end
        elseif field == "favorites" then
            if type(value) ~= "table" or value == Json.null or (not Json.isArray(value) and next(value) ~= nil) then
                return nil, Problem.invalidField("prefs.favorites", 'favorites must be a list such as ["light:21", "thermostat:30"]')
            end
            if #value > maxFavorites then
                return nil, Problem.invalidField("prefs.favorites", "at most " .. maxFavorites .. " favorites")
            end
            local list, seen = Json.array(), {}
            for _, entry in ipairs(value) do
                if type(entry) ~= "string" or #entry > 40 or not entry:match(FAVORITE) then
                    return nil, Problem.invalidField("prefs.favorites", 'each favorite is "kind:id", e.g. "light:21"')
                end
                if not seen[entry] then
                    seen[entry] = true
                    list[#list + 1] = entry
                end
            end
            changes.favorites = list
        elseif field == "hidden_rooms" then
            -- The rooms this person hides from their lists (only them: the home's order is shared).
            if type(value) ~= "table" or value == Json.null or (not Json.isArray(value) and next(value) ~= nil) or #value > 1000 then
                return nil, Problem.invalidField("prefs.hidden_rooms", "hidden_rooms must be a list of room ids")
            end
            local list, seen = Json.array(), {}
            for _, id in ipairs(value) do
                if type(id) ~= "number" or id ~= math.floor(id) or id < 1 then
                    return nil, Problem.invalidField("prefs.hidden_rooms", "each hidden room is a room id")
                end
                if not seen[id] then
                    seen[id] = true
                    list[#list + 1] = id
                end
            end
            changes.hidden_rooms = list
        else
            return nil, Problem.invalidField("prefs." .. tostring(field), "Unknown preference: " .. tostring(field))
        end
    end
    return changes
end

-- The caller's own profile, with its favorites of devices removed in Composer (1.8.0, ADR-059): the
-- app shows them as removed, with Remove, until the controller drops them (src/core/favorites_gone.lua).
local function ownView(ctx, profile)
    local result = view(profile)
    result.gone_favorites = FavoritesGone.list(result.prefs.favorites, ctx.apiKey)
    return result
end

function Profiles.current(ctx)
    local profile, problem = ownProfile(ctx)
    if not profile then
        return problem
    end
    return 200, ownView(ctx, profile)
end

-- PATCH {"prefs": {"language": "he", "favorites": [...]}, "version": 3}: changes the named
-- preferences (null clears one). With `version`, it applies only if nobody changed the profile
-- since that version was read (409 VERSION_CONFLICT).
function Profiles.update(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { prefs = true, version = true }, true)
    if problem then
        return problem
    end
    if body.prefs == nil then
        return Problem.invalidField("prefs", "prefs is required")
    end
    local version = body.version
    if version ~= nil and (type(version) ~= "number" or version ~= math.floor(version) or version < 0) then
        return Problem.invalidField("version", "version must be the profile's version, a whole number")
    end
    local profile
    profile, problem = ownProfile(ctx)
    if not profile then
        return problem
    end
    local changes
    changes, problem = validatePrefs(body.prefs, ctx.services.profiles.MAX_FAVORITES)
    if not changes then
        return problem
    end
    local updated, failure = ctx.services.profiles.updatePrefs(profile.id, changes, version)
    if not updated then
        if failure == "VERSION_CONFLICT" then
            return Problem.new(409, "VERSION_CONFLICT", "The profile changed on another device; read it again", { version = profile.version })
        end
        return Problem.notFound("Profile", profile.id)
    end
    return 200, ownView(ctx, updated)
end

function Profiles.list(ctx)
    local byProfile = keyIdsByProfile(ctx.services.keys)
    local items = Json.array()
    for _, profile in ipairs(ctx.services.profiles.list()) do
        items[#items + 1] = view(profile, byProfile[profile.id] or Json.array())
    end
    return 200, { items = items }
end

-- PATCH /v1/profiles/{profileId} {"name": "Dana"} (admins).
function Profiles.rename(ctx)
    local id = tostring(ctx.params.profileId or "")
    if not id:match("^%x%x%x%x%x%x%x%x$") then
        return Problem.invalidParameter("profileId", "profileId is 8 hex characters")
    end
    local body = ctx.body
    local problem = Validate.body(body, { name = true }, true)
    if problem then
        return problem
    end
    local name, nameProblem = Validate.name(body.name, "name")
    if nameProblem then
        return nameProblem
    end
    local renamed = ctx.services.profiles.rename(id, name)
    if not renamed then
        return Problem.notFound("Profile", id)
    end
    ctx.services.log.info("auth", "profile renamed", { profile = id, by = ctx.apiKey.id })
    return 200, view(renamed, keyIdsByProfile(ctx.services.keys)[id] or Json.array())
end

return Profiles
