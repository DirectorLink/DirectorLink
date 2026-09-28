-- The end-to-end lock (docs/ACCOUNTS.md): every remote request and answer is sealed with a key that
-- only the app and this controller hold, so the relay can pass it on but not read or change it.
-- AES-256-CBC, then an HMAC-SHA256 over the ciphertext (encrypt-then-MAC); both keys are derived
-- from the device's lock key, which is derived from its API key (or from an invitation's secret).
-- Everything goes through C4:HMAC and C4:Encrypt in hex, so Director's base64 line breaks never
-- matter; tests/vectors/lock.json is shared with the app and the cloud tests.

local Base64 = require("src.core.base64")
local Random = require("src.core.random")

local Lock = {}

Lock.WINDOW_SECONDS = 120 -- a request's ts may differ this much from the controller's clock
Lock.REMEMBER_SECONDS = 300 -- request ids are remembered this long, so none can be replayed

local DEVICE_LABEL = "DirectorLink e2e v1"
local INVITATION_LABEL = "DirectorLink invite v1"
local PAIRING_LABEL = "DirectorLink pair v1"

local function hmac(key, keyEncoding, data)
    local mac, err = C4:HMAC("SHA256", key, data, { key_encoding = keyEncoding, data_encoding = "NONE", return_encoding = "HEX" })
    if type(mac) ~= "string" or #mac ~= 64 then
        error("HMAC-SHA256 failed: " .. tostring(err), 0)
    end
    return mac:lower()
end

-- A device's lock key (hex) from its API key.
function Lock.deviceKey(apiKey)
    return hmac(apiKey, "NONE", DEVICE_LABEL)
end

-- An invitation's lock key (hex) from its secret.
function Lock.invitationKey(secret)
    return hmac(secret, "NONE", INVITATION_LABEL)
end

-- The lock key (hex) that seals a pairing answer: from the X25519 shared secret (hex), bound to
-- the pairing code and both public keys (base64), so the answer opens only for that exchange.
function Lock.pairingKey(sharedHex, code, appPublic, driverPublic)
    return hmac(sharedHex, "HEX", PAIRING_LABEL .. "|" .. code .. "|" .. appPublic .. "|" .. driverPublic)
end

local function subkeys(lockKey)
    return hmac(lockKey, "HEX", "enc"), hmac(lockKey, "HEX", "mac")
end

local function macInput(home, key, dir, iv, ct)
    return "v1|" .. home .. "|" .. key .. "|" .. dir .. "|" .. iv .. "|" .. ct
end

local function sameText(left, right)
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

function Lock.randomIv()
    return Random.hex(32)
end

-- Seals a plaintext for `home` and `key` (a key id or an invitation id). dir: "req" or "res".
function Lock.seal(lockKey, home, key, dir, plaintext, ivHex)
    local encKey, macKey = subkeys(lockKey)
    ivHex = ivHex or Lock.randomIv()
    local ct, err = C4:Encrypt("AES-256-CBC", encKey, ivHex, plaintext, {
        key_encoding = "HEX",
        iv_encoding = "HEX",
        data_encoding = "NONE",
        return_encoding = "BASE64",
        padding = true,
    })
    if type(ct) ~= "string" then
        error("AES-256-CBC failed: " .. tostring(err), 0)
    end
    ct = ct:gsub("%s+", "")
    local iv = Base64.encode(Base64.fromHex(ivHex))
    local mac = Base64.encode(Base64.fromHex(hmac(macKey, "HEX", macInput(home, key, dir, iv, ct))))
    return { v = 1, home = home, key = key, iv = iv, ct = ct, mac = mac }
end

-- Opens an envelope sealed in direction `dir`. Returns the plaintext, or nil and BAD_ENVELOPE,
-- BAD_MAC or BAD_CIPHERTEXT. Nothing is decrypted before the MAC is right.
function Lock.open(lockKey, envelope, dir)
    if type(envelope) ~= "table" or envelope.v ~= 1 then
        return nil, "BAD_ENVELOPE"
    end
    for _, field in ipairs({ "home", "key", "iv", "ct", "mac" }) do
        if type(envelope[field]) ~= "string" or envelope[field] == "" then
            return nil, "BAD_ENVELOPE"
        end
    end
    local iv, mac, ct = Base64.decode(envelope.iv), Base64.decode(envelope.mac), Base64.decode(envelope.ct)
    if not iv or #iv ~= 16 or not mac or #mac ~= 32 or not ct or #ct == 0 or #ct % 16 ~= 0 then
        return nil, "BAD_ENVELOPE"
    end
    local encKey, macKey = subkeys(lockKey)
    local expected = hmac(macKey, "HEX", macInput(envelope.home, envelope.key, dir, envelope.iv, envelope.ct))
    if not sameText(expected, Base64.toHex(mac)) then
        return nil, "BAD_MAC"
    end
    local plaintext = C4:Decrypt("AES-256-CBC", encKey, Base64.toHex(iv), Base64.toHex(ct), {
        key_encoding = "HEX",
        iv_encoding = "HEX",
        data_encoding = "HEX",
        return_encoding = "NONE",
        padding = true,
    })
    if type(plaintext) ~= "string" then
        return nil, "BAD_CIPHERTEXT"
    end
    return plaintext
end

-- tests/vectors/lock.json, "request": computed with Node's crypto.
local VECTOR = {
    api_key = "ak_0123456789abcdef0123456789abcdef0123456789abcdef",
    lock_key = "97293ed4b9cfe6157e256417c3ee23af62127b00759ac19a7f89030aa5c9946e",
    home = "00112233445566778899aabbccddeeff",
    key = "4fde46cc",
    iv = "000102030405060708090a0b0c0d0e0f",
    plaintext = '{"id":"a1b2c3d4e5f60718","ts":1790540000,"method":"GET","path":"/v1/system","body":null}',
    ct = "SByEGzNrpOCRxcwpm3wqpt4iOuOHlGW7IzLz+cTl2VJ2SH3g7i/EIm8qRz7zdYX3LGHuv1B/33yuS5+WnfVO5NDmxvvgRiL15xOGgZn79PB34KAPGyuYKkc2rYZN+WQc",
    mac = "VWnkIqYWu+ZbmQdzmJrTnYzdOlf88pgFB5wdOj4+4XM=",
}

-- Checks this controller's C4:HMAC and C4:Encrypt against the shared vector. Returns true, or false
-- and the step that differed. Remote access uses the lock only when this passes.
function Lock.selfTest()
    local ok, failed = pcall(function()
        if Lock.deviceKey(VECTOR.api_key) ~= VECTOR.lock_key then
            return "lock key"
        end
        local sealed = Lock.seal(VECTOR.lock_key, VECTOR.home, VECTOR.key, "req", VECTOR.plaintext, VECTOR.iv)
        if sealed.ct ~= VECTOR.ct then
            return "ciphertext"
        end
        if sealed.mac ~= VECTOR.mac then
            return "mac"
        end
        if Lock.open(VECTOR.lock_key, sealed, "req") ~= VECTOR.plaintext then
            return "decryption"
        end
        local tampered = { v = 1, home = sealed.home, key = sealed.key, iv = sealed.iv, ct = sealed.ct, mac = VECTOR.mac:gsub("^V", "W") }
        if Lock.open(VECTOR.lock_key, tampered, "req") ~= nil then
            return "tamper check"
        end
        return nil
    end)
    if not ok then
        return false, tostring(failed)
    end
    if failed then
        return false, failed
    end
    return true
end

return Lock
