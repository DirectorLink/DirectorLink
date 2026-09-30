-- Backups (ADR-042, docs/BACKUP.md): everything DirectorLink keeps on the controller, in one
-- document an admin downloads (GET /v1/backup) and restores (POST /v1/restore), only in sealed
-- requests: it holds every key's hash and lock key and the home's remote identity. The app encrypts
-- it with a password before it is saved and decrypts it before it comes back; the controller never
-- sees the password or the file.
--
-- A restore checks the whole document first, then replaces every store together or none: when a
-- write fails, the values from before are put back. What refers to the project's devices and rooms
-- by id (scene steps, favorites, hidden rooms, room names and the room order) is matched to the
-- project as it is now: by id, else by the same name in the same room; what matches nothing is left
-- out and listed. Composer properties are never restored, only listed: a file must never switch a
-- safety setting on.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Random = require("src.core.random")
local Version = require("src.core.version")
local Keys = require("src.auth.keys")
local Profiles = require("src.auth.profiles")
local RoomNames = require("src.core.room_names")
local RoomLayout = require("src.core.room_layout")
local Scenes = require("src.core.scenes")
local Schedules = require("src.core.schedules")
local JewishCalendar = require("src.core.jewish_calendar")
local Relay = require("src.cloud.relay")

local Backup = {}

Backup.FORMAT = "directorlink-backup"
Backup.FORMAT_VERSION = 1
-- The document comes back as its JSON text in parts (POST /v1/restore/parts), each small enough for
-- a sealed request at home (64 KiB of HTTP body) and through the account.
Backup.MAX_BYTES = 2 * 1024 * 1024
Backup.MAX_PART_BYTES = 48 * 1024
Backup.MAX_PARTS = 100
Backup.UPLOAD_SECONDS = 600
-- References that match nothing, listed one by one in a preview (all are counted).
Backup.MAX_LISTED = 100
-- DirectorLink's Composer properties: listed in the preview, never restored.
Backup.COMPOSER = { "Door Control", "Relay Hold", "Schedules", "Jewish Calendar", "Alarm Status", "Remote Access", "Log Level" }

-- Each section: the newest version of its store this driver reads (an older one is read as an
-- update reads it), and what it is.
local SECTIONS = {
    keys = { version = Keys.STORE_VERSION, list = "keys" },
    profiles = { version = 1, list = "profiles" },
    room_names = { version = 1, object = "rooms" },
    room_order = { version = 1, list = "order" },
    scenes = { version = 1, list = "scenes" },
    schedules = { version = 1, list = "schedules" },
    calendar = { version = 1, object = "settings" },
    remote_identity = { version = 1 },
}

-- Scene step types and favorites ("kind:id") name the kinds of the project's devices so.
local STEP_KINDS = { lights = "light", climate = "climate", fans = "fan", blinds = "blind", relays = "relay" }
local FAVORITE_KINDS = { light = "light", thermostat = "climate", fan = "fan", blind = "blind", camera = "camera", relay = "relay", doorbell = "doorbell" }

local function isWhole(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isObject(value)
    return type(value) == "table" and value ~= Json.null and not Json.isArray(value)
end

local function isHex(value, length)
    return type(value) == "string" and #value == length and value:match("^%x+$") ~= nil
end

local function items(list)
    local result = {}
    if type(list) == "table" and list ~= Json.null then
        for _, item in ipairs(list) do
            result[#result + 1] = item
        end
    end
    return result
end

local function nullable(value)
    if value == nil then
        return Json.null
    end
    return value
end

-- ---- The document ----------------------------------------------------------------------------

-- The project's name: its site, the top of Composer's project tree.
local function homeName(registry)
    local found
    for id, location in pairs(registry.locations or {}) do
        if location.type == "site" and (not found or tonumber(id) < found.id) then
            found = { id = tonumber(id), name = location.name }
        end
    end
    return found and found.name or nil
end

-- Calls visit(kind, id) for every device a section names ("room" for rooms).
local function eachReference(sections, visit)
    for _, scene in ipairs(items(sections.scenes and sections.scenes.scenes)) do
        for _, step in ipairs(items(type(scene) == "table" and scene.steps or nil)) do
            if type(step) == "table" then
                if tonumber(step.room_id) then
                    visit("room", tonumber(step.room_id))
                end
                for _, id in ipairs(items(step.device_ids)) do
                    if tonumber(id) then
                        visit(STEP_KINDS[step.type], tonumber(id))
                    end
                end
            end
        end
    end
    for _, profile in ipairs(items(sections.profiles and sections.profiles.profiles)) do
        local prefs = type(profile) == "table" and type(profile.prefs) == "table" and profile.prefs or {}
        for _, entry in ipairs(items(prefs.favorites)) do
            local kind, id = tostring(entry):match("^(%l+):(%d+)$")
            if kind then
                visit(FAVORITE_KINDS[kind], tonumber(id))
            end
        end
        for _, id in ipairs(items(prefs.hidden_rooms)) do
            if tonumber(id) then
                visit("room", tonumber(id))
            end
        end
    end
    local names = sections.room_names and sections.room_names.rooms
    for id in pairs(isObject(names) and names or {}) do
        if tonumber(id) then
            visit("room", tonumber(id))
        end
    end
    for _, id in ipairs(items(sections.room_order and sections.room_order.order)) do
        if tonumber(id) then
            visit("room", tonumber(id))
        end
    end
end

-- The names of the rooms and devices the sections name, as the project has them now: what a
-- restore matches by name when an id no longer fits.
local function references(registry, sections)
    local rooms, devices = {}, {}
    local function addRoom(id)
        local room = (registry.rooms or {})[id]
        if room then
            rooms[tostring(id)] = { name = room.name }
        end
    end
    eachReference(sections, function(kind, id)
        if kind == "room" then
            addRoom(id)
            return
        end
        local device = (registry.devices or {})[id]
        if device then
            devices[tostring(id)] = { name = device.name, kind = device.kind, room_id = nullable(tonumber(device.room_id)) }
            if tonumber(device.room_id) then
                addRoom(tonumber(device.room_id))
            end
        end
    end)
    return { rooms = rooms, devices = devices }
end

local function composerValues()
    local values = {}
    for _, name in ipairs(Backup.COMPOSER) do
        values[name] = nullable(Properties and Properties[name] or nil)
    end
    return values
end

-- The document GET /v1/backup answers (docs/BACKUP.md).
function Backup.export(registry)
    local sections = {
        keys = Keys.backup(),
        profiles = Profiles.backup(),
        room_names = RoomNames.backup(),
        room_order = RoomLayout.backup(),
        scenes = Scenes.backup(),
        schedules = Schedules.backup(),
        calendar = JewishCalendar.backup(),
        remote_identity = Relay.backupIdentity(),
    }
    return {
        format = Backup.FORMAT,
        format_version = Backup.FORMAT_VERSION,
        driver_version = Version.BRIDGE_VERSION,
        created_at = Clock.iso(),
        home = { name = nullable(homeName(registry)) },
        composer = composerValues(),
        references = references(registry, sections),
        sections = sections,
    }
end

-- ---- Parts of a document on its way back -------------------------------------------------------

-- One at a time: a new first part replaces a document not used yet.
local upload = nil

local function uploadProblem(code, detail)
    return nil, { status = code == "UPLOAD_NOT_FOUND" and 404 or 400, code = code, detail = detail }
end

-- A part of the document's JSON text: { upload (after the first), index (from 0), count, text }.
-- Returns { upload, received, count, complete }, or nil and a problem.
function Backup.receivePart(keyId, body, now)
    local count, index, text = body.count, body.index, body.text
    if not isWhole(count, 1, Backup.MAX_PARTS) then
        return uploadProblem("INVALID_FIELD", "count is how many parts there are, 1 to " .. Backup.MAX_PARTS)
    end
    if not isWhole(index, 0, count - 1) then
        return uploadProblem("INVALID_FIELD", "index is this part's place, from 0")
    end
    if type(text) ~= "string" or text == "" or #text > Backup.MAX_PART_BYTES then
        return uploadProblem("INVALID_FIELD", "text is a part of the backup's JSON, at most " .. Backup.MAX_PART_BYTES .. " bytes")
    end
    if index == 0 then
        if body.upload ~= nil then
            return uploadProblem("INVALID_FIELD", "The first part starts a new upload: leave out upload")
        end
        upload = { id = Random.hex(16), key = keyId, count = count, parts = { text }, bytes = #text, expires = now + Backup.UPLOAD_SECONDS }
    else
        if not upload or upload.id ~= body.upload or upload.key ~= keyId or now > upload.expires or not upload.parts then
            return uploadProblem("UPLOAD_NOT_FOUND", "No upload with this id is waiting; send the backup again from its first part")
        end
        if upload.count ~= count or index ~= #upload.parts then
            return uploadProblem("INVALID_FIELD", "Send the parts in order: part " .. #upload.parts .. " of " .. upload.count .. " is next")
        end
        if upload.bytes + #text > Backup.MAX_BYTES then
            upload = nil
            return uploadProblem("BACKUP_TOO_LARGE", "A backup is at most " .. Backup.MAX_BYTES .. " bytes")
        end
        upload.parts[#upload.parts + 1] = text
        upload.bytes = upload.bytes + #text
        upload.expires = now + Backup.UPLOAD_SECONDS
    end
    return { upload = upload.id, received = #upload.parts, count = upload.count, complete = #upload.parts == upload.count }
end

-- The document an upload of `keyId` carried, once all its parts are in (read once, then kept for
-- the restore that follows its check); nil and a problem otherwise.
function Backup.uploaded(keyId, id, now)
    if not upload or upload.id ~= id or upload.key ~= keyId or now > upload.expires then
        return uploadProblem("UPLOAD_NOT_FOUND", "No upload with this id is waiting; send the backup again")
    end
    if upload.parts then
        if #upload.parts ~= upload.count then
            return nil, { status = 409, code = "UPLOAD_INCOMPLETE", detail = "Part " .. #upload.parts .. " of " .. upload.count .. " is next" }
        end
        local document, err = Json.decode(table.concat(upload.parts))
        upload.parts = nil
        if type(document) ~= "table" then
            upload = nil
            return nil, { status = 422, code = "BACKUP_INVALID", detail = "The backup is not valid JSON: " .. tostring(err) }
        end
        upload.document = document
    end
    upload.expires = now + Backup.UPLOAD_SECONDS
    return upload.document
end

function Backup.forget(id)
    if upload and upload.id == id then
        upload = nil
    end
end

-- ---- Checking a document ---------------------------------------------------------------------

local function versionNumbers(text)
    local major, minor, patch = tostring(text or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if major then
        return { tonumber(major), tonumber(minor), tonumber(patch) }
    end
    return nil
end

-- True when `version` is a DirectorLink newer than `installed` (a development build is neither).
function Backup.newer(version, installed)
    local backup, mine = versionNumbers(version), versionNumbers(installed)
    if not backup or not mine then
        return false
    end
    for index = 1, 3 do
        if backup[index] ~= mine[index] then
            return backup[index] > mine[index]
        end
    end
    return false
end

local function invalid(errors)
    local detail = errors[1] and errors[1].message or "The backup is not valid"
    return nil, { status = 422, code = "BACKUP_INVALID", detail = detail, errors = errors }
end

local function tooNew(detail)
    return nil, { status = 409, code = "BACKUP_TOO_NEW", detail = detail }
end

local function validIdentity(section)
    if not isHex(section.home_id, 32) or not isHex(section.home_secret, 64) then
        return false
    end
    if section.next_secrets ~= nil and section.next_secrets ~= Json.null then
        if type(section.next_secrets) ~= "table" then
            return false
        end
        for _, item in ipairs(section.next_secrets) do
            if type(item) ~= "table" or not isHex(item.secret, 64) or type(item.at) ~= "number" then
                return false
            end
        end
    end
    return true
end

-- The document's own checks: what it is, from which DirectorLink, and a section of the right shape
-- for every store. Returns true, or nil and a problem.
local function validate(document)
    if not isObject(document) or document.format ~= Backup.FORMAT then
        return invalid({ { field = "format", message = "This is not a DirectorLink backup" } })
    end
    if not isWhole(document.format_version, 1, math.huge) then
        return invalid({ { field = "format_version", message = "format_version is missing" } })
    end
    if document.format_version > Backup.FORMAT_VERSION or Backup.newer(document.driver_version, Version.BRIDGE_VERSION) then
        return tooNew("This backup was made by DirectorLink " .. tostring(document.driver_version)
            .. ", newer than this one (" .. tostring(Version.BRIDGE_VERSION) .. "). Update DirectorLink first.")
    end
    if type(document.created_at) ~= "string" or type(document.driver_version) ~= "string" then
        return invalid({ { field = "created_at", message = "created_at and driver_version say when and by which DirectorLink the backup was made" } })
    end
    local sections = document.sections
    if not isObject(sections) then
        return invalid({ { field = "sections", message = "sections is missing" } })
    end
    local errors = {}
    for name in pairs(sections) do
        if not SECTIONS[name] then
            errors[#errors + 1] = { field = "sections." .. tostring(name), message = "Unknown section: " .. tostring(name) }
        end
    end
    for name, rule in pairs(SECTIONS) do
        local section = sections[name]
        local field = "sections." .. name
        if not isObject(section) then
            errors[#errors + 1] = { field = field, message = "The backup has no " .. name }
        elseif not isWhole(section.version, 1, math.huge) then
            errors[#errors + 1] = { field = field .. ".version", message = name .. " has no version" }
        elseif section.version > rule.version then
            return tooNew("This backup's " .. name .. " were saved by a newer DirectorLink (store version " .. section.version .. "). Update DirectorLink first.")
        elseif rule.list and not (type(section[rule.list]) == "table" and (Json.isArray(section[rule.list]) or next(section[rule.list]) == nil)) then
            errors[#errors + 1] = { field = field .. "." .. rule.list, message = name .. " must have a list " .. rule.list }
        elseif rule.object and not isObject(section[rule.object]) then
            errors[#errors + 1] = { field = field .. "." .. rule.object, message = name .. " must have an object " .. rule.object }
        elseif name == "remote_identity" and not validIdentity(section) then
            errors[#errors + 1] = { field = field, message = "The remote identity is not valid" }
        end
    end
    if #errors > 0 then
        table.sort(errors, function(a, b)
            return a.field < b.field
        end)
        return invalid(errors)
    end
    return true
end

-- ---- Matching the project ----------------------------------------------------------------------

-- Matches the backup's room and device ids to the project (`registry`), with what the backup says
-- of them (`refs`: its references), and keeps count for the preview.
local function newMatcher(registry, refs)
    refs = isObject(refs) and refs or {}
    return {
        registry = registry,
        rooms = isObject(refs.rooms) and refs.rooms or {},
        devices = isObject(refs.devices) and refs.devices or {},
        found = {},
        byId = 0,
        byName = {},
        renamed = {},
        unmatched = {},
        missing = {},
    }
end

local function infoName(info)
    return isObject(info) and type(info.name) == "string" and info.name or nil
end

-- The room a backup's room id is now: the same id, else the one room of the same name.
local function findRoom(m, id)
    local rooms = m.registry.rooms or {}
    if rooms[id] then
        return id, "id"
    end
    local name = infoName(m.rooms[tostring(id)])
    if not name then
        return nil
    end
    local match, count = nil, 0
    for roomId, room in pairs(rooms) do
        if room.name == name then
            match, count = tonumber(roomId), count + 1
        end
    end
    if count == 1 then
        return match, "name"
    end
    return nil
end

-- The device of `kind` a backup's device id is now: the same id if it is still a device of that
-- kind, else the one device of that kind with the same name in the same room.
local function findDevice(m, id, kind)
    local devices = m.registry.devices or {}
    local device = devices[id]
    if device and device.kind == kind then
        return id, "id"
    end
    local info = m.devices[tostring(id)]
    local name = infoName(info)
    if not name then
        return nil
    end
    local room = nil
    if tonumber(info.room_id) then
        room = findRoom(m, tonumber(info.room_id))
        if not room then
            return nil
        end
    end
    local match, count = nil, 0
    for deviceId, candidate in pairs(devices) do
        if candidate.kind == kind and candidate.name == name and (room == nil or tonumber(candidate.room_id) == room) then
            match, count = tonumber(deviceId), count + 1
        end
    end
    if count == 1 then
        return match, "name"
    end
    return nil
end

local function roomLabel(m, roomId)
    local info = m.rooms[tostring(roomId)]
    return infoName(info)
end

-- Resolves one reference: returns the id to keep, or nil (left out, listed with `where`: the
-- section and the name of what used it).
local function resolve(m, kind, id, where)
    local key = kind .. ":" .. tostring(id)
    local found = m.found[key]
    if found == nil then
        local newId, how
        if kind == "room" then
            newId, how = findRoom(m, id)
        else
            newId, how = findDevice(m, id, kind)
        end
        local info = kind == "room" and m.rooms[tostring(id)] or m.devices[tostring(id)]
        local name = infoName(info)
        local current = newId and (kind == "room" and (m.registry.rooms or {})[newId] or (m.registry.devices or {})[newId]) or nil
        if how == "id" then
            m.byId = m.byId + 1
            if name and current and current.name ~= name then
                m.renamed[#m.renamed + 1] = { kind = kind, id = id, name = name, now = current.name }
            end
        elseif how == "name" then
            m.byName[#m.byName + 1] = { kind = kind, name = name, room = kind ~= "room" and nullable(roomLabel(m, info.room_id)) or Json.null, from = id, to = newId }
        else
            local entry = {
                kind = kind,
                id = id,
                name = nullable(name),
                room = kind ~= "room" and isObject(info) and nullable(roomLabel(m, info.room_id)) or Json.null,
                used_in = Json.array(),
            }
            m.missing[key] = entry
            m.unmatched[#m.unmatched + 1] = entry
        end
        found = newId or false
        m.found[key] = found
    end
    if found == false then
        local entry = m.missing[key]
        if #entry.used_in < 10 then
            local seen = false
            for _, use in ipairs(entry.used_in) do
                seen = seen or (use.section == where.section and use.name == where.name)
            end
            if not seen then
                entry.used_in[#entry.used_in + 1] = { section = where.section, name = nullable(where.name) }
            end
        end
        return nil
    end
    return found
end

-- The scenes with their steps matched; a step left with no device, or whose room is not in the
-- project (it would reach every room), is left out.
local function matchScenes(m, scenes, counts)
    local seen = {}
    local result = Json.array()
    for _, scene in ipairs(scenes) do
        if seen[scene.id] then
            counts.scenes = counts.scenes + 1
        else
            seen[scene.id] = true
            local steps = Json.array()
            local where = { section = "scenes", name = scene.name }
            for _, step in ipairs(scene.steps) do
                local keep = true
                local roomId = step.room_id
                if roomId then
                    roomId = resolve(m, "room", roomId, where)
                    keep = roomId ~= nil
                end
                local ids = nil
                if keep and step.device_ids then
                    ids = Json.array()
                    local listed = {}
                    for _, id in ipairs(step.device_ids) do
                        local newId = resolve(m, STEP_KINDS[step.type], id, where)
                        if newId and not listed[newId] then
                            listed[newId] = true
                            ids[#ids + 1] = newId
                        end
                    end
                    keep = #ids > 0
                end
                if keep then
                    steps[#steps + 1] = { type = step.type, room_id = roomId, device_ids = ids, set = step.set }
                else
                    counts.steps = counts.steps + 1
                end
            end
            result[#result + 1] = {
                id = scene.id,
                name = scene.name,
                icon = scene.icon,
                show_on_home = scene.show_on_home,
                steps = steps,
                created_at = scene.created_at,
                updated_at = scene.updated_at,
                version = scene.version,
            }
        end
    end
    return result
end

local function matchProfiles(m, profiles, counts)
    local seen = {}
    local result = Json.array()
    for _, profile in ipairs(profiles) do
        if seen[profile.id] then
            counts.profiles = counts.profiles + 1
        else
            seen[profile.id] = true
            local where = { section = "profiles", name = profile.name }
            local favorites, listed = Json.array(), {}
            for _, entry in ipairs(profile.prefs.favorites or {}) do
                local kind, id = tostring(entry):match("^(%l+):(%d+)$")
                local newId = kind and FAVORITE_KINDS[kind] and resolve(m, FAVORITE_KINDS[kind], tonumber(id), where) or nil
                local value = newId and (kind .. ":" .. newId) or nil
                if value and not listed[value] and #favorites < Profiles.MAX_FAVORITES then
                    listed[value] = true
                    favorites[#favorites + 1] = value
                end
            end
            local hidden, hiddenSeen = Json.array(), {}
            for _, id in ipairs(profile.prefs.hidden_rooms or {}) do
                local newId = tonumber(id) and resolve(m, "room", tonumber(id), where) or nil
                if newId and not hiddenSeen[newId] then
                    hiddenSeen[newId] = true
                    hidden[#hidden + 1] = newId
                end
            end
            result[#result + 1] = {
                id = profile.id,
                name = profile.name,
                created_at = profile.created_at,
                version = profile.version,
                prefs = {
                    language = profile.prefs.language,
                    theme = profile.prefs.theme,
                    palette = profile.prefs.palette,
                    favorites = favorites,
                    hidden_rooms = hidden,
                },
            }
        end
    end
    return result
end

local function matchRoomNames(m, names)
    local rooms = {}
    local ids = {}
    for id in pairs(names) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local count = 0
    for _, id in ipairs(ids) do
        local newId = resolve(m, "room", id, { section = "room_names" })
        if newId and next(names[id]) then
            local key = tostring(newId)
            if not rooms[key] then
                rooms[key] = {}
                count = count + 1
            end
            for language, name in pairs(names[id]) do
                rooms[key][language] = rooms[key][language] or name
            end
        end
    end
    return rooms, count
end

local function matchRoomOrder(m, order)
    local result, seen = Json.array(), {}
    for _, id in ipairs(order) do
        local newId = resolve(m, "room", id, { section = "room_order" })
        if newId and not seen[newId] then
            seen[newId] = true
            result[#result + 1] = newId
        end
    end
    return result
end

-- ---- The keys and the remote identity ----------------------------------------------------------

-- The backup's keys, and the restoring admin's own as it is now, whatever the backup says of it: it
-- must keep working (ADR-042). Returns the keys and what the preview says of them.
local function mergeKeys(section, restorerId, now)
    local backupKeys, dropped = Keys.read(section)
    local current = nil
    for _, key in ipairs(Keys.backup().keys) do
        if key.id == restorerId then
            current = key
        end
    end
    local result, seen = Json.array(), {}
    local info = { expired = 0, left_out = dropped, conflict = false, yours = "added", limit = Keys.MAX_KEYS }
    for _, key in ipairs(backupKeys) do
        if key.expires and key.expires <= now then
            info.expired = info.expired + 1
        elseif seen[key.id] then
            info.left_out = info.left_out + 1
        elseif current and key.id == current.id then
            seen[key.id] = true
            if key.hash == current.hash then
                info.yours = "in_backup"
            else
                -- Another key with this key's id (8 random hex digits): the one in use wins.
                info.conflict = true
            end
            result[#result + 1] = current
        else
            seen[key.id] = true
            result[#result + 1] = key
        end
    end
    if current and not seen[current.id] then
        result[#result + 1] = current
    end
    info.count = #result
    info.over_limit = #result > Keys.MAX_KEYS
    return result, info, current
end

local function copyIdentity(identity)
    if not identity then
        return nil
    end
    local candidates = nil
    for _, item in ipairs(identity.next_secrets or {}) do
        candidates = candidates or {}
        candidates[#candidates + 1] = { secret = item.secret, at = item.at }
    end
    return { home_id = identity.home_id, home_secret = identity.home_secret, next_secrets = candidates, previous = copyIdentity(identity.previous) }
end

-- The identity to use after the restore (ADR-042). The same home: the one in use stays (its
-- secret may be newer than the backup's). Another home: the backup's, with the one it replaces kept
-- as `previous` until the relay accepts it; if the relay refuses it, that one comes back. A
-- controller that has none yet (remote access never on) takes the backup's.
local function chooseIdentity(section)
    local backup = { home_id = section.home_id, home_secret = section.home_secret, next_secrets = {} }
    for _, item in ipairs(items(section.next_secrets)) do
        backup.next_secrets[#backup.next_secrets + 1] = { secret = item.secret, at = item.at }
    end
    if #backup.next_secrets == 0 then
        backup.next_secrets = nil
    end
    local current = copyIdentity(Relay.storedIdentity())
    if not current then
        return backup, "restore", nil
    end
    local fallback = current.previous or current
    if section.home_id == current.home_id then
        return current, "same", current.home_id
    end
    if section.home_id == fallback.home_id then
        fallback.previous = nil
        return fallback, "restore", current.home_id
    end
    fallback.previous = nil
    backup.previous = fallback
    return backup, "restore", current.home_id
end

-- ---- Planning and applying a restore --------------------------------------------------------------

-- Checks `document` against this controller and works out everything a restore writes, without
-- changing anything. `context`: { registry, restorer (the admin's key id), now }. Returns the plan
-- ({ sections, identity, preview }), or nil and a problem ({ status, code, detail, errors }).
function Backup.plan(document, context)
    local ok, problem = validate(document)
    if not ok then
        return nil, problem
    end
    local now = context.now or Clock.now()
    local sections = document.sections
    local m = newMatcher(context.registry, document.references)
    local counts = { scenes = 0, steps = 0, schedules = 0, profiles = 0 }

    local keys, keyInfo, restorer = mergeKeys(sections.keys, context.restorer, now)

    local profiles, droppedProfiles = Profiles.read(sections.profiles)
    counts.profiles = droppedProfiles
    local matchedProfiles = matchProfiles(m, profiles, counts)
    -- The restoring admin's profile, when the backup does not have it, comes along with the key.
    if restorer and restorer.profile then
        local present = false
        for _, profile in ipairs(matchedProfiles) do
            present = present or profile.id == restorer.profile
        end
        local own = not present and Profiles.find(restorer.profile) or nil
        if own then
            matchedProfiles[#matchedProfiles + 1] = own
        end
    end

    local scenes, droppedSteps, droppedScenes = Scenes.read(sections.scenes)
    counts.steps, counts.scenes = droppedSteps, droppedScenes
    local matchedScenes = matchScenes(m, scenes, counts)
    local sceneIds = {}
    for _, scene in ipairs(matchedScenes) do
        sceneIds[scene.id] = true
    end

    local schedules, droppedSchedules = Schedules.read(sections.schedules)
    counts.schedules = droppedSchedules
    local keptSchedules, scheduleIds = Json.array(), {}
    for _, schedule in ipairs(schedules) do
        -- A schedule runs a scene of the backup, or none.
        if sceneIds[schedule.scene_id] and not scheduleIds[schedule.id] then
            scheduleIds[schedule.id] = true
            keptSchedules[#keptSchedules + 1] = schedule
        else
            counts.schedules = counts.schedules + 1
        end
    end

    local roomNames, namedRooms = matchRoomNames(m, RoomNames.read(sections.room_names))
    local order = matchRoomOrder(m, RoomLayout.read(sections.room_order))
    local calendar = JewishCalendar.read(sections.calendar)
    local identity, action, currentHome = chooseIdentity(sections.remote_identity)

    local composer = Json.array()
    local stored = isObject(document.composer) and document.composer or {}
    for _, name in ipairs(Backup.COMPOSER) do
        local value = stored[name]
        composer[#composer + 1] = {
            name = name,
            backup = type(value) == "string" and value or Json.null,
            current = nullable(Properties and Properties[name] or nil),
        }
    end

    local home = isObject(document.home) and document.home or {}
    local unmatched = Json.array()
    for index = 1, math.min(#m.unmatched, Backup.MAX_LISTED) do
        unmatched[index] = m.unmatched[index]
    end
    local preview = {
        backup = {
            created_at = document.created_at,
            driver_version = document.driver_version,
            format_version = document.format_version,
            home = type(home.name) == "string" and home.name or Json.null,
        },
        counts = {
            keys = #keys,
            profiles = #matchedProfiles,
            scenes = #matchedScenes,
            schedules = #keptSchedules,
            room_names = namedRooms,
            room_order = #order,
        },
        left_out = counts,
        keys = keyInfo,
        remote = {
            action = action,
            home_id = identity.home_id,
            current_home_id = nullable(currentHome),
            remote_access = Properties ~= nil and Properties["Remote Access"] == "On",
        },
        references = {
            by_id = m.byId,
            by_name = Json.array(m.byName),
            renamed = Json.array(m.renamed),
            unmatched = unmatched,
            unmatched_count = #m.unmatched,
        },
        composer = composer,
    }
    return {
        preview = preview,
        switching = action == "restore",
        sections = {
            keys = { version = Keys.STORE_VERSION, keys = keys },
            profiles = { version = 1, profiles = matchedProfiles },
            room_names = { version = 1, rooms = roomNames },
            room_order = { version = 1, order = order },
            scenes = { version = 1, scenes = matchedScenes },
            schedules = { version = 1, schedules = keptSchedules },
            calendar = { version = 1, settings = calendar },
            remote_identity = identity,
        },
    }
end

-- The stores in the order a restore writes them. `take` is what goes back when a later one fails.
local PARTS = {
    { name = "keys", take = Keys.backup, write = Keys.restore },
    { name = "profiles", take = Profiles.backup, write = Profiles.restore },
    { name = "room_names", take = RoomNames.backup, write = RoomNames.restore },
    { name = "room_order", take = RoomLayout.backup, write = RoomLayout.restore },
    { name = "scenes", take = Scenes.backup, write = Scenes.restore },
    {
        name = "schedules",
        take = Schedules.snapshot,
        write = function(data, now)
            return Schedules.restore(data, now)
        end,
        putBack = function(snapshot)
            return Schedules.restore(snapshot.data, nil, snapshot)
        end,
    },
    { name = "calendar", take = JewishCalendar.backup, write = JewishCalendar.restore },
    {
        name = "remote_identity",
        take = function()
            return copyIdentity(Relay.storedIdentity())
        end,
        write = Relay.restoreIdentity,
    },
}

local function write(part, data, now)
    local ok, saved = pcall(part.write, data, now)
    return ok and saved == true
end

-- Writes every store of `plan` (Backup.plan), or none: when one cannot be written, the ones written
-- so far, and that one, get their values from before. Returns true, or nil and the store that failed.
function Backup.apply(plan, now)
    now = now or Clock.now()
    local before = {}
    for index, part in ipairs(PARTS) do
        before[index] = part.take()
    end
    for index, part in ipairs(PARTS) do
        if not write(part, plan.sections[part.name], now) then
            for back = index, 1, -1 do
                local previous = PARTS[back]
                local ok, restored = pcall(previous.putBack or previous.write, before[back], now)
                if not (ok and restored == true) then
                    Log.error("backup", "a store could not be put back after a failed restore", { store = previous.name })
                end
            end
            Log.error("backup", "restore failed; the stores were put back", { store = part.name })
            return nil, part.name
        end
    end
    local counts = plan.preview.counts
    Log.info("backup", "restored from a backup", {
        made = plan.preview.backup.created_at,
        driver_version = plan.preview.backup.driver_version,
        keys = counts.keys,
        profiles = counts.profiles,
        scenes = counts.scenes,
        schedules = counts.schedules,
        remote = plan.preview.remote.action,
        unmatched = plan.preview.references.unmatched_count,
    })
    return true
end

return Backup
