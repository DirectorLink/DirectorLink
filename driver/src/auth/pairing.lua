local Pairing = {}

-- Keep the existing alpha token key so upgrades preserve the current owner
-- credential instead of invalidating already-paired browsers.
local OWNER_TOKEN_KEY = "c4bridge_api_token"
local PAIRING_COUNT_KEY = "c4bridge_pairing_count"

local CODE_TTL_SECONDS = 15 * 60
local FAILED_WINDOW_SECONDS = 60
local MAX_FAILED_ATTEMPTS = 5
local LOCK_SECONDS = 60

local state = {
    ownerToken = nil,
    code = nil,
    codeExpiresAt = 0,
    pairingCount = 0,
    failedAttempts = 0,
    failedWindowStartedAt = 0,
    lockedUntil = 0,
    updateProperty = nil,
    log = nil,
}

local function log(message)
    if state.log then
        state.log("[PAIRING] " .. tostring(message))
    end
end

local function persistGet(key, encrypted)
    local ok, value = pcall(function()
        return C4:PersistGetValue(key, encrypted == true)
    end)
    if ok then
        return value
    end
    return nil
end

local function persistSet(key, value, encrypted)
    local ok, err = pcall(function()
        C4:PersistSetValue(key, tostring(value or ""), encrypted == true)
    end)
    if not ok then
        log("PersistSetValue failed for " .. tostring(key) .. ": " .. tostring(err))
        return false
    end
    return true
end

local function generateOwnerToken()
    local token, err = C4:UUID("RANDOM")
    if not token then
        return nil, tostring(err or "UUID generation failed")
    end
    return tostring(token)
end

local function generatePairingCode()
    local randomUuid, err = C4:UUID("RANDOM")
    if not randomUuid then
        return nil, tostring(err or "UUID generation failed")
    end

    local compact = tostring(randomUuid):gsub("[^0-9a-fA-F]", "")
    local prefix = compact:sub(1, 8)
    local numeric = tonumber(prefix, 16)
    if not numeric then
        return nil, "Unable to derive pairing code"
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

local function pairingStatus(now)
    now = now or os.time()

    if state.lockedUntil > now then
        return "Locked for " .. tostring(state.lockedUntil - now) .. "s"
    end

    if not state.code then
        return "Unavailable"
    end

    if state.codeExpiresAt <= now then
        return "Expired - enter code once to rotate"
    end

    return "Ready - " .. tostring(state.pairingCount) .. " paired browser(s)"
end

local function publishProperties()
    if not state.updateProperty then
        return
    end

    state.updateProperty("Pairing Code", state.code or "Unavailable")
    state.updateProperty("Pairing Status", pairingStatus())
    state.updateProperty("API Token", "Hidden - use Pairing Code")
end

local function rotateCode()
    local code, err = generatePairingCode()
    if not code then
        state.code = nil
        state.codeExpiresAt = 0
        publishProperties()
        return false, err
    end

    state.code = code
    state.codeExpiresAt = os.time() + CODE_TTL_SECONDS
    publishProperties()
    return true
end

local function resetFailureWindow(now)
    state.failedAttempts = 0
    state.failedWindowStartedAt = now
end

function Pairing.initialize(options)
    options = options or {}
    state.updateProperty = options.updateProperty
    state.log = options.log

    local existing = persistGet(OWNER_TOKEN_KEY, true)
    if type(existing) == "string" and existing ~= "" then
        state.ownerToken = existing
    else
        local generated, err = generateOwnerToken()
        if not generated then
            return false, "Unable to generate owner credential: " .. tostring(err)
        end

        if not persistSet(OWNER_TOKEN_KEY, generated, true) then
            return false, "Unable to persist owner credential"
        end
        state.ownerToken = generated
    end

    state.pairingCount = tonumber(persistGet(PAIRING_COUNT_KEY, false)) or 0
    resetFailureWindow(os.time())
    state.lockedUntil = 0

    local rotated, rotateError = rotateCode()
    if not rotated then
        return false, "Unable to generate pairing code: " .. tostring(rotateError)
    end

    log("owner credential ready; pairing code generated")
    return true
end

function Pairing.ownerToken()
    return state.ownerToken
end

function Pairing.status()
    return {
        pairing_count = state.pairingCount,
        code_expires_at = state.codeExpiresAt,
        locked_until = state.lockedUntil,
    }
end

function Pairing.verify(code)
    local now = os.time()

    if not state.ownerToken or not state.code then
        return false, {
            code = "PAIRING_UNAVAILABLE",
            message = "Pairing is unavailable",
        }
    end

    if state.lockedUntil > now then
        publishProperties()
        return false, {
            code = "PAIRING_RATE_LIMITED",
            message = "Too many failed pairing attempts. Try again shortly.",
            retry_after = state.lockedUntil - now,
        }
    end

    if state.codeExpiresAt <= now then
        local rotated, rotateError = rotateCode()
        if not rotated then
            return false, {
                code = "PAIRING_UNAVAILABLE",
                message = "Pairing code expired and could not be rotated: " .. tostring(rotateError),
            }
        end

        log("expired pairing code rotated")
        return false, {
            code = "PAIRING_CODE_EXPIRED",
            message = "Pairing code expired. Composer now shows a new code.",
        }
    end

    if now - state.failedWindowStartedAt >= FAILED_WINDOW_SECONDS then
        resetFailureWindow(now)
    end

    if not constantTimeEqual(code, state.code) then
        state.failedAttempts = state.failedAttempts + 1

        if state.failedAttempts >= MAX_FAILED_ATTEMPTS then
            state.lockedUntil = now + LOCK_SECONDS
            resetFailureWindow(now)
            publishProperties()
            log("pairing temporarily locked after repeated failures")
            return false, {
                code = "PAIRING_RATE_LIMITED",
                message = "Too many failed pairing attempts. Try again in 60 seconds.",
                retry_after = LOCK_SECONDS,
            }
        end

        return false, {
            code = "PAIRING_CODE_INVALID",
            message = "Pairing code is incorrect",
            attempts_remaining = MAX_FAILED_ATTEMPTS - state.failedAttempts,
        }
    end

    state.pairingCount = state.pairingCount + 1
    persistSet(PAIRING_COUNT_KEY, state.pairingCount, false)

    local token = state.ownerToken

    resetFailureWindow(now)
    state.lockedUntil = 0

    local rotated, rotateError = rotateCode()
    if not rotated then
        log("pairing succeeded but next code rotation failed: " .. tostring(rotateError))
    end

    publishProperties()
    log("pairing succeeded; owner credential issued and pairing code rotated")

    return true, {
        token = token,
        scheme = "Bearer",
        pairing_count = state.pairingCount,
    }
end

return Pairing
