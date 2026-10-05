-- Admins and members, enforced on every request (ADR-054, src/auth/access.lua): what a member sees in
-- lists and by id, what they may change, open and run; rooms hidden from members; the person's
-- role and permissions through the API; the home's owner; the 1.7.0 store and its roles; the 1.7.0
-- role every key keeps.
--
-- The test project: Kitchen (10) has the light 20, the shutter 51, the camera 60, the doorbell 93
-- (its camera 92) and the gate relay 70; the Living Room (11) the lights 21 and 22, the thermostat
-- 30, the blind 50 and the DoorBird camera 61.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

local function start(prepare)
    local mock = Mock.startDriver(nil, nil, nil, prepare)
    local admin = T.pair(mock, "Owner's laptop")
    return mock, admin
end

local function get(mock, key, path)
    return T.http(mock, "GET", path, { key = key })
end

-- The ids of a list's items, sorted (lists are by name).
local function ids(items)
    local list = {}
    for _, item in ipairs(items or {}) do
        list[#list + 1] = item.id
    end
    table.sort(list, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return list
end

local function sorted(list)
    local copy = {}
    for index, value in ipairs(list) do
        copy[index] = value
    end
    table.sort(copy)
    return copy
end

-- A new member person with one key; `access` as PATCH /v1/profiles/{id}/access takes it.
local function member(mock, admin, access, name)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name or "Kid's phone", role = "member", access = access or {} } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json
end

local function profileOf(mock, key)
    return get(mock, key, "/v1/api-keys/current").json.profile_id
end

local function setAccess(mock, admin, profileId, body)
    return T.http(mock, "PATCH", "/v1/profiles/" .. profileId .. "/access", { key = admin, body = body })
end

function tests.lists_show_a_member_only_their_rooms_and_kinds()
    local mock, admin = start()
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, kinds = { climate = false, blind = false }, cameras = false })
    T.same(ids(get(mock, kid, "/v1/lights").json.items), { 21, 22 })
    T.same(ids(get(mock, kid, "/v1/thermostats").json.items), {}, "climate is off")
    T.same(ids(get(mock, kid, "/v1/blinds").json.items), {}, "blinds are off")
    T.same(ids(get(mock, kid, "/v1/cameras").json.items), {}, "cameras are off")
    T.same(ids(get(mock, kid, "/v1/relays").json.items), {}, "the gate is in the kitchen")
    T.same(ids(get(mock, kid, "/v1/doorbells").json.items), {}, "so is the doorbell")
    T.same(ids(get(mock, kid, "/v1/rooms").json.items), { 11 })
    T.eq(get(mock, kid, "/v1/rooms").json.items[1].device_count, 2, "only the devices they see")
    for _, device in ipairs(get(mock, kid, "/v1/devices").json.items) do
        T.eq(device.room ~= Json.null and device.room.id, 11, "every device listed is in their room")
        T.truthy(device.type ~= "thermostat" and device.type ~= "blind" and device.type ~= "camera", device.type)
    end
    -- The admin still sees everything.
    T.same(ids(get(mock, admin, "/v1/lights").json.items), { 20, 21, 22 })
    T.same(ids(get(mock, admin, "/v1/rooms").json.items), { 10, 11 })
end

function tests.a_device_a_member_may_not_see_answers_as_one_that_does_not_exist()
    local mock, admin = start()
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 } })
    local hidden = get(mock, kid, "/v1/lights/20")
    local missing = get(mock, kid, "/v1/lights/29")
    T.eq(hidden.status, 404)
    T.eq(hidden.json.code, missing.json.code)
    T.eq(hidden.json.detail:gsub("20", "29"), missing.json.detail, "the same words as for a light that is not there")
    T.eq(T.http(mock, "PATCH", "/v1/lights/20", { key = kid, body = { on = true } }).status, 404)
    T.eq(get(mock, kid, "/v1/devices/20").status, 404)
    T.eq(get(mock, kid, "/v1/rooms/10").status, 404)
    T.eq(get(mock, kid, "/v1/cameras/60").status, 404)
    T.eq(get(mock, kid, "/v1/cameras/60/snapshot").status, 404)
    T.eq(get(mock, kid, "/v1/relays/70").status, 404)
    T.eq(get(mock, kid, "/v1/doorbells/93").status, 404)
    T.eq(get(mock, kid, "/v1/lights/21").status, 200)
    T.eq(T.http(mock, "PATCH", "/v1/lights/21", { key = kid, body = { on = true } }).status, 202)
end

function tests.a_kind_switched_off_is_hidden_and_refused()
    local mock, admin = start()
    local kid = member(mock, admin, { kinds = { light = false } })
    T.eq(#get(mock, kid, "/v1/lights").json.items, 0)
    local before = #mock.commands
    T.eq(T.http(mock, "PATCH", "/v1/lights/21", { key = kid, body = { on = true } }).status, 404)
    T.eq(#mock.commands, before, "nothing reaches the light")
    T.eq(T.http(mock, "PATCH", "/v1/thermostats/30", { key = kid, body = { mode = "cool" } }).status, 202, "climate is on")
    T.eq(T.http(mock, "POST", "/v1/blinds/50/stop", { key = kid }).status, 202)
end

function tests.doors_and_gates_open_only_for_members_given_them()
    local mock, admin = start()
    Properties["Door Control"] = "Enabled"
    local kid = member(mock, admin, { doors = false })
    local teen = member(mock, admin, { doors = true }, "Teen's phone")
    T.eq(get(mock, kid, "/v1/relays/70").status, 200, "the gate's state is seen")
    local refused = T.http(mock, "POST", "/v1/relays/70/pulse", { key = kid })
    T.eq(refused.status, 403, "seen, not theirs to open: 403")
    T.eq(refused.json.code, "FORBIDDEN")
    T.eq(T.http(mock, "PATCH", "/v1/relays/70", { key = kid, body = { state = "open" } }).json.code, "FORBIDDEN")
    T.eq(T.http(mock, "POST", "/v1/doorbells/93/open", { key = kid }).json.code, "FORBIDDEN")
    T.eq(T.http(mock, "POST", "/v1/relays/70/pulse", { key = teen }).status, 202)
    T.eq(T.http(mock, "POST", "/v1/doorbells/93/open", { key = teen }).status, 202)
    Properties["Door Control"] = "Disabled"
    T.eq(T.http(mock, "POST", "/v1/relays/70/pulse", { key = teen }).json.code, "DOOR_CONTROL_DISABLED", "Door Control in Composer still decides")
    -- Only in their rooms.
    Properties["Door Control"] = "Enabled"
    T.eq(setAccess(mock, admin, profileOf(mock, teen), { all_rooms = false, rooms = { 11 } }).status, 200)
    T.eq(T.http(mock, "POST", "/v1/relays/70/pulse", { key = teen }).status, 404)
end

function tests.cameras_and_a_doorbells_picture_need_cameras()
    local mock, admin = start()
    local kid = member(mock, admin, { cameras = false })
    T.eq(#get(mock, kid, "/v1/cameras").json.items, 0)
    T.eq(get(mock, kid, "/v1/cameras/60/snapshot").status, 404)
    local bell = get(mock, kid, "/v1/doorbells/93")
    T.eq(bell.status, 200, "the doorbell (its rings) is theirs")
    T.eq(bell.json.camera, Json.null, "not its picture")
    T.eq(get(mock, kid, "/v1/cameras/92/snapshot").status, 404)
    T.eq(setAccess(mock, admin, profileOf(mock, kid), { cameras = true }).status, 200)
    T.same(ids(get(mock, kid, "/v1/cameras").json.items), { 60, 61, 92 })
    T.eq(get(mock, kid, "/v1/doorbells/93").json.camera.id, 92)
    T.eq(get(mock, kid, "/v1/cameras/60/snapshot").status, 200)
end

function tests.the_alarms_status_is_for_members_given_it()
    local mock, admin = start()
    Properties["Alarm Status"] = "On"
    local kid = member(mock, admin, { alarm = false })
    local mom = member(mock, admin, {}, "Mom's phone")
    local refused = get(mock, kid, "/v1/alarm")
    T.eq(refused.status, 403)
    T.eq(refused.json.code, "FORBIDDEN")
    T.eq(get(mock, mom, "/v1/alarm").json.code, "SEALED_REQUEST_REQUIRED", "allowed, and still only sealed")
    Properties["Alarm Status"] = "Off"
    T.eq(get(mock, kid, "/v1/alarm").json.enabled, false, "off for everyone")
end

local function scene(mock, admin, body)
    local created = T.http(mock, "POST", "/v1/scenes", { key = admin, body = body })
    T.eq(created.status, 201, created.body)
    return created.json.id
end

function tests.a_member_lists_and_runs_only_the_scenes_chosen_for_them_and_never_edits_one()
    local mock, admin = start()
    local lights = scene(mock, admin, { name = "Evening", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } })
    local other = scene(mock, admin, { name = "Away", steps = { { type = "lights", set = { on = false } } } })
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, kinds = { light = false }, scenes = { lights } })
    T.same(ids(get(mock, kid, "/v1/scenes").json.items), { lights })
    T.eq(get(mock, kid, "/v1/scenes/" .. other).status, 404)
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. other .. "/run", { key = kid }).status, 404)
    -- In full: the kitchen light, in a room that is not theirs, of a kind they do not have.
    local before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/" .. lights .. "/run", { key = kid })
    T.eq(ran.status, 202)
    T.eq(ran.json.ran, 1)
    T.eq(mock.commands[before + 1].device, 20)
    T.eq(T.http(mock, "POST", "/v1/scenes", { key = kid, body = { name = "Mine", steps = {} } }).status, 403)
    T.eq(T.http(mock, "PATCH", "/v1/scenes/" .. lights, { key = kid, body = { name = "x" } }).status, 403)
    T.eq(T.http(mock, "DELETE", "/v1/scenes/" .. lights, { key = kid }).status, 403)
    T.eq(T.http(mock, "POST", "/v1/scenes/try", { key = kid, body = { steps = {} } }).status, 403)
    T.same(ids(get(mock, admin, "/v1/scenes").json.items), sorted({ lights, other }), "admins see every scene")
end

function tests.a_scene_a_member_may_run_opens_its_doors_but_directorlink_itself_never_does()
    local mock, admin = start()
    Properties["Door Control"] = "Enabled"
    local gate = scene(mock, admin, { name = "Open the gate", steps = { { type = "relays", device_ids = { 70 }, set = { action = "pulse" } } } })
    local kid = member(mock, admin, { doors = false, scenes = { gate } })
    local ran = T.http(mock, "POST", "/v1/scenes/" .. gate .. "/run", { key = kid })
    T.eq(ran.json.ran, 1, "the admin chose it: it runs in full")
    local Handlers = require("src.api.handlers.scenes")
    local Services = { registry = require("src.core.registry"), adapters = require("src.adapters.manager"), log = require("src.core.log"), doorControlEnabled = function()
        return true
    end }
    local scheduled = Handlers.runSaved(Services, gate, { id = "schedule:1a2b3c4d", role = "member" })
    T.eq(scheduled.ran, 0)
    T.eq(scheduled.problems[1].code, "FORBIDDEN", "a schedule never opens doors")
end

function tests.schedules_history_keys_and_settings_are_the_admins()
    local mock, admin = start()
    local kid = member(mock, admin, {})
    local profile = profileOf(mock, admin)
    for _, route in ipairs({
        { "GET", "/v1/schedules" }, { "GET", "/v1/schedules/1a2b3c4d" }, { "GET", "/v1/activity" }, { "GET", "/v1/api-keys" },
        { "GET", "/v1/invitations" }, { "GET", "/v1/profiles" }, { "GET", "/v1/profiles/" .. profile .. "/access" },
        { "PUT", "/v1/rooms/order", { room_ids = { 11, 10 } } }, { "PATCH", "/v1/rooms/10", { names = { en = "x" } } },
        { "GET", "/v1/backup" }, { "GET", "/v1/logs" }, { "PATCH", "/v1/calendar/settings", {} }, { "GET", "/v1/scene-links" },
    }) do
        local answer = T.http(mock, route[1], route[2], { key = kid, body = route[3] })
        T.eq(answer.status, 403, route[1] .. " " .. route[2])
        T.eq(answer.json.code, "FORBIDDEN")
    end
    T.eq(get(mock, admin, "/v1/schedules").status, 200)
end

function tests.turn_off_all_names_only_what_the_member_controls()
    local mock, admin = start()
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, kinds = { climate = false } })
    local off = T.http(mock, "POST", "/v1/off", { key = kid, body = { type = "lights", device_ids = { 21, 22 } } })
    T.eq(off.status, 202)
    T.eq(off.json.ran, 2)
    local before = #mock.commands
    local kitchen = T.http(mock, "POST", "/v1/off", { key = kid, body = { type = "lights", device_ids = { 21, 20 } } })
    T.eq(kitchen.status, 400, "a light that is not theirs, like one that is not there")
    T.eq(T.http(mock, "POST", "/v1/off", { key = kid, body = { type = "lights", device_ids = { 29 } } }).json.detail:gsub("29", "20"), kitchen.json.detail)
    T.eq(T.http(mock, "POST", "/v1/off", { key = kid, body = { type = "climate", device_ids = { 30 } } }).status, 400, "climate is off")
    T.eq(#mock.commands, before, "nothing is turned off")
end

function tests.a_room_hidden_from_members_disappears_for_every_member()
    local mock, admin = start()
    local kid = member(mock, admin, {})
    local friend = member(mock, admin, { all_rooms = false, rooms = { 10, 11 } }, "Friend's phone")
    local hidden = T.http(mock, "PATCH", "/v1/rooms/10", { key = admin, body = { hidden_from_members = true } })
    T.eq(hidden.status, 200, hidden.body)
    T.eq(hidden.json.hidden_from_members, true)
    local rooms = get(mock, admin, "/v1/rooms").json.items
    T.same(ids(rooms), { 10, 11 }, "admins still see it")
    T.eq(rooms[1].hidden_from_members, true)
    T.eq(rooms[2].hidden_from_members, false)
    for _, key in ipairs({ kid, friend }) do
        T.same(ids(get(mock, key, "/v1/rooms").json.items), { 11 })
        T.same(ids(get(mock, key, "/v1/lights").json.items), { 21, 22 })
        T.eq(get(mock, key, "/v1/lights/20").status, 404)
        T.eq(#get(mock, key, "/v1/relays").json.items, 0)
    end
    T.eq(#get(mock, kid, "/v1/api-keys/current").json.access.rooms, 0, "every room but that one")
    T.same(get(mock, friend, "/v1/api-keys/current").json.access.rooms, { 11 })
    T.eq(T.http(mock, "PATCH", "/v1/rooms/10", { key = admin, body = { hidden_from_members = "yes" } }).status, 400)
    T.eq(T.http(mock, "PATCH", "/v1/rooms/10", { key = admin, body = {} }).status, 400)
    local history = get(mock, admin, "/v1/activity?kind=access").json.items
    T.eq(history[1].action, "room_hidden")
    T.eq(history[1].what, "Kitchen")
    T.eq(T.http(mock, "PATCH", "/v1/rooms/10", { key = admin, body = { hidden_from_members = false } }).json.hidden_from_members, false)
    T.same(ids(get(mock, kid, "/v1/lights").json.items), { 20, 21, 22 })
end

function tests.the_caller_learns_what_it_may_do()
    local mock, admin = start()
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, kinds = { music = false }, doors = true })
    local me = get(mock, kid, "/v1/api-keys/current").json
    T.eq(me.role, "doors", "the 1.7.0 role the key keeps")
    T.eq(me.access.role, "member")
    T.eq(me.access.owner, false)
    T.eq(me.access.all_rooms, false)
    T.same(me.access.rooms, { 11 })
    T.eq(me.access.kinds.music, false)
    T.eq(me.access.kinds.light, true)
    T.eq(me.access.doors, true)
    T.same(get(mock, kid, "/v1/profile").json.access, me.access)
    local mine = get(mock, admin, "/v1/api-keys/current").json.access
    T.eq(mine.role, "admin")
    T.eq(mine.owner, true, "the first admin is the owner")
    T.eq(mine.doors, true)
    T.eq(mine.cameras, true)
    T.eq(get(mock, admin, "/v1/system").json.features.people_permissions, true)
end

function tests.an_admin_sets_a_persons_role_and_permissions_for_all_their_devices()
    local mock, admin = start()
    local living = scene(mock, admin, { name = "Movie", steps = { { type = "lights", device_ids = { 21 }, set = { on = false } } } })
    local phone, created = member(mock, admin, {})
    local profile = created.profile_id
    local tablet = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Kid's tablet", profile_id = profile } }).json.key
    local changed = setAccess(mock, admin, profile, { all_rooms = false, rooms = { 11 }, kinds = { light = true, climate = false }, scenes = { living }, alarm = false })
    T.eq(changed.status, 200, changed.body)
    T.eq(changed.json.role, "member")
    T.same(changed.json.rooms, { 11 })
    T.same(changed.json.scenes, { living })
    T.eq(changed.json.kinds.climate, false)
    T.eq(changed.json.kinds.fan, true, "the kinds not sent stay")
    for _, key in ipairs({ phone, tablet }) do
        T.same(ids(get(mock, key, "/v1/lights").json.items), { 21, 22 })
        T.eq(#get(mock, key, "/v1/thermostats").json.items, 0)
        T.same(ids(get(mock, key, "/v1/scenes").json.items), { living })
    end
    T.eq(setAccess(mock, admin, profile, {}).status, 400, "nothing to change")
    T.eq(setAccess(mock, admin, profile, { rooms = { 99 } }).json.code, "INVALID_FIELD")
    T.eq(setAccess(mock, admin, profile, { scenes = { "00000000" } }).json.code, "INVALID_FIELD")
    T.eq(setAccess(mock, admin, profile, { kinds = { heater = true } }).json.code, "INVALID_FIELD")
    T.eq(setAccess(mock, admin, profile, { role = "viewer" }).json.code, "INVALID_FIELD")
    T.eq(setAccess(mock, admin, profile, { colour = "red" }).json.code, "INVALID_FIELD")
    T.eq(setAccess(mock, admin, "00000000", { doors = true }).status, 404)
    T.eq(get(mock, admin, "/v1/profiles/" .. profile .. "/access").json.alarm, false)
    -- Every person with their role, in the list admins read.
    for _, item in ipairs(get(mock, admin, "/v1/profiles").json.items) do
        T.eq(item.access.role, item.id == profile and "member" or "admin")
    end
    -- Made an admin: everything, at once.
    T.eq(setAccess(mock, admin, profile, { role = "admin" }).json.role, "admin")
    T.same(ids(get(mock, tablet, "/v1/lights").json.items), { 20, 21, 22 })
    T.eq(get(mock, tablet, "/v1/api-keys").status, 200)
    local history = get(mock, admin, "/v1/activity?kind=access").json.items
    T.eq(history[1].action, "role_changed")
    T.eq(history[1].from, "member")
    T.eq(history[1].to, "admin")
    T.eq(history[2].action, "permissions_changed")
end

function tests.each_key_keeps_the_1_7_role_of_its_person()
    local mock, admin = start()
    local _, created = member(mock, admin, {})
    local profile = created.profile_id
    local function role()
        for _, key in ipairs(get(mock, admin, "/v1/api-keys").json.items) do
            if key.id == created.id then
                return key.role
            end
        end
    end
    T.eq(role(), "member")
    setAccess(mock, admin, profile, { doors = true })
    T.eq(role(), "doors")
    setAccess(mock, admin, profile, { all_rooms = false, rooms = {} })
    T.eq(role(), "viewer", "no rooms")
    setAccess(mock, admin, profile, { role = "admin" })
    T.eq(role(), "admin")
    local stored = Json.decode(mock.persist["directorlink_api_key_hashes"]:sub(6))
    for _, key in ipairs(stored.keys) do
        if key.id == created.id then
            T.eq(key.role, "admin", "kept in the keys' store, which 1.7.0 reads")
        end
    end
end

function tests.the_owner_is_never_demoted_or_removed_by_another_admin()
    local mock, owner = start()
    local ownerProfile = profileOf(mock, owner)
    local ownerKey = get(mock, owner, "/v1/api-keys/current").json.id
    local other = T.http(mock, "POST", "/v1/api-keys", { key = owner, body = { name = "Partner's phone", role = "admin" } }).json
    local otherProfile = other.profile_id
    local kidKey, kid = member(mock, owner, {})

    local demote = setAccess(mock, other.key, ownerProfile, { role = "member" })
    T.eq(demote.status, 403)
    T.eq(demote.json.code, "OWNER_PROTECTED")
    T.eq(setAccess(mock, other.key, ownerProfile, { doors = false }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. ownerKey, { key = other.key }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. ownerKey, { key = other.key, body = { role = "member" } }).json.code, "OWNER_PROTECTED", "nor with a 1.7.0 role")
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. ownerKey, { key = other.key, body = { profile_id = otherProfile } }).json.code, "OWNER_PROTECTED", "nor moved away")
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. other.id, { key = other.key, body = { profile_id = ownerProfile } }).json.code, "OWNER_PROTECTED", "nor anyone moved into the owner")
    T.eq(get(mock, owner, "/v1/api-keys/current").json.access.role, "admin")

    local self = setAccess(mock, owner, ownerProfile, { role = "member" })
    T.eq(self.status, 409)
    T.eq(self.json.code, "OWNER_STAYS_ADMIN")
    -- The owner decides about the other admins, and the rest stays as before.
    T.eq(setAccess(mock, owner, otherProfile, { role = "member" }).status, 200)
    T.eq(get(mock, other.key, "/v1/api-keys").status, 403)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. kid.id, { key = owner }).status, 204)
    T.eq(get(mock, kidKey, "/v1/lights").status, 401)
end

function tests.there_is_always_an_admin()
    local mock, owner = start()
    local ownerKey = get(mock, owner, "/v1/api-keys/current").json.id
    local _, kid = member(mock, owner, {})
    local moved = T.http(mock, "PATCH", "/v1/api-keys/" .. ownerKey, { key = owner, body = { profile_id = kid.profile_id } })
    T.eq(moved.status, 409, "the only admin's only device would be a member's")
    T.eq(moved.json.code, "LAST_ADMIN")
end

-- The 1.7.0 store: keys with four roles and profiles, no people. Made by this driver, then the
-- people's store is removed, as 1.7.0 never wrote it.
local function oldHome()
    local mock, admin = start()
    local plain = scene(mock, admin, { name = "Evening", steps = { { type = "lights", set = { on = true } } } })
    local gate = scene(mock, admin, { name = "Gate", steps = { { type = "relays", device_ids = { 70 }, set = { action = "pulse" } } } })
    local keys = { admin = admin }
    for _, role in ipairs({ "viewer", "member", "doors" }) do
        keys[role] = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role .. " phone", role = role } }).json.key
    end
    mock.persist["directorlink_people"] = nil
    return mock, keys, plain, gate
end

function tests.a_1_7_store_becomes_people_as_their_roles_were()
    local before, keys, plain, gate = oldHome()
    local mock = Mock.updateDriver(before)
    T.truthy(mock.persist["directorlink_people"], "the people are saved once worked out")
    local function access(role)
        return get(mock, keys[role], "/v1/api-keys/current").json
    end
    local admin = access("admin")
    T.eq(admin.role, "admin")
    T.eq(admin.access.role, "admin")
    T.eq(admin.access.owner, true)
    local doors = access("doors")
    T.eq(doors.role, "doors", "the key keeps its role")
    T.eq(doors.access.role, "member")
    T.eq(doors.access.all_rooms, true)
    T.eq(doors.access.doors, true)
    T.eq(doors.access.cameras, true)
    T.eq(doors.access.alarm, true)
    T.same(doors.access.scenes, sorted({ plain, gate }), "every scene there was")
    local member = access("member")
    T.eq(member.role, "member")
    T.eq(member.access.doors, false)
    T.same(member.access.scenes, { plain }, "every scene but the one that opens a door")
    local viewer = access("viewer")
    T.eq(viewer.role, "viewer")
    T.eq(viewer.access.all_rooms, false)
    T.eq(#viewer.access.rooms, 0)
    T.eq(viewer.access.cameras, true)
    T.eq(viewer.access.alarm, false)
    for _, on in pairs(viewer.access.kinds) do
        T.eq(on, false)
    end
    -- What each can do now.
    T.eq(#get(mock, keys.viewer, "/v1/lights").json.items, 0, "a viewer has no rooms until an admin gives some")
    T.eq(#get(mock, keys.viewer, "/v1/cameras").json.items, 0)
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. plain .. "/run", { key = keys.member }).status, 202)
    T.eq(T.http(mock, "POST", "/v1/scenes/" .. gate .. "/run", { key = keys.member }).status, 404)
    T.eq(T.http(mock, "PATCH", "/v1/lights/20", { key = keys.member, body = { on = true } }).status, 202)
end

function tests.a_person_whose_keys_1_7_changed_is_read_again_from_them()
    local before, keys = oldHome()
    local mock = Mock.updateDriver(before)
    local memberId = get(mock, keys.member, "/v1/api-keys/current").json.id
    T.eq(get(mock, keys.member, "/v1/api-keys/current").json.access.doors, false)
    -- Back on 1.7.0, an admin gave that key the doors role; then 1.8.0 again.
    local stored = Json.decode(mock.persist["directorlink_api_key_hashes"]:sub(6))
    for _, key in ipairs(stored.keys) do
        if key.id == memberId then
            key.role = "doors"
        end
    end
    mock.persist["directorlink_api_key_hashes"] = "json:" .. Json.encode(stored)
    local again = Mock.updateDriver(mock)
    local me = get(again, keys.member, "/v1/api-keys/current").json
    T.eq(me.role, "doors")
    T.eq(me.access.doors, true, "what was decided last wins")
    -- A person 1.7.0 left alone keeps what 1.8.0 gave them.
    T.eq(get(again, keys.viewer, "/v1/api-keys/current").json.access.cameras, true)
end

function tests.clients_of_1_7_set_roles_as_they_did()
    local mock, admin = start()
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Old app", role = "viewer" } }).json
    T.eq(created.role, "viewer")
    local patched = T.http(mock, "PATCH", "/v1/api-keys/" .. created.id, { key = admin, body = { role = "doors" } })
    T.eq(patched.status, 200, patched.body)
    T.eq(patched.json.role, "doors")
    local access = get(mock, admin, "/v1/profiles/" .. created.profile_id .. "/access").json
    T.eq(access.doors, true)
    T.eq(access.all_rooms, true)
    -- A member's own choices stay when the role is the one the key has already.
    setAccess(mock, admin, created.profile_id, { all_rooms = false, rooms = { 11 }, doors = false })
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. created.id, { key = admin, body = { role = "member" } }).json.role, "member")
    T.same(get(mock, admin, "/v1/profiles/" .. created.profile_id .. "/access").json.rooms, { 11 })
    T.eq(T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "x", role = "viewer", access = {} } }).json.code, "INVALID_FIELD", "access goes with admin or member")
    T.eq(T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "x", profile_id = created.profile_id, access = {} } }).json.code, "INVALID_FIELD", "another device has its person's")
end

-- ---- invitations and claims, through the fake relay ---------------------------------------------

local function Lock()
    return require("src.cloud.lock")
end

local counter = 0

local function session()
    local mock, key = start()
    local _, connection = Harness.connected({ mock = mock })
    local me = get(mock, key, "/v1/api-keys/current").json
    local remote = get(mock, key, "/v1/remote").json
    return { mock = mock, connection = connection, key = key, keyId = me.id, home = remote.home_id }
end

local function send(s, message)
    return Harness.relayRequest(s.mock, s.connection, message)
end

local function join(s, invitation, name)
    local lock = Lock().invitationKey(invitation.secret)
    counter = counter + 1
    local request = { id = "join-" .. counter, ts = os.time(), method = "POST", path = "/v1/auth/join", body = { name = name } }
    local envelope = Lock().seal(lock, s.home, invitation.id, "req", Json.encode(request))
    local reply = send(s, { type = "join", id = "relay-join-" .. counter, invitation = invitation.id, envelope = envelope })
    return Json.decode(Json.decode(Lock().open(lock, reply.envelope, "res")).body)
end

function tests.an_invitation_carries_the_role_and_permissions()
    local s = session()
    local created = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", access = { all_rooms = false, rooms = { 11 }, cameras = false } } })
    T.eq(created.status, 201, created.body)
    T.eq(created.json.role, "member", "the 1.7.0 role it becomes")
    T.eq(created.json.access.role, "member")
    T.same(created.json.access.rooms, { 11 })
    T.same(get(s.mock, s.key, "/v1/invitations").json.items[1].access.rooms, { 11 })
    local key = join(s, created.json, "Grandma's iPhone")
    local me = get(s.mock, key.key, "/v1/api-keys/current").json
    T.eq(me.access.role, "member")
    T.same(me.access.rooms, { 11 })
    T.eq(me.access.cameras, false)
    T.same(ids(get(s.mock, key.key, "/v1/lights").json.items), { 21, 22 })
    -- A 1.7.0 app's roles keep working.
    local viewer = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer" } }).json
    T.eq(viewer.role, "viewer")
    T.eq(viewer.access.all_rooms, false)
    local admin = join(s, T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "admin" } }).json, "Partner")
    T.eq(get(s.mock, admin.key, "/v1/api-keys/current").json.access.role, "admin")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "doors", access = {} } }).json.code, "INVALID_FIELD")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", for_me = true, access = {} } }).json.code, "INVALID_FIELD")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", access = { rooms = { 99 } } } }).json.code, "INVALID_FIELD")
end

function tests.whoever_claims_the_home_is_its_owner_and_only_they_claim_it_again()
    local s = session()
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner's laptop", role = "admin" } }).json
    T.eq(get(s.mock, s.key, "/v1/api-keys/current").json.access.owner, true, "the oldest admin, until someone claims the home")
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = partner.key })
    T.eq(claim.status, 201)
    T.eq(send(s, { type = "claim", id = "c1", token = claim.json.claim_token }).ok, true)
    T.eq(get(s.mock, partner.key, "/v1/api-keys/current").json.access.owner, true)
    T.eq(get(s.mock, s.key, "/v1/api-keys/current").json.access.owner, false)
    T.eq(setAccess(s.mock, s.key, partner.profile_id, { role = "member" }).json.code, "OWNER_PROTECTED")
    local again = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(again.status, 403)
    T.eq(again.json.code, "OWNER_ONLY")
    T.eq(T.http(s.mock, "POST", "/v1/remote/claim", { key = partner.key }).status, 201)
    -- Survives a restart.
    local restarted = Mock.updateDriver(s.mock)
    T.eq(get(restarted, partner.key, "/v1/api-keys/current").json.access.owner, true)
end

function tests.the_relay_learns_the_keys_of_admin_people()
    local s = session()
    local _, kid = member(s.mock, s.key, {})
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner", role = "admin" } }).json
    -- The admins the driver announced last (docs/RELAY.md: keys).
    local function admins()
        local last
        for _, frame in ipairs(Harness.clientFrames(s.connection.sent)) do
            local message = Json.decode(frame.payload)
            if type(message) == "table" and message.type == "keys" then
                last = message.admins
            end
        end
        s.connection.sent = ""
        return last
    end
    s.connection.sent = ""
    setAccess(s.mock, s.key, kid.profile_id, { doors = true })
    local listed = admins()
    table.sort(listed)
    local expected = { s.keyId, partner.id }
    table.sort(expected)
    T.same(listed, expected, "a member's keys are not admin keys")
    setAccess(s.mock, s.key, kid.profile_id, { role = "admin" })
    T.eq(#admins(), 3, "made an admin, their keys are")
end

-- ---- the owner's person is the owner's (review of 1.8.0) ---------------------------------------

local function keyCount(mock, admin)
    return #get(mock, admin, "/v1/api-keys").json.items
end

-- Another admin never gets a key into the owner's person: with it they would be the owner, revoke
-- the owner's devices and claim the home.
function tests.another_admin_puts_no_key_into_the_owners_person()
    local s = session()
    local ownerProfile = profileOf(s.mock, s.key)
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(send(s, { type = "claim", id = "c1", token = claim.json.claim_token }).ok, true)
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner", role = "admin" } }).json
    local before = keyCount(s.mock, s.key)
    local sneaky = T.http(s.mock, "POST", "/v1/api-keys", { key = partner.key, body = { name = "Owner's tablet", profile_id = ownerProfile } })
    T.eq(sneaky.status, 403, sneaky.body)
    T.eq(sneaky.json.code, "OWNER_PROTECTED")
    T.eq(keyCount(s.mock, s.key), before, "no key was made")
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. s.keyId, { key = partner.key }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(s.mock, "POST", "/v1/remote/claim", { key = partner.key }).json.code, "OWNER_ONLY")
    -- Their own person, and a member's, they still add devices to; the owner adds to the owner's.
    T.eq(T.http(s.mock, "POST", "/v1/api-keys", { key = partner.key, body = { name = "Partner's tablet", profile_id = partner.profile_id } }).status, 201)
    local _, kid = member(s.mock, s.key, {})
    T.eq(T.http(s.mock, "POST", "/v1/api-keys", { key = partner.key, body = { name = "Kid's tablet", profile_id = kid.profile_id } }).status, 201)
    local mine = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Owner's tablet", profile_id = ownerProfile } })
    T.eq(mine.status, 201)
    T.eq(get(s.mock, mine.json.key, "/v1/api-keys/current").json.access.owner, true)
end

-- An invitation for its maker's other device (Add my other device, a device's join approved)
-- puts the device into the maker's person only while the maker may: one whose key left the owner's
-- person no longer adds to it.
function tests.an_invitation_joins_the_owners_person_only_while_its_maker_is_the_owner()
    local s = session()
    local ownerProfile = profileOf(s.mock, s.key)
    local phone = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Owner's phone", profile_id = ownerProfile } }).json
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner", role = "admin" } }).json
    local invitation = T.http(s.mock, "POST", "/v1/invitations", { key = phone.key, body = { role = "admin", for_me = true } })
    T.eq(invitation.status, 201, invitation.body)
    -- The phone now is the partner's.
    T.eq(T.http(s.mock, "PATCH", "/v1/api-keys/" .. phone.id, { key = s.key, body = { profile_id = partner.profile_id } }).status, 200)
    local before = keyCount(s.mock, s.key)
    local lock = Lock().invitationKey(invitation.json.secret)
    local request = { id = "join-owner", ts = os.time(), method = "POST", path = "/v1/auth/join", body = { name = "Tablet" } }
    local envelope = Lock().seal(lock, s.home, invitation.json.id, "req", Json.encode(request))
    local reply = send(s, { type = "join", id = "relay-join-owner", invitation = invitation.json.id, envelope = envelope })
    T.eq(reply.ok, false)
    T.eq(reply.code, "INVITATION_NOT_FOUND")
    T.eq(keyCount(s.mock, s.key), before, "no key was made")
    T.eq(#get(s.mock, s.key, "/v1/invitations").json.items, 0, "and the invitation went")
    -- The owner's own invitation for their other device still works.
    local own = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "admin", for_me = true } }).json
    local joined = join(s, own, "Owner's tablet")
    T.eq(get(s.mock, joined.key, "/v1/api-keys/current").json.access.owner, true)
end

-- Before anyone claimed the home with 1.8.0 the owner is the oldest admin: another admin may not
-- make an older person an admin (they would be the owner, holding a key the other admin made).
function tests.only_the_owner_makes_an_admin_who_would_be_the_owner()
    local mock, owner = start()
    local partner = T.http(mock, "POST", "/v1/api-keys", { key = owner, body = { name = "Partner", role = "admin" } }).json
    local _, kid = member(mock, owner, {})
    -- The kid's person is older than everyone's (made by 1.7.0 long ago).
    local stored = Json.decode(mock.persist["directorlink_profiles"]:sub(6))
    for _, profile in ipairs(stored.profiles) do
        if profile.id == kid.profile_id then
            profile.created_at = "2020-01-01T00:00:00Z"
        end
    end
    mock.persist["directorlink_profiles"] = "json:" .. Json.encode(stored)
    mock = Mock.updateDriver(mock)
    T.eq(get(mock, owner, "/v1/api-keys/current").json.access.owner, true)
    -- The partner adds a device of theirs to the kid, then tries to make the kid an admin.
    local planted = T.http(mock, "POST", "/v1/api-keys", { key = partner.key, body = { name = "Kid's tablet", profile_id = kid.profile_id } })
    T.eq(planted.status, 201)
    local promoted = setAccess(mock, partner.key, kid.profile_id, { role = "admin" })
    T.eq(promoted.status, 403, promoted.body)
    T.eq(promoted.json.code, "OWNER_PROTECTED")
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. kid.id, { key = partner.key, body = { role = "admin" } }).json.code, "OWNER_PROTECTED", "nor with a 1.7.0 role")
    T.eq(get(mock, planted.json.key, "/v1/api-keys/current").json.access.role, "member")
    -- The owner may: the kid is then the owner.
    T.eq(setAccess(mock, owner, kid.profile_id, { role = "admin" }).status, 200)
    T.eq(get(mock, planted.json.key, "/v1/api-keys/current").json.access.owner, true)
    -- Someone younger the partner may make an admin.
    local _, friend = member(mock, owner, {}, "Friend")
    T.eq(setAccess(mock, partner.key, friend.profile_id, { role = "admin" }).status, 200)
end

-- ---- when a store cannot be read ---------------------------------------------------------------

-- The people's store unreadable at a start: a key answers as its 1.7.0 role, never more: a member
-- key runs scenes but the doors in them stay shut, as 1.7.0 did.
function tests.while_the_people_cannot_be_read_a_member_key_opens_no_door_through_a_scene()
    local mock, admin = start()
    Properties["Door Control"] = "Enabled"
    local gate = scene(mock, admin, { name = "Gate", steps = { { type = "relays", device_ids = { 70 }, set = { action = "pulse" } }, { type = "lights", device_ids = { 21 }, set = { on = true } } } })
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, doors = false })
    local doors = member(mock, admin, { doors = true, scenes = { gate } }, "Doors phone")
    mock.persist["directorlink_people"] = "json:{broken"
    local again = Mock.updateDriver(mock)
    Properties["Door Control"] = "Enabled"
    T.eq(get(again, kid, "/v1/api-keys/current").json.role, "member")
    local before = #again.commands
    local ran = T.http(again, "POST", "/v1/scenes/" .. gate .. "/run", { key = kid })
    T.eq(ran.status, 202, "every scene, as 1.7.0's member role")
    T.eq(ran.json.ran, 1, "the light")
    T.eq(ran.json.problems[1].code, "FORBIDDEN", "the gate stays shut")
    for index = before + 1, #again.commands do
        T.truthy(again.commands[index].device ~= 70, "no command to the gate")
    end
    T.eq(T.http(again, "POST", "/v1/scenes/" .. gate .. "/run", { key = doors }).json.ran, 2, "a doors key opened them in 1.7.0 too")
end

-- While who the owner is cannot be known (the claim is in the people's store), nobody changes an
-- admin's devices or person, and nobody claims the home: 503, not a free hand.
function tests.while_the_owner_cannot_be_known_admins_devices_and_claims_wait()
    local s = session()
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(send(s, { type = "claim", id = "c1", token = claim.json.claim_token }).ok, true)
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner", role = "admin" } }).json
    local _, kid = member(s.mock, s.key, {})
    local ownerProfile = profileOf(s.mock, s.key)
    local people = s.mock.persist["directorlink_people"]
    s.mock.persist["directorlink_people"] = "json:{broken"
    local again = Mock.updateDriver(s.mock)
    Harness.connected({ mock = again })
    local function unavailable(answer, what)
        T.eq(answer.status, 503, what .. ": " .. answer.body)
        T.eq(answer.json.code, "UNAVAILABLE", what)
    end
    unavailable(T.http(again, "DELETE", "/v1/api-keys/" .. s.keyId, { key = partner.key }), "the owner's device revoked")
    unavailable(T.http(again, "PATCH", "/v1/api-keys/" .. s.keyId, { key = partner.key, body = { profile_id = partner.profile_id } }), "moved")
    unavailable(T.http(again, "POST", "/v1/api-keys", { key = partner.key, body = { name = "x", profile_id = ownerProfile } }), "a key added")
    unavailable(T.http(again, "POST", "/v1/remote/claim", { key = partner.key }), "the home claimed")
    unavailable(T.http(again, "POST", "/v1/remote/claim", { key = s.key }), "even by the owner")
    T.eq(get(again, s.key, "/v1/api-keys/current").json.access.owner, false, "not known")
    -- A member's device is no admin's: it may go.
    T.eq(T.http(again, "DELETE", "/v1/api-keys/" .. kid.id, { key = partner.key }).status, 204)
    -- Read again at the next start: the owner is the owner.
    again.persist["directorlink_people"] = people
    local fine = Mock.updateDriver(again)
    T.eq(get(fine, s.key, "/v1/api-keys/current").json.access.owner, true)
    T.eq(T.http(fine, "DELETE", "/v1/api-keys/" .. s.keyId, { key = partner.key }).json.code, "OWNER_PROTECTED")
end

-- The profiles' store unreadable at a start: nothing is worked out again or written over it, so the
-- people keep their permissions and the owner their claim; the next good start finds them all.
function tests.an_unreadable_profiles_store_changes_nobodys_permissions()
    local s = session()
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(send(s, { type = "claim", id = "c1", token = claim.json.claim_token }).ok, true)
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner", role = "admin" } }).json
    local kid = member(s.mock, s.key, { all_rooms = false, rooms = { 11 }, kinds = { climate = false } })
    local kidProfile = profileOf(s.mock, kid)
    local profiles, people = s.mock.persist["directorlink_profiles"], s.mock.persist["directorlink_people"]
    s.mock.persist["directorlink_profiles"] = "json:{broken"
    local again = Mock.updateDriver(s.mock)
    local me = get(again, kid, "/v1/api-keys/current").json.access
    T.eq(me.all_rooms, false, "still only the living room")
    T.eq(me.kinds.climate, false)
    T.same(ids(get(again, kid, "/v1/lights").json.items), { 21, 22 })
    T.eq(again.persist["directorlink_people"], people, "the people's store is as it was")
    T.eq(again.persist["directorlink_profiles"], "json:{broken", "nothing written over the profiles")
    -- The claim is known: the owner stays protected.
    T.eq(get(again, s.key, "/v1/api-keys/current").json.access.owner, true)
    T.eq(T.http(again, "DELETE", "/v1/api-keys/" .. s.keyId, { key = partner.key }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(again, "POST", "/v1/api-keys", { key = s.key, body = { name = "New", role = "member" } }).status, 503, "no new person meanwhile")
    T.eq(get(again, kid, "/v1/profile").status, 503, "their preferences come back at the next start: no new profile for them")
    T.eq(get(again, kid, "/v1/api-keys/current").json.profile_id, kidProfile, "the key keeps its person")
    again.persist["directorlink_profiles"] = profiles
    local fine = Mock.updateDriver(again)
    T.eq(get(fine, kid, "/v1/api-keys/current").json.access.all_rooms, false)
    T.eq(get(fine, s.key, "/v1/api-keys/current").json.access.owner, true)
end

-- Nobody has a record yet (the scenes could not be read at the first start of 1.8.0): a person is
-- what their keys say, and a change starts from that, with the owner's and the last admin's
-- protection.
function tests.a_person_without_a_record_is_changed_from_what_their_keys_say()
    local mock, owner = start()
    local ownerProfile = profileOf(mock, owner)
    local partner = T.http(mock, "POST", "/v1/api-keys", { key = owner, body = { name = "Partner", role = "admin" } }).json
    local kid = T.http(mock, "POST", "/v1/api-keys", { key = owner, body = { name = "Kid", role = "member" } }).json
    mock.persist["directorlink_people"] = nil
    mock.persist["directorlink_scenes"] = "json:{broken"
    local again = Mock.updateDriver(mock)
    T.eq(get(again, partner.key, "/v1/profiles/" .. ownerProfile .. "/access").json.owner, true, "the oldest admin, from the keys")
    local demoted = setAccess(again, partner.key, ownerProfile, { cameras = false })
    T.eq(demoted.status, 403, demoted.body)
    T.eq(demoted.json.code, "OWNER_PROTECTED")
    T.eq(setAccess(again, partner.key, ownerProfile, { role = "member" }).json.code, "OWNER_PROTECTED")
    T.eq(get(again, owner, "/v1/api-keys/current").json.role, "admin")
    T.eq(setAccess(again, owner, ownerProfile, { role = "member" }).json.code, "OWNER_STAYS_ADMIN")
    -- The partner's person, an admin, made a member by the owner: the rest as an admin had it.
    local made = setAccess(again, owner, partner.profile_id, { role = "member" })
    T.eq(made.status, 200, made.body)
    T.eq(made.json.all_rooms, true)
    T.eq(get(again, partner.key, "/v1/api-keys").status, 403)
    -- A member's permissions need their scenes, which cannot be read yet.
    T.eq(setAccess(again, owner, kid.profile_id, { cameras = false }).status, 503)
    T.eq(get(again, kid.key, "/v1/api-keys/current").json.role, "member", "unchanged")
end

-- The keys' store cannot be written when a person's access changes: the request fails and nothing
-- changes (a person kept with keys whose 1.7.0 role says otherwise would be read again from them
-- at the next start, widened).
function tests.when_the_keys_cannot_be_saved_a_persons_access_does_not_change()
    local mock, admin = start()
    local kid, created = member(mock, admin, {})
    local original = C4.PersistSetValue
    C4.PersistSetValue = function(self, name, value, encrypted)
        if name == "directorlink_api_key_hashes" then
            error("disk full")
        end
        return original(self, name, value, encrypted)
    end
    local narrowed = setAccess(mock, admin, created.profile_id, { all_rooms = false, rooms = {} })
    C4.PersistSetValue = original
    T.eq(narrowed.status, 500, narrowed.body)
    local me = get(mock, kid, "/v1/api-keys/current").json
    T.eq(me.role, "member")
    T.eq(me.access.all_rooms, true, "nothing changed")
    local again = Mock.updateDriver(mock)
    me = get(again, kid, "/v1/api-keys/current").json
    T.eq(me.access.all_rooms, true)
    T.eq(me.role, "member")
    -- Saved, it changes, and stays so.
    T.eq(setAccess(again, admin, created.profile_id, { all_rooms = false, rooms = {} }).status, 200)
    T.eq(get(Mock.updateDriver(again), kid, "/v1/api-keys/current").json.access.all_rooms, false)
end

-- ---- scene links of someone no longer an admin -------------------------------------------------

function tests.a_scene_link_goes_when_its_maker_is_no_longer_an_admin()
    local s = session()
    local partner = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner", role = "admin" } }).json
    local evening = scene(s.mock, s.key, { name = "Evening", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } })
    local link = T.http(s.mock, "POST", "/v1/scenes/" .. evening .. "/link", { key = partner.key })
    T.eq(link.status, 201, link.body)
    T.eq(setAccess(s.mock, s.key, partner.profile_id, { role = "member", scenes = {} }).status, 200)
    local before = #s.mock.commands
    local reply = send(s, { type = "link", id = "l1", link = link.json.link_id, secret = link.json.secret })
    T.eq(reply.ok, false)
    T.eq(reply.code, "NOT_FOUND")
    T.eq(#s.mock.commands, before, "nothing ran")
    T.eq(#get(s.mock, s.key, "/v1/scene-links").json.items, 0)
    local removed = get(s.mock, s.key, "/v1/activity?kind=access").json.items[1]
    T.eq(removed.action, "link_removed")
    T.eq(removed.reason, "no_access")

    -- At a start too: 1.7.0 made another admin's key a member meanwhile.
    local other = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Other admin", role = "admin" } }).json
    local second = T.http(s.mock, "POST", "/v1/scenes/" .. evening .. "/link", { key = other.key })
    T.eq(second.status, 201)
    local stored = Json.decode(s.mock.persist["directorlink_api_key_hashes"]:sub(6))
    for _, key in ipairs(stored.keys) do
        if key.id == other.id then
            key.role = "member"
        end
    end
    s.mock.persist["directorlink_api_key_hashes"] = "json:" .. Json.encode(stored)
    local again = Mock.updateDriver(s.mock)
    T.eq(#get(again, s.key, "/v1/scene-links").json.items, 0, "gone at the start")
    T.eq(get(again, s.key, "/v1/activity?kind=access").json.items[1].reason, "no_access")
end

-- ---- what a member learns of what they do not see ------------------------------------------------

-- A member's scene names no room or device they do not see: the step says it works elsewhere too.
function tests.a_members_scene_names_only_their_rooms_and_devices()
    local mock, admin = start()
    local id = scene(mock, admin, { name = "Good night", steps = {
        { type = "lights", room_id = 10, set = { on = false } },
        { type = "lights", device_ids = { 20, 21 }, set = { on = false } },
        { type = "blinds", room_id = 11, set = { position = 0 } },
    } })
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, scenes = { id } })
    local seen = get(mock, kid, "/v1/scenes/" .. id).json
    T.eq(Json.encode(seen.steps[1].room_id), "null")
    T.eq(seen.steps[1].elsewhere, true)
    T.same(seen.steps[2].device_ids, { 21 })
    T.eq(seen.steps[2].elsewhere, true)
    T.eq(seen.steps[3].room_id, 11)
    T.eq(seen.steps[3].elsewhere, nil)
    T.same(get(mock, kid, "/v1/scenes").json.items[1].steps, seen.steps)
    local full = get(mock, admin, "/v1/scenes/" .. id).json
    T.eq(full.steps[1].room_id, 10, "an admin sees the scene as it is")
    T.same(full.steps[2].device_ids, { 20, 21 })
    -- Its run names no device of theirs it skipped elsewhere.
    local Registry = require("src.core.registry")
    Registry.devices[20].supported = false
    local ran = T.http(mock, "POST", "/v1/scenes/" .. id .. "/run", { key = kid }).json
    Registry.devices[20].supported = true
    for _, problem in ipairs(ran.problems) do
        T.eq(problem.device_id, 0, Json.encode(problem))
    end
end

-- GET /v1/system's inventory counts for a member only what they see.
function tests.a_members_inventory_counts_only_what_they_see()
    local mock, admin = start()
    local off = { light = false, climate = false, fan = false, blind = false, music = false, refrigerator = false }
    local kid = member(mock, admin, { all_rooms = false, rooms = { 11 }, kinds = off, cameras = false })
    local mine = get(mock, kid, "/v1/system").json.inventory
    local all = get(mock, admin, "/v1/system").json.inventory
    T.eq(mine.rooms, 1)
    T.eq(mine.lights, 0)
    T.eq(mine.thermostats, 0)
    T.eq(mine.cameras, 0)
    T.truthy(all.lights > 0 and all.cameras > 0 and all.rooms == 2)
    T.eq(mine.devices, #get(mock, kid, "/v1/devices").json.items, "the devices they see")
end

return tests
