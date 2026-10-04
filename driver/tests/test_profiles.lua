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
    T.eq(T.http(mock, "GET", "/v1/profiles", { key = guest.key }).status, 403, "only admins see everyone")
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = guest.key, body = { prefs = { theme = "light" } } }).status, 200, "a viewer sets their own")

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
    local guest = createKey(mock, admin, { name = "Guest", role = "viewer" })
    local hidden = T.http(mock, "PATCH", "/v1/profile", { key = guest.key, body = { prefs = { hidden_rooms = { 11, 11, 10 } } } })
    T.eq(hidden.status, 200, hidden.body)
    T.same(hidden.json.prefs.hidden_rooms, { 11, 10 }, "a viewer hides rooms for themselves")
    local mine = T.http(mock, "GET", "/v1/profile", { key = admin }).json
    T.contains(Json.encode(mine.prefs), '"hidden_rooms":[]', "nobody else is affected")
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = guest.key, body = { prefs = { hidden_rooms = { "kitchen" } } } }).json.code, "INVALID_FIELD")
    T.eq(#T.http(mock, "GET", "/v1/rooms", { key = guest.key }).json.items, #T.http(mock, "GET", "/v1/rooms", { key = admin }).json.items, "the API still lists every room")
    local updated = Mock.updateDriver(mock)
    T.same(T.http(updated, "GET", "/v1/profile", { key = guest.key }).json.prefs.hidden_rooms, { 11, 10 })
end

-- Favorites of devices removed in Composer (1.8.0, ADR-059, src/core/favorites_gone.lua): marked
-- gone by the first project read that worked without them, shown to the app as gone, dropped from
-- every profile after 7 days; never on a read that failed, nor for a device missing for a moment.

local DAY = 24 * 3600

-- The driver's clock at `day` days from now (each start loads its modules afresh).
local function clockAt(base)
    local clock = { now = base }
    local Clock = require("src.core.clock")
    Clock.now = function()
        return clock.now
    end
    return function(days)
        clock.now = base + math.floor(days * DAY)
        return clock.now
    end
end

local function refresh()
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
end

local function minute()
    require("src.core.scheduler").tick()
end

local function gone(profile)
    local entries = {}
    for _, item in ipairs(profile.gone_favorites or {}) do
        entries[#entries + 1] = item.entry
    end
    return entries
end

function tests.favorites_of_a_removed_device_are_marked_gone_then_dropped_after_seven_days()
    local mock, key = start()
    local other = createKey(mock, key, { name = "Dana's phone", role = "member" })
    local base = os.time()
    local day = clockAt(base)
    local favorites = { "camera:60", "light:20", "camera:61", "music:3" }
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = key, body = { prefs = { favorites = favorites } } }).status, 200)
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = other.key, body = { prefs = { favorites = { "camera:60" } } } }).status, 200)
    local first = T.http(mock, "GET", "/v1/profile", { key = key })
    T.contains(first.body, '"gone_favorites":[]', "an empty list while every device is there")

    -- The Driveway camera is replaced in Composer: the next project read lacks it.
    Mock.removeDevice(mock.project, 60)
    refresh()
    local profile = T.http(mock, "GET", "/v1/profile", { key = key }).json
    T.same(gone(profile), { "camera:60" })
    T.eq(profile.gone_favorites[1].name, "Driveway", "by the name it had")
    T.eq(profile.gone_favorites[1].since, os.date("!%Y-%m-%dT%H:%M:%SZ", base))
    T.same(profile.prefs.favorites, favorites, "kept for now")
    T.same(gone(T.http(mock, "GET", "/v1/profile", { key = other.key }).json), { "camera:60" }, "for everyone who has it")

    -- A read that fails (Director listing nothing while it loads a project) changes nothing; nor
    -- does a device missing for a moment (the Gate camera, back at the next read).
    local devices = mock.project.devices
    mock.project.devices = {}
    day(3)
    refresh()
    mock.project.devices = devices
    local gate = mock.project.devices[61]
    mock.project.devices[61] = nil
    refresh()
    T.same(gone(T.http(mock, "GET", "/v1/profile", { key = key }).json), { "camera:60", "camera:61" })
    mock.project.devices[61] = gate
    refresh()
    T.same(gone(T.http(mock, "GET", "/v1/profile", { key = key }).json), { "camera:60" }, "back: no longer gone")

    -- Still there after six days, through a driver update (the marks are kept).
    local updated = Mock.updateDriver(mock, mock.project)
    day = clockAt(base)
    day(6.9)
    minute()
    T.same(T.http(updated, "GET", "/v1/profile", { key = key }).json.prefs.favorites, favorites)

    -- Seven days after the read that first lacked it: dropped from every profile, at the minute's
    -- look. The Gate camera, gone for a moment on the third day, stays; an unknown kind is never touched.
    day(7)
    minute()
    local after = T.http(updated, "GET", "/v1/profile", { key = key }).json
    T.same(after.prefs.favorites, { "light:20", "camera:61", "music:3" })
    T.same(gone(after), {})
    T.eq(after.version, profile.version + 1, "a change other devices see")
    T.eq(#T.http(updated, "GET", "/v1/profile", { key = other.key }).json.prefs.favorites, 0)
    local logged = false
    for _, line in ipairs(updated.debugLog) do
        logged = logged or line:find("a favorite of a device removed in Composer was dropped", 1, true) ~= nil
    end
    T.truthy(logged)
end

-- A restart whose project read did not work has not looked at the marks: nothing is dropped, even
-- when they are old enough (the device may have come back meanwhile).
function tests.favorites_are_dropped_only_after_a_project_read_in_this_run()
    local mock, key = start()
    local base = os.time()
    clockAt(base)
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = key, body = { prefs = { favorites = { "camera:60", "light:20" } } } }).status, 200)
    Mock.removeDevice(mock.project, 60)
    refresh()
    -- Ten days later the driver starts while Director lists no devices.
    local devices = mock.project.devices
    mock.project.devices = {}
    local updated = Mock.updateDriver(mock, mock.project)
    clockAt(base)(10)
    minute()
    mock.project.devices = devices
    T.same(T.http(updated, "GET", "/v1/profile", { key = key }).json.prefs.favorites, { "camera:60", "light:20" }, "not dropped")
    -- The project read once it loads: the device is still gone, and goes.
    refresh()
    T.same(T.http(updated, "GET", "/v1/profile", { key = key }).json.prefs.favorites, { "light:20" })
end

-- The app removes a gone favorite itself (Remove): the answer no longer lists it.
function tests.removing_a_gone_favorite_takes_it_off_the_list()
    local mock, key = start()
    T.http(mock, "PATCH", "/v1/profile", { key = key, body = { prefs = { favorites = { "camera:60", "light:20" } } } })
    Mock.removeDevice(mock.project, 60)
    refresh()
    local patched = T.http(mock, "PATCH", "/v1/profile", { key = key, body = { prefs = { favorites = { "light:20" } } } })
    T.eq(patched.status, 200, patched.body)
    T.same(gone(patched.json), {})
    T.contains(patched.body, '"gone_favorites":[]')
end

return tests
