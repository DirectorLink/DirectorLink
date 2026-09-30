-- Pairing with CPace (ADR-039, src/auth/cpace_pairing.lua) through POST /v1/auth/pair: the code
-- never crosses the network, the key is made only after the app proved it knew the code, and each
-- attempt counts against the limits of src/auth/pairing.lua. The app's side is played here with
-- the driver's own CPace (tests/app/cpace.test.mjs checks that the app computes the same).

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local function modules()
    return require("src.core.base64"), require("src.core.cpace"), require("src.auth.cpace_pairing"), require("src.cloud.lock")
end

local function codeOf(mock)
    return (mock.properties["Pairing Code"]:gsub(" ", ""))
end

-- The app's side. options: code, name, expiresIn, ip, nonce, scalar, channelName (the name the
-- app binds, when someone changed the one sent), share and confirm (sent instead of the right ones).
-- Returns the second answer (or the first, when it failed) and what the app computed.
local function pair(mock, options)
    local Base64, Cpace, CpacePairing = modules()
    local nonce = options.nonce or string.rep(string.char(1), 16)
    local start = T.http(mock, "POST", "/v1/auth/pair", {
        ip = options.ip,
        body = { name = options.name, expires_in = options.expiresIn, cpace = { nonce = Base64.encode(nonce) } },
    })
    if start.status ~= 200 then
        return start, { start = start }
    end
    local Ya = Base64.decode(start.json.cpace.share)
    local sid = nonce .. Base64.decode(start.json.cpace.nonce)
    local channelName = options.channelName
    if channelName == nil then
        channelName = options.name
    end
    local g = Cpace.generator(options.code or codeOf(mock), CpacePairing.channel(channelName, options.expiresIn), sid)
    local yb = options.scalar or string.rep(string.char(5), 32)
    local Yb = Cpace.share(yb, g)
    local isk = Cpace.isk(sid, Cpace.secret(yb, Ya), Ya, "", Yb, "")
    local macKey = Cpace.macKey(sid, isk)
    local finish = T.http(mock, "POST", "/v1/auth/pair", {
        ip = options.ip,
        body = { cpace = {
            session = start.json.cpace.session,
            share = Base64.encode(options.share or Yb),
            confirm = Base64.encode(options.confirm or Cpace.tag(macKey, Yb, "")),
        } },
    })
    return finish, { start = start, isk = isk, Ta = Cpace.tag(macKey, Ya, "") }
end

function tests.pairing_with_cpace_never_sends_the_code_and_seals_the_key()
    local mock = Mock.startDriver()
    local Base64, _, _, Lock = modules()
    local code = codeOf(mock)
    local finish, app = pair(mock, { name = "Chrome on Windows" })
    T.eq(app.start.status, 200, app.start.body)
    T.eq(finish.status, 201, finish.body)
    T.eq(finish.json.cpace.confirm, Base64.encode(app.Ta), "the controller proves it knew the code")
    local plaintext = Lock.open(Lock.cpaceKey(Base64.toHex(app.isk)), finish.json.sealed, "res")
    T.truthy(plaintext, "the key opens with the exchange's key")
    local created = Json.decode(plaintext)
    T.eq(created.name, "Chrome on Windows")
    T.eq(created.role, "admin")
    T.notContains(finish.body, created.key, "the key is not readable on the network")
    T.notContains(app.start.body, code, "the code is in no answer")
    T.eq(T.http(mock, "GET", "/v1/api-keys/current", { key = created.key }).status, 200, "and it works")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code } }).json.code, "PAIRING_NOT_ACTIVE", "the code works once")
end

function tests.the_key_is_made_only_after_the_proof()
    local mock = Mock.startDriver()
    local Base64 = modules()
    local start = T.http(mock, "POST", "/v1/auth/pair", { body = { name = "Tablet", cpace = { nonce = Base64.encode(string.rep("n", 16)) } } })
    T.eq(start.status, 200)
    T.eq(mock.properties["API Keys"], "0", "no key after the first request")
    local wrong = pair(mock, { code = "00000000", name = "Tablet" })
    T.eq(wrong.status, 403)
    T.eq(wrong.json.code, "PAIRING_CODE_INVALID")
    T.eq(mock.properties["API Keys"], "0", "none after a wrong code")
    T.eq(pair(mock, { name = "Tablet" }).status, 201, "the right code still works")
    T.eq(mock.properties["API Keys"], "1")
end

function tests.a_failed_confirmation_counts_as_a_wrong_code()
    local mock = Mock.startDriver()
    for left = 4, 1, -1 do
        local response = pair(mock, { code = "11112222", name = "Guess" })
        T.eq(response.json.code, "PAIRING_CODE_INVALID")
        T.eq(response.json.attempts_remaining, left)
    end
    local locked = pair(mock, { code = "11112222", name = "Guess" })
    T.eq(locked.status, 429, "the fifth wrong code locks this device, as with the code itself")
    T.eq(locked.headers["retry-after"], "60")
    T.eq(pair(mock, {}).status, 429, "even with the right code, for a minute")
    T.eq(pair(mock, { ip = "192.168.1.77" }).status, 201, "another device is not locked out")
end

function tests.attempts_started_and_never_finished_count_too()
    local mock = Mock.startDriver()
    local Base64 = modules()
    local function start(ip)
        return T.http(mock, "POST", "/v1/auth/pair", { ip = ip, body = { cpace = { nonce = Base64.encode(string.rep("s", 16)) } } })
    end
    for _ = 1, 5 do
        T.eq(start().status, 200)
    end
    T.eq(start().status, 429, "a sixth attempt within the minute")
    -- And the plain code shares the count.
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = codeOf(mock) } }).status, 429)
end

-- Five attempts started are the device's five tries of the minute: the plain code gets no sixth.
function tests.after_five_attempts_started_the_plain_code_is_not_compared()
    local mock = Mock.startDriver()
    local Base64 = modules()
    for _ = 1, 5 do
        T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = { nonce = Base64.encode(string.rep("s", 16)) } } }).status, 200)
    end
    local plain = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = codeOf(mock) } })
    T.eq(plain.status, 429, "even the right code")
    T.eq(plain.json.code, "PAIRING_RATE_LIMITED")
    -- Another device is not held up by it.
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { ip = "10.0.0.9", body = { pairing_code = codeOf(mock) } }).status, 201)
end

function tests.twenty_attempts_close_the_code()
    local mock = Mock.startDriver()
    for attempt = 1, 19 do
        T.eq(pair(mock, { code = "00000000", ip = "10.0.0." .. attempt }).json.code, "PAIRING_CODE_INVALID")
    end
    local last = pair(mock, { code = "00000000", ip = "10.0.0.20" })
    T.eq(last.json.code, "PAIRING_NOT_ACTIVE", "the twentieth closes it")
    T.eq(mock.properties["Pairing Code"], "-")
    T.eq(pair(mock, { code = "00000000", ip = "10.0.0.21" }).json.code, "PAIRING_NOT_ACTIVE")
end

function tests.a_name_or_expiry_changed_on_the_way_fails_like_a_wrong_code()
    local mock = Mock.startDriver()
    -- Someone in between sent "Evil" as the name; the app bound its own.
    local renamed = pair(mock, { name = "Evil", channelName = "Chrome" })
    T.eq(renamed.json.code, "PAIRING_CODE_INVALID")
    local expiry = pair(mock, { name = "Console", expiresIn = 2592000, channelName = "Console" })
    T.eq(expiry.status, 201, "the same name and expiry on both sides")
    T.eq(mock.properties["API Keys"], "1")
end

function tests.a_share_of_low_order_is_refused_and_makes_no_key()
    local Base64 = require("src.core.base64")
    for _, point in ipairs({
        string.rep("00", 32),
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880", -- bit 255 set
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    }) do
        local mock = Mock.startDriver()
        local refused = pair(mock, { share = Base64.fromHex(point) })
        T.eq(refused.status, 400, point)
        T.eq(refused.json.errors[1].field, "cpace.share")
        T.eq(mock.properties["API Keys"], "0")
    end
end

function tests.an_exchange_works_once_for_its_device_within_a_minute()
    local mock = Mock.startDriver()
    local Base64 = modules()
    local start = T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = { nonce = Base64.encode(string.rep("o", 16)) } } })
    local finish = { cpace = { session = start.json.cpace.session, share = Base64.encode(string.rep("x", 32)), confirm = Base64.encode(string.rep("t", 64)) } }
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { ip = "192.168.1.99", body = finish }).json.code, "PAIRING_SESSION_EXPIRED", "not from another device")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = finish }).json.code, "PAIRING_CODE_INVALID", "its own device: a wrong tag")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = finish }).json.code, "PAIRING_SESSION_EXPIRED", "used once")

    local later = T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = { nonce = Base64.encode(string.rep("o", 16)) } } })
    local realTime = os.time
    os.time = function()
        return realTime() + 61
    end
    local ok, response = pcall(T.http, mock, "POST", "/v1/auth/pair", { body = { cpace = {
        session = later.json.cpace.session, share = finish.cpace.share, confirm = finish.cpace.confirm,
    } } })
    os.time = realTime
    T.truthy(ok, response)
    T.eq(response.status, 409)
    T.eq(response.json.code, "PAIRING_SESSION_EXPIRED", "after a minute")
end

function tests.a_new_code_made_meanwhile_ends_the_attempt()
    local mock = Mock.startDriver()
    local Base64, Cpace, CpacePairing = modules()
    local oldCode = codeOf(mock)
    local nonce = string.rep(string.char(2), 16)
    local start = T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = { nonce = Base64.encode(nonce) } } })
    ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    local sid = nonce .. Base64.decode(start.json.cpace.nonce)
    local Ya = Base64.decode(start.json.cpace.share)
    local yb = string.rep(string.char(8), 32)
    local Yb = Cpace.share(yb, Cpace.generator(oldCode, CpacePairing.channel(nil, nil), sid))
    local isk = Cpace.isk(sid, Cpace.secret(yb, Ya), Ya, "", Yb, "")
    local response = T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = {
        session = start.json.cpace.session, share = Base64.encode(Yb), confirm = Base64.encode(Cpace.tag(Cpace.macKey(sid, isk), Yb, "")),
    } } })
    T.eq(response.json.code, "PAIRING_CODE_EXPIRED", "the old code is no longer valid, even when proven")
    T.eq(mock.properties["API Keys"], "0")
end

function tests.bad_requests_are_refused_before_anything_counts()
    local mock = Mock.startDriver()
    local Base64 = modules()
    local function field(body)
        local response = T.http(mock, "POST", "/v1/auth/pair", { body = body })
        T.eq(response.status, 400, response.body)
        return response.json.errors[1].field
    end
    T.eq(field({ cpace = { nonce = "AAAA" } }), "cpace.nonce")
    T.eq(field({ cpace = { nonce = Base64.encode(string.rep("n", 16)), extra = 1 } }), "cpace.extra")
    T.eq(field({ cpace = "yes" }), "cpace")
    T.eq(field({ pairing_code = codeOf(mock), cpace = { nonce = Base64.encode(string.rep("n", 16)) } }), "pairing_code", "never both")
    T.eq(field({ cpace = { nonce = Base64.encode(string.rep("n", 16)) }, expires_in = 30 }), "expires_in")
    T.eq(field({ cpace = { session = "x", share = "AAAA", confirm = "AAAA" }, name = "x" }), "name", "the second request has only cpace")
    T.eq(pair(mock, { name = "Chrome" }).status, 201, "none of them counted")
end

function tests.a_controller_that_cannot_seal_refuses_cpace_and_keeps_the_code()
    local mock = Mock.startDriver(nil, nil, nil, function()
        function C4:Encrypt()
            return nil
        end
    end)
    local Base64 = modules()
    local refused = T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = { nonce = Base64.encode(string.rep("n", 16)) } } })
    T.eq(refused.status, 503)
    T.eq(refused.json.code, "LOCK_UNAVAILABLE", "the app then warns before it sends the code, and says updating will not help")
    T.eq(T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = codeOf(mock), name = "Chrome" } }).status, 201, "not counted")
end

function tests.a_sealed_request_cannot_start_pairing()
    local mock = Mock.startDriver()
    local Base64 = modules()
    -- As through the relay: the request carries its device's key (src/cloud/remote.lua).
    local Auth = require("src.api.handlers.auth")
    local refused = Auth.pair({ request = { principal = { id = "4fde46cc" } }, body = { cpace = { nonce = Base64.encode(string.rep("n", 16)) } } })
    T.eq(refused.code, "PAIRING_ONLY_ON_HOME_NETWORK")
    T.truthy(mock.properties["Pairing Code"]:match("^%d%d%d%d %d%d%d%d$"), "the code is still there")
end

function tests.pairing_the_old_way_still_works_for_scripts()
    local mock = Mock.startDriver()
    local response = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = mock.properties["Pairing Code"], name = "Home Assistant" } })
    T.eq(response.status, 201)
    T.truthy(response.json.key:match("^ak_"), "the key in the clear, as documented")
    T.eq(response.json.expires_at, Json.null, "keys do not expire unless asked")
end

return tests
