-- Backup and restore (ADR-042, docs/BACKUP.md): GET /v1/backup, POST /v1/restore/parts and
-- POST /v1/restore, for admins, only in sealed requests. A round trip into a driver with fresh
-- storage, the document's checks, all or nothing, the restoring admin's key, devices matched by id
-- or by name, the remote identity, and a big home in parts.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

local counter = 0

local function Lock()
    return require("src.cloud.lock")
end

-- A driver with `project` (Mock.project()), an admin key paired at home: { mock, key, id }.
local function start(project, prepare)
    local mock = Mock.startDriver(project or Mock.project(), nil, nil, prepare)
    local key = T.pair(mock, "Owner phone")
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    return { mock = mock, key = key, id = me.id }
end

-- A request sealed at home, as the app sends every request (POST /v1/sealed). Returns the opened
-- answer (`json` decoded) and the HTTP request's body size.
local function sealed(s, request, key, keyId)
    local info = T.http(s.mock, "GET", "/v1/sealed").json
    counter = counter + 1
    request.id = "backup-" .. counter
    request.ts = info.time
    local lock = Lock().deviceKey(key or s.key)
    local envelope = Lock().seal(lock, info.home, keyId or s.id, "req", Json.encode(request))
    local body = Json.encode({ envelope = envelope })
    local response = T.http(s.mock, "POST", "/v1/sealed", { body = body })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock().open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer, #body
end

-- The same request as it runs once opened (src/cloud/remote.lua: the key as principal), without the
-- fake Director's AES, which is plain Lua and slow for a big home; with the size of the POST
-- /v1/sealed that would carry it (AES-CBC pads to 16 bytes, base64 takes 4 for 3).
local function opened(s, request)
    local plaintext = Json.encode({ id = "backup-0000", ts = os.time(), method = request.method, path = request.path, body = request.body or Json.null })
    local padded = (math.floor(#plaintext / 16) + 1) * 16
    local envelope = { v = 1, home = "lan", key = s.id, iv = string.rep("A", 22) .. "==", ct = string.rep("A", 4 * math.ceil(padded / 3)), mac = string.rep("A", 43) .. "=" }
    local status, _, body = require("src.api.server").handleRequest({
        method = request.method,
        path = request.path,
        query = {},
        headers = request.body and { ["content-type"] = "application/json" } or {},
        body = request.body and Json.encode(request.body) or "",
        principal = { id = s.id, name = "Owner phone", role = "admin", sealed = true },
    }, { ip = "192.168.1.50", port = "0" })
    return { status = status, body = body, json = Json.decode(body) }, #Json.encode({ envelope = envelope })
end

local function export(s, send)
    local answer = (send or sealed)(s, { method = "GET", path = "/v1/backup" })
    T.eq(answer.status, 200, answer.body)
    return answer.json, answer.body
end

-- Sends the document's JSON in parts of at most `size` bytes; returns the upload id and the
-- largest HTTP body a part took at home.
local function upload(s, document, size, send)
    local text = type(document) == "string" and document or Json.encode(document)
    size = size or 24000
    local count = math.ceil(#text / size)
    local id, largest = nil, 0
    for index = 0, count - 1 do
        local answer, bytes = (send or sealed)(s, { method = "POST", path = "/v1/restore/parts", body = {
            upload = id, index = index, count = count, text = text:sub(index * size + 1, (index + 1) * size),
        } })
        T.eq(answer.status, 200, answer.body)
        id = answer.json.upload
        largest = math.max(largest, bytes)
        T.eq(answer.json.received, index + 1)
        T.eq(answer.json.complete, index == count - 1)
    end
    return id, largest
end

local function restore(s, body, send)
    return (send or sealed)(s, { method = "POST", path = "/v1/restore", body = body })
end

-- Checks, then replaces everything with `document`; returns the result.
local function replace(s, document)
    local id = upload(s, document)
    local check = restore(s, { upload = id })
    T.eq(check.status, 200, check.body)
    T.eq(check.json.dry_run, true)
    local done = restore(s, { upload = id, dry_run = false })
    T.eq(done.status, 200, done.body)
    T.eq(done.json.dry_run, false)
    return done.json.restore, check.json.restore
end

local function createKey(s, name, role)
    local created = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = name, role = role } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json.id
end

local function stored(mock, name)
    local value = mock.persist[name]
    return type(value) == "string" and Json.decode(value:gsub("^json:", "")) or nil
end

-- The home as it was before the accident: scenes, a schedule, preferences, room names and order,
-- the calendar's settings, a member and a viewer, and its remote identity.
local function furnish(s)
    local night = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = {
        name = "Good night", icon = "moon", show_on_home = true,
        steps = {
            { type = "lights", device_ids = { 20, 21 }, set = { on = false } },
            { type = "blinds", room_id = 11, set = { position = 0 } },
            { type = "climate", device_ids = { 30 }, set = { mode = "cool", target_temperature = 24 } },
        },
    } })
    T.eq(night.status, 201, night.body)
    local morning = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = {
        name = "Morning", steps = { { type = "lights", room_id = 10, set = { brightness = 60 } } },
    } }).json
    local schedule = T.http(s.mock, "POST", "/v1/schedules", { key = s.key, body = {
        scene_id = night.json.id, trigger = { type = "time", at = "23:30" }, days = { 0, 1, 2, 3, 4 },
    } })
    T.eq(schedule.status, 201, schedule.body)
    T.eq(T.http(s.mock, "PATCH", "/v1/profile", { key = s.key, body = { prefs = {
        language = "he", theme = "dark", favorites = { "light:20", "thermostat:30", "blind:50" }, hidden_rooms = { 10 },
    } } }).status, 200)
    T.eq(T.http(s.mock, "PATCH", "/v1/rooms/11", { key = s.key, body = { names = { he = "סלון" } } }).status, 200)
    T.eq(T.http(s.mock, "PUT", "/v1/rooms/order", { key = s.key, body = { room_ids = { 11, 10 } } }).status, 200)
    -- The calendar's settings change only while it is on in Composer.
    Properties["Jewish Calendar"] = "On"
    T.eq(T.http(s.mock, "PATCH", "/v1/calendar/settings", { key = s.key, body = { candle_lighting_minutes = 30, havdalah_minutes = 50 } }).status, 200)
    local member, memberId = createKey(s, "Dana phone", "member")
    local viewer = createKey(s, "Hall tablet", "viewer")
    return { night = night.json, morning = morning, schedule = schedule.json, member = member, memberId = memberId, viewer = viewer }
end

local function list(mock, key, path)
    local response = T.http(mock, "GET", path, { key = key })
    T.eq(response.status, 200, response.body)
    return response.json
end

function tests.only_admins_in_sealed_requests_reach_the_backup()
    local s = start()
    for _, route in ipairs({ { "GET", "/v1/backup" }, { "POST", "/v1/restore/parts" }, { "POST", "/v1/restore" } }) do
        local clear = T.http(s.mock, route[1], route[2], { key = s.key, body = route[1] == "POST" and { dry_run = true } or nil })
        T.eq(clear.status, 403, route[2])
        T.eq(clear.json.code, "SEALED_REQUEST_REQUIRED", "in the clear the lock keys would cross the network")
    end
    for _, role in ipairs({ "viewer", "member", "doors" }) do
        local key, id = createKey(s, role .. " device", role)
        local answer = sealed(s, { method = "GET", path = "/v1/backup" }, key, id)
        T.eq(answer.status, 403, role)
        T.eq(answer.json.code, "FORBIDDEN")
        T.eq(sealed(s, { method = "POST", path = "/v1/restore", body = { document = {} } }, key, id).status, 403)
    end
    T.eq(export(s).format, "directorlink-backup")
end

function tests.the_document_holds_every_store_as_stored_and_no_key()
    local s = start()
    local home = furnish(s)
    Properties["Door Control"] = "Enabled"
    Properties["Remote Access"] = "On"
    local document, text = export(s)
    T.eq(document.format_version, 1)
    T.eq(document.driver_version, "dev")
    T.eq(document.home.name, "Home", "the project's site")
    T.truthy(document.created_at:match("^%d%d%d%d%-%d%d%-%d%dT"))
    T.eq(document.composer["Door Control"], "Enabled", "Composer's settings are listed")
    T.eq(document.composer["Remote Access"], "On")
    local sections = document.sections
    T.eq(#sections.scenes.scenes, 2)
    T.eq(#sections.schedules.schedules, 1)
    T.eq(sections.schedules.schedules[1].last_run, nil, "what schedules ran stays behind")
    T.eq(#sections.keys.keys, 3)
    T.eq(sections.keys.version, 4, "the keys as the store keeps them")
    for _, record in ipairs(sections.keys.keys) do
        T.truthy(record.hash:match("^%x+$") and record.lock:match("^%x+$"), "hashes and lock keys")
    end
    for _, secret in ipairs({ s.key, home.member, home.viewer }) do
        T.notContains(text, secret, "never a key itself")
    end
    T.eq(sections.profiles.profiles[1].prefs.language, "he")
    T.eq(sections.room_names.rooms["11"].he, "סלון")
    T.same(sections.room_order.order, { 11, 10 })
    T.eq(sections.calendar.settings.candle_lighting_minutes, 30)
    local identity = stored(s.mock, "directorlink_remote_identity")
    T.eq(sections.remote_identity.home_id, identity.home_id)
    T.eq(sections.remote_identity.home_secret, identity.home_secret)
    -- What the ids were, for a project whose ids changed.
    T.eq(document.references.devices["20"].name, "Kitchen Island")
    T.eq(document.references.devices["20"].room_id, 10)
    T.eq(document.references.devices["30"].kind, "climate")
    T.eq(document.references.rooms["11"].name, "Living Room")
    local invitations = require("src.auth.invitations")
    T.truthy(invitations.create("member", 3600, s.id), "an invitation waits")
    T.eq(export(s).sections.invitations, nil, "pending invitations are not in a backup")
end

function tests.a_restore_into_fresh_storage_brings_everything_back()
    local old = start()
    local home = furnish(old)
    local document = export(old)
    local scenes = list(old.mock, old.key, "/v1/scenes").items
    local schedules = list(old.mock, old.key, "/v1/schedules").items
    local profile = list(old.mock, old.key, "/v1/profile")
    local rooms = list(old.mock, old.key, "/v1/rooms").items

    -- The driver was removed and added again: nothing is left, and the owner pairs anew.
    local s = start()
    T.eq(#list(s.mock, s.key, "/v1/scenes").items, 0)
    local done, preview = replace(s, document)
    T.eq(preview.counts.scenes, 2)
    T.eq(preview.counts.schedules, 1)
    T.eq(preview.counts.keys, 4, "three from the backup, and the one restoring")
    T.eq(preview.keys.yours, "added")
    T.eq(preview.backup.home, "Home")
    T.eq(preview.references.unmatched_count, 0)
    T.eq(preview.references.by_id, 6, "rooms 10 and 11, lights 20 and 21, thermostat 30 and blind 50")
    T.eq(done.counts.scenes, 2)

    T.same(list(s.mock, s.key, "/v1/scenes").items, scenes, "the same scenes, ids and versions")
    local restoredSchedules = list(s.mock, s.key, "/v1/schedules").items
    T.eq(#restoredSchedules, 1)
    for _, field in ipairs({ "id", "scene_id", "trigger", "days", "enabled", "version", "created_at" }) do
        T.same(restoredSchedules[1][field], schedules[1][field], field)
    end
    -- Every device keeps working without pairing again: at home with its key, and sealed.
    T.eq(list(s.mock, old.key, "/v1/profile").prefs.language, "he", "the owner's old phone")
    T.same(list(s.mock, old.key, "/v1/profile").prefs, profile.prefs)
    T.eq(list(s.mock, home.member, "/v1/api-keys/current").role, "member")
    T.eq(list(s.mock, home.viewer, "/v1/api-keys/current").role, "viewer")
    T.eq(sealed(s, { method = "GET", path = "/v1/scenes" }, old.key, old.id).status, 200, "sealed with its lock key")
    T.eq(list(s.mock, s.key, "/v1/api-keys/current").role, "admin", "and the restoring admin's own")
    T.same(list(s.mock, s.key, "/v1/rooms").items, rooms, "names and order")
    Properties["Jewish Calendar"] = "On"
    T.eq(list(s.mock, s.key, "/v1/calendar").settings.candle_lighting_minutes, 30)
    T.eq(stored(s.mock, "directorlink_remote_identity").home_id, document.sections.remote_identity.home_id)
    T.eq(s.mock.properties["API Keys"], "4")
    -- And after the next start.
    local again = Mock.updateDriver(s.mock)
    T.same(list(again, old.key, "/v1/scenes").items, scenes)
end

function tests.a_check_changes_nothing()
    local old = start()
    furnish(old)
    local document = export(old)
    local s = start()
    local before = {}
    for name, value in pairs(s.mock.persist) do
        before[name] = value
    end
    local id = upload(s, document)
    local check = restore(s, { upload = id })
    T.eq(check.status, 200, check.body)
    T.eq(restore(s, { document = document }).status, 200, "a document in the request, checked the same way")
    for name, value in pairs(s.mock.persist) do
        if name ~= "directorlink_remote_seen" and name ~= "directorlink_random_pool" then
            T.eq(value, before[name], name .. " is unchanged")
        end
    end
    T.eq(#list(s.mock, s.key, "/v1/scenes").items, 0)
end

local function problem(s, document)
    local answer = restore(s, { document = document })
    return answer.status, answer.json and answer.json.code, answer.json
end

function tests.a_document_is_checked_before_anything_changes()
    local s = start()
    local good = export(s)
    local function variant(change)
        local document = Json.decode(Json.encode(good))
        change(document)
        return document
    end
    T.eq(problem(s, { hello = 1 }), 422, "not a backup")
    local status, code, body = problem(s, variant(function(d)
        d.format = "something-else"
    end))
    T.eq(status, 422)
    T.eq(code, "BACKUP_INVALID")
    T.eq(body.errors[1].field, "format")
    status, code, body = problem(s, variant(function(d)
        d.sections.scenes = nil
    end))
    T.eq(code, "BACKUP_INVALID", "every store has its section")
    T.eq(body.errors[1].field, "sections.scenes")
    status, code, body = problem(s, variant(function(d)
        d.sections.schedules.schedules = "all of them"
    end))
    T.eq(body.errors[1].field, "sections.schedules.schedules")
    status, code = problem(s, variant(function(d)
        d.sections.remote_identity.home_secret = "short"
    end))
    T.eq(code, "BACKUP_INVALID")
    status, code = problem(s, variant(function(d)
        d.sections.extra = { version = 1 }
    end))
    T.eq(code, "BACKUP_INVALID", "unknown sections")
    status, code = problem(s, variant(function(d)
        d.format_version = 2
    end))
    T.eq(status, 409)
    T.eq(code, "BACKUP_TOO_NEW")
    status, code = problem(s, variant(function(d)
        d.sections.keys.version = 5
    end))
    T.eq(code, "BACKUP_TOO_NEW", "a key store written by a newer DirectorLink")
    local parts = sealed(s, { method = "POST", path = "/v1/restore/parts", body = { index = 0, count = 1, text = "{not json" } })
    local bad = restore(s, { upload = parts.json.upload })
    T.eq(bad.status, 422)
    T.eq(bad.json.code, "BACKUP_INVALID")
    T.eq(restore(s, { upload = parts.json.upload, document = good }).status, 400, "one of upload and document")
    T.eq(restore(s, { document = good, dry_run = "yes" }).status, 400)
end

function tests.a_newer_directorlink_s_backup_is_refused_and_an_older_one_migrated()
    local s = start()
    local Version = require("src.core.version")
    Version.BRIDGE_VERSION = "1.4.0"
    local document = export(s)
    document.driver_version = "1.5.0"
    local status, code, body = problem(s, document)
    T.eq(status, 409)
    T.eq(code, "BACKUP_TOO_NEW")
    T.contains(body.detail, "1.5.0")
    document.driver_version = "1.4.1"
    T.eq(problem(s, document), 409)

    -- 1.2.0 kept its keys in store version 3: the console's key expires a day from the restore, as
    -- it does at an update to 1.3.0.
    local console = { id = "c0501e00", name = "DirectorLink Console", role = "admin", alg = "sha256", hash = string.rep("ab", 32), lock = string.rep("cd", 32), created_at = "2026-01-01T00:00:00Z" }
    document.driver_version = "1.2.0"
    document.sections.keys = { version = 3, keys = { console } }
    local answer = restore(s, { document = document, dry_run = false })
    T.eq(answer.status, 200, answer.body)
    local keys = stored(s.mock, "directorlink_api_key_hashes")
    T.eq(keys.version, 4)
    local expires
    for _, key in ipairs(keys.keys) do
        if key.id == console.id then
            expires = key.expires
        end
    end
    T.truthy(expires and math.abs(expires - (os.time() + 86400)) < 60, "the console's key expires in a day")
    Version.BRIDGE_VERSION = "dev"
end

function tests.a_write_that_fails_puts_every_store_back()
    local old = start()
    local home = furnish(old)
    local document = export(old)
    -- A controller with a home of its own in every store.
    local s = start()
    local mine = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Mine", steps = {} } }).json
    T.eq(T.http(s.mock, "POST", "/v1/schedules", { key = s.key, body = { scene_id = mine.id, trigger = { type = "time", at = "07:00" }, days = { 1 } } }).status, 201)
    T.eq(T.http(s.mock, "PATCH", "/v1/rooms/10", { key = s.key, body = { names = { he = "\215\158\215\152\215\145\215\151" } } }).status, 200)
    T.eq(T.http(s.mock, "PUT", "/v1/rooms/order", { key = s.key, body = { room_ids = { 10, 11 } } }).status, 200)
    Properties["Jewish Calendar"] = "On"
    T.eq(T.http(s.mock, "PATCH", "/v1/calendar/settings", { key = s.key, body = { havdalah_minutes = 72 } }).status, 200)
    export(s)
    local id = upload(s, document)
    T.eq(restore(s, { upload = id }).status, 200)
    local before = {}
    for name, value in pairs(s.mock.persist) do
        before[name] = value
    end
    local write = C4.PersistSetValue
    C4.PersistSetValue = function(self, name, value, encrypted)
        if name == "directorlink_calendar" then
            error("storage full")
        end
        return write(self, name, value, encrypted)
    end
    local failed = restore(s, { upload = id, dry_run = false })
    C4.PersistSetValue = write
    T.eq(failed.status, 500)
    T.eq(failed.json.code, "RESTORE_FAILED")
    T.eq(failed.json.store, "calendar")
    for _, name in ipairs({ "directorlink_api_key_hashes", "directorlink_profiles", "DIRECTORLINK_ROOM_NAMES", "directorlink_room_layout",
        "directorlink_scenes", "directorlink_schedules", "directorlink_calendar", "directorlink_remote_identity" }) do
        T.truthy(before[name], name .. " was there")
        T.same(stored(s.mock, name), Json.decode((before[name]:gsub("^json:", ""))), name .. " as before")
    end
    T.eq(#list(s.mock, s.key, "/v1/scenes").items, 1, "the scenes in use are the ones from before")
    T.eq(list(s.mock, s.key, "/v1/schedules").items[1].scene_id, mine.id)
    T.eq(list(s.mock, s.key, "/v1/calendar").settings.havdalah_minutes, 72)
    T.eq(list(s.mock, s.key, "/v1/rooms").items[1].names.he, "\215\158\215\152\215\145\215\151")
    T.eq(T.http(s.mock, "GET", "/v1/profile", { key = home.member }).status, 401, "the backup's keys are not in use")
    T.eq(list(s.mock, s.key, "/v1/api-keys/current").role, "admin")
    -- The upload is still there: once the controller can save again, the restore goes through.
    T.eq(restore(s, { upload = id, dry_run = false }).status, 200)
    T.eq(#list(s.mock, s.key, "/v1/scenes").items, 2)
end

function tests.the_restoring_admin_keeps_their_key_and_their_role()
    local s = start()
    -- The backup was made while the tablet was a member's; it is an admin's now, and restores.
    local tablet, tabletId = createKey(s, "Tablet", "member")
    local document = export(s)
    T.eq(T.http(s.mock, "PATCH", "/v1/api-keys/" .. tabletId, { key = s.key, body = { role = "admin" } }).status, 200)
    local answer = sealed(s, { method = "POST", path = "/v1/restore", body = { document = document, dry_run = false } }, tablet, tabletId)
    T.eq(answer.status, 200, answer.body)
    T.eq(answer.json.restore.keys.yours, "in_backup")
    T.eq(list(s.mock, tablet, "/v1/api-keys/current").role, "admin", "it keeps the role it has now")

    -- A key made after the backup was made is added.
    local late, lateId = createKey(s, "Late admin", "admin")
    answer = sealed(s, { method = "POST", path = "/v1/restore", body = { document = document, dry_run = false } }, late, lateId)
    T.eq(answer.status, 200, answer.body)
    T.eq(answer.json.restore.keys.yours, "added")
    T.eq(list(s.mock, late, "/v1/api-keys/current").role, "admin")
    T.eq(#list(s.mock, late, "/v1/api-keys").items, 3)
    T.eq(list(s.mock, tablet, "/v1/api-keys/current").role, "member", "the others are as the backup has them")

    -- A backup with another key of the same id (8 random hex digits): the one in use wins.
    local clash = Json.decode(Json.encode(document))
    for _, record in ipairs(clash.sections.keys.keys) do
        if record.id == s.id then
            record.hash = string.rep("0", 64)
            record.role = "viewer"
        end
    end
    local check = restore(s, { document = clash })
    T.eq(check.json.restore.keys.conflict, true)
    T.eq(restore(s, { document = clash, dry_run = false }).status, 200)
    T.eq(list(s.mock, s.key, "/v1/api-keys/current").role, "admin")

    -- The key limit: the restoring admin's own comes on top of a full backup.
    local full = Json.decode(Json.encode(document))
    full.sections.keys.keys = {}
    for index = 1, 20 do
        full.sections.keys.keys[index] = { id = string.format("%08x", index), name = "Device " .. index, role = "member", alg = "sha256", hash = string.rep(string.format("%02x", index), 32), lock = string.rep("ef", 32), created_at = "2026-01-01T00:00:00Z" }
    end
    local restored = restore(s, { document = full, dry_run = false })
    T.eq(restored.status, 200, restored.body)
    T.eq(restored.json.restore.keys.count, 21)
    T.eq(restored.json.restore.keys.over_limit, true)
    T.eq(list(s.mock, s.key, "/v1/api-keys/current").role, "admin")
    T.eq(T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "One more" } }).json.code, "KEY_LIMIT_REACHED")
end

function tests.expired_keys_stay_out()
    local s = start()
    local document = export(s)
    document.sections.keys.keys[#document.sections.keys.keys + 1] = { id = "0badc0de", name = "Old console", role = "admin", alg = "sha256", hash = string.rep("12", 32), lock = string.rep("34", 32), created_at = "2026-01-01T00:00:00Z", expires = os.time() - 60 }
    local check = restore(s, { document = document })
    T.eq(check.json.restore.keys.expired, 1)
    T.eq(check.json.restore.counts.keys, 1)
end

-- The project was rebuilt: the kitchen light has another id, the hall light is gone, the living
-- room is now the lounge (another id) and the kitchen another id with the same name.
local function rebuilt()
    local project = Mock.project()
    Mock.removeDevice(project, 20)
    Mock.addLight(project, 120, 220, 10, "Kitchen Island", 0)
    Mock.removeDevice(project, 21)
    return project
end

function tests.devices_are_matched_by_id_else_by_name_in_the_same_room_and_the_rest_listed()
    local old = start()
    furnish(old)
    T.eq(T.http(old.mock, "POST", "/v1/scenes", { key = old.key, body = {
        name = "Hall", steps = { { type = "lights", device_ids = { 21 }, set = { on = true } } },
    } }).status, 201)
    local document = export(old)

    local s = start(rebuilt())
    local done, preview = replace(s, document)
    local references = preview.references
    T.eq(#references.by_name, 1)
    T.eq(references.by_name[1].name, "Kitchen Island")
    T.eq(references.by_name[1].from, 20)
    T.eq(references.by_name[1].to, 120)
    T.eq(references.unmatched_count, 1)
    local missing = references.unmatched[1]
    T.eq(missing.id, 21)
    T.eq(missing.name, "Hall Light")
    T.eq(missing.room, "Living Room")
    T.eq(missing.kind, "light")
    T.eq(missing.used_in[1].section, "scenes")
    T.eq(missing.used_in[1].name, "Good night")
    T.eq(missing.used_in[2].name, "Hall")
    T.eq(preview.left_out.steps, 1, "the step with only the missing light")
    T.same(done.references, references, "the result says the same")

    local scenes = list(s.mock, s.key, "/v1/scenes").items
    local night, hall
    for _, scene in ipairs(scenes) do
        if scene.name == "Good night" then
            night = scene
        elseif scene.name == "Hall" then
            hall = scene
        end
    end
    T.same(night.steps[1].device_ids, { 120 }, "the kitchen light by its new id, the hall light left out")
    T.eq(#hall.steps, 0, "a scene whose only device is gone stays, without the step")
    T.same(list(s.mock, old.key, "/v1/profile").prefs.favorites, { "light:120", "thermostat:30", "blind:50" })
end

function tests.a_room_that_is_gone_never_becomes_the_whole_home()
    local old = start()
    furnish(old)
    local document = export(old)
    local project = Mock.project()
    -- The living room is gone (its devices moved to the kitchen); the kitchen has a new id.
    for id, device in pairs(project.devices) do
        if device.roomId == 11 then
            Mock.moveDevice(project, id, 10)
        end
    end
    Mock.removeRoom(project, 11)
    Mock.addRoom(project, 12, "Kitchen")
    Mock.removeRoom(project, 10)
    for id, device in pairs(project.devices) do
        if device.roomId == 10 then
            device.roomId = 12
        end
    end
    local s = start(project)
    local done = replace(s, document)
    local byName = done.references.by_name
    local kitchen = false
    for _, entry in ipairs(byName) do
        kitchen = kitchen or (entry.kind == "room" and entry.name == "Kitchen" and entry.from == 10 and entry.to == 12)
    end
    T.truthy(kitchen, "the kitchen by its name")
    local night = list(s.mock, s.key, "/v1/scenes").items[1]
    for _, step in ipairs(night.steps) do
        T.truthy(step.type ~= "blinds", "the living room's blinds step is left out, not run in every room")
    end
    local morning = list(s.mock, s.key, "/v1/scenes").items[2]
    T.eq(morning.steps[1].room_id, 12, "the kitchen step in the kitchen's new id")
    local rooms = list(s.mock, s.key, "/v1/rooms").items
    T.eq(#rooms, 1)
    T.same(list(s.mock, old.key, "/v1/profile").prefs.hidden_rooms, { 12 })
    local living = false
    for _, entry in ipairs(done.references.unmatched) do
        living = living or (entry.kind == "room" and entry.id == 11 and entry.name == "Living Room")
    end
    T.truthy(living, "the living room is listed")
end

function tests.a_schedule_starts_after_the_restore_and_its_scene_comes_with_it()
    local old = start()
    local home = furnish(old)
    local document = export(old)
    -- A schedule whose scene is not in the backup is left out.
    local orphan = Json.decode(Json.encode(document.sections.schedules.schedules[1]))
    orphan.id = "0000beef"
    orphan.scene_id = "0000dead"
    document.sections.schedules.schedules[2] = orphan
    local s = start()
    local done = replace(s, document)
    T.eq(done.counts.schedules, 1)
    T.eq(done.left_out.schedules, 1)
    local schedules = stored(s.mock, "directorlink_schedules").schedules
    T.truthy(schedules[1].updated_epoch >= os.time() - 5, "nothing due before the restore runs")
    local state = stored(s.mock, "directorlink_schedule_state")
    T.truthy(state.catch_up_after >= os.time() - 5, "and nothing is caught up")
    T.eq(schedules[1].id, home.schedule.id)
end

function tests.invitations_and_claims_from_before_are_revoked()
    local s = start()
    local document = export(s)
    local invitations = require("src.auth.invitations")
    T.truthy(invitations.create("member", 3600, s.id))
    T.eq(#invitations.list(), 1)
    T.eq(restore(s, { document = document, dry_run = false }).status, 200)
    T.eq(#invitations.list(), 0, "they were for the keys and the home there were")
end

function tests.uploads_come_in_order_for_one_key_and_expire()
    local s = start()
    local document = export(s)
    local text = Json.encode(document)
    local first = sealed(s, { method = "POST", path = "/v1/restore/parts", body = { index = 0, count = 2, text = text:sub(1, 100) } })
    T.eq(first.status, 200)
    local id = first.json.upload
    local incomplete = restore(s, { upload = id })
    T.eq(incomplete.status, 409)
    T.eq(incomplete.json.code, "UPLOAD_INCOMPLETE")
    T.eq(sealed(s, { method = "POST", path = "/v1/restore/parts", body = { upload = id, index = 2, count = 2, text = "x" } }).status, 400)
    T.eq(sealed(s, { method = "POST", path = "/v1/restore/parts", body = { upload = id, index = 1, count = 3, text = "x" } }).status, 400)
    local other, otherId = createKey(s, "Another admin", "admin")
    local foreign = sealed(s, { method = "POST", path = "/v1/restore/parts", body = { upload = id, index = 1, count = 2, text = text:sub(101) } }, other, otherId)
    T.eq(foreign.status, 404, "an upload is its key's")
    T.eq(sealed(s, { method = "POST", path = "/v1/restore/parts", body = { upload = id, index = 1, count = 2, text = text:sub(101) } }).status, 200)
    T.eq(restore(s, { upload = id }).status, 200)
    -- A part is at most 48 KiB (at home, a sealed request is at most 64 KiB anyway), a backup 2 MiB.
    local Backup = require("src.core.backup")
    local _, tooBig = Backup.receivePart(s.id, { index = 0, count = 1, text = string.rep("x", 48 * 1024 + 1) }, os.time())
    T.eq(tooBig.code, "INVALID_FIELD")
    local limit = Backup.MAX_BYTES
    Backup.MAX_BYTES = 100
    local begun = Backup.receivePart(s.id, { index = 0, count = 2, text = string.rep("x", 60) }, os.time())
    local _, large = Backup.receivePart(s.id, { upload = begun.upload, index = 1, count = 2, text = string.rep("x", 60) }, os.time())
    Backup.MAX_BYTES = limit
    T.eq(large.code, "BACKUP_TOO_LARGE")
    -- A new upload replaced the one before.
    T.eq(restore(s, { upload = id }).json.code, "UPLOAD_NOT_FOUND")
    id = upload(s, document)
    -- Ten minutes later it is gone.
    local now = os.time
    os.time = function(t)
        return t and now(t) or now() + 601
    end
    local late = restore(s, { upload = id })
    os.time = now
    T.eq(late.status, 404)
    T.eq(late.json.code, "UPLOAD_NOT_FOUND")
end

-- ---- The remote identity ----------------------------------------------------------------------

-- The relay's last live timer of this delay.
local function timerOf(mock, delay)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if timer.delay == delay and not timer.cancelled and not timer.fired and (timer.source or ""):find("cloud/relay", 1, true) then
            return timer
        end
    end
end

local function fire(mock, delay)
    local timer = assert(timerOf(mock, delay), "a timer of " .. delay .. " ms")
    timer.fired = true
    timer.callback()
end

-- The request the driver makes to connect again, `delay` ms after the restore's answer.
local function reconnection(mock, connection)
    connection.sent = ""
    fire(mock, 2000)
    local closing = Harness.clientFrames(connection.sent)
    T.eq(closing[#closing].opcode, 8, "the connection there was is closed")
    connection.sent = ""
    fire(mock, 1000)
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    local request = connection.sent
    connection.sent = ""
    return request
end

local function refuse()
    local body = '{"type":"about:blank","title":"Unauthorized","status":401,"code":"WRONG_HOME_SECRET"}'
    ReceivedFromNetwork(Harness.BINDING, 443, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\n"
        .. "Content-Length: " .. #body .. "\r\n\r\n" .. body)
end

-- A restore sealed through the account, as the app sends it away from home.
local function remoteRestore(s, connection, home, document)
    counter = counter + 1
    local lock = Lock().deviceKey(s.key)
    local envelope = Lock().seal(lock, home, s.id, "req", Json.encode({
        id = "remote-" .. counter, ts = os.time(), method = "POST", path = "/v1/restore", body = { document = document, dry_run = false },
    }))
    local reply = Harness.relayRequest(s.mock, connection, { type = "e2e", id = "relay-" .. counter, envelope = envelope })
    T.truthy(reply.envelope, "answered sealed")
    return Json.decode(Json.decode(Lock().open(lock, reply.envelope, "res")).body)
end

function tests.the_same_home_keeps_its_connection_and_newer_secret()
    local s = start()
    local document = export(s)
    local _, connection = Harness.connected({ mock = s.mock })
    -- The owner replaced the home secret after the backup was made.
    local Relay = require("src.cloud.relay")
    local identity = Relay.identity()
    identity.home_secret = string.rep("5a", 32)
    local home = identity.home_id
    local result = remoteRestore(s, connection, home, document)
    T.eq(result.restore.remote.action, "same")
    T.eq(timerOf(s.mock, 2000), nil, "no new connection")
    T.eq(Relay.identity().home_secret, string.rep("5a", 32), "the newer secret stays")
    T.eq(stored(s.mock, "directorlink_remote_identity").home_secret, string.rep("5a", 32))
end

function tests.another_home_s_identity_is_used_once_the_answer_is_out_and_kept_when_the_relay_knows_it()
    local old = start()
    local document = export(old)
    local backupHome = document.sections.remote_identity
    -- The controller linked again after the accident: another home, connected.
    local s = start()
    local _, connection = Harness.connected({ mock = s.mock })
    local currentHome = T.http(s.mock, "GET", "/v1/remote", { key = s.key }).json.home_id
    T.truthy(currentHome ~= backupHome.home_id)
    local result = remoteRestore(s, connection, currentHome, document)
    T.eq(result.restore.remote.action, "restore")
    T.eq(result.restore.remote.home_id, backupHome.home_id)
    T.eq(result.restore.remote.current_home_id, currentHome)
    T.eq(connection.disconnects, 0, "the answer went out on the connection there was")
    local saved = stored(s.mock, "directorlink_remote_identity")
    T.eq(saved.home_id, backupHome.home_id)
    T.eq(saved.previous.home_id, currentHome, "the controller's own is kept until the relay accepts the backup's")

    local request = reconnection(s.mock, connection)
    T.contains(request, "X-DirectorLink-Home: " .. backupHome.home_id)
    T.contains(request, "Authorization: Bearer " .. backupHome.home_secret)
    Harness.accept(request)
    local frames = Harness.clientFrames(connection.sent)
    local hello = Json.decode(frames[1].payload)
    T.eq(hello.type, "hello")
    T.eq(hello.home, backupHome.home_id)
    T.eq(Json.decode(frames[2].payload).type, "keys", "the restored keys are announced to that home")
    T.eq(stored(s.mock, "directorlink_remote_identity").previous, nil, "accepted: it is the home's now")
end

function tests.an_identity_the_relay_refuses_gives_way_to_the_controller_s_own()
    local old = start()
    local document = export(old)
    local s = start()
    local _, connection = Harness.connected({ mock = s.mock })
    local currentHome = T.http(s.mock, "GET", "/v1/remote", { key = s.key }).json.home_id
    local currentSecret = stored(s.mock, "directorlink_remote_identity").home_secret
    remoteRestore(s, connection, currentHome, document)
    local request = reconnection(s.mock, connection)
    T.contains(request, "X-DirectorLink-Home: " .. document.sections.remote_identity.home_id)
    -- Its secret was replaced after the backup was made: the relay does not accept it.
    refuse()
    T.contains(s.mock.properties["Remote Status"], "Reconnecting in 1 s")
    local saved = stored(s.mock, "directorlink_remote_identity")
    T.eq(saved.home_id, currentHome, "the controller's own identity is back")
    T.eq(saved.home_secret, currentSecret)
    T.eq(saved.previous, nil)
    connection.sent = ""
    fire(s.mock, 1000)
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    T.contains(connection.sent, "X-DirectorLink-Home: " .. currentHome)
    local said = false
    for _, line in ipairs(s.mock.debugLog) do
        said = said or line:find("refused the remote identity restored from a backup", 1, true) ~= nil
    end
    T.truthy(said, "the log says so")
end

function tests.with_remote_access_off_the_backup_s_identity_waits_for_the_relay()
    local old = start()
    local document = export(old)
    -- This controller had remote access on after the accident, then off.
    local s = start()
    Harness.connected({ mock = s.mock })
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    local own = stored(s.mock, "directorlink_remote_identity").home_id
    T.eq(restore(s, { document = document, dry_run = false }).status, 200)
    T.eq(timerOf(s.mock, 2000), nil, "nothing to reconnect")
    local saved = stored(s.mock, "directorlink_remote_identity")
    T.eq(saved.home_id, document.sections.remote_identity.home_id)
    T.eq(saved.previous.home_id, own)
    local updated = Mock.updateDriver(s.mock)
    local _, _, request = Harness.connected({ mock = updated })
    T.contains(request, "X-DirectorLink-Home: " .. document.sections.remote_identity.home_id, "switched on later, it is tried then")
    T.eq(stored(updated, "directorlink_remote_identity").previous, nil)
end

-- ---- A big home --------------------------------------------------------------------------------

-- Like the owner's: 111 lights in 40 rooms, 22 thermostats, 15 blinds; 50 scenes of 15 steps, 50
-- schedules, 20 keys with a profile each, 60 favorites each, and Hebrew names for every room.
local function bigProject()
    local project = Mock.project()
    for room = 1, 40 do
        Mock.addRoom(project, 200 + room, "Room " .. room)
    end
    for light = 1, 111 do
        Mock.addLight(project, 1000 + light, 5000 + light, 200 + (light % 40) + 1, "Light " .. light, 0)
    end
    return project
end

function tests.a_big_home_goes_both_ways_in_parts_that_fit_a_sealed_request()
    local s = start(bigProject())
    local Scenes = require("src.core.scenes")
    local Schedules = require("src.core.schedules")
    local Profiles = require("src.auth.profiles")
    local RoomNames = require("src.core.room_names")
    local sceneIds = {}
    for scene = 1, 50 do
        local steps = {}
        for step = 1, 15 do
            local ids = {}
            for index = 1, 8 do
                ids[index] = 1000 + ((scene * 15 + step * 8 + index) % 111) + 1
            end
            steps[step] = { type = "lights", device_ids = ids, set = { brightness = (scene + step) % 100 } }
        end
        local created = assert(Scenes.create({ name = "Scene " .. scene .. " — סצנה", steps = steps }))
        sceneIds[scene] = created.id
    end
    for index = 1, 50 do
        assert(Schedules.create(assert(Schedules.check({ scene_id = sceneIds[index], trigger = { type = "time", at = string.format("%02d:%02d", index % 24, index % 60) }, days = Json.array({ 0, 1, 2, 3, 4, 5, 6 }) }))))
    end
    for index = 1, 19 do
        createKey(s, "Phone " .. index, index % 2 == 0 and "member" or "viewer")
    end
    local favorites = Json.array()
    for index = 1, 60 do
        favorites[index] = "light:" .. (1000 + index)
    end
    for _, profile in ipairs(Profiles.list()) do
        Profiles.updatePrefs(profile.id, { favorites = favorites, language = "he" })
    end
    for room = 1, 40 do
        RoomNames.update(200 + room, { he = "חדר מספר " .. room, en = "Room number " .. room })
    end

    local document, text = export(s, opened)
    T.truthy(#text > 100 * 1024, "a big document: " .. #text .. " bytes")
    T.eq(#document.sections.scenes.scenes, 50)
    local scenes = list(s.mock, s.key, "/v1/scenes").items

    local fresh = start(bigProject())
    local id, largest = upload(fresh, text, 30000, opened)
    T.truthy(largest < 64 * 1024, "every part fits the 64 KiB a request at home may have: " .. largest)
    local check = restore(fresh, { upload = id }, opened)
    T.eq(check.status, 200, check.body)
    T.eq(check.json.restore.counts.scenes, 50)
    T.eq(check.json.restore.counts.schedules, 50)
    T.eq(check.json.restore.counts.keys, 21)
    T.eq(check.json.restore.counts.room_names, 40)
    T.eq(check.json.restore.references.unmatched_count, 0)
    local done = restore(fresh, { upload = id, dry_run = false }, opened)
    T.eq(done.status, 200, done.body)
    T.same(list(fresh.mock, s.key, "/v1/scenes").items, scenes)
    T.eq(#list(fresh.mock, s.key, "/v1/profile").prefs.favorites, 60)

    -- What the driver itself does (the controller's C4:Encrypt seals natively; the fake Director's
    -- AES here is plain Lua): on this PC, where the CORE-1's Cortex-A53 is some ten times slower.
    local Backup = require("src.core.backup")
    local Registry = require("src.core.registry")
    local started = os.clock()
    local encoded = Json.encode(Backup.export(Registry))
    local exported = os.clock() - started
    started = os.clock()
    local plan = Backup.plan(Json.decode(encoded), { registry = Registry, restorer = fresh.id })
    T.truthy(Backup.apply(plan))
    local restored = os.clock() - started
    T.truthy(exported < 0.5 and restored < 0.5, string.format("export %.2f s, restore %.2f s", exported, restored))
end

function tests.through_the_account_a_backup_comes_sealed_end_to_end()
    local s = start()
    furnish(s)
    local _, connection = Harness.connected({ mock = s.mock })
    local home = T.http(s.mock, "GET", "/v1/remote", { key = s.key }).json.home_id
    local lock = Lock().deviceKey(s.key)
    local envelope = Lock().seal(lock, home, s.id, "req", Json.encode({ id = "remote-backup", ts = os.time(), method = "GET", path = "/v1/backup" }))
    local reply, frame = Harness.relayRequest(s.mock, connection, { type = "e2e", id = "relay-backup", envelope = envelope })
    local answer = Json.decode(Lock().open(lock, reply.envelope, "res"))
    T.eq(answer.status, 200)
    local document = Json.decode(answer.body)
    T.eq(#document.sections.scenes.scenes, 2)
    for _, secret in ipairs({ document.sections.remote_identity.home_secret, document.sections.keys.keys[1].lock, "Good night" }) do
        T.notContains(frame.payload, secret, "the relay sees nothing of it")
    end
end

function tests.a_restore_waits_for_the_project()
    -- Director could not list the devices at start: nothing can be matched yet.
    local s = start(nil, function()
        C4.GetDevices = function()
            error("Director is busy")
        end
    end)
    local answer = restore(s, { document = export(s) })
    T.eq(answer.status, 503)
    T.eq(answer.json.code, "PROJECT_NOT_READY")
end

return tests
