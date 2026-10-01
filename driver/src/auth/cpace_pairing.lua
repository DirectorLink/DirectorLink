-- Pairing with CPace (ADR-039, docs/ACCOUNTS.md): the app proves it knows the pairing code without
-- sending it. Two requests to POST /v1/auth/pair (src/api/handlers/auth.lua):
--   1. { name, expires_in?, cpace = { nonce } }  ->  200 { cpace = { session, nonce, share } }
--      The controller is CPace's initiator A: its share Ya comes from a generator made from the
--      code, the channel (CI) and both nonces (sid).
--   2. { cpace = { session, share, confirm } }   ->  201 { cpace = { confirm }, sealed }
--      The app's share Yb and its tag Tb, which only a device that knew the code can make. Only
--      then is the key made. It comes back sealed with a key from the exchange, with the
--      controller's tag Ta: the app knows then that it spoke with this controller, and nobody in
--      between learned the code or the key.
-- CI = lv_cat("DirectorLink pair v2", name, expires_in) binds what the first request asked for;
-- sid = the app's nonce, then the controller's (16 bytes each); ADa = ADb = "". Each attempt is
-- one guess at the code (src/auth/pairing.lua counts it).

local Base64 = require("src.core.base64")
local Cpace = require("src.core.cpace")
local Random = require("src.core.random")
local X25519 = require("src.core.x25519")

local CpacePairing = {}

CpacePairing.LABEL = "DirectorLink pair v2"
CpacePairing.NONCE_BYTES = 16
-- The app answers within a second; an exchange left open longer is dropped.
CpacePairing.SESSION_SECONDS = 60
-- Open exchanges: one per device, and at most this many in all (the oldest goes).
local MAX_SESSIONS = 8
local AD = ""

local state = { sessions = {}, count = 0 }

-- CI: the label, the key's name as the app sent it ("" without one) and expires_in ("" without).
function CpacePairing.channel(name, expiresIn)
    return Cpace.lvCat(CpacePairing.LABEL, name or "", expiresIn and string.format("%d", expiresIn) or "")
end

local function remove(id)
    if state.sessions[id] then
        state.sessions[id] = nil
        state.count = state.count - 1
    end
end

local function prune(now, ip)
    local oldestId, oldestAt
    for id, session in pairs(state.sessions) do
        if session.expiresAt <= now or session.ip == ip then
            remove(id)
        elseif not oldestAt or session.createdAt < oldestAt then
            oldestId, oldestAt = id, session.createdAt
        end
    end
    if state.count >= MAX_SESSIONS and oldestId then
        remove(oldestId)
    end
end

-- Opens an exchange for `attempt` (Pairing.begin) of device `ip`. `appNonce` is 16 bytes; `name`
-- and `expiresIn` are what the app asked for. Returns the answer's cpace object.
function CpacePairing.open(attempt, ip, appNonce, name, expiresIn)
    local now = os.time()
    prune(now, ip)
    local nonce = Random.bytes(CpacePairing.NONCE_BYTES)
    local scalar = Random.bytes(32)
    local sid = appNonce .. nonce
    local share = Cpace.share(scalar, Cpace.generator(attempt.code, CpacePairing.channel(name, expiresIn), sid))
    local id = Random.hex(24)
    state.sessions[id] = {
        attempt = attempt,
        ip = ip,
        scalar = scalar,
        share = share,
        sid = sid,
        name = name,
        expiresIn = expiresIn,
        createdAt = now,
        expiresAt = now + CpacePairing.SESSION_SECONDS,
    }
    state.count = state.count + 1
    return { session = id, nonce = Base64.encode(nonce), share = Base64.encode(share) }
end

-- The open exchange `id` of device `ip`, taken out (each works once); nil when there is none.
function CpacePairing.take(id, ip)
    local session = type(id) == "string" and state.sessions[id] or nil
    if not session or session.ip ~= ip then
        return nil
    end
    remove(id)
    if session.expiresAt <= os.time() then
        return nil
    end
    return session
end

local function sameBytes(left, right)
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

-- The app's share and tag (bytes). Returns the intermediate session key and the controller's tag,
-- or nil plus "INVALID_SHARE" (a point of low order: the exchange stops) or "WRONG_TAG" (the app
-- did not know the code).
function CpacePairing.confirm(session, appShare, appTag)
    if #appShare ~= 32 or X25519.smallOrder(appShare) then
        return nil, "INVALID_SHARE"
    end
    local k = Cpace.secret(session.scalar, appShare)
    if not k then
        return nil, "INVALID_SHARE"
    end
    local isk = Cpace.isk(session.sid, k, session.share, AD, appShare, AD)
    local macKey = Cpace.macKey(session.sid, isk)
    if not sameBytes(Cpace.tag(macKey, appShare, AD), appTag) then
        return nil, "WRONG_TAG"
    end
    return isk, Cpace.tag(macKey, session.share, AD)
end

-- Open exchanges (tests).
function CpacePairing.openCount()
    return state.count
end

function CpacePairing.reset()
    state.sessions, state.count = {}, 0
end

return CpacePairing
