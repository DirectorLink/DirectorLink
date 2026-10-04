-- Who may see and do what (1.8.0, ADR-054). Every question about a person's permissions goes
-- through here, so that the rules live in one place and every handler asks the same way.
--
-- `actor` is the caller: the request's key (ctx.apiKey: { id, role, profile_id, ... }) or an actor
-- DirectorLink acts as itself (a schedule, a scene's link: { id = "schedule:…" | "link:…",
-- role = "member", system = true }). `device` is a registry device ({ id, kind, room_id, ... }), or
-- a table with the same fields for something that is not one (a Sonos room: kind "music").
--
-- Kinds: light, climate, fan, blind, music, refrigerator (device kinds a member may be given),
-- camera and doorbell (pictures), relay (doors and gates), alarm.
--
-- STUB (contract step): these answer as the roles of 1.7.0 do, so that nothing changes until the
-- admins and members model replaces them. Keep the names and arguments; the roles builder fills
-- in the rules (rooms, kinds, cameras, doors, the alarm, the scenes a member may run, the rooms
-- hidden from members).

local Roles = require("src.auth.roles")

local Access = {}

local function role(actor)
    return type(actor) == "table" and actor.role or nil
end

-- An admin: manages people, rooms, scenes, schedules, settings, history.
function Access.isAdmin(actor)
    return role(actor) == "admin"
end

-- May see the device at all (lists, Home, its state).
function Access.canSee(actor, device)
    return Roles.allows(role(actor), "viewer") and type(device) == "table"
end

-- May change it (lights, climate, fans, blinds, music, refrigerators).
function Access.canControl(actor, device)
    return Access.canSee(actor, device) and Roles.allows(role(actor), "member")
end

-- May see its pictures (a camera, a doorbell's camera).
function Access.canSeePictures(actor, device)
    return Access.canSee(actor, device)
end

-- May open it (a door or gate relay). Door Control in Composer is checked where it always was.
function Access.canOpen(actor, device)
    return Access.canSee(actor, device) and Roles.allows(role(actor), "doors")
end

-- May read the alarm's status (when Alarm Status is On in Composer).
function Access.canSeeAlarm(actor)
    return Roles.allows(role(actor), "member")
end

-- May run the scene with this id (never edit it: that is isAdmin).
function Access.mayRunScene(actor, sceneId)
    return sceneId ~= nil and Roles.allows(role(actor), "member")
end

-- The room ids the actor sees, as a set; nil when every room (admins, and every role until 1.8.0).
function Access.visibleRooms(actor)
    return nil
end

-- The devices of `list` the actor may see, in their order.
function Access.filter(actor, list)
    local seen = {}
    for _, device in ipairs(list or {}) do
        if Access.canSee(actor, device) then
            seen[#seen + 1] = device
        end
    end
    return seen
end

return Access
