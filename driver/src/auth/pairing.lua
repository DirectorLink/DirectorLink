-- Pairing: an 8-digit code, created on demand with the Composer action "New Pairing Code" (and
-- automatically while the driver has no API keys, e.g. right after it is added). A code is valid
-- for 15 minutes, works once, and gives an admin key: whoever can run Composer actions controls the
-- project anyway. Composer shows it as "1234 5678"; clients may send it with or without the space.

local Pairing = {}

local PAIRING_COUNT_KEY = "directorlink_pairing_count"

Pairing.CODE_TTL_SECONDS = 15 * 60
local FAILED_WINDOW_SECONDS = 60
local MAX_FAILED_ATTEMPTS = 5
local LOCK_SECONDS = 60

local OFF_TEXT = "Off - run New Pairing Code to pair a device"

local state = {
    code = nil,
    codeExpiresAt = 0,
    closedText = OFF_TEXT,
    pairingCount = 0,
    failedAttempts = 0,
    failedWindowStartedAt = 0,
    lockedUntil = 0,
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
    local uuid, err = C4:UUID("RANDOM")
    if not uuid then
        return nil, tostring(err or "UUID generation failed")
    end
    local numeric = tonumber(tostring(uuid):gsub("[^%x]", ""):sub(1, 8), 16)
    if not numeric then
        return nil, "Unable to derive a pairing code"
    end
    return string.format("%08d", numeric % 100000000)
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
    if state.lockedUntil > now then
        return "Locked for " .. tostring(state.lockedUntil - now) .. "s after failed attempts"
    end
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
    state.code = nil
    state.codeExpiresAt = 0
    state.closedText = text or OFF_TEXT
    publish()
end

local function resetFailures(now)
    state.failedAttempts = 0
    state.failedWindowStartedAt = now
end

-- Creates a new code, valid for CODE_TTL_SECONDS. Returns true, or false plus a reason.
function Pairing.open()
    local code, err = generateCode()
    if not code then
        close("Unavailable: " .. tostring(err))
        return false, err
    end
    cancelTimer()
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
    resetFailures(os.time())
    state.lockedUntil = 0

    if options.openNow then
        return Pairing.open()
    end
    close(OFF_TEXT)
    return true
end

-- Returns true, or false plus { code, message, retry_after?, attempts_remaining? }.
-- `input` is already normalized to 8 digits by the caller.
function Pairing.verify(input)
    local now = os.time()

    if state.lockedUntil > now then
        publish()
        return false, {
            code = "PAIRING_RATE_LIMITED",
            message = "Too many failed pairing attempts. Try again shortly.",
            retry_after = state.lockedUntil - now,
        }
    end

    if not Pairing.isActive(now) then
        if state.code then
            close("Expired - run New Pairing Code to pair a device")
        end
        return false, {
            code = "PAIRING_NOT_ACTIVE",
            message = "No pairing code is active. In Composer, run New Pairing Code on DirectorLink "
                .. "(or ask your installer); a code lasts 15 minutes and works once.",
        }
    end

    if now - state.failedWindowStartedAt >= FAILED_WINDOW_SECONDS then
        resetFailures(now)
    end

    if not constantTimeEqual(input, state.code) then
        state.failedAttempts = state.failedAttempts + 1
        if state.failedAttempts >= MAX_FAILED_ATTEMPTS then
            state.lockedUntil = now + LOCK_SECONDS
            resetFailures(now)
            publish()
            if state.log then
                state.log.warn("auth", "pairing locked after repeated failures", { seconds = LOCK_SECONDS })
            end
            return false, {
                code = "PAIRING_RATE_LIMITED",
                message = "Too many failed pairing attempts. Try again in " .. LOCK_SECONDS .. " seconds.",
                retry_after = LOCK_SECONDS,
            }
        end
        return false, {
            code = "PAIRING_CODE_INVALID",
            message = "The pairing code is incorrect",
            attempts_remaining = MAX_FAILED_ATTEMPTS - state.failedAttempts,
        }
    end

    state.pairingCount = state.pairingCount + 1
    pcall(function()
        C4:PersistSetValue(PAIRING_COUNT_KEY, tostring(state.pairingCount), false)
    end)
    resetFailures(now)
    state.lockedUntil = 0
    close("Used at " .. os.date("%H:%M") .. " - run New Pairing Code to pair another device")
    return true
end

function Pairing.status()
    return {
        active = Pairing.isActive(),
        pairing_count = state.pairingCount,
        code_expires_at = state.codeExpiresAt,
        locked_until = state.lockedUntil,
    }
end

return Pairing
