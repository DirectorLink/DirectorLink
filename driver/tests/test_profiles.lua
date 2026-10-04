-- Profiles (src/auth/profiles.lua, /v1/profile, /v1/profiles), the rooms each person hides, and the
-- home's room order (src/core/room_layout.lua, PUT /v1/rooms/order).

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local function start()
    local mock = Mock.startDriver()
    local key = T.pair(mock, "Chrome on Windows")
    return mock, key
end

local function createKey(mock, admin, body)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = body })
    T.eq(created.status, 201, created.body)
    return created.json
end

function tests.a_paired_device_has_its_own_empty_profile()
    local mock, key = start()
    local profile = T.http(mock, "GET", "/v1/profile", { key = key })
    T.eq(profile.status, 200)
    T.truthy(profile.json.id:match("^%x+$"))
    T.eq(profile.json.name, "Chrome on Windows")
    T.eq(profile.json.version, 0)
    T.contains(profile.body, '"favorites":[]', "an empty list, not an object")
    T.contains(profile.body, '"language":null')
    local current = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    T.eq(current.profile_id, profile.json.id)
end

function tests.preferences_are_saved_changed_and_cleared()
    local mock, key = start()
    local patch = function(body)
        return T.http(mock, "PATCH", "/v1/profile", { key = key, body = body })
    end
    local saved = patch({ prefs = { language = "he", theme = "dark", palette = "ocean", favorites = { "light:21", "thermostat:30", "light:21" } } })
    T.eq(saved.status, 200, saved.body)
    T.eq(saved.json.version, 1)
    T.eq(saved.json.prefs.language, "he")
    T.eq(saved.json.prefs.theme, "dark")
    T.same(saved.json.prefs.favorites, { "light:21", "thermostat:30" }, "duplicates dropped")
    local cleared = patch({ prefs = { theme = Json.null } })
    T.eq(cleared.json.prefs.language, "he", "untouched fields stay")
    T.truthy(cleared.json.prefs.theme == Json.null or cleared.json.prefs.theme == nil, "null clears")
    T.eq(patch({ prefs = { language = "Hebrew" } }).json.code, "INVALID_FIELD")
    T.eq(patch({ prefs = { theme = "neon" } }).json.code, "INVALID_FIELD")
    T.eq(patch({ prefs = { favorites = { "light" } } }).json.code, "INVALID_FIELD")
    T.eq(patch({ prefs = { wallpaper = "x" } }).json.code, "INVALID_FIELD", "unknown preferences are refused")
    T.eq(patch({ prefs = { language = "en" }, version = 0 }).json.code, "VERSION_CONFLICT", "changed since version 0")
    T.eq(patch({ prefs = { language = "en" }, version = cleared.json.version }).status, 200)
end

function tests.an_admin_adds_a_device_to_a_person_and_moves_keys_between_profiles()
    local mock, admin = start()
    local mine = T.http(mock, "GET", "/v1/profile", { key = admin }).json
    T.http(mock, "PATCH", "/v1/profile", { key = admin, body = { prefs = { language = "he" } } })
    local tablet = createKey(mock, admin, { name = "Tablet", profile_id = mine.id })
    T.eq(tablet.profile_id, mine.id)
    local shared = T.http(mock, "GET", "/v1/profile", { key = tablet.key }).json
    T.eq(shared.id, mine.id, "the same person")
    T.eq(shared.prefs.language, "he", "with their preferences")
    T.eq(T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "X", profile_id = "deadbeef" } }).json.code, "INVALID_FIELD")

    local guest = createKey(mock, admin, { name = "Guest phone", role = "viewer" })
    T.truthy(guest.profile_id ~= mine.id, "someone else: a new profile")
    local profiles = T.http(mock, "GET", "/v1/profiles", { key = admin }).json.items
    T.eq(#profiles, 2)
    -- The guest phone was really a second device of the admin: moving it removes its empty profile.
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. guest.id, { key = admin, body = { profile_id = mine.id } }).status, 200)
    profiles = T.http(mock, "GET", "/v1/profiles", { key = admin }).json.items
    T.eq(#profiles, 1)
    T.eq(#profiles[1].key_ids, 3)
    -- Moved into the admin's person, it has the admin's access (ADR-054).
    T.eq(T.http(mock, "GET", "/v1/profiles", { key = guest.key }).status, 200, "now one of the admin's devices")
    local viewer = createKey(mock, admin, { name = "Wall tablet", role = "viewer" })
    T.eq(T.http(mock, "GET", "/v1/profiles", { key = viewer.key }).status, 403, "only admins see everyone")
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = viewer.key, body = { prefs = { theme = "light" } } }).status, 200, "a member sets their own")

    local renamed = T.http(mock, "PATCH", "/v1/profiles/" .. mine.id, { key = admin, body = { name = "Dana" } })
    T.eq(renamed.json.name, "Dana")
    T.eq(T.http(mock, "PATCH", "/v1/profiles/deadbeef", { key = admin, body = { name = "X" } }).status, 404)
end

function tests.a_profile_goes_with_its_last_key()
    local mock, admin = start()
    local other = createKey(mock, admin, { name = "Phone" })
    T.eq(#T.http(mock, "GET", "/v1/profiles", { key = admin }).json.items, 2)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. other.id, { key = admin }).status, 204)
    T.eq(#T.http(mock, "GET", "/v1/profiles", { key = admin }).json.items, 1)
end

function tests.profiles_survive_updates_and_older_keys_get_one()
    local mock, key = start()
    T.http(mock, "PATCH", "/v1/profile", { key = key, body = { prefs = { language = "he", favorites = { "light:21" } } } })
    local before = T.http(mock, "GET", "/v1/profile", { key = key }).json
    local updated = Mock.updateDriver(mock)
    local after = T.http(updated, "GET", "/v1/profile", { key = key }).json
    T.eq(after.id, before.id)
    T.same(after.prefs.favorites, { "light:21" })

    -- A key stored by 0.11 has no profile: the next start gives it one.
    local stored = updated.persist["directorlink_api_key_hashes"]
    updated.persist["directorlink_api_key_hashes"] = stored:gsub(',?"profile":"%x+"', "")
    updated.persist["directorlink_profiles"] = nil
    local again = Mock.updateDriver(updated)
    local fresh = T.http(again, "GET", "/v1/profile", { key = key })
    T.eq(fresh.status, 200)
    T.eq(fresh.json.name, "Chrome on Windows")
    T.eq(T.http(again, "GET", "/v1/api-keys/current", { key = key }).json.profile_id, fresh.json.id)
end

function tests.the_home_room_order_and_hidden_rooms()
    local mock, admin = start()
    local ids = function(m, key)
        local list = {}
        for _, room in ipairs(T.http(m, "GET", "/v1/rooms", { key = key }).json.items) do
            list[#list + 1] = room.id
        end
        return list
    end
    local original = ids(mock, admin)
    T.truthy(#original >= 2)
    local reversed = {}
    for index = #original, 1, -1 do
        reversed[#reversed + 1] = original[index]
    end
    local put = T.http(mock, "PUT", "/v1/rooms/order", { key = admin, body = { room_ids = reversed } })
    T.eq(put.status, 200, put.body)
    T.same(ids(mock, admin), reversed)
    T.same(ids(mock, admin), reversed)
    T.eq(T.http(mock, "PUT", "/v1/rooms/order", { key = admin, body = { room_ids = { 999 } } }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "PUT", "/v1/rooms/order", { key = admin, body = { room_ids = { original[1], original[1] } } }).json.code, "INVALID_FIELD")
    -- Only the first room named: it comes first, the others keep Control4's order.
    T.eq(T.http(mock, "PUT", "/v1/rooms/order", { key = admin, body = { room_ids = { original[#original] } } }).status, 200)
    T.eq(ids(mock, admin)[1], original[#original])

    local viewer = createKey(mock, admin, { name = "Viewer", role = "viewer" })
    T.eq(T.http(mock, "PUT", "/v1/rooms/order", { key = viewer.key, body = { room_ids = original } }).status, 403)

    local updated = Mock.updateDriver(mock)
    T.eq(ids(updated, admin)[1], original[#original], "the order survives an update")
end

function tests.each_person_hides_rooms_for_themselves_only()
    local mock, admin = start()
    local guest = createKey(mock, admin, { name = "Guest", role = "member" })
    local hidden = T.http(mock, "PATCH", "/v1/profile", { key = guest.key, body = { prefs = { hidden_rooms = { 11, 11, 10 } } } })
    T.eq(hidden.status, 200, hidden.body)
    T.same(hidden.json.prefs.hidden_rooms, { 11, 10 }, "a member hides rooms for themselves")
    local mine = T.http(mock, "GET", "/v1/profile", { key = admin }).json
    T.contains(Json.encode(mine.prefs), '"hidden_rooms":[]', "nobody else is affected")
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = guest.key, body = { prefs = { hidden_rooms = { "kitchen" } } } }).json.code, "INVALID_FIELD")
    T.eq(#T.http(mock, "GET", "/v1/rooms", { key = guest.key }).json.items, #T.http(mock, "GET", "/v1/rooms", { key = admin }).json.items, "the API still lists every room")
    local updated = Mock.updateDriver(mock)
    T.same(T.http(updated, "GET", "/v1/profile", { key = guest.key }).json.prefs.hidden_rooms, { 11, 10 })
end

return tests
