-- Security of the home network (docs/ACCOUNTS.md): pairing with a key exchange, so the new key is
-- never sent in the clear; sealed requests at home, so the key never crosses the network again;
-- and random values that do not depend on Director's UUIDs alone.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local function hex(data)
    return (data:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

local function modules()
    return require("src.core.base64"), require("src.cloud.lock"), require("src.core.x25519")
end

-- Pairs like the app: with the public half of a key exchange. Returns the opened answer.
local function sealedPair(mock)
    local Base64, Lock, X25519 = modules()
    ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    local code = mock.properties["Pairing Code"]:gsub(" ", "")
    local private = string.rep(string.char(7), 31) .. string.char(42)
    local public = Base64.encode(X25519.publicKey(private))
    local response = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code, name = "Chrome", exchange = { public_key = public } } })
    T.eq(response.status, 201, response.body)
    local driverPublic = response.json.exchange.public_key
    local shared = X25519.shared(private, Base64.decode(driverPublic))
    local lockKey = Lock.pairingKey(hex(shared), code, public, driverPublic)
    local plaintext = Lock.open(lockKey, response.json.sealed, "res")
    T.truthy(plaintext, "the answer opens with the exchanged key")
    return Json.decode(plaintext), response
end

function tests.pairing_with_a_key_exchange_never_sends_the_key_in_the_clear()
    local mock = Mock.startDriver()
    local created, response = sealedPair(mock)
    T.truthy(created.key and created.key:match("^ak_%x+$"), "a key")
    T.notContains(response.body, created.key, "the key is not readable on the network")
    T.eq(T.http(mock, "GET", "/v1/system", { key = created.key }).status, 200, "and it works")
    T.eq(created.role, "admin")
end

function tests.a_bad_exchange_key_is_refused_and_no_key_is_left_behind()
    local mock = Mock.startDriver()
    local code = mock.properties["Pairing Code"]
    local short = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code, exchange = { public_key = "AAAA" } } })
    T.eq(short.status, 400)
    local zero = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code, exchange = { public_key = string.rep("A", 43) .. "=" } } })
    T.eq(zero.status, 400, "a public key that gives no shared secret")
    T.eq(mock.properties["API Keys"], "0", "the key made for it was taken back")
end

-- A sealed request at home: POST /v1/sealed with the device's lock key, no Authorization header.
local function sealed(mock, key, keyId, request)
    local _, Lock = modules()
    local info = T.http(mock, "GET", "/v1/sealed").json
    local lock = Lock.deviceKey(key)
    request.id = request.id or ("r" .. tostring(math.random(1, 1e9)))
    request.ts = request.ts or info.time
    local envelope = Lock.seal(lock, info.home_id, keyId, "req", Json.encode(request))
    local response = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    if response.status ~= 200 then
        return nil, response, envelope
    end
    return Json.decode(Lock.open(lock, response.json.envelope, "res")), response, envelope
end

function tests.sealed_requests_at_home_run_as_their_key_and_answer_sealed()
    local mock = Mock.startDriver()
    local created = sealedPair(mock)
    local info = T.http(mock, "GET", "/v1/sealed").json
    T.truthy(info.home_id:match("^%x+$") and #info.home_id == 32)
    T.truthy(type(info.time) == "number")
    local answer, response = sealed(mock, created.key, created.id, { method = "GET", path = "/v1/lights" })
    T.eq(answer.status, 200)
    T.truthy(Json.decode(answer.body).items[1], "the lights, inside the sealed answer")
    T.notContains(response.body, "Kitchen Island", "nothing readable on the network")

    local command = sealed(mock, created.key, created.id, { method = "PATCH", path = "/v1/lights/20", body = { on = true } })
    T.eq(command.status, 202)
    local _, first, envelope = sealed(mock, created.key, created.id, { method = "GET", path = "/v1/system", id = "once" })
    T.eq(first.status, 200)
    local again = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    T.eq(again.json.code, "REPLAYED", "an envelope works once")
    local _, stale = sealed(mock, created.key, created.id, { method = "GET", path = "/v1/system", ts = os.time() - 600 })
    T.eq(stale.json.code, "STALE")
    T.truthy(type(stale.json.time) == "number", "the controller's time, to set the clock right")
    local _, unknown = sealed(mock, created.key, "deadbeef", { method = "GET", path = "/v1/system" })
    T.eq(unknown.status, 401)
    T.eq(unknown.json.code, "UNKNOWN_KEY")
    local pair = sealed(mock, created.key, created.id, { method = "POST", path = "/v1/auth/pair", body = { pairing_code = "12345678" } })
    T.eq(pair.status, 403, "pairing is never sealed")
end

function tests.a_viewer_key_sealed_at_home_keeps_its_role()
    local mock = Mock.startDriver()
    local admin = sealedPair(mock)
    local viewer = T.http(mock, "POST", "/v1/api-keys", { key = admin.key, body = { name = "Guest", role = "viewer" } }).json
    local answer = sealed(mock, viewer.key, viewer.id, { method = "PATCH", path = "/v1/lights/20", body = { on = true } })
    T.eq(answer.status, 403)
end

function tests.secrets_differ_even_if_directors_uuids_do_not()
    local mock = Mock.startDriver()
    function C4:UUID()
        return "00000000-0000-4000-8000-000000000000"
    end
    local Random = require("src.core.random")
    local seen = {}
    for _ = 1, 50 do
        local value = Random.hex(64)
        T.truthy(not seen[value], "no value repeats")
        seen[value] = true
    end
    T.truthy(mock.persist.directorlink_entropy, "the pool is kept across restarts")
end

return tests
