-- The end-to-end lock (src/cloud/lock.lua) against tests/vectors/lock.json, which Node's crypto
-- computed; the app and the cloud tests check the same vectors.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")

local tests = {}

local function vectors()
    local file = assert(io.open("tests/vectors/lock.json", "rb"))
    local text = file:read("*a")
    file:close()
    return Json.decode(text)
end

local function lock()
    Mock.install()
    package.loaded["src.cloud.lock"] = nil
    return require("src.cloud.lock")
end

local function copy(envelope, changes)
    local result = {}
    for name, value in pairs(envelope) do
        result[name] = value
    end
    for name, value in pairs(changes or {}) do
        result[name] = value
    end
    return result
end

function tests.keys_are_derived_as_the_vectors_say()
    local Lock, v = lock(), vectors()
    T.eq(Lock.deviceKey(v.device.api_key), v.device.lock_key_hex)
    T.eq(Lock.invitationKey(v.invitation.secret), v.invitation.lock_key_hex)
end

function tests.sealing_matches_the_vectors_byte_for_byte()
    local Lock, v = lock(), vectors()
    for _, name in ipairs({ "request", "answer" }) do
        local case = v[name]
        local sealed = Lock.seal(v.device.lock_key_hex, case.envelope.home, case.envelope.key, case.dir, case.plaintext, case.iv_hex)
        T.eq(sealed.ct, case.envelope.ct, name .. " ciphertext (the fake Director breaks base64 into lines; they are removed)")
        T.eq(sealed.iv, case.envelope.iv, name .. " iv")
        T.eq(sealed.mac, case.envelope.mac, name .. " mac")
        T.eq(sealed.v, 1)
    end
    local join = v.join
    local sealed = Lock.seal(v.invitation.lock_key_hex, join.envelope.home, join.envelope.key, join.dir, join.plaintext, join.iv_hex)
    T.eq(sealed.mac, join.envelope.mac, "invitation envelope")
end

function tests.envelopes_from_node_open()
    local Lock, v = lock(), vectors()
    T.eq(Lock.open(v.device.lock_key_hex, v.request.envelope, "req"), v.request.plaintext)
    T.eq(Lock.open(v.device.lock_key_hex, v.answer.envelope, "res"), v.answer.plaintext)
    T.eq(Lock.open(v.invitation.lock_key_hex, v.join.envelope, "req"), v.join.plaintext)
end

function tests.anything_changed_is_refused_before_decrypting()
    local Lock, v = lock(), vectors()
    local key, envelope = v.device.lock_key_hex, v.request.envelope
    local mock = Mock.install()
    mock.cryptCalls = 0
    local ct = envelope.ct
    local flipped = (ct:sub(1, 1) == "A" and "B" or "A") .. ct:sub(2)
    local cases = {
        { copy(envelope, { ct = flipped }), "req", "BAD_MAC", "a changed ciphertext" },
        { copy(envelope, { key = "00000000" }), "req", "BAD_MAC", "another key id" },
        { copy(envelope, { home = "ffeeddccbbaa99887766554433221100" }), "req", "BAD_MAC", "another home" },
        { envelope, "res", "BAD_MAC", "a request presented as an answer" },
        { copy(envelope, { iv = "AAECAwQFBgcICQoLDA0ODg==" }), "req", "BAD_MAC", "another iv" },
        { copy(envelope, { mac = "not base64!" }), "req", "BAD_ENVELOPE", "a malformed mac" },
        { copy(envelope, { v = 2 }), "req", "BAD_ENVELOPE", "another version" },
        { copy(envelope, { ct = "AAAA" }), "req", "BAD_ENVELOPE", "a ciphertext that is not whole blocks" },
        { "not a table", "req", "BAD_ENVELOPE", "not an envelope" },
    }
    for _, case in ipairs(cases) do
        local plaintext, code = Lock.open(key, case[1], case[2])
        T.eq(plaintext, nil, case[4])
        T.eq(code, case[3], case[4])
    end
    T.eq(mock.cryptCalls, 0, "nothing was decrypted")
    local _, code = Lock.open(v.invitation.lock_key_hex, envelope, "req")
    T.eq(code, "BAD_MAC", "another device's key")
end

function tests.a_fresh_seal_opens_and_uses_a_new_iv()
    local Lock, v = lock(), vectors()
    local one = Lock.seal(v.device.lock_key_hex, "00112233445566778899aabbccddeeff", "4fde46cc", "res", "hello")
    local two = Lock.seal(v.device.lock_key_hex, "00112233445566778899aabbccddeeff", "4fde46cc", "res", "hello")
    T.truthy(one.iv ~= two.iv, "a random iv each time")
    T.eq(Lock.open(v.device.lock_key_hex, one, "res"), "hello")
    T.truthy(not one.ct:find("%s"), "no line breaks in the ciphertext")
end

function tests.the_self_test_passes_on_a_correct_director()
    local Lock = lock()
    T.eq(Lock.selfTest(), true)
    -- A Director whose HMAC differs is caught.
    local hmac = C4.HMAC
    function C4:HMAC(digest, key, data, options)
        local value = hmac(self, digest, key, data, options)
        return value and (value:sub(1, -2) .. (value:sub(-1) == "0" and "1" or "0"))
    end
    local ok, step = Lock.selfTest()
    T.eq(ok, false)
    T.eq(step, "lock key")
end

function tests.base64_is_exact()
    for _, text in ipairs({ "", "f", "fo", "foo", "foob", "fooba", "foobar", "\0\255\128" }) do
        T.eq(Base64.decode(Base64.encode(text)), text)
    end
    T.eq(Base64.encode("foobar"), "Zm9vYmFy")
    T.eq(Base64.encode("fo"), "Zm8=")
    T.eq(Base64.decode("Zm9v\nYmFy"), "foobar", "line breaks are ignored")
    for _, bad in ipairs({ "Zm9", "Zm=v", "Zm8=Zm8=", "Zm*v", 5 }) do
        T.eq(Base64.decode(bad), nil, tostring(bad))
    end
    T.eq(Base64.toHex("\1\171"), "01ab")
    T.eq(Base64.fromHex("01AB"), "\1\171")
    T.eq(Base64.fromHex("0g"), nil)
end

return tests
