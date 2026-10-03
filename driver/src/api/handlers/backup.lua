-- Backup and restore (ADR-042, docs/BACKUP.md, src/core/backup.lua), for admins, and only in sealed
-- requests (at home and through the account), like GET /v1/alarm: a backup holds every key's hash
-- and lock key and the home's remote identity, which never cross a network in the clear.
--   GET  /v1/backup         the document (the app encrypts it with a password before saving it)
--   POST /v1/restore/parts  the document's JSON text on its way back, in parts
--   POST /v1/restore        checks it ("dry_run", the default: nothing changes) or restores it;
--                           "replaces_key": this device is that key of the backup's, "move_remote":
--                           another home's remote identity moves here
-- Automatic backups to the account (ADR-048, src/cloud/auto_backup.lua):
--   GET    /v1/backup/automatic      whether they are on, the backup password's public key, the last
--   PUT    /v1/backup/automatic      the backup password's public key, salt and iterations (sealed)
--   DELETE /v1/backup/automatic      turns them off (sealed)
--   POST   /v1/backup/automatic/run  Back up now

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Backup = require("src.core.backup")
local AutoBackup = require("src.cloud.auto_backup")

local Handlers = {}

-- Sealed requests carry their key as principal (src/cloud/remote.lua); a request with an
-- Authorization header came as plain HTTP.
local function inTheClear(ctx)
    if ctx.request and ctx.request.principal then
        return nil
    end
    return Problem.new(403, "SEALED_REQUEST_REQUIRED",
        "A backup holds every key's lock key and the home's remote identity: it goes only in sealed requests, as the DirectorLink app sends them; this request came in the clear")
end

local function problemFrom(failure)
    local extra = failure.extra
    if failure.errors then
        extra = extra or {}
        extra.errors = Json.array(failure.errors)
    end
    return Problem.new(failure.status, failure.code, failure.detail, extra)
end

function Handlers.export(ctx)
    local refused = inTheClear(ctx)
    if refused then
        return refused
    end
    Backup.sweep(Clock.now())
    local document = Backup.export(ctx.services.registry)
    -- Whether Director gave the controller's MAC address (C4:GetUniqueMAC) and the relay had
    -- accepted the home's identity: what tells this home's backups from another's (ADR-042).
    ctx.services.log.info("backup", "backup made", {
        key_id = ctx.apiKey.id,
        scenes = #document.sections.scenes.scenes,
        keys = #document.sections.keys.keys,
        controller_known = document.controller_id ~= Json.null,
        remote_identity = document.sections.remote_identity.linked == true,
    })
    return 200, document
end

-- POST /v1/restore/parts {"index": 0, "count": 3, "text": "..."}, then {"upload": id, "index": 1, ...}.
function Handlers.part(ctx)
    local refused = inTheClear(ctx)
    if refused then
        return refused
    end
    local problem = Validate.body(ctx.body, { upload = true, index = true, count = true, text = true }, true)
    if problem then
        return problem
    end
    if ctx.body.upload ~= nil and not (type(ctx.body.upload) == "string" and ctx.body.upload:match("^%x+$")) then
        return Problem.invalidField("upload", "upload is the id the first part's answer gave")
    end
    local result, failure = Backup.receivePart(ctx.apiKey.id, ctx.body, Clock.now())
    if not result then
        return problemFrom(failure)
    end
    return 200, result
end

-- POST /v1/restore {"upload": id} or {"document": {...}}, and "dry_run": false to restore.
function Handlers.restore(ctx)
    local refused = inTheClear(ctx)
    if refused then
        return refused
    end
    local body = ctx.body
    local problem = Validate.body(body, { upload = true, document = true, dry_run = true, replaces_key = true, move_remote = true }, true)
    if problem then
        return problem
    end
    if (body.upload == nil) == (body.document == nil) then
        return Problem.invalidRequest("Send the backup as upload (POST /v1/restore/parts) or as document, one of them")
    end
    if body.dry_run ~= nil and type(body.dry_run) ~= "boolean" then
        return Problem.invalidField("dry_run", "dry_run must be true or false")
    end
    if body.replaces_key ~= nil and not (type(body.replaces_key) == "string" and #body.replaces_key == 8 and body.replaces_key:match("^[0-9a-f]+$")) then
        return Problem.invalidField("replaces_key", "replaces_key is the id of the backup's key this device takes the place of (8 hex digits)")
    end
    if body.move_remote ~= nil and type(body.move_remote) ~= "boolean" then
        return Problem.invalidField("move_remote", "move_remote must be true or false")
    end
    local services = ctx.services
    -- Devices and rooms are matched to the project: it has to have been read.
    if services.status().state ~= "ok" then
        return Problem.new(503, "PROJECT_NOT_READY", "DirectorLink has not read the project yet; try again in a minute")
    end
    local now = Clock.now()
    local document = body.document
    if body.upload ~= nil then
        local failure
        document, failure = Backup.uploaded(ctx.apiKey.id, tostring(body.upload), now)
        if not document then
            return problemFrom(failure)
        end
    end
    local plan, failure = Backup.plan(document, {
        registry = services.registry,
        restorer = ctx.apiKey.id,
        now = now,
        replaces = body.replaces_key,
        move_remote = body.move_remote == true,
        controller = Backup.controllerId(),
    })
    if not plan then
        return problemFrom(failure)
    end
    if body.dry_run ~= false then
        return 200, { dry_run = true, restore = plan.preview }
    end
    local ok, store = Backup.apply(plan, now)
    if not ok then
        return Problem.new(500, "RESTORE_FAILED", "The " .. tostring(store) .. " could not be saved; nothing was changed", { store = store })
    end
    if body.upload ~= nil then
        Backup.forget(ctx.apiKey.id, tostring(body.upload))
    end
    if services.onRestored then
        pcall(services.onRestored, { switching = plan.switching })
    end
    return 200, { dry_run = false, restore = plan.preview, restored_at = Clock.iso(now) }
end

function Handlers.automatic(ctx)
    return 200, AutoBackup.status()
end

-- PUT /v1/backup/automatic {"public_key", "salt", "iterations", "kdf"}: sealed only, so that nobody
-- on the network can put their own key in its place.
function Handlers.set_automatic(ctx)
    local refused = inTheClear(ctx)
    if refused then
        return refused
    end
    local problem = Validate.body(ctx.body, { public_key = true, salt = true, iterations = true, kdf = true })
    if problem then
        return problem
    end
    local status, failure = AutoBackup.setKey(ctx.body, ctx.apiKey.id, Clock.now())
    if not status then
        if failure.field then
            return Problem.invalidField(failure.field, failure.detail)
        end
        return problemFrom(failure)
    end
    return 200, status
end

function Handlers.clear_automatic(ctx)
    local refused = inTheClear(ctx)
    if refused then
        return refused
    end
    local ok, failure = AutoBackup.clear(ctx.apiKey.id)
    if not ok then
        return problemFrom(failure)
    end
    return 204
end

-- Why Back up now cannot start: the status and what to say.
local NOT_NOW = {
    AUTOMATIC_BACKUP_OFF = { 409, "Automatic backups are off: set the backup password first" },
    BACKUP_RUNNING = { 409, "A backup is being made; it is done in a minute" },
    REMOTE_ACCESS_OFF = { 409, "Backups go to the account through remote access: turn on Remote Access in Composer first" },
    HOME_NOT_LINKED = { 409, "DirectorLink's servers have not accepted this home yet: link it to your account first" },
    LOCK_UNAVAILABLE = { 503, "This controller cannot seal (the lock self-test failed; see the log)" },
    REMOTE_OFFLINE = { 503, "The controller is not connected to DirectorLink's servers; try again in a minute" },
    PROJECT_NOT_READY = { 503, "DirectorLink has not read the project yet; try again in a minute" },
}

function Handlers.run_automatic(ctx)
    local ok, code = AutoBackup.runNow(ctx.apiKey.id, Clock.now())
    if not ok then
        local answer = NOT_NOW[code] or { 500, "The backup could not start" }
        return Problem.new(answer[1], code, answer[2])
    end
    return 202, { started = true, status = AutoBackup.status() }
end

return Handlers
