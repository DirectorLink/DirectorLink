-- Who may see and do what (src/auth/access.lua, ADR-054). Contract step of 1.8.0: the module
-- answers as the roles of 1.7.0 do; the admins and members model replaces these expectations.

local T = require("helpers")
local Access = require("src.auth.access")

local tests = {}

local light = { id = 10, kind = "light", room_id = 1 }
local gate = { id = 20, kind = "relay", room_id = 2 }

function tests.the_roles_of_1_7_answer_as_before()
    local viewer, member, doors, admin = { role = "viewer" }, { role = "member" }, { role = "doors" }, { role = "admin" }
    T.eq(Access.canSee(viewer, light), true)
    T.eq(Access.canControl(viewer, light), false)
    T.eq(Access.canControl(member, light), true)
    T.eq(Access.canOpen(member, gate), false)
    T.eq(Access.canOpen(doors, gate), true)
    T.eq(Access.canSeeAlarm(viewer), false)
    T.eq(Access.canSeeAlarm(member), true)
    T.eq(Access.mayRunScene(member, "s1"), true)
    T.eq(Access.mayRunScene(viewer, "s1"), false)
    T.eq(Access.isAdmin(doors), false)
    T.eq(Access.isAdmin(admin), true)
    T.eq(Access.visibleRooms(member), nil)
end

function tests.no_actor_or_no_device_may_do_nothing()
    T.eq(Access.canSee(nil, light), false)
    T.eq(Access.canSee({ role = "admin" }, nil), false)
    T.eq(Access.canControl({ role = "nobody" }, light), false)
    T.same(Access.filter({ role = "viewer" }, { light, gate }), { light, gate })
    T.same(Access.filter(nil, { light }), {})
end

return tests
