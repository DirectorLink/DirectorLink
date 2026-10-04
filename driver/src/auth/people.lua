-- People (1.8.0, ADR-054): each person's role on this controller, admin or member, and what a
-- member may see and do; who the home's owner is; and the rooms hidden from every member. A person
-- is a profile (profiles.lua): every key of theirs follows it. src/auth/access.lua answers the
-- questions; this module only keeps the records.
--
-- A member's record: the rooms they see (all, or a list), the kinds of devices they use there
-- (KINDS, each on or off), whether they see cameras, open doors and gates, see the alarm's status,
-- and the scenes they may run. Kept in a store of its own, which DirectorLink 1.7.0 never reads or
-- writes (it rewrites the profiles' store without what it does not know); every key keeps a 1.7.0
-- role worked out from its person (People.legacyRole), so that 1.7.0 behaves close to it after a
-- downgrade, and so that a person whose keys were changed meanwhile by 1.7.0 is read again from
-- them (People.reconcile).

local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local People = {}

local STORE_KEY = "directorlink_people"
People.STORE_VERSION = 1
-- The kinds of devices a member may be given, in the order the app lists them.
People.KINDS = { "light", "climate", "fan", "blind", "music", "refrigerator" }
People.MAX_ROOMS = 1000
People.MAX_SCENES = 200

local KIND = {}
for _, kind in ipairs(People.KINDS) do
    KIND[kind] = true
end
People.KIND = KIND

-- people: profile id -> record; owner: the profile that last claimed the home for an account
-- (remote.lua); hidden: room id -> true. `complete` is false after the store could not be read:
-- it is then never written over, and Access answers from the keys' 1.7.0 roles meanwhile.
-- `revision` goes up with every change (Access keeps what it worked out until then).
local state = { people = {}, owner = nil, hidden = {}, complete = true, revision = 0 }

local function isWhole(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1
end

local function allKinds(on)
    local kinds = {}
    for _, kind in ipairs(People.KINDS) do
        kinds[kind] = on
    end
    return kinds
end

-- A new member: every room and kind, cameras and the alarm's status, no doors, no scenes.
function People.defaults(role)
    return {
        role = role == "admin" and "admin" or "member",
        all_rooms = true,
        rooms = {},
        kinds = allKinds(true),
        cameras = true,
        doors = false,
        alarm = true,
        scenes = {},
    }
end

local function opensDoors(scene)
    for _, step in ipairs(type(scene) == "table" and scene.steps or {}) do
        if type(step) == "table" and step.type == "relays" then
            return true
        end
    end
    return false
end

-- The person a 1.7.0 role becomes (the migration, ADR-054). `scenes`: the scenes there are
-- (Scenes.list()). doors: every room and kind, cameras, doors, the alarm and every scene; member:
-- the same without doors, and without the scenes that open doors or gates (in 1.7.0 their doors
-- were skipped for a member: running them in full now would open doors for someone who could not);
-- viewer: no rooms and cameras only; admin: an admin.
function People.fromLegacy(role, scenes)
    if role == "admin" then
        return People.defaults("admin")
    end
    local record = People.defaults("member")
    if role == "doors" or role == "member" then
        record.doors = role == "doors"
        for _, scene in ipairs(scenes or {}) do
            if type(scene) == "table" and type(scene.id) == "string" and (record.doors or not opensDoors(scene)) then
                record.scenes[#record.scenes + 1] = scene.id
            end
        end
        return record
    end
    record.all_rooms = false
    record.kinds = allKinds(false)
    record.alarm = false
    return record
end

-- The 1.7.0 role a person's keys keep: admin; a member with no rooms is a viewer; a member who opens
-- doors and gates, doors; any other member, member. 1.7.0 does not know rooms, kinds, cameras or
-- scenes: after a downgrade a member controls every room again (ADR-054).
function People.legacyRole(record)
    if type(record) ~= "table" then
        return nil
    end
    if record.role == "admin" then
        return "admin"
    end
    if not record.all_rooms and #(record.rooms or {}) == 0 then
        return "viewer"
    end
    return record.doors and "doors" or "member"
end

-- A record as kept: only known fields, lists without repeats. nil for something that is not one.
local function clean(item)
    if type(item) ~= "table" or (item.role ~= "admin" and item.role ~= "member") then
        return nil
    end
    local record = People.defaults(item.role)
    if type(item.all_rooms) == "boolean" then
        record.all_rooms = item.all_rooms
    end
    local seen = {}
    for _, id in ipairs(Store.items(item.rooms)) do
        id = tonumber(id)
        if isWhole(id) and not seen[id] and #record.rooms < People.MAX_ROOMS then
            seen[id] = true
            record.rooms[#record.rooms + 1] = id
        end
    end
    if type(item.kinds) == "table" then
        for _, kind in ipairs(People.KINDS) do
            if type(item.kinds[kind]) == "boolean" then
                record.kinds[kind] = item.kinds[kind]
            end
        end
    end
    for _, field in ipairs({ "cameras", "doors", "alarm" }) do
        if type(item[field]) == "boolean" then
            record[field] = item[field]
        end
    end
    seen = {}
    for _, id in ipairs(Store.items(item.scenes)) do
        if type(id) == "string" and id:match("^%x+$") and #id <= 16 and not seen[id] and #record.scenes < People.MAX_SCENES then
            seen[id] = true
            record.scenes[#record.scenes + 1] = id
        end
    end
    return record
end

local function copy(record)
    return record and clean(record) or nil
end

-- The record as stored and as the API shows it (rooms and scenes always lists).
function People.view(record)
    record = clean(record) or People.defaults("member")
    local rooms, scenes, kinds = Json.array(), Json.array(), {}
    for _, id in ipairs(record.rooms or {}) do
        rooms[#rooms + 1] = id
    end
    for _, id in ipairs(record.scenes or {}) do
        scenes[#scenes + 1] = id
    end
    for _, kind in ipairs(People.KINDS) do
        kinds[kind] = record.kinds[kind] == true
    end
    return {
        role = record.role,
        all_rooms = record.all_rooms == true,
        rooms = rooms,
        kinds = kinds,
        cameras = record.cameras == true,
        doors = record.doors == true,
        alarm = record.alarm == true,
        scenes = scenes,
    }
end

-- The people, owner and hidden rooms of a stored record ({ version, people, owner, hidden_rooms },
-- as the store or a backup holds it). Returns { people, owner, hidden } and how many were left out.
function People.read(data)
    local result, dropped = { people = {}, owner = nil, hidden = {} }, 0
    if type(data) ~= "table" then
        return result, 0
    end
    if type(data.people) == "table" then
        for id, item in pairs(data.people) do
            local record = type(id) == "string" and id:match("^%x+$") and clean(item) or nil
            if record then
                result.people[id] = record
            else
                dropped = dropped + 1
            end
        end
    end
    if type(data.owner) == "string" and data.owner:match("^%x+$") then
        result.owner = data.owner
    end
    for _, id in ipairs(Store.items(data.hidden_rooms)) do
        id = tonumber(id)
        if isWhole(id) then
            result.hidden[id] = true
        end
    end
    return result, dropped
end

local function record(read)
    local people = {}
    for id, item in pairs(read.people) do
        people[id] = People.view(item)
    end
    local hidden = {}
    for id in pairs(read.hidden) do
        hidden[#hidden + 1] = id
    end
    table.sort(hidden)
    local list = Json.array()
    for _, id in ipairs(hidden) do
        list[#list + 1] = id
    end
    return { version = People.STORE_VERSION, people = people, owner = read.owner, hidden_rooms = list }
end

local function current()
    return { people = state.people, owner = state.owner, hidden = state.hidden }
end

local function save()
    state.revision = state.revision + 1
    if not state.complete then
        Log.error("auth", "people not saved: their store could not be read at start")
        return false
    end
    local ok = Store.write(STORE_KEY, record(current()), false)
    if not ok then
        Log.error("auth", "could not save the people's roles")
    end
    return ok
end

function People.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable" and (data == nil or type(data) == "table")
    local read = People.read(data)
    state.people, state.owner, state.hidden = read.people, read.owner, read.hidden
    state.revision = state.revision + 1
    if not state.complete then
        Log.error("auth", "the people's roles could not be read; keys follow their 1.7.0 roles until the next start")
    end
    local count = 0
    for _ in pairs(state.people) do
        count = count + 1
    end
    return count, form
end

-- False after a load that could not read the store: nothing is written over it.
function People.complete()
    return state.complete
end

function People.revision()
    return state.revision
end

-- A copy of a person's record, or nil.
function People.get(profileId)
    return copy(state.people[profileId])
end

-- The record as kept, not copied: for Access, which only reads it.
function People.peek(profileId)
    return state.people[profileId]
end

-- Replaces a person's record (checked by the API). Returns true once saved; nil and UNAVAILABLE
-- when the store could not be read at start, PERSIST_FAILED when it could not be written.
function People.set(profileId, item)
    if not state.complete then
        return nil, "UNAVAILABLE"
    end
    local record = clean(item)
    if type(profileId) ~= "string" or not record then
        return nil, "INVALID"
    end
    local before = state.people[profileId]
    state.people[profileId] = record
    if not save() then
        state.people[profileId] = before
        return nil, "PERSIST_FAILED"
    end
    return true
end

-- Every person's record (profile id -> copy).
function People.all()
    local result = {}
    for id, item in pairs(state.people) do
        result[id] = copy(item)
    end
    return result
end

-- The profile that claimed the home last (remote.lua), when it is still one.
function People.claimedBy()
    return state.owner
end

function People.setOwner(profileId)
    if not state.complete or type(profileId) ~= "string" or state.owner == profileId then
        return state.owner == profileId
    end
    state.owner = profileId
    return save()
end

-- The home's owner among `profiles` (Profiles.list()): the profile that claimed the home for an
-- account, while it is an admin; else the oldest admin. nil when there is no admin.
function People.ownerOf(profiles)
    local oldest
    for _, profile in ipairs(profiles or {}) do
        local item = state.people[profile.id]
        if item and item.role == "admin" then
            if profile.id == state.owner then
                return profile.id
            end
            if not oldest or tostring(profile.created_at or "") < tostring(oldest.created_at or "") then
                oldest = profile
            end
        end
    end
    return oldest and oldest.id or nil
end

-- The rooms hidden from members: room id -> true (not a copy: read only).
function People.hiddenRooms()
    return state.hidden
end

function People.setRoomHidden(roomId, hidden)
    if not state.complete then
        return nil, "UNAVAILABLE"
    end
    if (state.hidden[roomId] == true) == (hidden == true) then
        return true
    end
    state.hidden[roomId] = hidden and true or nil
    if not save() then
        state.hidden[roomId] = (not hidden) and true or nil
        return nil, "PERSIST_FAILED"
    end
    return true
end

-- Every key keeps the 1.7.0 role of its person (`keys`: src/auth/keys.lua); the keys of a person
-- without a record stay as they are. Returns how many changed.
function People.syncKeys(keys)
    if not state.complete then
        return 0
    end
    return (keys.setRoles(function(key)
        local item = key.profile and state.people[key.profile]
        return item and People.legacyRole(item) or nil
    end))
end

-- Brings the records in line with the keys (`keys`: Keys.list(), `profiles`: Profiles.list(),
-- `scenes`: Scenes.list()): a person without a record becomes what the highest role among their
-- keys was (People.fromLegacy), and so, unless `missingOnly`, does a person whose keys no longer
-- have the 1.7.0 role worked out from their record (DirectorLink 1.7.0 changed them after a
-- downgrade: what was decided last wins); records of profiles that are gone go. Returns how many
-- people were read from their keys.
local RANK = { viewer = 1, member = 2, doors = 3, admin = 4 }

function People.reconcile(keys, profiles, scenes, missingOnly)
    if not state.complete then
        return 0
    end
    local roles = {}
    for _, key in ipairs(keys or {}) do
        if key.profile then
            roles[key.profile] = roles[key.profile] or {}
            table.insert(roles[key.profile], key.role)
        end
    end
    local changed, migrated, exists = false, 0, {}
    for _, profile in ipairs(profiles or {}) do
        exists[profile.id] = true
        local item = state.people[profile.id]
        local theirs = roles[profile.id] or {}
        local stale = false
        local highest = nil
        for _, role in ipairs(theirs) do
            stale = stale or (item ~= nil and not missingOnly and role ~= People.legacyRole(item))
            if RANK[role] and (not highest or RANK[role] > RANK[highest]) then
                highest = role
            end
        end
        if (not item or stale) and highest then
            state.people[profile.id] = People.fromLegacy(highest, scenes)
            migrated = migrated + 1
            changed = true
        end
    end
    for id in pairs(state.people) do
        if not exists[id] then
            state.people[id] = nil
            changed = true
        end
    end
    if state.owner and not exists[state.owner] then
        state.owner = nil
        changed = true
    end
    if changed then
        save()
    end
    if migrated > 0 then
        Log.info("auth", "people's roles worked out from their keys", { people = migrated })
    end
    return migrated
end

-- Records of profiles that are gone go (`profiles`: Profiles.list()), with the owner's claim.
function People.prune(profiles)
    if not state.complete then
        return 0
    end
    local exists, removed = {}, 0
    for _, profile in ipairs(profiles or {}) do
        exists[profile.id] = true
    end
    for id in pairs(state.people) do
        if not exists[id] then
            state.people[id] = nil
            removed = removed + 1
        end
    end
    local ownerGone = state.owner ~= nil and not exists[state.owner]
    if ownerGone then
        state.owner = nil
    end
    if removed > 0 or ownerGone then
        save()
    end
    return removed
end

-- Backups (ADR-042, src/core/backup.lua): the store as it is.
function People.backup()
    return record(current())
end

-- Replaces everything with what `data` holds (a backup's section, matched by the restore). Returns
-- true once saved.
function People.restore(data)
    local read = People.read(data)
    state.people, state.owner, state.hidden = read.people, read.owner, read.hidden
    state.complete = true
    return save()
end

return People
