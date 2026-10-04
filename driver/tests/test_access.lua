-- Who may see and do what (src/auth/access.lua, src/auth/people.lua, ADR-054): admins and members,
-- set per person; a member's rooms, kinds of devices, cameras, doors and gates, the alarm and the
-- scenes they may run; rooms hidden from members; DirectorLink acting itself; the 1.7.0 roles a
-- person becomes, and the role their keys keep.

local Mock = require("c4mock")
local T = require("helpers")
local Access = require("src.auth.access")
local People = require("src.auth.people")
local Registry = require("src.core.registry")

local tests = {}

-- Kitchen (10) and Living Room (11), as the test project has them, and a Bedroom (12).
local light = { id = 20, kind = "light", room_id = 10 }
local hall = { id = 21, kind = "light", room_id = 11 }
local ac = { id = 30, kind = "climate", room_id = 11 }
local fan = { id = 80, kind = "fan", room_id = 10 }
local blind = { id = 50, kind = "blind", room_id = 11 }
local camera = { id = 60, kind = "camera", room_id = 10 }
local doorbell = { id = 93, kind = "doorbell", room_id = 10 }
local gate = { id = 70, kind = "relay", room_id = 10 }
local fridge = { id = 140, kind = "refrigerator", room_id = 10 }
local sonos = { id = "RINCON_1", kind = "music", room_id = 11 }
local unplaced = { id = 99, kind = "light" }

-- People: profile id -> record, as PATCH /v1/profiles/{id}/access leaves them.
local function setPeople(people, hidden, owner)
    Mock.install()
    local data = { version = 1, people = {}, hidden_rooms = hidden or {}, owner = owner }
    for id, record in pairs(people) do
        local full = People.defaults(record.role or "member")
        for field, value in pairs(record) do
            full[field] = value
        end
        data.people[id] = People.view(full)
    end
    People.restore(data)
    Registry.rooms = { [10] = { id = 10, name = "Kitchen" }, [11] = { id = 11, name = "Living Room" }, [12] = { id = 12, name = "Bedroom" } }
end

local function person(id)
    return { id = "k" .. id, role = "member", profile = id }
end

function tests.an_admin_sees_and_does_everything()
    setPeople({ ["aaaa0001"] = { role = "admin" } })
    local admin = person("aaaa0001")
    for _, device in ipairs({ light, ac, fan, blind, camera, doorbell, gate, fridge, sonos, unplaced }) do
        T.eq(Access.canSee(admin, device), true)
    end
    T.eq(Access.canControl(admin, light), true)
    T.eq(Access.canOpen(admin, gate), true)
    T.eq(Access.canOpen(admin, doorbell), true)
    T.eq(Access.canSeePictures(admin, doorbell), true)
    T.eq(Access.canSeeAlarm(admin), true)
    T.eq(Access.mayRunScene(admin, "abcd0001"), true)
    T.eq(Access.isAdmin(admin), true)
    T.eq(Access.visibleRooms(admin), nil)
end

function tests.an_admin_sees_rooms_hidden_from_members()
    setPeople({ ["aaaa0001"] = { role = "admin" } }, { 10 })
    T.eq(Access.canSee(person("aaaa0001"), light), true)
    T.eq(Access.seesRoom(person("aaaa0001"), 10), true)
end

function tests.a_new_member_sees_every_room_and_kind_but_opens_nothing_and_runs_no_scene()
    setPeople({ ["eeee0001"] = {} })
    local member = person("eeee0001")
    for _, device in ipairs({ light, ac, fan, blind, camera, doorbell, gate, fridge, sonos, unplaced }) do
        T.eq(Access.canSee(member, device), true, "sees " .. device.kind)
    end
    T.eq(Access.canControl(member, light), true)
    T.eq(Access.canControl(member, sonos), true)
    T.eq(Access.canControl(member, gate), false, "a gate is opened, not controlled")
    T.eq(Access.canControl(member, camera), false)
    T.eq(Access.canOpen(member, gate), false)
    T.eq(Access.canOpen(member, doorbell), false)
    T.eq(Access.canSeeAlarm(member), true, "the alarm's status is on by default")
    T.eq(Access.mayRunScene(member, "abcd0001"), false, "no scene until an admin chooses some")
    T.eq(Access.isAdmin(member), false)
    T.eq(Access.visibleRooms(member), nil, "every room")
end

function tests.a_members_rooms_limit_everything_they_see()
    setPeople({ ["eeee0001"] = { all_rooms = false, rooms = { 11 } } })
    local member = person("eeee0001")
    T.eq(Access.canSee(member, hall), true)
    T.eq(Access.canSee(member, ac), true)
    T.eq(Access.canSee(member, sonos), true)
    T.eq(Access.canSee(member, light), false, "the kitchen is not theirs")
    T.eq(Access.canSee(member, camera), false)
    T.eq(Access.canSee(member, doorbell), false)
    T.eq(Access.canSee(member, gate), false)
    T.eq(Access.canSee(member, unplaced), false, "a device in no room: only with every room")
    T.eq(Access.canControl(member, light), false)
    T.same(Access.visibleRooms(member), { [11] = true })
    T.same(Access.filter(member, { light, hall, ac, camera }), { hall, ac })
end

function tests.a_kind_switched_off_is_hidden_from_the_member()
    setPeople({ ["eeee0001"] = { kinds = { light = false, climate = true, fan = true, blind = true, music = false, refrigerator = false } } })
    local member = person("eeee0001")
    T.eq(Access.canSee(member, light), false)
    T.eq(Access.canSee(member, hall), false)
    T.eq(Access.canControl(member, light), false)
    T.eq(Access.canSee(member, sonos), false)
    T.eq(Access.canSee(member, fridge), false)
    T.eq(Access.canSee(member, ac), true)
    T.eq(Access.canControl(member, ac), true)
    -- Kinds combine with rooms: a light shows only if its room is theirs AND lights are on.
    setPeople({ ["eeee0001"] = { all_rooms = false, rooms = { 10 }, kinds = { light = true, climate = false } } })
    T.eq(Access.canSee(member, light), true)
    T.eq(Access.canSee(member, hall), false)
    T.eq(Access.canSee(member, ac), false)
end

function tests.cameras_off_hides_cameras_and_a_doorbells_picture_but_not_its_ring()
    setPeople({ ["eeee0001"] = { cameras = false } })
    local member = person("eeee0001")
    T.eq(Access.canSee(member, camera), false)
    T.eq(Access.canSeePictures(member, camera), false)
    T.eq(Access.canSee(member, doorbell), true, "the ring")
    T.eq(Access.canSeePictures(member, doorbell), false, "not its picture")
    setPeople({ ["eeee0001"] = { cameras = true } })
    T.eq(Access.canSeePictures(member, doorbell), true)
    T.eq(Access.canSeePictures(member, camera), true)
    -- Only in their rooms.
    setPeople({ ["eeee0001"] = { cameras = true, all_rooms = false, rooms = { 11 } } })
    T.eq(Access.canSeePictures(member, camera), false)
    T.eq(Access.canSeePictures(member, doorbell), false)
end

function tests.doors_and_gates_open_only_with_doors_and_only_in_their_rooms()
    setPeople({ ["eeee0001"] = { doors = true } })
    local member = person("eeee0001")
    T.eq(Access.canOpen(member, gate), true)
    T.eq(Access.canOpen(member, doorbell), true)
    T.eq(Access.canOpen(member, light), false, "a light is not a door")
    setPeople({ ["eeee0001"] = { doors = true, all_rooms = false, rooms = { 11 } } })
    T.eq(Access.canOpen(member, gate), false)
    T.eq(Access.canSee(member, gate), false)
    T.eq(Access.opensDoors(member), true)
    setPeople({ ["eeee0001"] = { doors = false } })
    T.eq(Access.canSee(member, gate), true, "seen (its state), not opened")
    T.eq(Access.canOpen(member, gate), false)
    T.eq(Access.opensDoors(member), false)
    T.eq(Access.opensDoors({ id = "schedule:1a2b3c4d", role = "member" }), false, "DirectorLink itself opens none")
    T.eq(Access.opensDoors({ role = "admin" }), true)
end

function tests.the_alarm_status_is_a_members_switch()
    setPeople({ ["eeee0001"] = { alarm = false }, ["eeee0002"] = { alarm = true } })
    T.eq(Access.canSeeAlarm(person("eeee0001")), false)
    T.eq(Access.canSeeAlarm(person("eeee0002")), true)
end

function tests.a_member_runs_only_the_scenes_chosen_for_them()
    setPeople({ ["eeee0001"] = { scenes = { "abcd0001" } } })
    local member = person("eeee0001")
    T.eq(Access.mayRunScene(member, "abcd0001"), true)
    T.eq(Access.mayRunScene(member, "abcd0002"), false)
    T.eq(Access.mayRunScene(member, nil), false)
    T.eq(Access.scenesOpenDoors(member), true, "a scene they may run runs in full")
end

function tests.a_room_hidden_from_members_disappears_whatever_their_rooms()
    setPeople({ ["eeee0001"] = {}, ["eeee0002"] = { all_rooms = false, rooms = { 10, 11 } } }, { 10 })
    for _, id in ipairs({ "eeee0001", "eeee0002" }) do
        local member = person(id)
        T.eq(Access.canSee(member, light), false, id)
        T.eq(Access.canSee(member, camera), false, id)
        T.eq(Access.canSee(member, gate), false, id)
        T.eq(Access.canSee(member, hall), true, id)
        T.eq(Access.seesRoom(member, 10), false, id)
    end
    T.same(Access.visibleRooms(person("eeee0001")), { [11] = true, [12] = true }, "every room but the hidden one")
    T.same(Access.visibleRooms(person("eeee0002")), { [11] = true }, "theirs but the hidden one")
    T.same(Access.describe(person("eeee0002")).rooms, { 11 }, "the hidden room is not among theirs")
end

-- Keys.list()'s records ({ id, role, profile }), as ask links and alerts pass them, and a key's API
-- view ({ id, role, profile_id }) answer as the request's key does.
function tests.key_records_and_views_answer_as_their_person()
    setPeople({ ["eeee0001"] = { doors = true, all_rooms = false, rooms = { 10 } } })
    T.eq(Access.canOpen({ id = "0a1b2c3d", role = "doors", profile = "eeee0001" }, gate), true)
    T.eq(Access.canOpen({ id = "0a1b2c3d", role = "doors", profile_id = "eeee0001" }, gate), true)
    T.eq(Access.canSee({ id = "0a1b2c3d", role = "doors", profile_id = "eeee0001" }, hall), false)
end

function tests.directorlink_itself_controls_everything_but_opens_no_door()
    setPeople({}, { 10 })
    for _, actor in ipairs({ { id = "schedule:1a2b3c4d", role = "member" }, { id = "link:1a2b3c4d", role = "member" }, { id = "x", role = "member", system = true } }) do
        T.eq(Access.canSee(actor, light), true, actor.id)
        T.eq(Access.canControl(actor, light), true, actor.id)
        T.eq(Access.canOpen(actor, gate), false, actor.id)
        T.eq(Access.mayRunScene(actor, "abcd0001"), true, actor.id)
        T.eq(Access.scenesOpenDoors(actor), false, actor.id)
        T.eq(Access.isAdmin(actor), false, actor.id)
    end
end

function tests.a_key_without_a_person_answers_as_its_1_7_role_became()
    setPeople({})
    local viewer, member, doors, admin = { role = "viewer" }, { role = "member" }, { role = "doors" }, { role = "admin" }
    T.eq(Access.canSee(viewer, light), false, "a viewer has no rooms")
    T.eq(Access.canSeeAlarm(viewer), false)
    T.eq(Access.canControl(member, light), true)
    T.eq(Access.canOpen(member, gate), false)
    T.eq(Access.canOpen(doors, gate), true)
    T.eq(Access.canSeeAlarm(member), true)
    T.eq(Access.mayRunScene(member, "s1"), true, "every scene, as in 1.7.0")
    T.eq(Access.mayRunScene(viewer, "s1"), false)
    T.eq(Access.isAdmin(doors), false)
    T.eq(Access.isAdmin(admin), true)
end

function tests.no_actor_or_no_device_may_do_nothing()
    setPeople({ ["eeee0001"] = {} })
    T.eq(Access.canSee(nil, light), false)
    T.eq(Access.canSee({ role = "admin" }, nil), false)
    T.eq(Access.canControl({ role = "nobody" }, light), false)
    T.eq(Access.canSeeAlarm(nil), false)
    T.eq(Access.mayRunScene(nil, "s1"), false)
    T.same(Access.filter(nil, { light }), {})
end

function tests.a_change_to_a_person_applies_at_once()
    setPeople({ ["eeee0001"] = {} })
    local member = person("eeee0001")
    T.eq(Access.canSee(member, light), true)
    People.set("eeee0001", { role = "member", all_rooms = false, rooms = { 11 }, kinds = {}, scenes = {} })
    T.eq(Access.canSee(member, light), false, "worked out again after the change")
    People.set("eeee0001", { role = "admin" })
    T.eq(Access.isAdmin(member), true)
end

function tests.the_1_7_roles_become_people_and_keys_keep_a_1_7_role()
    local scenes = { { id = "abcd0001", steps = { { type = "lights" } } }, { id = "abcd0002", steps = { { type = "relays" } } } }
    local admin = People.fromLegacy("admin", scenes)
    T.eq(admin.role, "admin")
    local doors = People.fromLegacy("doors", scenes)
    T.eq(doors.role, "member")
    T.eq(doors.all_rooms, true)
    T.eq(doors.doors, true)
    T.eq(doors.cameras, true)
    T.eq(doors.alarm, true)
    T.same(doors.scenes, { "abcd0001", "abcd0002" }, "every scene")
    local member = People.fromLegacy("member", scenes)
    T.eq(member.doors, false)
    T.same(member.scenes, { "abcd0001" }, "every scene but those that open doors")
    for _, kind in ipairs(People.KINDS) do
        T.eq(member.kinds[kind], true, kind)
    end
    local viewer = People.fromLegacy("viewer", scenes)
    T.eq(viewer.role, "member")
    T.eq(viewer.all_rooms, false)
    T.same(viewer.rooms, {})
    T.eq(viewer.cameras, true, "cameras only")
    T.eq(viewer.alarm, false)
    T.eq(viewer.doors, false)
    T.same(viewer.scenes, {})
    for _, kind in ipairs(People.KINDS) do
        T.eq(viewer.kinds[kind], false, kind)
    end

    T.eq(People.legacyRole(admin), "admin")
    T.eq(People.legacyRole(doors), "doors")
    T.eq(People.legacyRole(member), "member")
    T.eq(People.legacyRole(viewer), "viewer")
    T.eq(People.legacyRole({ role = "member", all_rooms = false, rooms = {}, doors = true, kinds = {} }), "viewer", "no rooms, nothing to open")
    T.eq(People.legacyRole({ role = "member", all_rooms = false, rooms = { 11 }, doors = false, kinds = {} }), "member")
end

function tests.the_owner_is_who_claimed_else_the_oldest_admin()
    setPeople({ ["aaaa0001"] = { role = "admin" }, ["aaaa0002"] = { role = "admin" }, ["eeee0001"] = {} })
    local profiles = {
        { id = "eeee0001", created_at = "2026-01-01T00:00:00Z" },
        { id = "aaaa0002", created_at = "2026-03-01T00:00:00Z" },
        { id = "aaaa0001", created_at = "2026-02-01T00:00:00Z" },
    }
    T.eq(People.ownerOf(profiles), "aaaa0001", "the oldest admin")
    People.setOwner("aaaa0002")
    T.eq(People.ownerOf(profiles), "aaaa0002", "who claimed the home")
    People.set("aaaa0002", { role = "member" })
    T.eq(People.ownerOf(profiles), "aaaa0001", "the owner is an admin, else the oldest admin is")
    T.eq(People.ownerOf({ { id = "eeee0001" } }), nil, "no admin, no owner")
end

return tests
