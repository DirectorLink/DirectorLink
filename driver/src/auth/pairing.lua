-- Pairing: an 8-digit code shown in Composer that can be exchanged once for an API key.
-- Temporary bootstrap until approval from the Control4 app replaces it (planned for 0.3.0).

local Pairing = {}

local PAIRING_COUNT_KEY = "c4bridge_pairing_count"

local CODE_TTL_SECONDS = 15 * 60
local FAILED_WINDOW_SECONDS = 60
local MAX_FAILED_ATTEMPTS = 5
local LOCK_SECONDS = 60

local state = {
    code = nil,
    codeExpiresAt = 0,
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

function Pairing.statusText(now)
    now = now or os.time()
    if state.lockedUntil > now then
        return "Locked for " .. tostring(state.lockedUntil - now) .. "s after failed attempts"
    end
    if not state.code then
        return "Unavailable"
    end
    if state.codeExpiresAt <= now then
        return "Expired - use the New Pairing Code action"
    end
    return "Ready until " .. os.date("%H:%M", state.codeExpiresAt)
end

local function publish()
    if state.onChange then
        state.onChange(state.code or "Unavailable", Pairing.statusText())
    end
end

local rotate

local function scheduleExpiry()
    pcall(function()
        if state.expiryTimer then
            state.expiryTimer:Cancel()
        end
        state.expiryTimer = C4:SetTimer(CODE_TTL_SECONDS * 1000, function()
            state.expiryTimer = nil
            rotate()
        end, false)
    end)
end

rotate = function()
    local code, err = generateCode()
    if not code then
        state.code = nil
        state.codeExpiresAt = 0
        publish()
        return false, err
    end
    state.code = code
    state.codeExpiresAt = os.time() + CODE_TTL_SECONDS
    scheduleExpiry()
    publish()
    return true
end

local function resetFailures(now)
    state.failedAttempts = 0
    state.failedWindowStartedAt = now
end

-- options: { onChange = function(code, status), log = Log }
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

    return rotate()
end

function Pairing.rotate()
    local ok, err = rotate()
    if ok then
        log("new pairing code generated")
    end
    return ok, err
end

-- Returns true, or false plus { code, message, retry_after?, attempts_remaining? }.
function Pairing.verify(code)
    local now = os.time()

    if not state.code then
        return false, { code = "PAIRING_UNAVAILABLE", message = "Pairing is unavailable" }
    end

    if state.lockedUntil > now then
        publish()
        return false, {
            code = "PAIRING_RATE_LIMITED",
            message = "Too many failed pairing attempts. Try again shortly.",
            retry_after = state.lockedUntil - now,
        }
    end

    if state.codeExpiresAt <= now then
        rotate()
        return false, {
            code = "PAIRING_CODE_EXPIRED",
            message = "The pairing code expired. Composer now shows a new code.",
        }
    end

    if now - state.failedWindowStartedAt >= FAILED_WINDOW_SECONDS then
        resetFailures(now)
    end

    if not constantTimeEqual(code, state.code) then
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
    rotate()
    return true
end

function Pairing.status()
    return {
        pairing_count = state.pairingCount,
        code_expires_at = state.codeExpiresAt,
        locked_until = state.lockedUntil,
    }
end

return Pairing
