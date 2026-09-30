-- Pairing: an 8-digit code, created on demand with the Composer action "New Pairing Code" (and
-- automatically while the driver has no API keys, e.g. right after it is added). A code is valid
-- for 15 minutes, works once, and gives an admin key: whoever can run Composer actions controls the
-- project anyway. Composer shows it as "1234 5678"; clients may send it with or without the space.
-- The app never sends it: it pairs with CPace (src/auth/cpace_pairing.lua, ADR-039), whose
-- attempts count against the same limits (Pairing.begin and Pairing.conclude).

local Random = require("src.core.random")

local Pairing = {}

local PAIRING_COUNT_KEY = "directorlink_pairing_count"

Pairing.CODE_TTL_SECONDS = 15 * 60
local FAILED_WINDOW_SECONDS = 60
-- Per device (IP address): so one device's wrong guesses do not lock out everyone else.
local MAX_FAILED_ATTEMPTS = 5
local LOCK_SECONDS = 60
-- Per code, from all devices together: then the code is closed and a new one is needed.
local MAX_CODE_FAILURES = 20
local MAX_TRACKED_CLIENTS = 200

local OFF_TEXT = "Off - run New Pairing Code to pair a device"

local state = {
    code = nil,
    codeExpiresAt = 0,
    closedText = OFF_TEXT,
    pairingCount = 0,
    clients = {}, -- ip -> { failed, windowStartedAt, lockedUntil }
    trackedClients = 0,
    codeFailures = 0,
    -- Changes whenever a code is made or closed: a CPace attempt belongs to the code it began with.
    generation = 0,
    expiryTimer = nil,
    onChange = nil,
    log = nil,
}

local function log(message, data)
    if state.log then
        state.log.info("auth", message, data)
    end
end

local function generateCode()
    local ok, numeric = pcall(Random.below, 100000000)
    if not ok then
        return nil, tostring(numeric)
    end
    return string.format("%08d", numeric)
end

local function constantTimeEqual(left, right)
    left = tostring(left or "")
    right = tostring(right or "")
    if #left ~= #right then
        return false
    end
    local same = true
    for index = 1, #left do
        if left:byte(index) ~= right:byte(index) then
            same = false
        end
    end
    return same
end

-- "12345678" -> "1234 5678"
function Pairing.format(code)
    code = tostring(code or "")
    return code:sub(1, 4) .. " " .. code:sub(5, 8)
end

-- Accepts "12345678", "1234 5678" or "1234-5678"; returns the 8 digits or nil.
function Pairing.normalize(input)
    if type(input) ~= "string" then
        return nil
    end
    local digits = input:gsub("[%s%-]", "")
    if digits:match("^%d%d%d%d%d%d%d%d$") then
        return digits
    end
    return nil
end

function Pairing.isActive(now)
    return state.code ~= nil and state.codeExpiresAt > (now or os.time())
end

function Pairing.statusText(now)
    now = now or os.time()
    if Pairing.isActive(now) then
        return "Ready until " .. os.date("%H:%M", state.codeExpiresAt) .. " - works once"
    end
    return state.closedText
end

local function publish()
    if state.onChange then
        state.onChange(Pairing.isActive() and Pairing.format(state.code) or "-", Pairing.statusText())
    end
end

local function cancelTimer()
    pcall(function()
        if state.expiryTimer then
            state.expiryTimer:Cancel()
        end
    end)
    state.expiryTimer = nil
end

local function close(text)
    cancelTimer()
    state.generation = state.generation + 1
    state.code = nil
    state.codeExpiresAt = 0
    state.closedText = text or OFF_TEXT
    publish()
end

local function resetFailures()
    state.clients = {}
    state.trackedClients = 0
    state.codeFailures = 0
end

local function clientState(ip, now)
    ip = tostring(ip or "unknown")
    local client = state.clients[ip]
    if not client then
        if state.trackedClients >= MAX_TRACKED_CLIENTS then
            -- Too many devices guessing: start counting afresh (the per-code limit still holds).
            state.clients, state.trackedClients = {}, 0
        end
        client = { failed = 0, windowStartedAt = now, lockedUntil = 0 }
        state.clients[ip] = client
        state.trackedClients = state.trackedClients + 1
    end
    return client
end

-- Creates a new code, valid for CODE_TTL_SECONDS. Returns true, or false plus a reason.
function Pairing.open()
    local code, err = generateCode()
    if not code then
        close("Unavailable: " .. tostring(err))
        return false, err
    end
    cancelTimer()
    resetFailures()
    state.generation = state.generation + 1
    state.code = code
    state.codeExpiresAt = os.time() + Pairing.CODE_TTL_SECONDS
    pcall(function()
        state.expiryTimer = C4:SetTimer(Pairing.CODE_TTL_SECONDS * 1000, function()
            state.expiryTimer = nil
            close("Expired - run New Pairing Code to pair a device")
            log("pairing code expired unused")
        end, false)
    end)
    publish()
    log("pairing code created", { valid_minutes = Pairing.CODE_TTL_SECONDS / 60 })
    return true
end

-- options: { onChange = function(code, status), log = Log, openNow = boolean }
function Pairing.initialize(options)
    options = options or {}
    state.onChange = options.onChange
    state.log = options.log

    local ok, count = pcall(function()
        return C4:PersistGetValue(PAIRING_COUNT_KEY, false)
    end)
    state.pairingCount = ok and tonumber(count) or 0
    resetFailures()

    if options.openNow then
        return Pairing.open()
    end
    close(OFF_TEXT)
    return true
end

local function notActive()
    return {
        code = "PAIRING_NOT_ACTIVE",
        message = "No pairing code is active. In Composer, run New Pairing Code on DirectorLink "
            .. "(or ask your installer); a code lasts 15 minutes and works once.",
    }
end

-- Before a code is tried: the device is not locked out, and a code is active. Returns a failure, or nil.
local function admit(client, now)
    if client.lockedUntil > now then
        return {
            code = "PAIRING_RATE_LIMITED",
            message = "Too many failed pairing attempts. Try again shortly.",
            retry_after = client.lockedUntil - now,
        }
    end
    if not Pairing.isActive(now) then
        if state.code then
            close("Expired - run New Pairing Code to pair a device")
        end
        return notActive()
    end
    if now - client.windowStartedAt >= FAILED_WINDOW_SECONDS then
        client.failed, client.windowStartedAt = 0, now
    end
    return nil
end

local function closeAfterFailures()
    close("Closed after " .. MAX_CODE_FAILURES .. " wrong codes - run New Pairing Code to pair a device")
    if state.log then
        state.log.warn("auth", "pairing code closed after repeated failures", { failures = MAX_CODE_FAILURES })
    end
    return {
        code = "PAIRING_NOT_ACTIVE",
        message = "This pairing code was closed after too many wrong attempts. Run New Pairing Code again.",
    }
end

local function lockDevice(client, ip, now)
    client.lockedUntil = now + LOCK_SECONDS
    client.failed, client.windowStartedAt = 0, now
    if state.log then
        state.log.warn("auth", "pairing locked for a device after repeated failures", { seconds = LOCK_SECONDS, client = tostring(ip) })
    end
    return {
        code = "PAIRING_RATE_LIMITED",
        message = "Too many failed pairing attempts. Try again in " .. LOCK_SECONDS .. " seconds.",
        retry_after = LOCK_SECONDS,
    }
end

-- What a wrong code, already counted, means: the code closes after MAX_CODE_FAILURES in all, the
-- device is locked after MAX_FAILED_ATTEMPTS, or it may try again.
local function wrongCode(client, ip, now)
    if state.codeFailures >= MAX_CODE_FAILURES then
        return closeAfterFailures()
    end
    if client.failed >= MAX_FAILED_ATTEMPTS then
        return lockDevice(client, ip, now)
    end
    return {
        code = "PAIRING_CODE_INVALID",
        message = "The pairing code is incorrect",
        attempts_remaining = MAX_FAILED_ATTEMPTS - client.failed,
    }
end

local function used()
    state.pairingCount = state.pairingCount + 1
    pcall(function()
        C4:PersistSetValue(PAIRING_COUNT_KEY, tostring(state.pairingCount), false)
    end)
    resetFailures()
    close("Used at " .. os.date("%H:%M") .. " - run New Pairing Code to pair another device")
end

-- Returns true, or false plus { code, message, retry_after?, attempts_remaining? }.
-- `input` is already normalized to 8 digits by the caller; `ip` is the device that sent it.
function Pairing.verify(input, ip)
    local now = os.time()
    local client = clientState(ip, now)
    local refused = admit(client, now)
    if refused then
        return false, refused
    end
    if not constantTimeEqual(input, state.code) then
        client.failed = client.failed + 1
        state.codeFailures = state.codeFailures + 1
        return false, wrongCode(client, ip, now)
    end
    used()
    return true
end

-- A CPace attempt (ADR-039) starts before the code can be checked: the device proves it knew the
-- code only at its end. So it counts as a wrong code from the start, and a success takes that back
-- (a success clears all counts): the limits stay those of Pairing.verify, and attempts that are
-- started and never finished run into them too. Returns the attempt { code, ip, generation }, or
-- nil plus a failure as Pairing.verify's.
function Pairing.begin(ip)
    local now = os.time()
    local client = clientState(ip, now)
    local refused = admit(client, now)
    if refused then
        return nil, refused
    end
    if state.codeFailures >= MAX_CODE_FAILURES then
        return nil, closeAfterFailures()
    end
    if client.failed >= MAX_FAILED_ATTEMPTS then
        return nil, lockDevice(client, ip, now)
    end
    client.failed = client.failed + 1
    state.codeFailures = state.codeFailures + 1
    return { code = state.code, ip = ip, generation = state.generation }
end

-- The end of an attempt: `matched` says whether the device proved it knew the code. Returns true
-- (the code is used), or false plus a failure as Pairing.verify's, or PAIRING_CODE_EXPIRED when a
-- new code was made meanwhile.
function Pairing.conclude(attempt, matched)
    local now = os.time()
    if attempt.generation ~= state.generation or not Pairing.isActive(now) then
        if Pairing.isActive(now) then
            return false, {
                code = "PAIRING_CODE_EXPIRED",
                message = "A new pairing code was made meanwhile. Pair again with the new code.",
            }
        end
        return false, notActive()
    end
    if not matched then
        return false, wrongCode(clientState(attempt.ip, now), attempt.ip, now)
    end
    used()
    return true
end

function Pairing.status()
    return {
        active = Pairing.isActive(),
        pairing_count = state.pairingCount,
        code_expires_at = state.codeExpiresAt,
        code_failures = state.codeFailures,
    }
end

return Pairing
