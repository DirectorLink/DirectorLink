-- Who may see and do what (1.8.0, ADR-054). Every question about a person's permissions goes
-- through here, so that the rules live in one place and every handler asks the same way.
--
-- `actor` is the caller: the request's key (ctx.apiKey: { id, role, profile, ... }, or a record of
-- Keys.list(), shaped the same) or an actor
-- DirectorLink acts as itself (a schedule, a scene's link: { id = "schedule:…" | "link:…",
-- role = "member", system = true }). `device` is a registry device ({ id, kind, room_id, ... }), or
-- a table with the same fields for something that is not one (a Sonos room: kind "music").
--
-- Kinds: light, climate, fan, blind, music, refrigerator (device kinds a member may be given),
-- camera and doorbell (pictures), relay (doors and gates), alarm.
--
-- Two roles, set per person (src/auth/people.lua): every key of a person has that person's
-- permissions. An admin may see and do everything. A member sees the rooms an admin gave them (all,
-- or a list), never a room hidden from members; there, the kinds of devices they were given (each
-- on or off: off hides that kind from them), cameras if they were given cameras, every doorbell
-- (its ring; its picture with cameras) and every door and gate (its state; opening it with doors
-- and gates, and Door Control on in Composer, which the handlers check as before). A device a member
-- may not see is, for them, a device that does not exist. They may run the scenes an admin chose
-- for them, in full, and read the alarm's status if they were given it.
--
-- DirectorLink acting itself (schedules, scene links) sees and controls everything but opens no
-- door or gate, as the member role of 1.7.0 did. A key whose person has no record (the people's
-- store could not be read, or a key just made) answers as its 1.7.0 role maps to a person
-- (People.fromLegacy), with every scene for member and doors keys.

local Keys = require("src.auth.keys")
local People = require("src.auth.people")
local Profiles = require("src.auth.profiles")
local Registry = require("src.core.registry")
local Roles = require("src.auth.roles")

local Access = {}

-- What was worked out for an actor (a request's key lives as long as the request; a LAN key's
-- record longer), until the people change or the actor's person or role does.
local cache = setmetatable({}, { __mode = "k" })

local function rules(record, profileId, everyScene)
    if record.role == "admin" then
        return { admin = true, profile = profileId }
    end
    local rooms, scenes = {}, {}
    for _, id in ipairs(record.rooms or {}) do
        rooms[id] = true
    end
    for _, id in ipairs(record.scenes or {}) do
        scenes[id] = true
    end
    return {
        profile = profileId,
        all_rooms = record.all_rooms == true,
        rooms = rooms,
        kinds = record.kinds or {},
        cameras = record.cameras == true,
        doors = record.doors == true,
        alarm = record.alarm == true,
        scenes = everyScene and true or scenes,
    }
end

-- The rules for `actor`, or nil when it may do nothing.
local function resolve(actor)
    if type(actor) ~= "table" then
        return nil
    end
    -- DirectorLink acting itself: `system`, or an id naming what acts ("schedule:…", "link:…"),
    -- which no key's id (8 hex digits) does.
    if actor.system or (type(actor.id) == "string" and actor.id:find(":", 1, true)) then
        return { system = true }
    end
    -- A request's key (ctx.apiKey) and Keys.list()'s records say `profile`; a key's API view says
    -- `profile_id`.
    local profileId = actor.profile or actor.profile_id
    if profileId == nil and type(actor.id) == "string" then
        profileId = Keys.profileOf(actor.id)
    end
    local revision = People.revision()
    local cached = cache[actor]
    if cached and cached.revision == revision and cached.profile == profileId and cached.role == actor.role then
        return cached.rules
    end
    local record = profileId and People.peek(profileId) or nil
    local result = nil
    if record then
        result = rules(record, profileId)
    elseif Roles.valid(actor.role) then
        result = rules(People.fromLegacy(actor.role), profileId, actor.role ~= "viewer")
    end
    cache[actor] = { revision = revision, profile = profileId, role = actor.role, rules = result }
    return result
end

local function seesRoom(rule, roomId)
    if rule.admin or rule.system then
        return true
    end
    roomId = tonumber(roomId)
    -- A device in no room: only for those who see every room.
    if roomId == nil then
        return rule.all_rooms
    end
    if People.hiddenRooms()[roomId] then
        return false
    end
    return rule.all_rooms or rule.rooms[roomId] == true
end

-- An admin: manages people, rooms, scenes, schedules, settings, history.
function Access.isAdmin(actor)
    local rule = resolve(actor)
    return rule ~= nil and rule.admin == true
end

-- May see the device at all (lists, Home, its state).
function Access.canSee(actor, device)
    local rule = resolve(actor)
    if not rule or type(device) ~= "table" then
        return false
    end
    if rule.admin or rule.system then
        return true
    end
    if not seesRoom(rule, device.room_id) then
        return false
    end
    if People.KIND[device.kind] then
        return rule.kinds[device.kind] == true
    end
    if device.kind == "camera" then
        return rule.cameras
    end
    -- Doorbells (their rings), doors and gates (their state), what DirectorLink does not control.
    return true
end

-- May change it (lights, climate, fans, blinds, music, refrigerators).
function Access.canControl(actor, device)
    if not Access.canSee(actor, device) then
        return false
    end
    return Access.isAdmin(actor) or People.KIND[device.kind] == true
end

-- May see its pictures (a camera, a doorbell's camera).
function Access.canSeePictures(actor, device)
    if not Access.canSee(actor, device) then
        return false
    end
    local rule = resolve(actor)
    return rule.admin == true or rule.system == true or rule.cameras == true
end

-- May open it (a door or gate relay, the door at a doorbell). Door Control in Composer is checked
-- where it always was. DirectorLink itself never opens one.
function Access.canOpen(actor, device)
    if not Access.canSee(actor, device) then
        return false
    end
    local rule = resolve(actor)
    if rule.admin then
        return true
    end
    return rule.doors == true and (device.kind == "relay" or device.kind == "doorbell")
end

-- May read the alarm's status (when Alarm Status is On in Composer).
function Access.canSeeAlarm(actor)
    local rule = resolve(actor)
    return rule ~= nil and (rule.admin == true or rule.system == true or rule.alarm == true)
end

-- May run the scene with this id (never edit it: that is isAdmin).
function Access.mayRunScene(actor, sceneId)
    local rule = resolve(actor)
    if not rule or sceneId == nil then
        return false
    end
    return rule.admin == true or rule.system == true or rule.scenes == true or rule.scenes[sceneId] == true
end

-- Whether a scene this actor runs opens the doors and gates it names: a person's run does (a scene
-- they may run runs in full: the admin chose what it does), DirectorLink's own runs (schedules,
-- scene links) never, as in 1.7.0. Door Control in Composer is checked where it always was.
function Access.scenesOpenDoors(actor)
    local rule = resolve(actor)
    return rule ~= nil and not rule.system
end

-- Whether the actor sees the room with this id (its devices, in lists and on Home).
function Access.seesRoom(actor, roomId)
    local rule = resolve(actor)
    return rule ~= nil and seesRoom(rule, roomId)
end

-- The room ids the actor sees, as a set; nil when every room (admins, DirectorLink itself, and
-- members with every room while no room is hidden from members).
function Access.visibleRooms(actor)
    local rule = resolve(actor)
    if not rule then
        return {}
    end
    if rule.admin or rule.system or (rule.all_rooms and next(People.hiddenRooms()) == nil) then
        return nil
    end
    local rooms = {}
    for id in pairs(Registry.rooms or {}) do
        if seesRoom(rule, id) then
            rooms[tonumber(id)] = true
        end
    end
    return rooms
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

-- The home's owner (src/auth/people.lua): the profile id, or nil when there is no admin.
function Access.owner()
    return People.ownerOf(Profiles.list())
end

-- Whether the actor is the home's owner, or another device of theirs.
function Access.isOwner(actor)
    local rule = resolve(actor)
    return rule ~= nil and rule.profile ~= nil and rule.profile == Access.owner()
end

-- What the actor may do, as GET /v1/api-keys/current and /v1/profile say it (ADR-054): an admin
-- everything (`scenes` then lists none: every scene is theirs), a member their permissions.
function Access.describe(actor)
    local rule = resolve(actor) or rules(People.fromLegacy("viewer"))
    local record
    if rule.admin then
        record = People.defaults("admin")
        record.doors = true
    else
        record = { role = "member", all_rooms = rule.all_rooms, rooms = {}, kinds = rule.kinds, cameras = rule.cameras, doors = rule.doors, alarm = rule.alarm, scenes = {} }
        for id in pairs(rule.rooms or {}) do
            record.rooms[#record.rooms + 1] = id
        end
        table.sort(record.rooms)
        if type(rule.scenes) == "table" then
            for id in pairs(rule.scenes) do
                record.scenes[#record.scenes + 1] = id
            end
            table.sort(record.scenes)
        end
    end
    local view = People.view(record)
    view.owner = rule.profile ~= nil and rule.profile == Access.owner()
    -- Rooms hidden from members are not theirs, whatever their list says.
    if not rule.admin then
        local rooms = view.rooms
        for index = #rooms, 1, -1 do
            if People.hiddenRooms()[rooms[index]] then
                table.remove(rooms, index)
            end
        end
    end
    return view
end

return Access
