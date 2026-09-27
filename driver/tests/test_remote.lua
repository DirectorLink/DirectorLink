-- Remote access with accounts (docs/ACCOUNTS.md): sealed requests, claims and invitations, through
-- the fake relay (relay_harness.lua) exactly as the cloud passes them on.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Harness = require("relay_harness")

local tests = {}

local counter = 0

local function Lock()
    return require("src.cloud.lock")
end

-- A driver paired on the home network (an admin key), with remote access on and connected.
local function session(options)
    options = options or {}
    local mock = Mock.startDriver(nil, nil, nil, options.prepare)
    local key = T.pair(mock)
    local _, connection = Harness.connected({ mock = mock })
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    local remote = T.http(mock, "GET", "/v1/remote", { key = key }).json
    return { mock = mock, connection = connection, key = key, keyId = me.id, home = remote.home_id }
end

local function send(s, message)
    return Harness.relayRequest(s.mock, s.connection, message)
end

-- Seals `request` as a device would; options: apiKey, keyId, home, lock, dir.
local function seal(s, request, options)
    options = options or {}
    counter = counter + 1
    request.id = request.id or ("request-" .. counter)
    request.ts = request.ts or os.time()
    local lock = options.lock or Lock().deviceKey(options.apiKey or s.key)
    local envelope = Lock().seal(lock, options.home or s.home, options.keyId or s.keyId, options.dir or "req", Json.encode(request))
    return envelope, lock
end

-- Sends a sealed request; returns the opened answer, and the relay message.
local function e2e(s, request, options)
    local envelope, lock = seal(s, request, options)
    local reply, frame = send(s, { type = "e2e", id = "relay-" .. counter, envelope = envelope })
    if not reply.envelope then
        return nil, reply, frame
    end
    T.eq(reply.envelope.key, (options and options.keyId) or s.keyId, "the answer is sealed for the same key")
    local plaintext = Lock().open(lock, reply.envelope, "res")
    T.truthy(plaintext, "the answer opens with the device's lock key")
    return Json.decode(plaintext), reply, frame
end

local function createKey(s, role)
    local created = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = role .. " device", role = role } })
    T.eq(created.status, 201)
    return created.json.key, created.json.id
end

function tests.a_sealed_request_runs_as_its_key_and_comes_back_sealed()
    local s = session()
    local answer, reply, frame = e2e(s, { method = "GET", path = "/v1/system" })
    T.eq(answer.status, 200)
    T.eq(answer.id, "request-" .. counter, "the answer names its request")
    T.truthy(math.abs(answer.ts - os.time()) < 5)
    local system = Json.decode(answer.body)
    T.eq(system.bridge.version, "dev")
    T.eq(reply.type, "e2e")
    T.eq(reply.id, "relay-" .. counter)
    T.notContains(frame.payload, "bridge", "the relay sees nothing of the answer")
    T.notContains(frame.payload, "Kitchen")
end

function tests.requests_with_a_body_and_query_work_and_roles_apply()
    local s = session()
    local lights = Json.decode((e2e(s, { method = "GET", path = "/v1/lights?room_id=10" })).body).items
    T.truthy(#lights > 0, "the query string reaches the API")
    local light = lights[1]
    local changed = e2e(s, { method = "PATCH", path = "/v1/lights/" .. light.id, body = { on = true } })
    T.truthy(changed.status == 200 or changed.status == 202, "an admin key may switch a light: " .. tostring(changed.status))

    local viewer, viewerId = createKey(s, "viewer")
    local refused = e2e(s, { method = "PATCH", path = "/v1/lights/" .. light.id, body = { on = false } }, { apiKey = viewer, keyId = viewerId })
    T.eq(refused.status, 403)
    T.eq(Json.decode(refused.body).code, "FORBIDDEN")
    T.eq(e2e(s, { method = "GET", path = "/v1/lights" }, { apiKey = viewer, keyId = viewerId }).status, 200, "but may read")
end

function tests.camera_pictures_come_back_as_base64_inside_the_seal()
    local s = session()
    local answer = e2e(s, { method = "GET", path = "/v1/cameras/60/snapshot" })
    T.eq(answer.status, 200)
    T.eq(answer.content_type, "image/jpeg")
    T.eq(answer.body, nil)
    local picture = Base64.decode(answer.body_base64)
    T.truthy(picture and picture:sub(1, 2) == "\255\216", "a JPEG")
end

function tests.a_request_is_accepted_once_and_only_while_fresh()
    local s = session()
    local envelope = seal(s, { method = "GET", path = "/v1/system" })
    T.truthy(send(s, { type = "e2e", id = "first", envelope = envelope }).envelope, "the first time")
    T.eq(send(s, { type = "e2e", id = "again", envelope = envelope }).code, "REPLAYED")
    local old = seal(s, { method = "GET", path = "/v1/system", ts = os.time() - 3600 })
    T.eq(send(s, { type = "e2e", id = "old", envelope = old }).code, "STALE")
    local future = seal(s, { method = "GET", path = "/v1/system", ts = os.time() + 3600 })
    T.eq(send(s, { type = "e2e", id = "future", envelope = future }).code, "STALE")
end

function tests.unknown_revoked_changed_or_misaddressed_envelopes_are_refused()
    local s = session()
    local _, reply = e2e(s, { method = "GET", path = "/v1/system" }, { keyId = "00000000" })
    T.eq(reply.code, "UNKNOWN_KEY")

    local envelope = seal(s, { method = "GET", path = "/v1/system" })
    envelope.ct = (envelope.ct:sub(1, 1) == "A" and "B" or "A") .. envelope.ct:sub(2)
    T.eq(send(s, { type = "e2e", id = "changed", envelope = envelope }).code, "BAD_MAC")

    local _, other = e2e(s, { method = "GET", path = "/v1/system" }, { home = "ffeeddccbbaa99887766554433221100" })
    T.eq(other.code, "BAD_ENVELOPE", "sealed for another home")

    local answerShaped = seal(s, { method = "GET", path = "/v1/system" }, { dir = "res" })
    T.eq(send(s, { type = "e2e", id = "turned", envelope = answerShaped }).code, "BAD_MAC", "an answer sent back as a request")

    local member, memberId = createKey(s, "member")
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. memberId, { key = s.key }).status, 204)
    local _, revoked = e2e(s, { method = "GET", path = "/v1/system" }, { apiKey = member, keyId = memberId })
    T.eq(revoked.code, "UNKNOWN_KEY", "a revoked key stops working remotely too")
end

function tests.a_key_from_before_remote_access_gets_its_lock_key_on_first_use_at_home()
    local hash = Base64.toHex(require("sha256")("ak_fromzeroninetwo"))
    local s = session({
        prepare = function(fresh)
            fresh.persist["directorlink_api_key_hashes"] = "json:" .. Json.encode({ version = 3, keys = {
                { id = "0a1b2c3d", name = "Old phone", role = "admin", alg = "sha256", hash = hash, created_at = "2026-09-27T15:00:00Z" },
            } })
        end,
    })
    local _, before = e2e(s, { method = "GET", path = "/v1/system" }, { apiKey = "ak_fromzeroninetwo", keyId = "0a1b2c3d" })
    T.eq(before.code, "UNKNOWN_KEY", "no lock key yet")
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = "ak_fromzeroninetwo" }).status, 200)
    T.eq(e2e(s, { method = "GET", path = "/v1/system" }, { apiKey = "ak_fromzeroninetwo", keyId = "0a1b2c3d" }).status, 200)
    T.notContains(s.mock.persist["directorlink_api_key_hashes"], "ak_fromzeroninetwo", "the key itself is still not stored")
end

function tests.a_claim_token_works_once_and_only_from_the_home_network()
    local s = session()
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(claim.status, 201)
    T.eq(claim.json.home_id, s.home)
    T.truthy(claim.json.claim_token:match("^%x+$") and #claim.json.claim_token == 48)
    T.eq(send(s, { type = "claim", id = "c1", token = "0" .. claim.json.claim_token:sub(2) }).ok, false, "a wrong token")
    local right = send(s, { type = "claim", id = "c2", token = claim.json.claim_token })
    T.eq(right.type, "claim_result")
    T.eq(right.ok, true)
    T.eq(send(s, { type = "claim", id = "c3", token = claim.json.claim_token }).ok, false, "a token works once")

    local remote = e2e(s, { method = "POST", path = "/v1/remote/claim" })
    T.eq(remote.status, 403)
    T.eq(Json.decode(remote.body).code, "CLAIM_ONLY_ON_HOME_NETWORK")
    local viewer = createKey(s, "viewer")
    T.eq(T.http(s.mock, "POST", "/v1/remote/claim", { key = viewer }).status, 403, "admins only")
    for _, line in ipairs(s.mock.debugLog) do
        T.notContains(line, claim.json.claim_token, "the token is never logged")
    end
end

function tests.remote_status_and_claims_need_remote_access_on()
    local mock = Mock.startDriver()
    local key = T.pair(mock)
    local status = T.http(mock, "GET", "/v1/remote", { key = key }).json
    T.eq(status.enabled, false)
    T.eq(status.connected, false)
    T.eq(status.lock, true, "the self-test passed")
    T.truthy(status.home_id == Json.null or status.home_id == nil, "no home id while off")
    local claim = T.http(mock, "POST", "/v1/remote/claim", { key = key })
    T.eq(claim.status, 409)
    T.eq(claim.json.code, "REMOTE_ACCESS_OFF")
    T.eq(T.http(mock, "POST", "/v1/invitations", { key = key, body = { role = "member" } }).json.code, "REMOTE_ACCESS_OFF")

    local s = session()
    local on = T.http(s.mock, "GET", "/v1/remote", { key = s.key }).json
    T.eq(on.enabled, true)
    T.eq(on.connected, true)
    T.truthy(on.home_id:match("^%x+$") and #on.home_id == 32)
end

-- An invitation's link carries home, id and secret; this plays the invited person's app.
local function join(s, invitation, name, options)
    options = options or {}
    local lock = Lock().invitationKey(options.secret or invitation.secret)
    counter = counter + 1
    local request = { id = "join-" .. counter, ts = options.ts or os.time(), method = "POST", path = "/v1/auth/join", body = { name = name } }
    local envelope = Lock().seal(lock, s.home, invitation.id, "req", Json.encode(request))
    local reply = send(s, { type = "join", id = "relay-join-" .. counter, invitation = invitation.id, envelope = envelope })
    if not reply.ok then
        return nil, reply
    end
    local answer = Json.decode(Lock().open(lock, reply.envelope, "res"))
    return answer, reply
end

function tests.an_invitation_gives_its_role_once_and_its_secret_is_never_stored()
    local s = session()
    local created = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } })
    T.eq(created.status, 201)
    local invitation = created.json
    T.truthy(invitation.id:match("^%x+$") and #invitation.id == 8)
    T.truthy(invitation.secret:match("^%x+$") and #invitation.secret == 64)
    T.eq(invitation.home_id, s.home)
    T.eq(invitation.role, "member")
    local listed = T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items
    T.eq(#listed, 1)
    T.eq(listed[1].secret, nil, "the list never shows secrets")
    T.notContains(s.mock.persist["directorlink_invitations"], invitation.secret, "only the lock key is stored")

    local answer, reply = join(s, invitation, "Safari on iPhone")
    T.eq(reply.type, "join_result")
    T.eq(reply.ok, true)
    T.eq(answer.status, 201)
    local newKey = Json.decode(answer.body)
    T.eq(newKey.role, "member")
    T.eq(newKey.name, "Safari on iPhone")
    T.eq(reply.key_id, newKey.id, "the relay learns the new key's id, not the key")
    T.notContains(Json.encode(reply), newKey.key)

    local works = e2e(s, { method = "GET", path = "/v1/api-keys/current" }, { apiKey = newKey.key, keyId = newKey.id })
    T.eq(works.status, 200, "the new key works through remote access at once")
    T.eq(Json.decode(works.body).role, "member")
    local _, again = join(s, invitation, "Someone else")
    T.eq(again.code, "INVITATION_NOT_FOUND", "an invitation works once")
    T.eq(#T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items, 0)
    for _, line in ipairs(s.mock.debugLog) do
        T.notContains(line, invitation.secret)
        T.notContains(line, newKey.key)
    end
end

function tests.invitations_are_refused_when_wrong_revoked_or_expired()
    local s = session()
    local invitation = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer", expires_in = 600 } }).json
    local _, wrong = join(s, invitation, "Guess", { secret = string.rep("0", 64) })
    T.eq(wrong.code, "BAD_MAC", "a guessed secret")
    T.eq(T.http(s.mock, "DELETE", "/v1/invitations/" .. invitation.id, { key = s.key }).status, 204)
    local _, revoked = join(s, invitation, "Late")
    T.eq(revoked.code, "INVITATION_NOT_FOUND")

    local expiring = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer", expires_in = 60 } }).json
    local Clock = require("src.core.clock")
    local now = Clock.now
    Clock.now = function()
        return now() + 61
    end
    local _, expired = join(s, expiring, "Too late", { ts = os.time() })
    Clock.now = now
    T.eq(expired.code, "INVITATION_NOT_FOUND", "expired")

    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "owner" } }).status, 400)
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", expires_in = 30 } }).status, 400)
    T.eq(T.http(s.mock, "DELETE", "/v1/invitations/nothex!!", { key = s.key }).status, 400)
    local member = createKey(s, "member")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = member, body = { role = "member" } }).status, 403, "admins only")
end

function tests.when_the_self_test_fails_nothing_remote_is_accepted()
    local s = session({
        prepare = function()
            local hmac = C4.HMAC
            function C4:HMAC(digest, key, data, options)
                local value = hmac(self, digest, key, data, options)
                return value and value:gsub("%x$", function(last)
                    return last == "0" and "1" or "0"
                end)
            end
        end,
    })
    T.eq(T.http(s.mock, "GET", "/v1/remote", { key = s.key }).json.lock, false)
    local reply = send(s, { type = "e2e", id = "x", envelope = { v = 1, home = s.home, key = s.keyId, iv = "", ct = "", mac = "" } })
    T.eq(reply.code, "LOCK_UNAVAILABLE")
    T.eq(T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key }).status, 503)
    T.contains(table.concat(s.mock.debugLog, "\n"), "lock self-test failed")
end

return tests
