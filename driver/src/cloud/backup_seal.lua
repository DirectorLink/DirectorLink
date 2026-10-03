-- Sealing an automatic backup (ADR-048, docs/BACKUP.md) to the backup password's public key, so
-- that only someone who types the password can open it: not DirectorLink's servers, which keep it,
-- and not this controller, which forgets its half of the key as soon as the backup is sealed.
--
-- The browser makes an X25519 key pair from the backup password (PBKDF2-SHA-256 with a random
-- salt) and gives the controller only the public key. For each backup the controller makes a key
-- pair used once (the ephemeral key), and the X25519 shared value of the two locks the backup as
-- lock.lua locks a sealed request: a lock key HMAC-SHA256(shared, label|epk|public key), its "enc"
-- and "mac" keys, AES-256-CBC, then an HMAC-SHA256 over everything that says how to open it
-- (encrypt-then-MAC). C4:HMAC and C4:Encrypt do the work in hex, as in lock.lua; the two scalar
-- multiplications are plain Lua (src/core/x25519.lua), a slice at a time (job.step), so that none
-- holds Director's Lua thread long. tests/vectors/cloud_backup.json is shared with the app.

local Base64 = require("src.core.base64")
local Random = require("src.core.random")
local X25519 = require("src.core.x25519")

local BackupSeal = {}

BackupSeal.FORMAT = "directorlink-cloud-backup"
BackupSeal.VERSION = 1
BackupSeal.CIPHER = "X25519-AES-256-CBC-HMAC-SHA256"
BackupSeal.KDF = "PBKDF2-SHA-256"
BackupSeal.LABEL = "DirectorLink cloud backup v1"
-- Ladder steps per slice: 255 make a scalar multiplication, about 29 ms on a PC and some 0.15 to
-- 0.3 s on a CORE-1; a quarter of that at a time. A seal takes 11 steps.
BackupSeal.STEPS = 64

local BASE = string.char(9) .. string.rep(string.char(0), 31)

local function hmac(key, keyEncoding, data)
    local mac, err = C4:HMAC("SHA256", key, data, { key_encoding = keyEncoding, data_encoding = "NONE", return_encoding = "HEX" })
    if type(mac) ~= "string" or #mac ~= 64 then
        error("HMAC-SHA256 failed: " .. tostring(err), 0)
    end
    return mac:lower()
end

-- Which backup password a public key (32 bytes) is: its first 8 bytes in hex, which the account
-- service lists with each backup (a backup made before the password was changed needs the old one).
function BackupSeal.keyId(publicKey)
    return Base64.toHex(publicKey:sub(1, 8)):lower()
end

-- The lock key (hex) and its two keys for the shared value (32 bytes), the ephemeral public key and
-- the backup password's (both base64).
function BackupSeal.keys(shared, epk, publicKey)
    local lock = hmac(Base64.toHex(shared), "HEX", BackupSeal.LABEL .. "|" .. epk .. "|" .. publicKey)
    return lock, hmac(lock, "HEX", "enc"), hmac(lock, "HEX", "mac")
end

local function macInput(sealed)
    return BackupSeal.LABEL .. "|" .. sealed.key_id .. "|" .. sealed.salt .. "|" .. tostring(sealed.iterations)
        .. "|" .. sealed.epk .. "|" .. sealed.iv .. "|" .. sealed.ct
end

-- Starts sealing `plaintext` (the backup's JSON) to `key` ({ public_key, salt (base64), iterations,
-- key_id }, as the app set it). options (tests): ephemeral (32 bytes), iv (hex). job.step() does
-- one slice and returns true once the backup is sealed; job.result() is then the sealed backup
-- (docs/BACKUP.md). A step that fails raises an error.
function BackupSeal.start(key, plaintext, options)
    options = options or {}
    local recipient = Base64.decode(key.public_key)
    assert(recipient and #recipient == 32, "the backup key is not an X25519 public key")
    local ephemeral = options.ephemeral or Random.bytes(32)
    local phase, ladder = "public", X25519.start(ephemeral, BASE)
    local epk, shared, sealed = nil, nil, nil
    local job = {}
    -- Each call does one of these: a slice of a scalar multiplication, the inversion that ends it
    -- (about as long as a slice), or the encryption (C4:HMAC and C4:Encrypt, native).
    function job.step()
        if phase == "public" or phase == "shared" then
            if ladder.step(BackupSeal.STEPS) then
                phase = phase .. " done"
            end
        elseif phase == "public done" then
            epk = ladder.result()
            phase, ladder = "shared", X25519.start(ephemeral, recipient)
        elseif phase == "shared done" then
            shared = ladder.result()
            ladder = nil
            if shared == string.rep(string.char(0), 32) then
                error("the backup key gives no shared secret", 0)
            end
            -- The ephemeral key is no longer needed: this controller cannot open the backup.
            ephemeral = nil
            phase = "lock"
        elseif phase == "lock" then
            local epkText = Base64.encode(epk)
            local _, encKey, macKey = BackupSeal.keys(shared, epkText, key.public_key)
            shared = nil
            local ivHex = options.iv or Random.hex(32)
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
            sealed = {
                format = BackupSeal.FORMAT,
                version = BackupSeal.VERSION,
                cipher = BackupSeal.CIPHER,
                kdf = BackupSeal.KDF,
                iterations = key.iterations,
                salt = key.salt,
                key_id = key.key_id,
                epk = epkText,
                iv = Base64.encode(Base64.fromHex(ivHex)),
                ct = (ct:gsub("%s+", "")),
            }
            sealed.mac = Base64.encode(Base64.fromHex(hmac(macKey, "HEX", macInput(sealed))))
            phase = "done"
        end
        return phase == "done"
    end
    function job.result()
        assert(phase == "done", "the backup is not sealed yet")
        return sealed
    end
    return job
end

-- The whole sealing at once (tests and the self-test).
function BackupSeal.seal(key, plaintext, options)
    local job = BackupSeal.start(key, plaintext, options)
    while not job.step() do
    end
    return job.result()
end

return BackupSeal
