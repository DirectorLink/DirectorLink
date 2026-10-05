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
-- and gates, and Door Control on in Composer, which the handlers check as before), the alarm's
-- partitions if they were given the alarm, and the other devices there that DirectorLink does not
-- control (their names only). A device a member may not see is, for them, a device that does not
-- exist. They may run the scenes an admin chose for them, in full, and read the alarm's status if
-- they were given it.
--
-- DirectorLink acting itself (schedules, scene links) sees and controls everything but opens no
-- door or gate, as the member role of 1.7.0 did.
--
-- A key whose person has no record answers as its 1.7.0 role did in 1.7.0, never more: the
-- people's store could not be read at this start, or the scenes could not be read at the first
-- start of 1.8.0 (until then nobody has a record). A viewer key sees nothing (no rooms), a member
-- key every room and kind and runs every scene, but the doors and gates in a scene stay shut for
-- it (1.7.0 skipped them for a member), a doors key opens them too, an admin key is an admin.
--
-- The home's owner (Access.owner) is the person who claimed the home for an account with 1.8.0,
-- while they are an admin, else the oldest admin. Only the owner changes the owner's person: their
-- role and permissions, their devices, a key or device put into it (Access.mayChangePerson, which
-- every such path asks), and only the owner makes a person an admin who would then be the owner. A
-- key or invitation for a new person never makes an owner: that person is the newest. While the
-- owner cannot be known (the people's store, which holds the claim, could not be read at start; or
-- the profiles' store could not be, and the claimer is not known: the oldest admin needs the
-- profiles), nobody changes an admin's person or devices, makes a person an admin, or claims the
-- home: the handlers answer 503 UNAVAILABLE until a start reads the stores.

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
        -- No record: what the 1.7.0 role did, never more (the header).
        result = rules(People.fromLegacy(actor.role), profileId, actor.role ~= "viewer")
        result.legacy = true
        result.sceneDoors = actor.role == "doors"
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
    -- An alarm's partition (its name and state): only with the alarm's status.
    if device.kind == "alarm" then
        return rule.alarm
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

-- Whether the actor opens doors and gates at all (an admin; a member given doors and gates, in
-- their rooms): for what is about doors without naming one, such as a list of ask links.
function Access.opensDoors(actor)
    local rule = resolve(actor)
    return rule ~= nil and (rule.admin == true or rule.doors == true)
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
-- scene links) never, as in 1.7.0; nor a key whose person has no record, unless its 1.7.0 role
-- opened doors (doors, admin). Door Control in Composer is checked where it always was.
function Access.scenesOpenDoors(actor)
    local rule = resolve(actor)
    if rule == nil or rule.system then
        return false
    end
    return not rule.legacy or rule.admin == true or rule.sceneDoors == true
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

-- ---- the home's owner (ADR-054) ---------------------------------------------------------------

-- Whether the person (a profile id) is an admin: as their record says; a person without one as
-- their keys answer (the highest 1.7.0 role among them, as resolve does). `keys`: Keys.list(), when
-- the caller has it already.
function Access.isAdminPerson(profileId, keys)
    if type(profileId) ~= "string" then
        return false
    end
    local record = People.peek(profileId)
    if record then
        return record.role == "admin"
    end
    for _, key in ipairs(keys or Keys.list()) do
        if key.profile == profileId and key.role == "admin" then
            return true
        end
    end
    return false
end

-- The owner if the person `extra` were an admin too (nil: as things are), or nil and true when that
-- cannot be known (the header).
local function ownerWith(extra)
    if not People.complete() then
        return nil, true
    end
    local keys = Keys.list()
    local function admin(profileId)
        return profileId == extra or Access.isAdminPerson(profileId, keys)
    end
    if Profiles.complete() then
        return People.ownerOf(Profiles.list(), admin)
    end
    local claimed = People.claimedBy()
    if claimed and admin(claimed) then
        return claimed
    end
    return nil, true
end

-- The home's owner: the profile id, or nil when there is no admin; nil and true when it cannot be
-- known (the header).
function Access.owner()
    return ownerWith(nil)
end

-- Whether the actor is the home's owner, or another device of theirs (false while the owner cannot
-- be known).
function Access.isOwner(actor)
    local rule = resolve(actor)
    if rule == nil or rule.profile == nil then
        return false
    end
    return rule.profile == Access.owner()
end

-- The one rule for changing a person (ADR-054): whether `actor` may change the person `profileId`
-- (their role and permissions, revoke or move one of their devices, put a key or device into them:
-- a key made for them, a device moved in, an invitation for them and its join). `makesAdmin`: the
-- change makes them an admin. Only the owner changes the owner's person, and only the owner makes
-- an admin who would then be the owner (an older person, while nobody claimed the home with 1.8.0);
-- while the owner cannot be known, nobody changes an admin's person or makes an admin. Returns true,
-- or false and the problem's code: OWNER_PROTECTED (403) or UNAVAILABLE (503).
function Access.mayChangePerson(actor, profileId, makesAdmin)
    local owner, unknown = ownerWith(nil)
    if unknown then
        if makesAdmin or Access.isAdminPerson(profileId) then
            return false, "UNAVAILABLE"
        end
        return true
    end
    local rule = resolve(actor)
    local isOwner = rule ~= nil and rule.profile ~= nil and rule.profile == owner
    if isOwner then
        return true
    end
    if owner ~= nil and profileId == owner then
        return false, "OWNER_PROTECTED"
    end
    if makesAdmin then
        local after, unknownAfter = ownerWith(profileId)
        if unknownAfter then
            return false, "UNAVAILABLE"
        end
        if after ~= owner then
            return false, "OWNER_PROTECTED"
        end
    end
    return true
end

-- Whether `actor` may claim the home for an account (POST /v1/remote/claim): once a person claimed
-- it with 1.8.0, only the owner (that person, while an admin); before that, any admin, as in 1.7.0.
-- Returns true, or false and OWNER_ONLY (403) or UNAVAILABLE (503: the owner cannot be known).
function Access.mayClaim(actor)
    local owner, unknown = ownerWith(nil)
    if unknown then
        return false, "UNAVAILABLE"
    end
    local claimed = People.claimedBy()
    if claimed == nil or (owner ~= claimed and not Profiles.find(claimed)) then
        return true
    end
    local rule = resolve(actor)
    if rule ~= nil and rule.profile ~= nil and rule.profile == owner then
        return true
    end
    return false, "OWNER_ONLY"
end

-- ---- users and their devices (1.9.0, ADR-061) ----------------------------------------------------

-- The user (profile id) the actor's key belongs to, or nil (DirectorLink itself, or no key).
local function userOf(actor)
    local rule = resolve(actor)
    return rule ~= nil and not rule.system and rule.profile or nil
end

-- Whether the actor sees the user `profileId` and their devices in Settings → Users: an admin
-- every user, anyone else only their own.
function Access.seesUser(actor, profileId)
    if Access.isAdmin(actor) then
        return true
    end
    local own = userOf(actor)
    return own ~= nil and own == profileId
end

-- Whether the actor adds a device to their own user (Add my other device, a device of their account
-- that asks to join approved): every user, admin or member, within the device limit, which the
-- handlers check; the owner's user only by the owner (mayChangePerson, which the handlers ask too).
function Access.mayAddOwnDevice(actor)
    return userOf(actor) ~= nil
end

-- Whether the actor may remove the device `key` (a record of Keys.list(), or { profile }): an admin
-- any device but the owner's, which only the owner removes (mayChangePerson); a member only the
-- devices of their own user. Returns true, or false and the problem's code: NOT_FOUND (a member:
-- another user's device is, for them, one that does not exist), OWNER_PROTECTED or UNAVAILABLE.
function Access.mayRemoveDevice(actor, key)
    if type(key) ~= "table" then
        return false, "NOT_FOUND"
    end
    if Access.isAdmin(actor) then
        return Access.mayChangePerson(actor, key.profile)
    end
    local own = userOf(actor)
    if own == nil or key.profile ~= own then
        return false, "NOT_FOUND"
    end
    return true
end

-- Whether two users are alike: the same role, neither of them the owner, and (members) the same
-- permissions. Bringing the devices of one account together from such users gives no device
-- anything it did not have, so DirectorLink does it by itself (ADR-061); a user without a record
-- (the people's store could not be read) is never alike.
function Access.alike(left, right)
    local a, b = People.peek(left), People.peek(right)
    if not a or not b or not People.complete() then
        return false
    end
    local owner, unknown = ownerWith(nil)
    if unknown or left == owner or right == owner then
        return false
    end
    local va, vb = People.view(a), People.view(b)
    if va.role ~= vb.role then
        return false
    end
    if va.role == "admin" then
        return true
    end
    local function sameList(x, y)
        local seen = {}
        for _, item in ipairs(x) do
            seen[item] = true
        end
        if #x ~= #y then
            return false
        end
        for _, item in ipairs(y) do
            if not seen[item] then
                return false
            end
        end
        return true
    end
    for _, field in ipairs({ "all_rooms", "cameras", "doors", "alarm" }) do
        if va[field] ~= vb[field] then
            return false
        end
    end
    for _, kind in ipairs(People.KINDS) do
        if va.kinds[kind] ~= vb.kinds[kind] then
            return false
        end
    end
    return sameList(va.rooms, vb.rooms) and sameList(va.scenes, vb.scenes)
end

-- Whether the actor may bring the devices of one account together from the users `profileIds`
-- into `keepId`, whose permissions stay (a suggestion in Settings → Users, ADR-061): an admin who
-- may change each of those users (mayChangePerson); one of them the owner's: only the owner, and
-- the owner's user is the one that stays (the owner's devices never move). Returns true, or false
-- and OWNER_PROTECTED (403), OWNER_KEEPS (the owner's user must stay) or UNAVAILABLE (503).
function Access.mayMerge(actor, profileIds, keepId)
    if not Access.isAdmin(actor) then
        return false, "FORBIDDEN"
    end
    local owner, unknown = ownerWith(nil)
    if unknown then
        return false, "UNAVAILABLE"
    end
    for _, id in ipairs(profileIds) do
        if owner ~= nil and id == owner then
            if userOf(actor) ~= owner then
                return false, "OWNER_PROTECTED"
            end
            if keepId ~= owner then
                return false, "OWNER_KEEPS"
            end
        end
    end
    for _, id in ipairs(profileIds) do
        local allowed, refusal = Access.mayChangePerson(actor, id)
        if not allowed then
            return false, refusal
        end
    end
    return true
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
