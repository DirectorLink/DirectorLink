-- Remote access (docs/RELAY.md): the driver's WebSocket client and relay module against a fake
-- relay that speaks the protocol at the byte level.

local Mock = require("c4mock")
local T = require("helpers")
local Base64 = require("src.core.base64")
local Json = require("src.core.json")
local sha1 = require("sha1")
local sha256 = require("sha256")

local tests = {}

local Harness = require("relay_harness")
local BINDING = Harness.BINDING
local bigEndian, serverFrame, clientFrames = Harness.bigEndian, Harness.serverFrame, Harness.clientFrames
local connected, relayRequest = Harness.connected, Harness.relayRequest

local function lastTimer(mock, delay)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if timer.delay == delay and not timer.cancelled and not timer.fired then
            return timer
        end
    end
end

function tests.remote_access_is_off_by_default()
    local mock = Mock.startDriver()
    T.eq(next(mock.network), nil, "no outgoing connection")
    T.eq(mock.properties["Remote Status"], "Off")
end

function tests.switching_on_opens_a_tls_connection_to_the_relay()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local connection = mock.network[BINDING]
    T.eq(connection.host, "api.directorlink.io")
    T.eq(connection.port, 443)
    T.eq(connection.kind, "SSL")
    T.eq(connection.connects, 1)
    T.eq(mock.properties["Remote Status"], "Connecting...")
    T.eq(mock.persistEncrypted["directorlink_remote_identity"], false, "plain storage survives updates")
end

-- Without VERIFY_MODE, Director checks no certificate at all.
function tests.the_relay_certificate_is_checked_against_the_packaged_roots()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local options = mock.network[BINDING].options
    T.eq(options.VERIFY_MODE, "peer")
    T.eq(options.CACERTFILE, "./certs/directorlink-roots.pem")
    local roots = mock.network[BINDING].caCertificates
    T.truthy(roots, "the CA file is in the driver package")
    local count = select(2, roots:gsub("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-", ""))
    T.eq(count, 9, "Let's Encrypt, Google Trust Services and SSL.com roots")
    T.notContains(roots, "PRIVATE KEY")
    -- The certificate under each label is that root (SHA-256 of its DER bytes, as pinned in
    -- scripts/check_package.py), not only its name: today's chain ends at GTS Root R4.
    local pinned = {
        ["ISRG Root X1"] = "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6",
        ["ISRG Root X2"] = "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470",
        ["GTS Root R1"] = "d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf",
        ["GTS Root R4"] = "349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d",
        ["SSL.com TLS RSA Root CA 2022"] = "8faf7d2e2cb4709bb8e0b33666bf75a5dd45b5de480f8ea8d4bfe6bebc17f2ed",
        ["SSL.com TLS ECC Root CA 2022"] = "c32ffd9f46f936d16c3673990959434b9ad60aafbb9e7cf33654f144cc1ba143",
    }
    local found = {}
    for label, body in roots:gmatch("\n# ([^\n]+)\n%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-\n([%w+/=\n]-)\n%-%-%-%-%-END CERTIFICATE%-%-%-%-%-") do
        found[label] = Base64.toHex(sha256(Base64.decode((body:gsub("\n", "")))))
    end
    for root, fingerprint in pairs(pinned) do
        T.eq(found[root], fingerprint, root)
    end
end

function tests.handshake_sends_the_home_identity_and_hello_follows()
    local mock, _, request, hello = connected()
    T.truthy(request:match("^GET /relay/connect HTTP/1%.1\r\n"), "request line")
    T.contains(request, "\r\nHost: api.directorlink.io\r\n")
    T.contains(request, "\r\nUpgrade: websocket\r\n")
    T.contains(request, "\r\nSec-WebSocket-Version: 13\r\n")
    T.truthy(request:match("\r\nSec%-WebSocket%-Key: [%w+/]+==\r\n"), "a base64 key of 16 bytes")
    local secret = request:match("\r\nAuthorization: Bearer (%x+)\r\n")
    local home = request:match("\r\nX%-DirectorLink%-Home: (%x+)\r\n")
    T.eq(#secret, 64)
    T.eq(#home, 32)
    T.truthy(request:match("\r\n\r\n$"), "headers end the request")

    T.eq(#hello, 2, "hello, then the key ids")
    T.eq(hello[1].opcode, 1, "text frame")
    local message = Json.decode(hello[1].payload)
    T.eq(message.type, "hello")
    T.eq(message.home, home)
    T.truthy(message.version, "driver version")
    local keys = Json.decode(hello[2].payload)
    T.eq(keys.type, "keys")
    T.eq(#keys.ids, 0, "no keys yet")
    T.contains(hello[2].payload, '"ids":[]', "an empty list is a JSON array")
    T.contains(mock.properties["Remote Status"], "Connected since")
    T.contains(mock.properties["Remote Status"], home:sub(1, 8))
end

function tests.plain_relayed_requests_are_refused_without_reaching_the_api()
    local mock, connection = connected()
    local before = #mock.commands
    for _, message in ipairs({
        { type = "request", id = "r1", method = "GET", path = "/v1/lights?room_id=11", body = Json.null },
        { type = "request", id = "r2", method = "GET", path = "/v1/cameras/61/snapshot" },
        { type = "request", id = "r3", method = "PATCH", path = "/v1/lights/21", body = '{"on":true}' },
    }) do
        local response = relayRequest(mock, connection, message)
        T.eq(response.type, "response")
        T.eq(response.id, message.id)
        T.eq(response.status, 410, "since 0.10.0 only sealed requests are accepted")
        T.eq(Json.decode(response.body).code, "RELAY_REQUESTS_RETIRED")
        T.notContains(response.body, "Kitchen", "nothing of the home")
        T.eq(response.body_base64, nil)
    end
    T.eq(#mock.commands, before, "nothing reaches a device")
end

function tests.pings_are_answered_and_fragments_joined()
    local _, connection = connected()
    ReceivedFromNetwork(BINDING, 443, serverFrame(9, "x"))
    local pong = clientFrames(connection.sent)
    connection.sent = ""
    T.eq(pong[1].opcode, 10)
    T.eq(pong[1].payload, "x")

    local message = Json.encode({ type = "request", id = "f1", method = "GET", path = "/v1/system" })
    local split = 20
    -- Two network chunks, and the message in two frames: data arrives however TCP delivers it.
    local wire = serverFrame(1, message:sub(1, split), false) .. serverFrame(0, message:sub(split + 1))
    ReceivedFromNetwork(BINDING, 443, wire:sub(1, 7))
    ReceivedFromNetwork(BINDING, 443, wire:sub(8))
    local frames = clientFrames(connection.sent)
    T.eq(Json.decode(frames[1].payload).id, "f1")
    T.eq(frames[1].header, 4, "a response longer than 125 bytes uses the 16-bit length")
end

function tests.large_frames_use_64_bit_lengths()
    local WebSocket = require("src.cloud.websocket")
    local payload = string.rep("a", 70000)
    local frames = clientFrames(WebSocket.frame(1, payload, "\1\2\3\4"))
    T.eq(frames[1].header, 10)
    T.eq(frames[1].payload, payload, "mask round trip")
end

function tests.keepalive_pings_and_silence_reconnects()
    local mock, connection = connected()
    local keepalive = lastTimer(mock, 25000)
    T.truthy(keepalive and keepalive.repeating, "a repeating 25 s keep-alive")
    keepalive.callback()
    T.eq(clientFrames(connection.sent)[1].payload, "ping")
    connection.sent = ""

    local realTime = os.time
    os.time = function()
        return realTime() + 120
    end
    keepalive.callback()
    os.time = realTime
    T.eq(connection.disconnects >= 1, true, "a silent connection is dropped")
    T.contains(mock.properties["Remote Status"], "Reconnecting in 5 s")
end

function tests.lost_connections_reconnect_with_backoff()
    local mock, connection = connected()
    local delays = {}
    for _ = 1, 5 do
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        local retry
        for index = #mock.timers, 1, -1 do
            local timer = mock.timers[index]
            if not timer.fired and not timer.cancelled and not timer.repeating then
                retry = timer
                break
            end
        end
        delays[#delays + 1] = retry.delay / 1000
        retry.fired = true
        retry.callback()
    end
    T.same(delays, { 5, 10, 30, 60, 60 })
    T.eq(connection.connects, 6)
end

local function logged(mock, key, message)
    for _, entry in ipairs(T.http(mock, "GET", "/v1/logs?category=relay", { key = key }).json.items) do
        if entry.message == message then
            return true
        end
    end
    return false
end

-- Control4 does not document how Director reports a certificate that fails VERIFY_MODE, and it may
-- report nothing: an attempt that has not opened within 30 s is dropped and retried with the backoff.
function tests.an_attempt_that_never_opens_is_retried()
    local mock = Mock.startDriver()
    local key = T.pair(mock)
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local connection = mock.network[BINDING]
    T.eq(mock.properties["Remote Status"], "Connecting...")
    local limit = lastTimer(mock, 30000)
    T.truthy(limit and not limit.repeating, "a one-shot 30 s limit on the attempt")
    limit.fired = true
    limit.callback()
    T.eq(connection.disconnects, 1, "the attempt is dropped")
    T.eq(mock.properties["Remote Status"], "Reconnecting in 5 s (no connection within 30 s)")
    T.truthy(logged(mock, key, "no TLS connection to the relay within 30 s; the certificate check may have failed"))

    local retry = lastTimer(mock, 5000)
    retry.fired = true
    retry.callback()
    T.eq(connection.connects, 2, "and tried again")
    T.eq(mock.properties["Remote Status"], "Connecting...")

    -- TLS is up, but the relay never answers the upgrade: the same.
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    limit = lastTimer(mock, 30000)
    limit.fired = true
    limit.callback()
    T.eq(mock.properties["Remote Status"], "Reconnecting in 10 s (no connection within 30 s)")
    T.truthy(logged(mock, key, "the relay did not answer the upgrade within 30 s"))
end

function tests.the_attempt_limit_ends_with_the_attempt()
    local mock = connected()
    T.eq(lastTimer(mock, 30000), nil, "an open connection has no limit left")
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    T.eq(lastTimer(mock, 30000), nil, "a lost attempt waits for its backoff instead")
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    T.eq(lastTimer(mock, 30000), nil, "switching off ends it")
    T.eq(mock.properties["Remote Status"], "Off")
end

function tests.refusals_wait_longer_and_say_why()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    local body = '{"type":"about:blank","title":"Unauthorized","status":401,"code":"HOME_SECRET_MISMATCH"}'
    ReceivedFromNetwork(BINDING, 443, "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\n"
        .. "Content-Length: " .. #body .. "\r\n\r\n" .. body)
    T.contains(mock.properties["Remote Status"], "Reconnecting in 300 s")
    T.contains(mock.properties["Remote Status"], "HOME_SECRET_MISMATCH")
end

function tests.a_close_from_the_relay_is_answered_then_retried()
    local mock, connection = connected()
    ReceivedFromNetwork(BINDING, 443, serverFrame(8, bigEndian(4000, 2) .. "replaced"))
    local frames = clientFrames(connection.sent)
    T.eq(frames[1].opcode, 8, "close echoed")
    T.contains(mock.properties["Remote Status"], "closed by the relay (4000 replaced)")
end

function tests.switching_off_closes_and_stays_off()
    local mock, connection = connected()
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    T.eq(clientFrames(connection.sent)[1].opcode, 8, "a close frame")
    T.eq(connection.disconnects, 1)
    T.eq(mock.properties["Remote Status"], "Off")
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    T.eq(mock.properties["Remote Status"], "Off", "no reconnect after switching off")
end

function tests.the_identity_survives_updates_and_the_secret_is_never_logged()
    local mock, _, request = connected()
    local home = request:match("X%-DirectorLink%-Home: (%x+)")
    local secret = request:match("Authorization: Bearer (%x+)")

    local updated = Mock.updateDriver(mock)
    local _, _, again = connected({ mock = updated })
    T.eq(again:match("X%-DirectorLink%-Home: (%x+)"), home, "same home id after an update")
    T.eq(again:match("Authorization: Bearer (%x+)"), secret, "and the same secret")

    for _, logMock in ipairs({ mock, updated }) do
        for _, line in ipairs(logMock.debugLog) do
            T.truthy(not line:find(secret, 1, true), "the home secret never reaches the log")
        end
    end
end

function tests.an_identity_kept_encrypted_by_0_9_0_is_moved_to_plain_storage()
    local old = { home_id = string.rep("ab", 16), home_secret = string.rep("cd", 32) }
    local mock = Mock.startDriver(nil, nil, "DIT_UPDATING", function(fresh)
        fresh.persist["DIRECTORLINK_REMOTE_IDENTITY"] = Json.encode(old)
        fresh.persistEncrypted["DIRECTORLINK_REMOTE_IDENTITY"] = true
    end)
    local _, _, request = connected({ mock = mock })
    T.eq(request:match("X%-DirectorLink%-Home: (%x+)"), old.home_id, "the home keeps its id")
    T.notContains(mock.persist["DIRECTORLINK_REMOTE_IDENTITY"], old.home_secret, "the encrypted copy is emptied")
    T.eq(mock.persistEncrypted["directorlink_remote_identity"], false)
    local _, _, again = connected({ mock = Mock.updateDriver(mock) })
    T.eq(again:match("X%-DirectorLink%-Home: (%x+)"), old.home_id, "and keeps it through the next update")
end

function tests.an_identity_stored_by_0_9_1_as_plain_json_is_kept()
    -- 0.9.1 stored plain JSON, which Director hands back decoded.
    local old = { home_id = string.rep("ef", 16), home_secret = string.rep("01", 32) }
    local mock = Mock.startDriver(nil, nil, "DIT_UPDATING", function(fresh)
        fresh.persist["directorlink_remote_identity"] = Json.encode(old)
    end)
    local _, _, request = connected({ mock = mock })
    T.eq(request:match("X%-DirectorLink%-Home: (%x+)"), old.home_id, "the home keeps its id")
    T.eq(mock.persist["directorlink_remote_identity"]:sub(1, 5), "json:", "and it is stored the current way")
    local _, _, again = connected({ mock = Mock.updateDriver(mock) })
    T.eq(again:match("X%-DirectorLink%-Home: (%x+)"), old.home_id)
end

function tests.the_relay_learns_the_key_ids_after_every_change_and_nothing_else()
    local mock, connection = connected()
    local key = T.pair(mock)
    local frames = {}
    local sent = function()
        local keys = {}
        for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
            frames[#frames + 1] = frame
        end
        Harness.answers(Harness.clientFrames(connection.sent), keys)
        connection.sent = ""
        return keys
    end
    local afterPairing = sent()
    T.eq(#afterPairing, 1, "pairing made a key")
    local first = afterPairing[1]
    T.eq(#first, 1)
    T.truthy(first[1]:match("^%x+$"), "a key id")

    local created = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Tablet", role = "viewer" } }).json
    local afterCreate = sent()
    T.eq(#afterCreate[#afterCreate], 2)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. created.id, { key = key }).status, 204)
    local afterRevoke = sent()
    T.eq(#afterRevoke[#afterRevoke], 1, "the revoked key is gone from the list")
    T.eq(afterRevoke[#afterRevoke][1], first[1])

    ExecuteCommand("LUA_ACTION", { ACTION = "REVOKE_API_KEYS" })
    local afterAll = sent()
    T.eq(#afterAll[#afterAll], 0, "Revoke All API Keys: none")
    T.truthy(#frames >= 4, "the frames were looked at")
    for _, frame in ipairs(frames) do
        T.notContains(frame.payload, "Tablet", "names never go to the relay")
        T.notContains(frame.payload, "viewer", "nor roles")
        T.notContains(frame.payload, "ak_", "nor keys")
    end
end

function tests.a_key_store_that_could_not_be_read_is_never_announced_as_empty()
    local mock = Mock.startDriver(nil, nil, nil, function(fresh)
        fresh.persist["directorlink_api_key_hashes"] = "json:{not json"
    end)
    local _, connection, _, hello = connected({ mock = mock })
    for _, frame in ipairs(hello) do
        T.notContains(frame.payload, '"keys"', "no list that could be short")
    end
    -- Once a key is saved again the list is complete, and it is announced.
    connection.sent = ""
    T.pair(mock)
    local keys = {}
    Harness.answers(Harness.clientFrames(connection.sent), keys)
    T.eq(#keys, 1)
    T.eq(#keys[1], 1)
end

return tests
