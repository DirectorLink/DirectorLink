-- Automatic backups to the account (ADR-048, docs/BACKUP.md): the seal against
-- tests/vectors/cloud_backup.json (Node's crypto made it; the app opens the same), a slice at a
-- time; the backup password's key, set by admins in sealed requests; Back up now, sealed and sent
-- over the relay connection in chunks, each answered before the next; and the daily backup at the
-- home's minute.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Harness = require("relay_harness")

local tests = {}

local counter = 0

local function vectors()
    local file = assert(io.open("tests/vectors/cloud_backup.json", "rb"))
    local text = file:read("*a")
    file:close()
    return Json.decode(text)
end

local function bytes(hex)
    return Base64.fromHex(hex)
end

-- A driver with an admin key paired at home: { mock, key, id }.
local function start(project, prepare)
    local mock = Mock.startDriver(project or Mock.project(), nil, nil, prepare)
    local key = T.pair(mock, "Owner phone")
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    return { mock = mock, key = key, id = me.id }
end

-- A request sealed at home (POST /v1/sealed), as the app sends it; the answer opened.
local function sealed(s, request, key, keyId)
    local Lock = require("src.cloud.lock")
    local info = T.http(s.mock, "GET", "/v1/sealed").json
    counter = counter + 1
    request.id = "auto-" .. counter
    request.ts = info.time
    local lock = Lock.deviceKey(key or s.key)
    local envelope = Lock.seal(lock, info.home, keyId or s.id, "req", Json.encode(request))
    local response = T.http(s.mock, "POST", "/v1/sealed", { body = Json.encode({ envelope = envelope }) })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer
end

-- The vector's backup password key, as the app sends it (with the iterations a real one has).
local function keyBody()
    local key = vectors().key
    return { public_key = key.public_key, salt = key.salt, iterations = 600000, kdf = "PBKDF2-SHA-256" }
end

local function setKey(s, body)
    local answer = sealed(s, { method = "PUT", path = "/v1/backup/automatic", body = body or keyBody() })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function status(s)
    local answer = T.http(s.mock, "GET", "/v1/backup/automatic", { key = s.key })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

-- Runs the timers of automatic backups (src/cloud/auto_backup.lua), one after another, until
-- none is left; returns how many ran.
local function runSteps(mock)
    local ran = 0
    for _ = 1, 1000 do
        local pending
        for _, timer in ipairs(mock.timers) do
            if not timer.fired and not timer.cancelled and timer.source:find("auto_backup.lua", 1, true) then
                pending = timer
                break
            end
        end
        if not pending then
            return ran
        end
        pending.fired = true
        pending.callback()
        ran = ran + 1
    end
    error("the backup never stopped stepping")
end

-- The backup chunks the driver sent since the last look.
local function chunksSent(connection)
    local found = {}
    for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" and message.type == "backup_chunk" then
            found[#found + 1] = message
        end
    end
    connection.sent = ""
    return found
end

local function reply(message)
    ReceivedFromNetwork(Harness.BINDING, 443, Harness.serverFrame(1, Json.encode(message)))
end

-- Plays the account service: runs the backup's steps, takes each chunk as the cloud does
-- (`answer(chunk, chunks)` may answer otherwise) and returns the chunks and the text they make.
local function upload(s, connection, answer)
    local chunks, steps = {}, 0
    for _ = 1, 500 do
        steps = steps + runSteps(s.mock)
        local sent = chunksSent(connection)
        if #sent == 0 then
            break
        end
        T.eq(#sent, 1, "one chunk at a time: the next waits for the answer")
        local chunk = sent[1]
        chunks[#chunks + 1] = chunk
        local result = answer and answer(chunk, chunks) or nil
        if not result then
            result = { ok = true, backup = string.rep("b", 32) }
            if chunk.index == chunks[1].count - 1 then
                result.complete = true
            end
        end
        result.type, result.id = "backup_result", chunk.id
        reply(result)
    end
    local parts = {}
    for index, chunk in ipairs(chunks) do
        parts[index] = chunk.data
    end
    return chunks, table.concat(parts), steps
end

-- Opens a sealed backup with the backup password's private key, as the app does: the MAC first.
local function open(text, privateKey)
    local BackupSeal = require("src.cloud.backup_seal")
    local X25519 = require("src.core.x25519")
    local sealedBackup = Json.decode(text)
    local shared = X25519.shared(privateKey, Base64.decode(sealedBackup.epk))
    local _, enc, mac = BackupSeal.keys(shared, sealedBackup.epk, Base64.encode(X25519.publicKey(privateKey)))
    local input = BackupSeal.LABEL .. "|" .. sealedBackup.key_id .. "|" .. sealedBackup.salt .. "|" .. sealedBackup.iterations
        .. "|" .. sealedBackup.epk .. "|" .. sealedBackup.iv .. "|" .. sealedBackup.ct
    local expected = C4:HMAC("SHA256", mac, input, { key_encoding = "HEX", data_encoding = "NONE", return_encoding = "HEX" })
    T.eq(Base64.toHex(Base64.decode(sealedBackup.mac)), expected:lower(), "the MAC")
    local plaintext = C4:Decrypt("AES-256-CBC", enc, Base64.toHex(Base64.decode(sealedBackup.iv)), Base64.toHex(Base64.decode(sealedBackup.ct)), {
        key_encoding = "HEX", iv_encoding = "HEX", data_encoding = "HEX", return_encoding = "NONE", padding = true,
    })
    return Json.decode(plaintext), sealedBackup
end

local function logged(s, message)
    local found = {}
    for _, entry in ipairs(T.http(s.mock, "GET", "/v1/logs?category=backup", { key = s.key }).json.items) do
        if entry.message == message then
            found[#found + 1] = entry
        end
    end
    return found
end

-- ---- The seal ------------------------------------------------------------------------------------

function tests.the_seal_reproduces_the_shared_vectors()
    Mock.install()
    package.loaded["src.cloud.backup_seal"] = nil
    local BackupSeal = require("src.cloud.backup_seal")
    local X25519 = require("src.core.x25519")
    local v = vectors()
    -- The app's key pair: the driver gets only the public key.
    T.eq(Base64.encode(X25519.publicKey(bytes(v.key.private_hex))), v.key.public_key)
    T.eq(BackupSeal.keyId(Base64.decode(v.key.public_key)), v.key.key_id)
    -- Each step of the seal.
    local ephemeral = bytes(v.seal.ephemeral_hex)
    T.eq(Base64.encode(X25519.publicKey(ephemeral)), v.seal.epk)
    local shared = X25519.shared(ephemeral, Base64.decode(v.seal.public_key))
    T.eq(Base64.toHex(shared), v.seal.shared_hex)
    local lock, enc, mac = BackupSeal.keys(shared, v.seal.epk, v.seal.public_key)
    T.eq(lock, v.seal.lock_key_hex)
    T.eq(enc, v.seal.enc_key_hex)
    T.eq(mac, v.seal.mac_key_hex)
    local key = { public_key = v.seal.public_key, salt = v.key.salt, iterations = v.key.iterations, key_id = v.key.key_id }
    local result = BackupSeal.seal(key, v.seal.plaintext, { ephemeral = ephemeral, iv = v.seal.iv_hex })
    T.same(result, v.seal.sealed, "the sealed backup, field by field")
    -- The private key opens it; a byte changed does not.
    local document = open(Json.encode(result), bytes(v.key.private_hex))
    T.eq(document.home.name, "בית Home")
    -- Its length is known before sealing (a backup too large for the account is not sealed).
    T.eq(BackupSeal.size(key, #v.seal.plaintext), #Json.encode(result))
    for _, length in ipairs({ 0, 15, 16, 17, 47, 48 }) do
        local plaintext = string.rep("x", length)
        T.eq(BackupSeal.size(key, length), #Json.encode(BackupSeal.seal(key, plaintext, { ephemeral = ephemeral, iv = v.seal.iv_hex })), "length " .. length)
    end
    local changed = Json.decode(Json.encode(result))
    changed.iterations = 600000
    T.truthy(not pcall(open, Json.encode(changed), bytes(v.key.private_hex)), "the MAC covers how to open it")
end

function tests.sealing_runs_a_slice_at_a_time()
    Mock.install()
    package.loaded["src.cloud.backup_seal"] = nil
    local BackupSeal = require("src.cloud.backup_seal")
    local X25519 = require("src.core.x25519")
    local v = vectors()
    -- A scalar multiplication in uneven slices is the same one.
    local job = X25519.start(bytes(v.seal.ephemeral_hex), Base64.decode(v.seal.public_key))
    local slices = 0
    for _, count in ipairs({ 1, 100, 7, 200 }) do
        slices = slices + 1
        if job.step(count) then
            break
        end
    end
    T.eq(slices, 4)
    T.eq(Base64.toHex(job.result()), v.seal.shared_hex)
    -- Two scalar multiplications of 255 steps, 64 at a time: 4 slices and the inversion each, then
    -- the encryption.
    local key = { public_key = v.seal.public_key, salt = v.key.salt, iterations = v.key.iterations, key_id = v.key.key_id }
    local sealing = BackupSeal.start(key, v.seal.plaintext, { ephemeral = bytes(v.seal.ephemeral_hex), iv = v.seal.iv_hex })
    local steps = 1
    while not sealing.step() do
        steps = steps + 1
    end
    T.eq(steps, 11)
    T.same(sealing.result(), v.seal.sealed)
end

-- ---- The backup password's key ---------------------------------------------------------------------

function tests.admins_set_the_backup_password_s_key_in_sealed_requests_only()
    local s = start()
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.features.automatic_backup, true)
    local off = status(s)
    T.eq(off.enabled, false)
    T.eq(tostring(off.key), "null")
    T.eq(tostring(off.time), "null")
    -- In the clear, someone on the network could put their own key in its place.
    local clear = T.http(s.mock, "PUT", "/v1/backup/automatic", { key = s.key, body = keyBody() })
    T.eq(clear.status, 403)
    T.eq(clear.json.code, "SEALED_REQUEST_REQUIRED")
    T.eq(T.http(s.mock, "DELETE", "/v1/backup/automatic", { key = s.key }).status, 403)
    for field, value in pairs({
        public_key = Base64.encode(string.rep("x", 31)),
        salt = Base64.encode(string.rep("s", 8)),
        iterations = 1000,
        kdf = "scrypt",
    }) do
        local body = keyBody()
        body[field] = value
        local refused = sealed(s, { method = "PUT", path = "/v1/backup/automatic", body = body })
        T.eq(refused.status, 400, field)
        T.eq(refused.json.errors[1].field, field)
    end
    local lowOrder = keyBody()
    lowOrder.public_key = Base64.encode(string.rep(string.char(0), 32))
    T.eq(sealed(s, { method = "PUT", path = "/v1/backup/automatic", body = lowOrder }).status, 400, "a key with no shared secret")
    local extra = keyBody()
    extra.password = "never sent"
    T.eq(sealed(s, { method = "PUT", path = "/v1/backup/automatic", body = extra }).status, 400)
    for _, role in ipairs({ "viewer", "member", "doors" }) do
        local created = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = role, role = role } }).json
        T.eq(sealed(s, { method = "PUT", path = "/v1/backup/automatic", body = keyBody() }, created.key, created.id).status, 403, role)
        T.eq(T.http(s.mock, "GET", "/v1/backup/automatic", { key = created.key }).status, 403, role)
    end

    local on = setKey(s)
    T.eq(on.enabled, true)
    T.eq(on.key.key_id, vectors().key.key_id)
    T.eq(on.key.iterations, 600000)
    -- In the clear, nothing to check a guessed password with: the key's id and when it was set.
    local clearly = status(s)
    T.eq(clearly.enabled, true)
    T.eq(clearly.key.key_id, on.key.key_id)
    T.eq(clearly.key.set_at, on.key.set_at)
    T.eq(clearly.time, on.time)
    for _, field in ipairs({ "public_key", "salt", "iterations", "kdf" }) do
        T.eq(clearly.key[field], nil, field .. " is not in the clear")
    end
    local inside = sealed(s, { method = "GET", path = "/v1/backup/automatic" })
    T.eq(inside.status, 200)
    T.same(inside.json.key, on.key, "sealed, all of it")
    local hour, minute = on.time:match("^(%d%d):(%d%d)$")
    local at = tonumber(hour) * 60 + tonumber(minute)
    T.truthy(at >= 180 and at < 300, "the home's minute is between 03:00 and 04:59: " .. on.time)
    T.eq(logged(s, "automatic backups turned on")[1].data.by, s.id)
    -- Kept across a driver update, the minute too.
    local again = Mock.updateDriver(s.mock)
    local kept = T.http(again, "GET", "/v1/backup/automatic", { key = s.key }).json
    T.eq(kept.key.key_id, on.key.key_id)
    T.eq(kept.time, on.time)
    s.mock = again
    -- A new password: a new key, the same minute.
    local other = keyBody()
    other.public_key = Base64.encode(require("src.core.x25519").publicKey(string.rep(string.char(5), 32)))
    local changed = setKey(s, other)
    T.truthy(changed.key.key_id ~= on.key.key_id)
    T.eq(changed.time, on.time)
    T.eq(#logged(s, "backup password changed"), 1)
    T.eq(sealed(s, { method = "DELETE", path = "/v1/backup/automatic" }).status, 204)
    T.eq(status(s).enabled, false)
    T.eq(#logged(s, "automatic backups turned off"), 1)
end

-- ---- Back up now -------------------------------------------------------------------------------------

function tests.back_up_now_seals_the_backup_and_sends_it_in_chunks_one_at_a_time()
    local rooms = { RINCON_000E58A0B1C201400 = { room_id = 10, name = "Kitchen Amp" } }
    local s = start(nil, function(mock)
        mock.persist["directorlink_sonos_rooms"] = "json:" .. Json.encode({ version = 1, rooms = rooms })
    end)
    T.eq(T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Good night", steps = {} } }).status, 201)
    local _, connection = Harness.connected({ mock = s.mock })
    setKey(s)
    -- Small chunks, so that a small home takes several.
    require("src.cloud.auto_backup").CHUNK_BYTES = 800
    local started = T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key })
    T.eq(started.status, 202, started.body)
    T.eq(started.json.status.running, true)
    T.eq(#chunksSent(connection), 0, "nothing is sent in the request itself: the work waits for timers")
    local chunks, text, steps = upload(s, connection)
    T.truthy(steps >= 10, "the document, its JSON, the seal's eleven steps and the chunks each in a tick of their own: " .. steps)
    T.truthy(#chunks >= 3, "several chunks: " .. #chunks .. " for " .. #text)
    T.eq(chunks[1].index, 0)
    T.eq(chunks[1].count, #chunks)
    T.eq(chunks[1].size, #text)
    T.eq(chunks[1].key_id, vectors().key.key_id)
    T.eq(chunks[1].why, "now", "the account counts Back up now apart from the nightly backup")
    T.eq(chunks[1].backup, nil)
    for index, chunk in ipairs(chunks) do
        T.eq(chunk.index, index - 1)
        T.truthy(#chunk.data <= 800)
        if index > 1 then
            T.eq(chunk.backup, string.rep("b", 32), "the backup the account named")
            T.eq(chunk.count, nil)
            T.eq(chunk.why, nil)
        end
    end
    -- Only the password's private key opens it.
    local document, sealedBackup = open(text, bytes(vectors().key.private_hex))
    T.eq(sealedBackup.format, "directorlink-cloud-backup")
    T.eq(sealedBackup.iterations, 600000)
    T.eq(sealedBackup.salt, vectors().key.salt)
    T.eq(document.format, "directorlink-backup")
    T.eq(document.sections.scenes.scenes[1].name, "Good night")
    T.same(document.sections.sonos_rooms.rooms, rooms, "the Sonos rooms are in it")
    T.eq(document.sections.remote_identity.linked, true)
    for _, chunk in ipairs(chunks) do
        T.notContains(chunk.data, "Good night", "the relay sees nothing of it")
    end
    local after = status(s)
    T.eq(after.running, false)
    T.eq(after.last.ok, true)
    T.eq(after.last.size, #text)
    T.eq(after.last.why, "now")
    local uploaded = logged(s, "backup uploaded")
    T.eq(#uploaded, 1)
    T.eq(uploaded[1].data.size, #text)
    T.eq(uploaded[1].data.chunks, #chunks)
    T.eq(uploaded[1].data.why, "now")
    -- The history (ADR-046): who asked, and that it went.
    local entry = (require("src.core.activity").list({ kinds = { system = true } }))[1]
    T.eq(entry.action, "cloud_backup")
    T.eq(entry.outcome, "ran")
    T.eq(entry.who.type, "key", "Back up now names who pressed it")
end

function tests.back_up_now_needs_the_key_remote_access_and_a_linked_home()
    local s = start()
    local function run()
        return T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key })
    end
    T.eq(run().json.code, "AUTOMATIC_BACKUP_OFF")
    setKey(s)
    local off = run()
    T.eq(off.status, 409)
    T.eq(off.json.code, "REMOTE_ACCESS_OFF")
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local offline = run()
    T.eq(offline.status, 503, "on, but not connected yet")
    T.eq(offline.json.code, "REMOTE_OFFLINE")
    local _, connection = Harness.connected({ mock = s.mock })
    T.eq(run().status, 202)
    local busy = run()
    T.eq(busy.status, 409)
    T.eq(busy.json.code, "BACKUP_RUNNING")
    upload(s, connection)
    T.eq(run().status, 202, "once done, again")
    local member = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "member", role = "member" } }).json
    T.eq(T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = member.key }).status, 403)
end

function tests.a_home_the_relay_never_accepted_sends_nothing()
    local s = start()
    setKey(s)
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local Relay = require("src.cloud.relay")
    local connected = Relay.connected
    Relay.connected = function()
        return true
    end
    local identity = Relay.identity()
    identity.linked = nil
    local answer = T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key })
    Relay.connected = connected
    T.eq(answer.status, 409)
    T.eq(answer.json.code, "HOME_NOT_LINKED")
end

function tests.a_refused_or_unanswered_chunk_ends_the_backup()
    local s = start()
    local _, connection = Harness.connected({ mock = s.mock })
    setKey(s)
    -- Larger than the account takes: not sent at all.
    local AutoBackup = require("src.cloud.auto_backup")
    local limit = AutoBackup.MAX_BYTES
    AutoBackup.MAX_BYTES = 1000
    T.eq(T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key }).status, 202)
    local chunks, _, steps = upload(s, connection)
    T.eq(#chunks, 0)
    T.eq(steps, 2, "the document and its JSON: not sealed")
    T.eq(status(s).last.code, "BACKUP_TOO_LARGE")
    T.eq(logged(s, "automatic backup not made")[1].data.step, "json")
    T.eq((require("src.core.activity").list({ kinds = { system = true } }))[1].reason, "too_large")
    AutoBackup.MAX_BYTES = limit
    T.eq(T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key }).status, 202)
    local chunks = upload(s, connection, function()
        return { ok = false, code = "NOT_CLAIMED" }
    end)
    T.eq(#chunks, 1, "nothing more after a refusal")
    local last = status(s).last
    T.eq(last.ok, false)
    T.eq(last.code, "NOT_CLAIMED")
    local notMade = logged(s, "automatic backup not made")
    T.eq(notMade[#notMade].data.code, "NOT_CLAIMED")
    local failed = (require("src.core.activity").list({ kinds = { system = true } }))[1]
    T.eq(failed.action, "cloud_backup")
    T.eq(failed.outcome, "failed")
    T.eq(failed.reason, "not_linked", "the history says why, in a few words")
    T.eq(failed.note, nil, "Back up now is not tried again")
    T.eq(failed.who.type, "key")
    -- No answer: the backup ends when the relay's wait does.
    T.eq(T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key }).status, 202)
    runSteps(s.mock)
    T.eq(#chunksSent(connection), 1)
    for _, timer in ipairs(s.mock.timers) do
        if not timer.fired and not timer.cancelled and timer.delay == 30000 and timer.source:find("cloud/relay", 1, true) then
            timer.fired = true
            timer.callback()
        end
    end
    T.eq(status(s).last.code, "RELAY_TIMEOUT")
    T.eq(status(s).running, false)
    local unanswered = (require("src.core.activity").list({ kinds = { system = true } }))[1]
    T.eq(unanswered.reason, "account_unreachable")
    T.eq(unanswered.note, nil, "Back up now is not tried again")
    -- The password changed while a backup was being made: it stops, made with the old one.
    T.eq(T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key }).status, 202)
    local other = keyBody()
    other.public_key = Base64.encode(require("src.core.x25519").publicKey(string.rep(string.char(5), 32)))
    setKey(s, other)
    runSteps(s.mock)
    T.eq(#chunksSent(connection), 0)
    T.eq(status(s).last.code, "KEY_CHANGED")
    T.eq((require("src.core.activity").list({ kinds = { system = true } }))[1].reason, "stopped")
end

-- Turned off, or the password changed, while a backup is being uploaded: no more chunks go, and the
-- account gets no backup sealed to a key that is no longer wanted.
function tests.turning_off_or_a_new_password_stops_an_upload_under_way()
    local s = start()
    local _, connection = Harness.connected({ mock = s.mock })
    setKey(s)
    require("src.cloud.auto_backup").CHUNK_BYTES = 500
    local other = keyBody()
    other.public_key = Base64.encode(require("src.core.x25519").publicKey(string.rep(string.char(5), 32)))
    for _, case in ipairs({
        { code = "AUTOMATIC_BACKUP_OFF", change = function()
            T.eq(sealed(s, { method = "DELETE", path = "/v1/backup/automatic" }).status, 204)
        end },
        { code = "KEY_CHANGED", change = function()
            setKey(s, other)
        end },
    }) do
        if not status(s).enabled then
            setKey(s)
        end
        T.eq(T.http(s.mock, "POST", "/v1/backup/automatic/run", { key = s.key }).status, 202)
        local chunks = upload(s, connection, function(chunk, sent)
            if chunk.index == 1 then
                case.change()
            end
            return nil
        end)
        T.eq(#chunks, 2, case.code .. ": the chunk under way is answered, and nothing more goes")
        T.truthy(chunks[1].count > 2, "it had more to send")
        local last = status(s).last
        T.eq(last.ok, false)
        T.eq(last.code, case.code)
        local entry = (require("src.core.activity").list({ kinds = { system = true } }))[1]
        T.eq(entry.action, "cloud_backup")
        T.eq(entry.outcome, "failed")
        T.eq(entry.reason, "stopped")
    end
end

-- ---- Every day ----------------------------------------------------------------------------------------

-- `day` days from a fixed date, at `minute` of the controller's day.
local function at(day, minute)
    return os.time({ year = 2026, month = 10, day = 5 + day, hour = math.floor(minute / 60), min = minute % 60, sec = 1 })
end

function tests.the_daily_backup_runs_at_the_home_s_minute_once_a_day_and_is_tried_again()
    local s = start()
    local _, connection = Harness.connected({ mock = s.mock })
    local hour, min = setKey(s).time:match("^(%d%d):(%d%d)$")
    local minute = tonumber(hour) * 60 + tonumber(min)
    local Scheduler = require("src.core.scheduler")
    local function tick(time)
        Scheduler.tick(time)
        return status(s).running
    end
    T.eq(tick(at(0, minute - 1)), false, "not before the home's minute")
    T.eq(tick(at(0, minute)), true, "the scheduler's minute starts it")
    local chunks = upload(s, connection)
    T.truthy(#chunks >= 1)
    T.eq(chunks[1].why, "daily", "the account lets the nightly backup through besides Back up now")
    T.eq(status(s).last.why, "daily")
    T.eq(tick(at(0, minute + 1)), false, "once a day")
    T.eq(tick(at(0, 23 * 60)), false)
    -- The next day the account refuses it: tried again 15 minutes later, until it is made.
    T.eq(tick(at(1, minute)), true)
    upload(s, connection, function()
        return { ok = false, code = "INTERNAL" }
    end)
    T.eq(status(s).last.ok, false)
    T.eq(tick(at(1, minute + 5)), false)
    T.eq(tick(at(1, minute + 15)), true)
    upload(s, connection)
    T.eq(status(s).last.ok, true)
    T.eq(tick(at(1, minute + 30)), false)
    -- Past 06:00 a day that has none gets none.
    T.eq(tick(at(2, 6 * 60)), false)
    T.eq(tick(at(3, 2 * 60 + 59)), false)
    -- With Remote Access off it is not made, and the log says so once a day.
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    T.eq(tick(at(3, minute)), false)
    T.eq(tick(at(3, minute + 15)), false)
    T.eq(status(s).last.code, "REMOTE_ACCESS_OFF")
    local notMade = 0
    for _, entry in ipairs(logged(s, "automatic backup not made")) do
        notMade = notMade + (entry.data.code == "REMOTE_ACCESS_OFF" and 1 or 0)
    end
    T.eq(notMade, 1)
    -- And after a restart, a day whose backup was made is not made again.
    Properties["Remote Access"] = "On"
    local again = Mock.updateDriver(s.mock)
    s.mock = again
    T.eq(require("src.cloud.auto_backup").tick(at(1, minute + 45)), false)
end

-- The history keeps 500 entries: a night whose backup fails says so once, and a refusal that 15
-- minutes will not change is not tried again (each try seals the backup again).
function tests.a_night_of_failures_is_one_history_entry_and_a_refusal_is_not_tried_again()
    local s = start()
    local _, connection = Harness.connected({ mock = s.mock })
    local hour, min = setKey(s).time:match("^(%d%d):(%d%d)$")
    local minute = tonumber(hour) * 60 + tonumber(min)
    local Scheduler = require("src.core.scheduler")
    local Activity = require("src.core.activity")
    local function backups()
        local found = {}
        for _, entry in ipairs(Activity.list({ kinds = { system = true }, limit = 200 })) do
            if entry.action == "cloud_backup" then
                found[#found + 1] = entry
            end
        end
        return found
    end
    -- Every minute of the night, the account refusing each backup as `code`: how many it tried.
    local function night(day, code)
        local tries = 0
        for m = minute, 6 * 60 + 5 do
            Scheduler.tick(at(day, m))
            if status(s).running then
                tries = tries + 1
                upload(s, connection, function()
                    return { ok = false, code = code }
                end)
            end
        end
        return tries
    end
    -- The home is not in an account any more (NOT_CLAIMED): one try, one entry.
    T.eq(night(0, "NOT_CLAIMED"), 1)
    local entries = backups()
    T.eq(#entries, 1)
    T.eq(entries[1].outcome, "failed")
    T.eq(entries[1].reason, "not_linked")
    T.eq(entries[1].note, nil, "not tried again tonight")
    T.eq(entries[1].who.type, "controller")
    -- The account's limits (backups started today, the owner's space), and any other refusal of
    -- the account's (an older or newer account service): the same.
    for day, case in ipairs({ { "BACKUP_LIMIT", "limit" }, { "ACCOUNT_BACKUPS_FULL", "account_full" }, { "OUT_OF_ORDER", "error" } }) do
        T.eq(night(day, case[1]), 1, case[1])
        T.eq(#backups(), day + 1)
        T.eq(backups()[1].reason, case[2])
        T.eq(backups()[1].note, nil)
    end
    -- The account service's own error may pass: tried again every 15 minutes until 06:00, and the
    -- history says it once, with "retry".
    local tries = night(4, "INTERNAL")
    T.eq(tries, math.floor((6 * 60 - 1 - minute) / 15) + 1, "every 15 minutes until 06:00")
    entries = backups()
    T.eq(#entries, 5, "once a night")
    T.eq(entries[1].reason, "account_unreachable")
    T.eq(entries[1].note, "retry")
    -- No answer the first time, then made: the failure once, then that it was made.
    Scheduler.tick(at(5, minute))
    T.eq(status(s).running, true)
    runSteps(s.mock)
    T.eq(#chunksSent(connection), 1)
    for _, timer in ipairs(s.mock.timers) do
        if not timer.fired and not timer.cancelled and timer.delay == 30000 and timer.source:find("cloud/relay", 1, true) then
            timer.fired = true
            timer.callback()
        end
    end
    T.eq(status(s).last.code, "RELAY_TIMEOUT")
    Scheduler.tick(at(5, minute + 15))
    T.truthy(#upload(s, connection) >= 1)
    T.eq(status(s).last.ok, true)
    entries = backups()
    T.eq(#entries, 7)
    T.eq(entries[1].outcome, "ran")
    T.eq(entries[1].who.type, "controller")
    T.eq(entries[2].reason, "account_unreachable")
    T.eq(entries[2].note, "retry")
    -- Tried for the first time less than 15 minutes before 06:00 (the controller was off until
    -- then): not "retry".
    T.eq(require("src.cloud.auto_backup").tick(at(6, 6 * 60 - 10)), true)
    upload(s, connection, function()
        return { ok = false, code = "INTERNAL" }
    end)
    T.eq(#backups(), 8)
    T.eq(backups()[1].reason, "account_unreachable")
    T.eq(backups()[1].note, nil, "06:00 comes first")
end

-- A start that is refused is said once a night too, and only what may pass is tried again.
function tests.a_backup_that_cannot_start_is_tried_again_only_when_that_may_help()
    local s = start()
    local hour, min = setKey(s).time:match("^(%d%d):(%d%d)$")
    local minute = tonumber(hour) * 60 + tonumber(min)
    local AutoBackup = require("src.cloud.auto_backup")
    local Activity = require("src.core.activity")
    -- Remote Access off (as it ships): not tried again that night.
    T.eq(AutoBackup.tick(at(0, minute)), false)
    local entry = Activity.list({ kinds = { system = true } })[1]
    T.eq(entry.action, "cloud_backup")
    T.eq(entry.reason, "remote_off")
    T.eq(entry.note, nil)
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    T.eq(AutoBackup.tick(at(0, minute + 15)), false)
    T.eq(status(s).last.code, "REMOTE_ACCESS_OFF", "not tried again")
    -- Remote Access on, the relay not connected: tried again, said once.
    T.eq(AutoBackup.tick(at(1, minute)), false)
    T.eq(status(s).last.code, "REMOTE_OFFLINE")
    entry = Activity.list({ kinds = { system = true } })[1]
    T.eq(entry.reason, "account_unreachable")
    T.eq(entry.note, "retry")
    local count = Activity.count()
    T.eq(AutoBackup.tick(at(1, minute + 14)), false)
    T.eq(status(s).last.at, require("src.core.clock").iso(at(1, minute)), "not before 15 minutes")
    T.eq(AutoBackup.tick(at(1, minute + 15)), false)
    T.eq(status(s).last.at, require("src.core.clock").iso(at(1, minute + 15)), "tried again")
    T.eq(Activity.count(), count, "said once")
end

return tests
