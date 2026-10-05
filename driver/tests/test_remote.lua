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

    -- A viewer of 1.7.0 is a member with no rooms (ADR-054): through the account too, a light is,
    -- for them, one that does not exist, and admin routes are refused.
    local viewer, viewerId = createKey(s, "viewer")
    local refused = e2e(s, { method = "PATCH", path = "/v1/lights/" .. light.id, body = { on = false } }, { apiKey = viewer, keyId = viewerId })
    T.eq(refused.status, 404)
    T.eq(Json.decode(refused.body).code, "NOT_FOUND")
    local listed = e2e(s, { method = "GET", path = "/v1/lights" }, { apiKey = viewer, keyId = viewerId })
    T.eq(listed.status, 200)
    T.eq(#Json.decode(listed.body).items, 0, "none of theirs")
    T.eq(e2e(s, { method = "GET", path = "/v1/api-keys" }, { apiKey = viewer, keyId = viewerId }).status, 403)
end

-- The room order is the only PUT; the app seals it like everything else, so from 1.0.0 it failed
-- through the account as well as at home.
function tests.the_room_order_is_set_through_the_account_by_admins_only()
    local s = session()
    local answer = e2e(s, { method = "PUT", path = "/v1/rooms/order", body = { room_ids = { 11, 10 } } })
    T.eq(answer.status, 200, answer.body)
    local items = Json.decode(answer.body).items
    T.eq(items[1].id, 11)
    T.eq(items[2].id, 10)
    T.eq(T.http(s.mock, "GET", "/v1/rooms", { key = s.key }).json.items[1].id, 11, "the home's order was saved")

    local member, memberId = createKey(s, "member")
    local refused = e2e(s, { method = "PUT", path = "/v1/rooms/order", body = { room_ids = { 10, 11 } } }, { apiKey = member, keyId = memberId })
    T.eq(refused.status, 403)
    T.eq(Json.decode(refused.body).code, "FORBIDDEN")
    T.eq(T.http(s.mock, "GET", "/v1/rooms", { key = s.key }).json.items[1].id, 11, "unchanged")
end

-- Through the account, a relay is held closed only with Relay Hold allowed, as on the home
-- network (1.1.1).
function tests.a_remote_request_holds_a_relay_closed_only_with_relay_hold()
    local s = session()
    Properties["Door Control"] = "Enabled"
    local commands = s.mock.commands
    local before = #commands
    local refused = e2e(s, { method = "PATCH", path = "/v1/relays/70", body = { state = "closed" } })
    T.eq(refused.status, 409)
    T.eq(Json.decode(refused.body).code, "HOLD_NOT_ALLOWED")
    T.eq(#commands, before, "nothing reaches the relay")
    T.eq(e2e(s, { method = "POST", path = "/v1/relays/70/pulse" }).status, 202)
    T.eq(commands[#commands].command, "Close Relay")
    T.eq(e2e(s, { method = "PATCH", path = "/v1/relays/70", body = { state = "open" } }).status, 202)
    T.eq(commands[#commands].command, "Open Relay")

    Properties["Relay Hold"] = "Allowed"
    OnPropertyChanged("Relay Hold")
    T.eq(e2e(s, { method = "PATCH", path = "/v1/relays/70", body = { state = "closed" } }).status, 202)
    T.eq(commands[#commands].command, "Close Relay", "held")
end

-- Whatever method the API routes, a sealed request may carry it: a path nothing answers gives the
-- router's 404, which a request refused by the remote path never reaches.
function tests.every_method_the_api_routes_can_come_sealed()
    local s = session()
    local methods = {}
    for _, route in ipairs(require("src.api.routes")) do
        methods[route.method] = true
    end
    T.truthy(methods.PUT, "the routes still have a PUT")
    for method in pairs(methods) do
        local answer = e2e(s, { method = method, path = "/v1/nothing-here" })
        T.eq(answer.status, 404, method .. " reaches the router: " .. tostring(answer.body))
    end
    local other = e2e(s, { method = "TRACE", path = "/v1/system" })
    T.eq(other.status, 400, "other methods are still refused")
    T.contains(other.body, "GET, POST, PUT, PATCH or DELETE")
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
    local token = claim.json.claim_token
    local wrong = (token:sub(1, 1) == "0" and "1" or "0") .. token:sub(2)
    T.eq(send(s, { type = "claim", id = "c1", token = wrong }).ok, false, "a wrong token")
    local right = send(s, { type = "claim", id = "c2", token = claim.json.claim_token })
    T.eq(right.type, "claim_result")
    T.eq(right.ok, true)
    T.eq(send(s, { type = "claim", id = "c3", token = claim.json.claim_token }).ok, false, "a token works once")

    local remote = e2e(s, { method = "POST", path = "/v1/remote/claim" })
    T.eq(remote.status, 403)
    T.eq(Json.decode(remote.body).code, "CLAIM_ONLY_ON_HOME_NETWORK")
    -- Nor wrapped in a home-network sealed request sent through the relay.
    local inner = Lock().seal(Lock().deviceKey(s.key), "lan", s.keyId, "req", Json.encode({ id = "inner-1", ts = os.time(), method = "POST", path = "/v1/remote/claim" }))
    local nested = e2e(s, { method = "POST", path = "/v1/sealed", body = { envelope = inner } })
    T.eq(nested.status, 400)
    T.eq(Json.decode(nested.body).code, "BAD_REQUEST")
    T.eq(e2e(s, { method = "POST", path = "/v1/sealed/", body = { envelope = inner } }).status, 400)
    -- Nor can a pairing code be guessed from outside, even while one is active.
    ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    local pair = e2e(s, { method = "POST", path = "/v1/auth/pair", body = Json.encode({ pairing_code = s.mock.properties["Pairing Code"] }) })
    T.eq(pair.status, 403)
    T.eq(Json.decode(pair.body).code, "PAIRING_ONLY_ON_HOME_NETWORK")
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
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).json.code, "LOCK_UNAVAILABLE", "no invitations that could never work")
    T.contains(table.concat(s.mock.debugLog, "\n"), "lock self-test failed")
end

function tests.a_request_captured_before_a_restart_is_refused_after_it()
    -- The driver started 30 s ago and the request was sealed then: well within the 2-minute window,
    -- so only the start time refuses it after the restart.
    local before = os.time() - 30
    local Clock, now
    local s = session({
        prepare = function()
            Clock = require("src.core.clock")
            now = Clock.now
            Clock.now = function()
                return before
            end
        end,
    })
    local envelope = seal(s, { method = "GET", path = "/v1/system", ts = before })
    local reply = send(s, { type = "e2e", id = "before", envelope = envelope })
    Clock.now = now
    T.truthy(reply.envelope, "accepted before the restart (" .. tostring(reply.code) .. ")")
    local updated = Mock.updateDriver(s.mock)
    local _, connection = Harness.connected({ mock = updated })
    local again = Harness.relayRequest(updated, connection, { type = "e2e", id = "after", envelope = envelope })
    T.eq(again.code, "STALE", "sealed before this start: refused, although its id is no longer remembered")
end

function tests.revoking_keys_revokes_their_invitations_and_the_claim_token()
    local s = session()
    local admin, adminId = createKey(s, "admin")
    local byAdmin = T.http(s.mock, "POST", "/v1/invitations", { key = admin, body = { role = "member" } }).json
    local byOwner = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer" } }).json
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. adminId, { key = s.key }).status, 204)
    local listed = T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items
    T.eq(#listed, 1, "the revoked admin's invitation went with the key")
    T.eq(listed[1].id, byOwner.id)
    local _, refused = join(s, byAdmin, "Late")
    T.eq(refused.code, "INVITATION_NOT_FOUND")

    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key }).json
    ExecuteCommand("LUA_ACTION", { ACTION = "REVOKE_API_KEYS" })
    local _, afterAll = join(s, byOwner, "After revoke all")
    T.eq(afterAll.code, "INVITATION_NOT_FOUND", "Revoke All API Keys revokes the invitations too")
    T.eq(send(s, { type = "claim", id = "late", token = claim.claim_token }).ok, false, "and the claim token")
end

function tests.a_claim_answer_has_a_code_only_when_it_fails_and_joins_update_the_key_count()
    local s = session()
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key }).json
    local right = send(s, { type = "claim", id = "c", token = claim.claim_token })
    T.eq(right.ok, true)
    T.eq(right.code, nil)
    local invitation = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).json
    local before = s.mock.properties["API Keys"]
    join(s, invitation, "Phone")
    T.eq(tonumber(s.mock.properties["API Keys"]), tonumber(before) + 1, "Composer shows the new key")
end

function tests.a_request_dated_ahead_of_the_controller_clock_cannot_be_replayed_after_a_restart()
    local s = session()
    local now = seal(s, { method = "GET", path = "/v1/system" })
    T.truthy(send(s, { type = "e2e", id = "now", envelope = now }).envelope)
    T.eq(s.mock.persist["directorlink_remote_seen"], nil, "requests dated now are not written to persistence")
    -- A phone 100 s ahead: still inside the 2-minute window after a restart 20 s later.
    local ahead = seal(s, { method = "GET", path = "/v1/system", ts = os.time() + 100 })
    T.truthy(send(s, { type = "e2e", id = "ahead", envelope = ahead }).envelope, "accepted before the restart")
    T.eq(send(s, { type = "e2e", id = "again", envelope = ahead }).code, "REPLAYED")
    local updated = Mock.updateDriver(s.mock)
    local _, connection = Harness.connected({ mock = updated })
    local replay = Harness.relayRequest(updated, connection, { type = "e2e", id = "after", envelope = ahead })
    T.eq(replay.code, "REPLAYED", "its id was saved")
    local fresh = seal(s, { method = "GET", path = "/v1/system", ts = os.time() + 100 })
    T.truthy(Harness.relayRequest(updated, connection, { type = "e2e", id = "new", envelope = fresh }).envelope, "new requests from that phone still work")
end

function tests.a_claim_token_dies_with_its_admin_key_and_demotion_revokes_invitations()
    local s = session()
    local admin, adminId = createKey(s, "admin")
    local revoked = T.http(s.mock, "POST", "/v1/remote/claim", { key = admin }).json
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. adminId, { key = s.key }).status, 204)
    T.eq(send(s, { type = "claim", id = "c1", token = revoked.claim_token }).ok, false, "the key that asked for it was revoked")

    local other, otherId = createKey(s, "admin")
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = other }).json
    local invitation = T.http(s.mock, "POST", "/v1/invitations", { key = other, body = { role = "admin" } }).json
    T.eq(T.http(s.mock, "PATCH", "/v1/api-keys/" .. otherId, { key = s.key, body = { role = "member" } }).status, 200)
    T.eq(send(s, { type = "claim", id = "c2", token = claim.claim_token }).ok, false, "the key is no longer admin")
    T.eq(#T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items, 0, "its invitations went with its admin role")
    local _, refused = join(s, invitation, "Back door")
    T.eq(refused.code, "INVITATION_NOT_FOUND")

    local mine = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key }).json
    T.eq(send(s, { type = "claim", id = "c3", token = mine.claim_token }).ok, true, "an admin's own token still works")
end

function tests.my_other_device_joins_my_profile_and_someone_else_gets_their_own()
    local s = session()
    local mine = T.http(s.mock, "GET", "/v1/profile", { key = s.key }).json
    T.http(s.mock, "PATCH", "/v1/profile", { key = s.key, body = { prefs = { language = "he", favorites = { "light:21" } } } })
    local forMe = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "admin", expires_in = 600, for_me = true } }).json
    T.eq(forMe.for_me, true)
    local phone = Json.decode(join(s, forMe, "Safari on iPhone").body)
    local phoneProfile = T.http(s.mock, "GET", "/v1/profile", { key = phone.key }).json
    T.eq(phoneProfile.id, mine.id, "my other device")
    T.eq(phoneProfile.prefs.language, "he", "with my language and favorites")

    local forGuest = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer" } }).json
    T.eq(forGuest.for_me, false)
    local guest = Json.decode(join(s, forGuest, "Guest").body)
    local guestProfile = T.http(s.mock, "GET", "/v1/profile", { key = guest.key }).json
    T.truthy(guestProfile.id ~= mine.id, "someone else: their own profile")
    T.eq(guestProfile.name, "Guest")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer", for_me = "yes" } }).json.code, "INVALID_FIELD")
end

function tests.my_other_device_invitation_keeps_its_profile_across_a_restart()
    local s = session()
    local mine = T.http(s.mock, "GET", "/v1/profile", { key = s.key }).json
    local forMe = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "admin", expires_in = 600, for_me = true } }).json
    local updated = Mock.updateDriver(s.mock)
    local _, connection = Harness.connected({ mock = updated })
    local after = { mock = updated, connection = connection, key = s.key, keyId = s.keyId, home = s.home }
    local phone = Json.decode(join(after, forMe, "Safari on iPhone").body)
    T.eq(T.http(updated, "GET", "/v1/profile", { key = phone.key }).json.id, mine.id)
end

-- What the driver sent the relay since `from` (not key announcements).
local function sentFrames(s)
    local frames = {}
    for _, frame in ipairs(Harness.answers(Harness.clientFrames(s.connection.sent))) do
        frames[#frames + 1] = Json.decode(frame.payload)
    end
    s.connection.sent = ""
    return frames
end

local function relayAnswers(message)
    ReceivedFromNetwork(Harness.BINDING, 443, Harness.serverFrame(1, Json.encode(message)))
end

function tests.an_invitation_with_an_email_is_registered_by_the_controller()
    local s = session()
    s.connection.sent = ""
    local pending = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", email = " Dana@Example.com " } })
    T.eq(pending.status, nil, "the answer waits for the account service")
    local asked = sentFrames(s)
    T.eq(#asked, 1)
    T.eq(asked[1].type, "invitation")
    T.eq(asked[1].email, "dana@example.com")
    T.truthy(asked[1].invitation_id:match("^%x+$") and asked[1].expires_at:match("Z$"))
    T.eq(asked[1].secret, nil, "the secret never goes to the relay")
    T.same(asked[1].pending, { asked[1].invitation_id }, "with the invitations still waiting here")
    relayAnswers({ type = "invitation_result", id = asked[1].id, ok = true })
    local created = T.response(s.mock, pending.handle)
    T.eq(created.status, 201, created.body)
    T.eq(created.json.registered, true)
    T.truthy(created.json.secret:match("^%x+$"))

    -- Refused by the account service: the invitation goes, since its link would not work.
    local refused = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer", email = "guest@example.com" } })
    local second = sentFrames(s)[1]
    relayAnswers({ type = "invitation_result", id = second.id, ok = false, code = "INVITATION_EXISTS" })
    T.eq(T.response(s.mock, refused.handle).status, 502)
    T.eq(#T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items, 1, "only the registered one is left")

    -- No answer at all.
    local silent = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer", email = "late@example.com" } })
    sentFrames(s)
    Mock.fireTimers(s.mock, 1)
    local timedOut = T.response(s.mock, silent.handle)
    T.eq(timedOut.status, 503)
    T.eq(timedOut.json.code, "REMOTE_OFFLINE")
    local cancelled = false
    for _, frame in pairs(sentFrames(s)) do
        cancelled = cancelled or (type(frame) == "table" and frame.type == "invitation_cancel" and frame.invitation_id ~= nil)
    end
    T.truthy(cancelled, "the account service is told to forget it, had it taken it after all")
    T.eq(#T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items, 1)
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "viewer", email = "not an email" } }).status, 400)

    -- Revoked here: the account service is told to forget it too.
    sentFrames(s)
    T.eq(T.http(s.mock, "DELETE", "/v1/invitations/" .. created.json.id, { key = s.key }).status, 204)
    local told = false
    for _, frame in pairs(sentFrames(s)) do
        told = told or (type(frame) == "table" and frame.type == "invitation_cancel" and frame.invitation_id == created.json.id)
    end
    T.truthy(told)
end

-- The retry timer the driver set last (reconnecting).
local function fireRetry(mock)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if not timer.fired and not timer.cancelled and not timer.repeating then
            timer.fired = true
            timer.callback()
            return timer.delay / 1000
        end
    end
end

-- The relay refuses the connection attempt the driver is making now.
local function refuse(s)
    local body = '{"type":"about:blank","title":"Unauthorized","status":401,"code":"HOME_SECRET_MISMATCH"}'
    ReceivedFromNetwork(Harness.BINDING, 443, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\n"
        .. "Content-Length: " .. #body .. "\r\n\r\n" .. body)
end

local function identity(s)
    return Json.decode(s.mock.persist.directorlink_remote_identity:sub(#"json:" + 1))
end

-- Reconnects after the relay closed the connection, and returns the upgrade request sent.
local function reconnect(s)
    s.connection.sent = ""
    OnConnectionStatusChanged(Harness.BINDING, 443, "OFFLINE")
    fireRetry(s.mock)
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    local request = s.connection.sent
    s.connection.sent = ""
    return request
end

local function sha256(text)
    return C4:Hash("SHA256", text, { return_encoding = "HEX" }):lower()
end

function tests.a_new_home_secret_waits_for_the_owner_and_is_used_once_approved()
    local s = session()
    local before = identity(s)
    local first = T.http(s.mock, "POST", "/v1/remote/secret", { key = s.key })
    T.eq(first.status, 200, first.body)
    T.eq(first.json.home_id, s.home)
    local second = T.http(s.mock, "POST", "/v1/remote/secret", { key = s.key }).json
    T.truthy(second.secret_sha256 ~= first.json.secret_sha256, "a new one each time, never one made earlier")
    local waiting = identity(s)
    T.eq(waiting.home_secret, before.home_secret, "the secret in use stays until a new one works")
    T.eq(#waiting.next_secrets, 2)
    T.eq(sha256(waiting.next_secrets[1].secret), second.secret_sha256, "newest first")
    T.eq(sha256(waiting.next_secrets[2].secret), first.json.secret_sha256)
    T.notContains(first.body, waiting.next_secrets[2].secret, "only its hash leaves the controller")

    -- Not approved yet: the current secret still works, and the new ones keep waiting.
    local request = reconnect(s)
    T.contains(request, "Authorization: Bearer " .. before.home_secret)
    Harness.accept(request)
    T.eq(#identity(s).next_secrets, 2)

    -- The owner approved the first one: the relay refuses the old secret, the driver tries the
    -- waiting ones, newest first.
    T.contains(reconnect(s), "Authorization: Bearer " .. before.home_secret)
    refuse(s)
    T.eq(fireRetry(s.mock), 1)
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    T.contains(s.connection.sent, "Authorization: Bearer " .. waiting.next_secrets[1].secret)
    refuse(s)
    T.eq(fireRetry(s.mock), 1)
    s.connection.sent = ""
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    T.contains(s.connection.sent, "Authorization: Bearer " .. waiting.next_secrets[2].secret)
    Harness.accept(s.connection.sent)
    local after = identity(s)
    T.eq(after.home_secret, waiting.next_secrets[2].secret, "the approved one is the home secret now")
    T.eq(after.next_secrets, nil, "and the others are gone")
end

function tests.only_the_newest_replacements_wait()
    local s = session()
    local hashes = {}
    for index = 1, 4 do
        hashes[index] = T.http(s.mock, "POST", "/v1/remote/secret", { key = s.key }).json.secret_sha256
    end
    local waiting = identity(s).next_secrets
    T.eq(#waiting, 3)
    T.eq(sha256(waiting[1].secret), hashes[4])
    T.eq(sha256(waiting[3].secret), hashes[2], "the oldest one went")
end

function tests.a_refused_new_secret_is_tried_once_then_the_driver_waits()
    local s = session()
    local before = identity(s)
    T.eq(T.http(s.mock, "POST", "/v1/remote/secret", { key = s.key }).status, 200)
    reconnect(s)
    refuse(s)
    T.eq(fireRetry(s.mock), 1, "the new secret is tried")
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    refuse(s)
    T.contains(s.mock.properties["Remote Status"], "Reconnecting in 300 s", "then the usual wait, with the reason")
    T.eq(fireRetry(s.mock), 300)
    s.connection.sent = ""
    OnConnectionStatusChanged(Harness.BINDING, 443, "ONLINE")
    T.contains(s.connection.sent, "Authorization: Bearer " .. before.home_secret, "and the current secret again, no loop")
    T.truthy(identity(s).next_secrets, "the new one still waits")
end

function tests.the_home_secret_is_replaced_only_from_the_home_network()
    local s = session()
    local answer = e2e(s, { method = "POST", path = "/v1/remote/secret" })
    T.eq(answer.status, 403)
    T.eq(Json.decode(answer.body).code, "SECRET_ONLY_ON_HOME_NETWORK")
    T.eq(identity(s).next_secrets, nil)
    local member = createKey(s, "member")
    T.eq(T.http(s.mock, "POST", "/v1/remote/secret", { key = member }).status, 403, "admins only")
end

function tests.composer_resets_the_remote_identity()
    local s = session()
    local before = identity(s)
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).status, 201)
    ExecuteCommand("LUA_ACTION", { ACTION = "RESET_REMOTE_IDENTITY" })
    local after = identity(s)
    T.truthy(after.home_id ~= before.home_id and after.home_secret ~= before.home_secret, "a new home id and secret")
    T.eq(#T.http(s.mock, "GET", "/v1/invitations", { key = s.key }).json.items, 0, "invitations for the old home are gone")
    T.eq(T.http(s.mock, "GET", "/v1/remote", { key = s.key }).json.home_id, after.home_id)
    T.contains(reconnect(s), "X-DirectorLink-Home: " .. after.home_id)
end

return tests
