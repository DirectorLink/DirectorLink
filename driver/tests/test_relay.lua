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

-- The last live timer of this delay, leaving out the scheduler's minute timer: its delay depends on
-- the wall clock (exactly 30 s when a test starts at second 31).
local function lastTimer(mock, delay)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if timer.delay == delay and not timer.cancelled and not timer.fired
            and not (timer.source or ""):find("core/scheduler", 1, true) then
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

-- The certificates of a CA file as OpenSSL (Director's TLS) reads it: line by line, whatever the
-- line endings (a Windows checkout can have CRLF), with trailing whitespace dropped. Returns the
-- SHA-256 of each block by the "# label" line above it, and the number of blocks; or nil and why,
-- for any BEGIN or END line that is not a plain certificate's (OpenSSL also loads TRUSTED
-- CERTIFICATE blocks) and anything in a block that is not base64.
local function certificates(text)
    local lines = {}
    for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("[%c ]+$", ""))
    end
    local found, count, label, body = {}, 0, nil, nil
    for index, line in ipairs(lines) do
        local marker = line:upper():find("-----BEGIN", 1, true) or line:upper():find("-----END", 1, true)
        if body == nil then
            if line == "-----BEGIN CERTIFICATE-----" then
                body, label = {}, (lines[index - 1] or ""):match("^# (.+)$") or ""
            elseif marker then
                return nil, "not a plain certificate block: " .. line
            end
        elseif line == "-----END CERTIFICATE-----" then
            count = count + 1
            found[label] = Base64.toHex(sha256(Base64.decode(table.concat(body))))
            body = nil
        elseif marker or not line:match("^[%w+/=]+$") then
            return nil, "not base64 inside a certificate block: " .. line
        else
            body[#body + 1] = line
        end
    end
    if body then
        return nil, "a certificate block does not end"
    end
    return found, count
end

-- The certificate under each label is that root (SHA-256 of its DER bytes, as pinned in
-- scripts/check_package.py), not only its name: today's chain ends at GTS Root R4.
local PINNED_ROOTS = {
    ["ISRG Root X1"] = "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6",
    ["ISRG Root X2"] = "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470",
    ["GTS Root R1"] = "d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf",
    ["GTS Root R3"] = "34d8a73ee208d9bcdb0d956520934b4e40e69482596e8b6f73c8426b010a6f48",
    ["GTS Root R4"] = "349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d",
    ["SSL.com TLS RSA Root CA 2022"] = "8faf7d2e2cb4709bb8e0b33666bf75a5dd45b5de480f8ea8d4bfe6bebc17f2ed",
    ["SSL.com TLS ECC Root CA 2022"] = "c32ffd9f46f936d16c3673990959434b9ad60aafbb9e7cf33654f144cc1ba143",
    ["SSL.com Root Certification Authority RSA"] = "85666a562ee0be5ce925c1d8890a6f76a87ec16d4d7d5f29ea7419cf20123b69",
    ["SSL.com Root Certification Authority ECC"] = "3417bb06cc6007da1b961c920b8ab4ce3fad820e4aa30b9acbc4a74ebdcebc65",
}

local function packagedRoots()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    return mock, mock.network[BINDING].caCertificates
end

-- Without VERIFY_MODE, Director checks no certificate at all.
function tests.the_relay_certificate_is_checked_against_the_packaged_roots()
    local mock, roots = packagedRoots()
    local options = mock.network[BINDING].options
    T.eq(options.VERIFY_MODE, "peer")
    T.eq(options.CACERTFILE, "./certs/directorlink-roots.pem")
    T.truthy(roots, "the CA file is in the driver package")
    T.notContains(roots, "PRIVATE KEY")
    local found, count = certificates(roots)
    T.truthy(found, count)
    T.eq(count, 9, "Let's Encrypt, Google Trust Services and SSL.com roots, nothing else")
    for root, fingerprint in pairs(PINNED_ROOTS) do
        T.eq(found[root], fingerprint, root)
    end
end

-- Line endings do not change what is read, and a block OpenSSL would load but a narrower reading
-- would miss (a TRUSTED CERTIFICATE, a trailing space) is never skipped.
function tests.the_roots_are_read_as_openssl_reads_them()
    local _, roots = packagedRoots()
    local found, count = certificates((roots:gsub("\r?\n", "\r\n")))
    T.eq(count, 9, "with CRLF")
    T.eq(found["GTS Root R4"], PINNED_ROOTS["GTS Root R4"])
    for _, extra in ipairs({
        "-----BEGIN TRUSTED CERTIFICATE----- \nAAAA\n-----END TRUSTED CERTIFICATE-----\n",
        "-----BEGIN CERTIFICATE----- \nAAAA\n-----END CERTIFICATE-----\n",
        -- A key, its label split so that no scanner takes this file for one.
        "-----BEGIN " .. "PRIVATE KEY-----\nAAAA\n-----END " .. "PRIVATE KEY-----\n",
    }) do
        local all, extraCount = certificates(roots .. "\n# Extra\n" .. extra)
        T.truthy(not all or extraCount ~= 9, "counted: " .. extra:match("^[^\n]+"))
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

-- Runs `body(advance)` with os.time moved on by advance(seconds), then puts the clock back.
local function withClock(body)
    local realTime = os.time
    local offset = 0
    os.time = function(date)
        if date then
            return realTime(date)
        end
        return realTime() + offset
    end
    local ok, err = pcall(body, function(seconds)
        offset = offset + seconds
    end)
    os.time = realTime
    if not ok then
        error(err, 0)
    end
end

local function fire(timer)
    T.truthy(timer, "a timer is waiting")
    timer.fired = true
    timer.callback()
end

-- The relay log's last entry with this message, or nil; and how many there are.
local function relayLog(message)
    local found, count = nil, 0
    for _, entry in ipairs(require("src.core.log").query({ category = "relay" })) do
        if entry.message == message then
            found, count = entry, count + 1
        end
    end
    return found, count
end

local function near(actual, expected, what)
    T.truthy(type(actual) == "number" and actual >= expected and actual <= expected + 2,
        what .. ": " .. tostring(actual) .. ", expected " .. expected)
end

-- Director makes the new connection; the relay accepts it.
local function online(connection)
    connection.sent = ""
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    Harness.accept(connection.sent)
    connection.sent = ""
end

function tests.keepalive_pings_and_silence_reconnects()
    withClock(function(advance)
        local mock, connection = connected()
        local keepalive = lastTimer(mock, 25000)
        T.truthy(keepalive and keepalive.repeating, "a repeating 25 s keep-alive")
        keepalive.callback()
        T.eq(clientFrames(connection.sent)[1].payload, "ping")
        connection.sent = ""

        advance(120)
        keepalive.callback()
        T.eq(connection.disconnects >= 1, true, "a silent connection is dropped")
        local close = clientFrames(connection.sent)[1]
        T.eq(close.opcode, 8, "with a close frame, in case the relay still hears it")
        T.eq(close.payload, bigEndian(1000, 2) .. "no answer", "saying why, for the relay's log")
        -- It had been up for two minutes: it is tried again at once.
        T.eq(mock.properties["Remote Status"], "Reconnecting in 1 s (no answer)")
        local entry = relayLog("no answer from the relay; reconnecting")
        T.eq(entry.level, "warn")
        near(entry.data.heard_s, 120, "heard_s")
        T.eq(entry.data.retry_s, 1)
    end)
end

-- Director's own monitoring polls the connection and drops it when no data comes back in its
-- window, which up to 1.4.0 ended the relay connection every 10 to 40 minutes: it stays off, and
-- the driver's keep-alive checks the connection instead.
function tests.director_does_not_monitor_the_relay_connection()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local options = mock.network[BINDING].options
    T.eq(options.MONITOR_CONNECTION, false)
    T.eq(options.KEEP_ALIVE, true, "TCP keep-alive stays on")
    T.eq(options.KEEP_CONNECTION, false, "the driver reconnects itself, with its backoff")
end

-- If Director polls all the same, a ping makes the relay answer at once.
function tests.a_poll_from_director_is_answered_with_a_ping()
    local _, connection = connected()
    OnPoll(BINDING, 443)
    local frames = clientFrames(connection.sent)
    T.eq(#frames, 1)
    T.eq(frames[1].payload, "ping")
    connection.sent = ""
    OnPoll(6002, 443)
    T.eq(connection.sent, "", "another binding's poll is not the relay's")
end

function tests.a_stable_connection_that_is_lost_comes_back_at_once_and_says_why()
    withClock(function(advance)
        local mock, connection = connected()
        advance(600)
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        T.eq(mock.properties["Remote Status"], "Reconnecting in 1 s (connection lost)")
        local closed = relayLog("relay connection closed")
        T.eq(closed.level, "info")
        T.eq(closed.data.reason, "connection lost")
        T.eq(closed.data.attempt, 1)
        T.eq(closed.data.retry_s, 1)
        near(closed.data.up_s, 600, "up_s")
        near(closed.data.heard_s, 600, "heard_s (no pong since it opened)")

        fire(lastTimer(mock, 1000))
        T.eq(connection.connects, 2)
        T.eq(mock.properties["Remote Status"], "Connecting...")
        -- That attempt fails too: the backoff follows.
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        T.eq(mock.properties["Remote Status"], "Reconnecting in 5 s (connection lost)")
        local failed = relayLog("relay connection attempt failed")
        T.eq(failed.data.attempt, 2)
        T.eq(failed.data.retry_s, 5)

        advance(6)
        fire(lastTimer(mock, 5000))
        online(connection)
        local back = relayLog("connected to the relay")
        T.eq(back.data.attempts, 2)
        near(back.data.down_s, 6, "down_s")
        T.truthy(mock.properties["Remote Status"]:match("^Connected since %d%d:%d%d %- home %x+ %- last drop %d%d:%d%d %(connection lost%)$"),
            mock.properties["Remote Status"])
    end)
end

function tests.a_connection_lost_soon_after_it_opens_keeps_the_backoff()
    local mock, connection = connected()
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    -- Two reports of one loss: one reconnect.
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    T.eq(mock.properties["Remote Status"], "Reconnecting in 5 s (connection lost)")
    local _, count = relayLog("relay connection closed")
    T.eq(count, 1, "logged once")
    local waiting = 0
    for _, timer in ipairs(mock.timers) do
        if timer.delay == 5000 and not timer.fired and not timer.cancelled and not (timer.source or ""):find("core/scheduler", 1, true) then
            waiting = waiting + 1
        end
    end
    T.eq(waiting, 1, "one retry waits")

    fire(lastTimer(mock, 5000))
    online(connection)
    -- Lost again as soon as it opened: the backoff goes on rather than starting again.
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    T.eq(mock.properties["Remote Status"], "Reconnecting in 10 s (connection lost)")
end

function tests.the_wait_after_the_relay_closes_depends_on_its_code()
    local cases = {
        -- Another connection with this identity took over: give it time.
        { code = 4000, reason = "replaced", up = 600, wait = 30 },
        -- The owner approved a new secret: try it at once.
        { code = 4001, reason = "secret replaced", up = 0, wait = 1 },
        -- The relay restarted (a deploy): at once after a stable connection, else the backoff.
        { code = 1012, reason = "restart", up = 600, wait = 1 },
        { code = 1012, reason = "restart", up = 0, wait = 5 },
    }
    for _, case in ipairs(cases) do
        withClock(function(advance)
            local mock, connection = connected()
            advance(case.up)
            ReceivedFromNetwork(BINDING, 443, serverFrame(8, bigEndian(case.code, 2) .. case.reason))
            T.eq(clientFrames(connection.sent)[1].opcode, 8, "close echoed")
            T.eq(mock.properties["Remote Status"],
                "Reconnecting in " .. case.wait .. " s (closed by the relay (" .. case.code .. " " .. case.reason .. "))")
            T.eq(relayLog("relay connection closed").data.code, case.code)
        end)
    end
end

-- Director reports a connection's state without saying which connection: the OFFLINE for one the
-- driver closed may arrive after it started the next.
function tests.an_offline_for_the_connection_it_closed_does_not_end_the_next_attempt()
    withClock(function(advance)
        local mock, connection = connected()
        advance(600)
        ReceivedFromNetwork(BINDING, 443, serverFrame(8, bigEndian(1012, 2)))
        T.eq(connection.disconnects, 1)
        fire(lastTimer(mock, 1000))
        T.eq(connection.connects, 2)
        -- Only now does Director report the old connection closed.
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        T.eq(mock.properties["Remote Status"], "Connecting...", "the attempt goes on")
        T.eq(relayLog("relay connection attempt failed"), nil)
        online(connection)
        T.contains(mock.properties["Remote Status"], "Connected since")
        -- A real loss afterwards is still one.
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        T.contains(mock.properties["Remote Status"], "Reconnecting in")
    end)
end

function tests.a_late_connection_and_stale_data_do_not_disturb_the_next_attempt()
    local mock = Mock.startDriver()
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    local connection = mock.network[BINDING]
    fire(lastTimer(mock, 30000))
    T.eq(connection.disconnects, 1, "the attempt is given up")
    -- The connection Director was still making comes up after all: no upgrade, and it is closed.
    connection.sent = ""
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    T.eq(connection.sent, "", "no upgrade request")
    T.eq(connection.disconnects, 2, "Director is asked to close it")
    T.eq(mock.properties["Remote Status"], "Reconnecting in 5 s (no connection within 30 s)")
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    T.eq(mock.properties["Remote Status"], "Reconnecting in 5 s (no connection within 30 s)")

    fire(lastTimer(mock, 5000))
    T.eq(connection.connects, 2)
    -- Bytes of the old connection arrive late: they are not the relay's answer to this one.
    ReceivedFromNetwork(BINDING, 443, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
    T.eq(mock.properties["Remote Status"], "Connecting...")
    online(connection)
    T.contains(mock.properties["Remote Status"], "Connected since")
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
