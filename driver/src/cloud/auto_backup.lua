-- Automatic backups to the home's account (ADR-048, docs/BACKUP.md). Once a day, at the home's own
-- minute between 03:00 and 04:59 (the controller's time), and when an admin asks (Back up now),
-- DirectorLink makes the document GET /v1/backup gives, seals it to the backup password's public
-- key (src/cloud/backup_seal.lua) and sends it to the account service over the relay connection,
-- in chunks, each answered before the next goes. Only while Remote Access is on and the relay has
-- accepted the home (a home in the account); the account service keeps the last 7 and cannot open
-- them: an admin types the backup password in the app to restore one.
--
-- An admin sets the password in the app, which keeps it: the controller gets only the public key,
-- the salt and the iterations it was made with (PUT /v1/backup/automatic, sealed requests only).
-- Nothing here holds the Lua thread long: the document, each slice of the two scalar
-- multiplications, the encryption and each chunk run in a timer tick of their own.

local Activity = require("src.core.activity")
local Backup = require("src.core.backup")
local BackupSeal = require("src.cloud.backup_seal")
local Base64 = require("src.core.base64")
local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Random = require("src.core.random")
local Relay = require("src.cloud.relay")
local Store = require("src.core.store")
local X25519 = require("src.core.x25519")

local AutoBackup = {}

local STORE_KEY = "directorlink_auto_backup"
-- The home's minute is one of these 120 (03:00 to 04:59), picked at random once.
AutoBackup.FIRST_MINUTE = 3 * 60
AutoBackup.WINDOW_MINUTES = 120
-- A daily backup that could not be made for a reason that may pass (RETRY) is tried again this
-- often, until 06:00; then that day has none.
AutoBackup.RETRY_MINUTES = 15
AutoBackup.LAST_MINUTE = 6 * 60
-- What 15 minutes may change: the relay offline or not answering, the account service's own error,
-- the project still being read. Anything else (Remote Access off, the home not in an account, too
-- large, the password changed, any other refusal or failure) is not tried again that night.
AutoBackup.RETRY = { REMOTE_OFFLINE = true, RELAY_TIMEOUT = true, INTERNAL = true, PROJECT_NOT_READY = true }
-- Why a backup was not made, as the history says it (GET /v1/activity's `reason`, docs/HISTORY.md):
-- these few; "error" for the rest. The log and GET /v1/backup/automatic have the code itself.
AutoBackup.HISTORY_REASONS = {
    REMOTE_ACCESS_OFF = "remote_off",
    REMOTE_OFFLINE = "account_unreachable",
    RELAY_TIMEOUT = "account_unreachable",
    INTERNAL = "account_unreachable",
    HOME_NOT_LINKED = "not_linked",
    NOT_CLAIMED = "not_linked",
    BACKUP_TOO_LARGE = "too_large",
    AUTOMATIC_BACKUP_OFF = "stopped",
    KEY_CHANGED = "stopped",
}
-- Each chunk is at most this many characters of the sealed backup's text (the account service
-- takes 65536), and the whole at most MAX_BYTES (cloud/src/backups.js).
AutoBackup.CHUNK_BYTES = 60000
AutoBackup.MAX_BYTES = 3000000
-- How long each chunk's answer may take.
AutoBackup.ANSWER_SECONDS = 30
-- Between two steps of a backup, so that Director runs what waits meanwhile.
AutoBackup.STEP_MS = 20
-- The password's key: as the app makes it (PBKDF2-SHA-256), within these.
AutoBackup.KDF = BackupSeal.KDF
AutoBackup.MIN_ITERATIONS = 100000
AutoBackup.MAX_ITERATIONS = 5000000

-- config: { version, key = { public_key, salt, iterations, kdf, key_id, set_at, set_by } or nil,
-- minute (of the day), daily (the local date whose backup was made), last = { at, ok, size,
-- code, why } }. complete: the stored config was read (or there was none). retryAt: when the
-- night's backup is tried again; warnedDay: the night whose failure the history has; overDay: the
-- night whose backup is not tried again.
local state = { config = { version = 1 }, complete = true, job = nil, timer = nil, retryAt = nil, warnedDay = nil, overDay = nil, options = {} }

local function save()
    return Store.write(STORE_KEY, state.config, false)
end

local function localDay(now)
    local fields = os.date("*t", now)
    return string.format("%04d-%02d-%02d", fields.year, fields.month, fields.day), fields.hour * 60 + fields.min
end

local function validKey(key)
    if type(key) ~= "table" then
        return false
    end
    local public, salt = Base64.decode(key.public_key), Base64.decode(key.salt)
    return public ~= nil and #public == 32 and salt ~= nil and #salt == 16 and key.kdf == AutoBackup.KDF
        and type(key.iterations) == "number" and key.iterations == math.floor(key.iterations)
        and key.iterations >= AutoBackup.MIN_ITERATIONS and key.iterations <= AutoBackup.MAX_ITERATIONS
        and key.key_id == BackupSeal.keyId(public)
end

function AutoBackup.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    state.config = { version = 1 }
    if type(data) == "table" then
        state.config.key = validKey(data.key) and {
            public_key = data.key.public_key,
            salt = data.key.salt,
            iterations = data.key.iterations,
            kdf = data.key.kdf,
            key_id = data.key.key_id,
            set_at = tonumber(data.key.set_at),
            set_by = type(data.key.set_by) == "string" and data.key.set_by or nil,
        } or nil
        local minute = tonumber(data.minute)
        if minute and minute >= AutoBackup.FIRST_MINUTE and minute < AutoBackup.FIRST_MINUTE + AutoBackup.WINDOW_MINUTES then
            state.config.minute = math.floor(minute)
        end
        state.config.daily = type(data.daily) == "string" and data.daily or nil
        state.config.last = type(data.last) == "table" and data.last or nil
    elseif not state.complete then
        Log.warn("backup", "the automatic backup settings are unreadable")
    end
end

-- options: { registry, ready() (the project is read), remoteEnabled(), lockAvailable() }
function AutoBackup.configure(options)
    state.options = options or {}
end

-- The home's minute (03:00 to 04:59), picked once.
local function homeMinute()
    if not state.config.minute then
        state.config.minute = AutoBackup.FIRST_MINUTE + Random.below(AutoBackup.WINDOW_MINUTES)
    end
    return state.config.minute
end

-- What GET /v1/backup/automatic answers. The public key, salt and iterations only when `full` (a
-- sealed request): with them a password can be guessed offline, so they never go in the clear.
function AutoBackup.status(full)
    local key, last = state.config.key, state.config.last
    local minute = state.config.minute or AutoBackup.FIRST_MINUTE
    local options = state.options
    local identity = Relay.storedIdentity()
    return {
        enabled = key ~= nil,
        key = key and {
            key_id = key.key_id,
            public_key = full and key.public_key or nil,
            salt = full and key.salt or nil,
            iterations = full and key.iterations or nil,
            kdf = full and key.kdf or nil,
            set_at = key.set_at and Clock.iso(key.set_at) or Json.null,
        } or Json.null,
        -- The controller's time, from when the password is set.
        time = key and string.format("%02d:%02d", math.floor(minute / 60), minute % 60) or Json.null,
        running = state.job ~= nil,
        last = last and {
            at = Clock.iso(tonumber(last.at) or 0),
            ok = last.ok == true,
            size = tonumber(last.size) or Json.null,
            code = type(last.code) == "string" and last.code or Json.null,
            why = type(last.why) == "string" and last.why or Json.null,
        } or Json.null,
        remote = {
            enabled = options.remoteEnabled ~= nil and options.remoteEnabled() == true,
            connected = Relay.connected(),
            linked = identity ~= nil and identity.linked == true,
        },
    }
end

local function invalid(field, detail)
    return nil, { status = 400, code = "INVALID_FIELD", detail = detail, field = field }
end

-- Sets the backup password's public key ({ public_key, salt, iterations, kdf }) from now on, for
-- the admin key `keyId`. Returns the status, or nil and a problem.
function AutoBackup.setKey(body, keyId, now)
    if not state.complete then
        return nil, { status = 503, code = "UNAVAILABLE", detail = "DirectorLink could not read its automatic backup settings when it started. Restart the driver and try again" }
    end
    local public = type(body.public_key) == "string" and Base64.decode(body.public_key) or nil
    if not public or #public ~= 32 or X25519.smallOrder(public) then
        return invalid("public_key", "public_key is the backup password's X25519 public key, 32 bytes in base64")
    end
    local salt = type(body.salt) == "string" and Base64.decode(body.salt) or nil
    if not salt or #salt ~= 16 then
        return invalid("salt", "salt is the 16 random bytes the key was made with, in base64")
    end
    local iterations = body.iterations
    if type(iterations) ~= "number" or iterations ~= math.floor(iterations) or iterations < AutoBackup.MIN_ITERATIONS or iterations > AutoBackup.MAX_ITERATIONS then
        return invalid("iterations", "iterations is PBKDF2's, " .. AutoBackup.MIN_ITERATIONS .. " to " .. AutoBackup.MAX_ITERATIONS)
    end
    if body.kdf ~= AutoBackup.KDF then
        return invalid("kdf", "kdf is " .. AutoBackup.KDF)
    end
    local before = state.config.key
    local changed = before ~= nil
    state.config.key = {
        public_key = Base64.encode(public),
        salt = Base64.encode(salt),
        iterations = iterations,
        kdf = AutoBackup.KDF,
        key_id = BackupSeal.keyId(public),
        set_at = now or Clock.now(),
        set_by = keyId,
    }
    homeMinute()
    if not save() then
        state.config.key = before
        return nil, { status = 500, code = "PERSIST_FAILED", detail = "The backup password's key could not be saved" }
    end
    Log.info("backup", changed and "backup password changed" or "automatic backups turned on", { key_id = state.config.key.key_id, by = keyId })
    return AutoBackup.status(true)
end

-- Turns automatic backups off (the key goes). Returns true, or nil and a problem.
function AutoBackup.clear(keyId)
    if not state.complete then
        return nil, { status = 503, code = "UNAVAILABLE", detail = "DirectorLink could not read its automatic backup settings when it started. Restart the driver and try again" }
    end
    local before = state.config.key
    state.config.key = nil
    if not save() then
        state.config.key = before
        return nil, { status = 500, code = "PERSIST_FAILED", detail = "The change could not be saved" }
    end
    if before then
        Log.info("backup", "automatic backups turned off", { by = keyId })
    end
    return true
end

-- ---- One backup ---------------------------------------------------------------------------------

local function cancelTimer()
    if state.timer then
        pcall(function()
            state.timer:Cancel()
        end)
        state.timer = nil
    end
end

-- Runs `step` STEP_MS from now, in a timer kept referenced.
local function later(step)
    cancelTimer()
    local ok = pcall(function()
        state.timer = C4:SetTimer(AutoBackup.STEP_MS, function()
            state.timer = nil
            step()
        end, false)
    end)
    if not ok then
        step()
    end
end

-- The history's entry (ADR-046) for a backup not made: why, in a few words, and "retry" when the
-- night's backup is tried again.
local function recordFailed(code, by, retry)
    Activity.record("system", "cloud_backup", {
        by = by,
        outcome = "failed",
        reason = AutoBackup.HISTORY_REASONS[code] or "error",
        note = retry and "retry" or nil,
    })
end

-- The night's backup (the local date `day`) was not made (`code`), tried at `at`: it is tried again
-- RETRY_MINUTES later when that may help and is before LAST_MINUTE, else not that night. The
-- history says so once a night, at the first failure (a backup made later that night is listed as
-- made); the log every time. Returns whether it is tried again.
local function nightFailed(day, at, code)
    local retryDay, retryMinute = localDay(at + AutoBackup.RETRY_MINUTES * 60)
    local retry = AutoBackup.RETRY[code] == true and retryDay == day and retryMinute < AutoBackup.LAST_MINUTE
    if retry then
        state.retryAt = at + AutoBackup.RETRY_MINUTES * 60
    else
        state.retryAt, state.overDay = nil, day
    end
    if state.warnedDay ~= day then
        state.warnedDay = day
        recordFailed(code, nil, retry)
    end
    return retry
end

local function finish(job, ok, code, size)
    cancelTimer()
    state.job = nil
    local now = Clock.now()
    state.config.last = { at = now, ok = ok, size = size, code = code, why = job.why }
    if ok then
        state.retryAt = nil
        if job.why == "daily" then
            state.config.daily = job.day
        end
        Log.info("backup", "backup uploaded", {
            why = job.why,
            size = size,
            chunks = job.count,
            key_id = job.key.key_id,
            seal_ms = job.sealMs,
            total_ms = Clock.millis() - job.started,
        })
        -- The history: who asked (Back up now) or the controller (every night).
        Activity.record("system", "cloud_backup", { by = job.by, outcome = "ran" })
    elseif job.why == "daily" then
        -- From when it started (the scheduler's minute).
        local retry = nightFailed(job.day, job.at, code)
        Log.warn("backup", "automatic backup not made", { why = job.why, code = code, step = job.phase, retry = retry })
    else
        Log.warn("backup", "automatic backup not made", { why = job.why, code = code, step = job.phase })
        recordFailed(code, job.by, false)
    end
    save()
end

-- What stops a backup under way: automatic backups turned off, or the password changed (it was
-- being made for the old one). Nil while it may go on.
local function stopped(job)
    if not state.config.key then
        return "AUTOMATIC_BACKUP_OFF"
    elseif state.config.key.key_id ~= job.key.key_id then
        return "KEY_CHANGED"
    end
    return nil
end

-- Why a backup cannot start now; nil when it can.
local function blocked()
    local options = state.options
    if not state.config.key then
        return "AUTOMATIC_BACKUP_OFF"
    elseif state.job then
        return "BACKUP_RUNNING"
    elseif not (options.remoteEnabled and options.remoteEnabled()) then
        return "REMOTE_ACCESS_OFF"
    elseif options.lockAvailable and not options.lockAvailable() then
        return "LOCK_UNAVAILABLE"
    elseif not Relay.connected() then
        return "REMOTE_OFFLINE"
    end
    local identity = Relay.storedIdentity()
    if not (identity and identity.linked) then
        return "HOME_NOT_LINKED"
    elseif options.ready and not options.ready() then
        return "PROJECT_NOT_READY"
    end
    return nil
end

local upload

-- Sends chunk `index` and, once it is answered, the next.
local function sendChunk(job, index)
    if state.job ~= job then
        return
    end
    job.phase = "upload"
    -- Turned off or the password changed while it uploads: nothing more goes (the account service
    -- drops the unfinished upload).
    local halt = stopped(job)
    if halt then
        finish(job, false, halt)
        return
    end
    local data = job.text:sub(index * AutoBackup.CHUNK_BYTES + 1, (index + 1) * AutoBackup.CHUNK_BYTES)
    local message = { type = "backup_chunk", index = index, data = data }
    if index == 0 then
        message.count, message.size, message.key_id = job.count, #job.text, job.key.key_id
    else
        message.backup = job.backup
    end
    Relay.ask(message, AutoBackup.ANSWER_SECONDS, function(answer, failure)
        if state.job ~= job then
            return
        end
        if not answer then
            finish(job, false, failure or "RELAY_TIMEOUT")
        elseif answer.ok ~= true then
            finish(job, false, type(answer.code) == "string" and answer.code or "REFUSED")
        elseif index == job.count - 1 then
            if answer.complete == true then
                finish(job, true, nil, #job.text)
            else
                finish(job, false, "NOT_COMPLETE")
            end
        else
            if index == 0 then
                job.backup = answer.backup
            end
            if type(job.backup) ~= "string" then
                finish(job, false, "NO_BACKUP_ID")
                return
            end
            later(function()
                sendChunk(job, index + 1)
            end)
        end
    end)
end

upload = function(job)
    job.text = Json.encode(job.sealed)
    job.sealed = nil
    if #job.text > AutoBackup.MAX_BYTES then
        finish(job, false, "BACKUP_TOO_LARGE")
        return
    end
    job.count = math.ceil(#job.text / AutoBackup.CHUNK_BYTES)
    sendChunk(job, 0)
end

-- Runs the backup's next step, then schedules the one after it.
local function advance(job)
    if state.job ~= job then
        return
    end
    -- The password changed or automatic backups were turned off meanwhile.
    local halt = stopped(job)
    if halt then
        finish(job, false, halt)
        return
    end
    local tooLarge = false
    local ok, err = pcall(function()
        if job.phase == "document" then
            job.document = Backup.export(state.options.registry)
            job.phase = "json"
        elseif job.phase == "json" then
            job.plaintext = Json.encode(job.document)
            job.document = nil
            -- Larger sealed than the account takes: not sealed at all.
            if BackupSeal.size(job.key, #job.plaintext) > AutoBackup.MAX_BYTES then
                tooLarge = true
                job.plaintext = nil
                return
            end
            job.seal = BackupSeal.start(job.key, job.plaintext)
            job.phase = "seal"
        elseif job.phase == "seal" then
            local started = Clock.millis()
            local done = job.seal.step()
            job.sealMs = job.sealMs + (Clock.millis() - started)
            if done then
                job.sealed = job.seal.result()
                job.seal, job.plaintext = nil, nil
                job.phase = "sealed"
            end
        end
    end)
    if not ok then
        Log.error("backup", "an automatic backup failed", { step = job.phase, error = tostring(err) })
        finish(job, false, "FAILED")
        return
    elseif tooLarge then
        finish(job, false, "BACKUP_TOO_LARGE")
        return
    end
    if job.phase == "sealed" then
        later(function()
            if state.job == job then
                upload(job)
            end
        end)
    else
        later(function()
            advance(job)
        end)
    end
end

-- Starts a backup: why = "daily" or "now". Returns true, or nil and why it cannot start.
local function start(why, now)
    local code = blocked()
    if code then
        return nil, code
    end
    now = now or Clock.now()
    local job = { why = why, at = now, day = localDay(now), key = state.config.key, phase = "document", sealMs = 0, started = Clock.millis() }
    state.job = job
    later(function()
        advance(job)
    end)
    return true
end

-- Back up now (POST /v1/backup/automatic/run).
function AutoBackup.runNow(keyId, now)
    local ok, code = start("now", now)
    if ok then
        state.job.by = keyId
        Log.info("backup", "backup started", { why = "now", by = keyId })
    end
    return ok, code
end

-- Every minute (the scheduler's tick): the day's backup at the home's minute, and again every
-- RETRY_MINUTES until LAST_MINUTE while it could not be made for a reason that may pass.
function AutoBackup.tick(now)
    now = now or Clock.now()
    if not state.config.key or not state.complete or state.job then
        return false
    end
    local day, minute = localDay(now)
    if state.config.daily == day or state.overDay == day or minute < homeMinute() or minute >= AutoBackup.LAST_MINUTE then
        return false
    end
    if state.retryAt and now < state.retryAt then
        return false
    end
    local ok, code = start("daily", now)
    if not ok then
        state.config.last = { at = now, ok = false, code = code, why = "daily" }
        save()
        -- Once a night in the log too: Remote Access may be off for good.
        local first = state.warnedDay ~= day
        local retry = nightFailed(day, now, code)
        if first then
            Log.warn("backup", "automatic backup not made", { why = "daily", code = code, retry = retry })
        end
    end
    return ok == true
end

-- Test support: forget everything (a fresh driver instance).
function AutoBackup.reset()
    cancelTimer()
    state.config, state.complete, state.job, state.retryAt, state.warnedDay, state.overDay, state.options = { version = 1 }, true, nil, nil, nil, nil, {}
end

return AutoBackup
