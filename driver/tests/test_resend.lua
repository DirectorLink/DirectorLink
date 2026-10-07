-- A request the relay sends again after a lost connection runs once (1.10.0, ADR-072,
-- src/cloud/answers.lua, docs/RELAY.md "While the driver reconnects"): the same id gets the first
-- answer again, one still running is not run again and answers on the new connection, one the
-- driver never got runs; what is remembered is bounded in time, number and bytes.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Harness = require("relay_harness")

local tests = {}

local BINDING = Harness.BINDING
local DOOR = 70 -- the mock home's KNX door relay ("Main Door")

local function Lock()
    return require("src.cloud.lock")
end

local counter = 0

-- A driver paired on the home network (an admin key), Door Control on, remote access connected.
local function session(prepare)
    local mock = Mock.startDriver(nil, nil, nil, function(fresh)
        Properties["Door Control"] = "Enabled"
        if prepare then
            prepare(fresh)
        end
    end)
    local key = T.pair(mock)
    local _, connection, _, hello = Harness.connected({ mock = mock })
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json
    local home = T.http(mock, "GET", "/v1/remote", { key = key }).json.home_id
    return { mock = mock, connection = connection, key = key, keyId = me.id, home = home, hello = Json.decode(hello[1].payload) }
end

-- A request sealed by this device, as the relay passes it on (`id`: the relay's).
local function sealed(s, request, id)
    counter = counter + 1
    request.id = request.id or ("request-" .. counter)
    request.ts = request.ts or os.time()
    local lock = Lock().deviceKey(s.key)
    local envelope = Lock().seal(lock, s.home, s.keyId, "req", Json.encode(request))
    return { type = "e2e", id = id or ("relay-" .. counter), envelope = envelope }, lock
end

-- The relay sends `message`; returns the driver's frames (key id lists left out), decoded, and the
-- raw payloads.
local function deliver(s, message)
    s.connection.sent = ""
    ReceivedFromNetwork(BINDING, 443, Harness.serverFrame(1, Json.encode(message)))
    local frames = Harness.answers(Harness.clientFrames(s.connection.sent))
    s.connection.sent = ""
    local decoded, payloads = {}, {}
    for index, frame in ipairs(frames) do
        decoded[index] = Json.decode(frame.payload)
        payloads[index] = frame.payload
    end
    return decoded, payloads
end

-- The same frame again, as the relay resends it on the next connection.
local function again(message, times)
    local copy = {}
    for name, value in pairs(message) do
        copy[name] = value
    end
    copy.resent = times or 1
    return copy
end

local function opened(lock, reply)
    T.truthy(reply and reply.envelope, "a sealed answer: " .. Json.encode(reply or {}))
    return Json.decode(Lock().open(lock, reply.envelope, "res"))
end

local function closes(mock)
    local count = 0
    for _, command in ipairs(mock.commands) do
        if command.device == DOOR and command.command == "Close Relay" then
            count = count + 1
        end
    end
    return count
end

-- The reconnect the driver is waiting for (its one-shot timer).
local function pendingRetry(mock)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if not timer.fired and not timer.cancelled and not timer.repeating and timer.source:find("cloud/relay", 1, true) then
            return timer
        end
    end
    return nil
end

-- The driver's live timer that pings every second in a new connection's first seconds, if any.
local function watchTimer(mock)
    for index = #mock.timers, 1, -1 do
        local timer = mock.timers[index]
        if not timer.cancelled and timer.repeating and timer.delay == 1000 and timer.source:find("cloud/relay", 1, true) then
            return timer
        end
    end
    return nil
end

-- The connection is cut (Director reports it lost), and the driver connects again after waiting
-- `seconds` (checked: the relay sends a request again only within 10 s of getting it, so the wait
-- matters); `advance` (withClock), if given, moves the clock on by that wait. Returns the new hello.
local function blink(s, seconds, advance)
    OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
    local retry = pendingRetry(s.mock)
    T.truthy(retry, "a reconnect is waiting")
    T.eq(retry.delay, seconds * 1000, "the wait before the driver connects again")
    if advance then
        advance(seconds)
    end
    retry.fired = true
    retry.callback()
    s.connection.sent = ""
    OnConnectionStatusChanged(BINDING, 443, "ONLINE")
    local upgrade = s.connection.sent
    s.connection.sent = ""
    Harness.accept(upgrade)
    local frames = Harness.clientFrames(s.connection.sent)
    s.connection.sent = ""
    T.contains(s.mock.properties["Remote Status"], "Connected since")
    return Json.decode(frames[1].payload)
end

-- The relay log's entries with this message.
local function relayLog(message)
    local found = {}
    for _, entry in ipairs(require("src.core.log").query({ category = "relay" })) do
        if entry.message == message then
            found[#found + 1] = entry
        end
    end
    return found
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

-- ---- through the relay connection --------------------------------------------------------------

-- Runs `body(s)` with a session (session(prepare)) whose connection has been up an hour (the owner's
-- case: a cut every 20 to 60 minutes), on a clock the test moves (withClock): however long the test
-- itself takes, the driver connects again 1 s after a cut, and after the next two
-- (Relay.QUICK_IN_ROW).
local function upAnHour(prepare, body)
    withClock(function(advance)
        local s = session(prepare)
        advance(3600)
        body(s)
    end)
end

-- The owner pressed Open at the door just as the connection died: the controller opened it, its
-- answer was lost, and the relay sends the request again on the next connection. The door opens
-- once; the answer is the first one, byte for byte (not sealed again, so not run again), and the
-- sealed request's replay check never sees it a second time.
function tests.a_door_pulse_sent_again_gets_its_first_answer_and_opens_once()
    upAnHour(nil, function(s)
        local message, lock = sealed(s, { method = "POST", path = "/v1/relays/" .. DOOR .. "/pulse" })
        local first, firstPayloads = deliver(s, message)
        T.eq(#first, 1)
        T.eq(opened(lock, first[1]).status, 202)
        T.eq(closes(s.mock), 1, "the door opened")

        local hello = blink(s, 1)
        T.eq(hello.instance, s.hello.instance, "the same start of the driver")
        local second, secondPayloads = deliver(s, again(message))
        T.eq(#second, 1, "answered again")
        T.eq(secondPayloads[1], firstPayloads[1], "the first answer, as it was")
        T.eq(second[1].code, nil, "not REPLAYED")
        T.eq(closes(s.mock), 1, "the door opened once")

        -- However often it comes (the relay sends at most twice more), and even unmarked.
        T.eq(deliver(s, again(message, 2))[1].envelope.mac, first[1].envelope.mac)
        T.eq(deliver(s, message)[1].envelope.mac, first[1].envelope.mac)
        T.eq(closes(s.mock), 1)
        local entries = relayLog("a request the relay sent again")
        T.eq(#entries, 3)
        T.eq(entries[1].data.outcome, "answered again")
        T.eq(entries[1].data.type, "e2e")
        T.eq(entries[1].data.resent, 1)
    end)
end

-- Another relay id with the same sealed request is still a replay: the answer cache goes by the
-- relay's id, the replay check by the device's request id.
function tests.the_same_sealed_request_under_another_relay_id_is_still_refused()
    local s = session()
    local message = sealed(s, { method = "POST", path = "/v1/relays/" .. DOOR .. "/pulse" })
    T.truthy(deliver(s, message)[1].envelope)
    local other = again(message)
    other.id = "relay-other"
    T.eq(deliver(s, other)[1].code, "REPLAYED")
    T.eq(closes(s.mock), 1)
end

-- The press never reached the controller (the 21:01 case): the request sent again runs.
function tests.a_request_never_received_runs_when_sent_again()
    upAnHour(nil, function(s)
        blink(s, 1)
        local message, lock = sealed(s, { method = "POST", path = "/v1/relays/" .. DOOR .. "/pulse" })
        local reply = deliver(s, again(message))
        T.eq(#reply, 1)
        T.eq(opened(lock, reply[1]).status, 202)
        T.eq(closes(s.mock), 1, "the door opened, once")
        local entries = relayLog("a request the relay sent again")
        T.eq(entries[#entries].data.outcome, "new")
    end)
end

-- A camera picture was still on its way when the request came again: nothing more is asked of the
-- camera, and the answer goes on the connection there is when it is ready.
function tests.a_request_still_running_is_not_run_again_and_answers_on_the_new_connection()
    upAnHour(function(fresh)
        fresh.httpDeferred = true
    end, function(s)
        local message, lock = sealed(s, { method = "GET", path = "/v1/cameras/60/snapshot" })
        T.eq(#deliver(s, message), 0, "the picture is on its way")
        T.eq(#s.mock.httpQueue, 1, "one picture asked for")
        blink(s, 1)
        T.eq(#deliver(s, again(message)), 0, "still running: nothing now")
        T.eq(#s.mock.httpQueue, 1, "and the camera is not asked again")
        Mock.deliverHttp(s.mock)
        local frames = Harness.answers(Harness.clientFrames(s.connection.sent))
        s.connection.sent = ""
        T.eq(#frames, 1, "the answer goes on the new connection")
        local reply = Json.decode(frames[1].payload)
        T.eq(reply.id, message.id)
        local answer = opened(lock, reply)
        T.eq(answer.status, 200)
        T.eq(Base64.decode(answer.body_base64):sub(1, 2), "\255\216", "a JPEG")
        -- Asked once more, it is the same answer.
        T.eq(deliver(s, again(message, 2))[1].envelope.mac, reply.envelope.mac)
    end)
end

-- The answer was ready while the connection was down (nothing could carry it): it is given when
-- the request comes again.
function tests.an_answer_ready_while_disconnected_is_given_when_sent_again()
    upAnHour(function(fresh)
        fresh.httpDeferred = true
    end, function(s)
        local message, lock = sealed(s, { method = "GET", path = "/v1/cameras/60/snapshot" })
        deliver(s, message)
        OnConnectionStatusChanged(BINDING, 443, "OFFLINE")
        s.connection.sent = ""
        Mock.deliverHttp(s.mock)
        T.eq(s.connection.sent, "", "no connection to carry it")
        -- The driver connects again (blink's own cut is a second one: still the same start).
        blink(s, 1)
        local reply = deliver(s, again(message))
        T.eq(#reply, 1)
        T.eq(opened(lock, reply[1]).status, 200)
        T.eq(#s.mock.httpQueue, 0, "the camera was asked once")
    end)
end

-- An answer too large to keep (a picture over 16 KiB): the request is remembered as done, and
-- coming again it gets ANSWER_NOT_KEPT, which the relay turns into 502 HOME_DISCONNECTED as before.
function tests.a_request_whose_answer_was_too_large_answers_not_kept_and_never_runs_again()
    local asked = 0
    upAnHour(function(fresh)
        fresh.http = function(request)
            if request.url:find("192.0.2.21", 1, true) then -- the Driveway camera's address
                asked = asked + 1
                return { code = 200, headers = { ["Content-Type"] = "image/jpeg" }, body = "\255\216" .. string.rep("x", 100000) .. "\255\217" }
            end
            return false
        end
    end, function(s)
        local message, lock = sealed(s, { method = "GET", path = "/v1/cameras/60/snapshot" })
        local first = deliver(s, message)
        T.eq(opened(lock, first[1]).status, 200)
        T.truthy(#Base64.decode(opened(lock, first[1]).body_base64) > 100000, "the large picture")
        local before = asked
        T.truthy(before >= 1, "the camera was asked")
        blink(s, 1)
        local reply = deliver(s, again(message))
        T.eq(#reply, 1)
        T.same(reply[1], { type = "e2e", id = message.id, ok = false, code = "ANSWER_NOT_KEPT" })
        T.eq(asked, before, "not run again")
        local _, kept, bytes = require("src.cloud.answers").counts()
        T.eq(kept, 0)
        T.eq(bytes, 0)
    end)
end

-- A scene link's run, a claim and a join: each runs once, and the same id gets the same answer.
function tests.links_claims_and_joins_sent_again_run_once()
    upAnHour(nil, function(s)
        local scene = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Good night", steps = { { type = "lights", device_ids = { 20, 21 }, set = { on = false } } } } })
        T.eq(scene.status, 201, scene.body)
        local link = T.http(s.mock, "POST", "/v1/scenes/" .. scene.json.id .. "/link", { key = s.key }).json
        local run = { type = "link", id = "link-1", link = link.link_id, secret = link.secret }
        local before = #s.mock.commands
        local ran = deliver(s, run)[1]
        T.eq(ran.result, "ran")
        local sent = #s.mock.commands - before
        T.truthy(sent >= 2, "the scene switched its lights")
        blink(s, 1)
        T.same(deliver(s, again(run))[1], ran)
        T.eq(#s.mock.commands - before, sent, "the scene ran once")

        local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key }).json
        local claimed = deliver(s, { type = "claim", id = "claim-1", token = claim.claim_token })[1]
        T.eq(claimed.ok, true)
        T.eq(deliver(s, { type = "claim", id = "claim-1", token = claim.claim_token, resent = 1 })[1].ok, true, "the same answer, though the token is used up")
        T.eq(deliver(s, { type = "claim", id = "claim-2", token = claim.claim_token })[1].ok, false, "used once")

        local invitation = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).json
        local keysBefore = #T.http(s.mock, "GET", "/v1/api-keys", { key = s.key }).json.items
        local lock = Lock().invitationKey(invitation.secret)
        local request = { id = "join-1", ts = os.time(), method = "POST", path = "/v1/auth/join", body = { name = "Phone" } }
        local join = { type = "join", id = "relay-join-1", invitation = invitation.id, envelope = Lock().seal(lock, s.home, invitation.id, "req", Json.encode(request)) }
        local joined, joinedPayloads = deliver(s, join)
        T.eq(joined[1].ok, true)
        blink(s, 1)
        local rejoined, rejoinedPayloads = deliver(s, again(join))
        T.eq(rejoinedPayloads[1], joinedPayloads[1], "the same new key, sealed as it was")
        T.eq(#T.http(s.mock, "GET", "/v1/api-keys", { key = s.key }).json.items, keysBefore + 1, "one new key")
    end)
end

-- A driver that restarted remembers nothing, so the relay sends again only to the start of the
-- driver its hello names (`instance`). Were a sealed request sent to a restarted driver all the
-- same, it would be refused: it was sealed before that start (STALE). The door never opens twice.
function tests.a_restarted_driver_is_a_new_instance_and_refuses_what_was_sealed_before()
    withClock(function(advance)
        local s = session()
        advance(3600)
        local message = sealed(s, { method = "POST", path = "/v1/relays/" .. DOOR .. "/pulse" })
        T.truthy(deliver(s, message)[1].envelope)
        T.eq(closes(s.mock), 1)
        T.eq(blink(s, 1).instance, s.hello.instance, "a reconnect keeps it")
        -- Updated in Composer a few seconds later: the driver starts again.
        advance(5)
        local updated = Mock.updateDriver(s.mock)
        local _, connection, _, hello = Harness.connected({ mock = updated })
        local newHello = Json.decode(hello[1].payload)
        T.truthy(type(newHello.instance) == "string" and newHello.instance ~= s.hello.instance, "a new start, a new instance")
        local refused = Harness.relayRequest(updated, connection, again(message))
        T.eq(refused.code, "STALE", "sealed before this start")
        T.eq(closes(updated), 0, "not opened again")
    end)
end

-- The home's route to Cloudflare flips again right after a cut (it was seen to flip every few
-- seconds), and the connection that came back is lost within seconds too. After a stable
-- connection, the driver connects again after 1 s for two such connections in a row, then goes on
-- with the backoff; a connection up a minute starts a new row. (Review of 1.10.0: a second blink
-- waited 5 s, too late for the relay's second resend.)
function tests.a_route_that_flips_again_is_followed_at_once_twice_in_a_row()
    withClock(function(advance)
        local s = session()
        advance(3600)
        blink(s, 1, advance)
        advance(3)
        blink(s, 1, advance)
        advance(3)
        blink(s, 1, advance)
        advance(3)
        blink(s, 5, advance)
        advance(60)
        blink(s, 1, advance)
        advance(3)
        blink(s, 1, advance)
    end)
end

-- The relay sent a door's press into the cut connection, and again into the next one, which the
-- route's next flip cut before the press got there. A connection that follows a lost one pings
-- every second at first, so the driver finds the second cut within a second (Director refuses the
-- ping) and is back 1 s later, in time for the relay's second resend; the door opens once.
function tests.a_second_cut_right_after_the_first_is_found_within_a_second()
    withClock(function(advance)
        local s = session()
        T.eq(watchTimer(s.mock), nil, "a first connection pings every 5 s")
        advance(3600)
        local message, lock = sealed(s, { method = "POST", path = "/v1/relays/" .. DOOR .. "/pulse" })
        blink(s, 1, advance)
        local watch = watchTimer(s.mock)
        T.truthy(watch, "a ping every second")
        s.connection.sent = ""
        watch.callback()
        T.eq(Harness.clientFrames(s.connection.sent)[1].payload, "ping")
        -- That ping is refused: the route flipped again, and the relay's resend never arrived.
        local hello = blink(s, 1, advance)
        T.eq(hello.instance, s.hello.instance)
        local reply = deliver(s, again(message, 2))
        T.eq(opened(lock, reply[1]).status, 202)
        T.eq(closes(s.mock), 1, "the door opened once")
        -- Four pings a second apart, then only the keep-alive's every 5 s.
        watch = watchTimer(s.mock)
        for _ = 1, 4 do
            watch.callback()
        end
        T.truthy(watch.cancelled)
        T.eq(watchTimer(s.mock), nil)
    end)
end

-- ---- what is remembered ----------------------------------------------------------------------

local function answersModule()
    Mock.startDriver()
    local Answers = require("src.cloud.answers")
    Answers.reset()
    return Answers
end

-- A runner that answers at once, counting its runs; `size`: the answer's body length.
local function runner(runs, size)
    return function(message, reply)
        runs[message.id] = (runs[message.id] or 0) + 1
        reply({ type = "e2e", id = message.id, envelope = { ct = string.rep("a", size or 10) } })
        return true
    end
end

local function collect(list)
    return function(text)
        list[#list + 1] = text
    end
end

function tests.requests_are_remembered_two_minutes_whatever_the_clock_does()
    withClock(function(advance)
        local Answers = answersModule()
        local runs, sent = {}, {}
        Answers.handle({ type = "e2e", id = "a" }, collect(sent), runner(runs))
        T.eq(#sent, 1)

        -- The clock set an hour forward: Answers counts keep-alive ticks, so "a" is still remembered.
        advance(3600)
        Answers.tick()
        local handled, what = Answers.handle({ type = "e2e", id = "a", resent = 1 }, collect(sent), runner(runs))
        T.eq(handled, true)
        T.eq(what, "answered again")
        T.eq(runs.a, 1)
        T.eq(sent[2], sent[1])
        -- Set back an hour: no different.
        advance(-3600)
        Answers.tick()
        T.eq(select(2, Answers.handle({ type = "e2e", id = "a", resent = 1 }, collect(sent), runner(runs))), "answered again")

        -- Two minutes of keep-alive ticks (5 s each) later, it is forgotten.
        for _ = 1, 24 do
            advance(5)
            Answers.tick()
        end
        T.eq(Answers.counts(), 0, "forgotten after 120 s")
        Answers.handle({ type = "e2e", id = "a" }, collect(sent), runner(runs))
        T.eq(runs.a, 2, "the relay never sends one again that late: a new request")
    end)
end

-- A clock that steps back and forth while the keep-alive ticks (each step 30 s, four times each way
-- in 20 s) does not age a request: a door's press sent again is answered from memory, not run again
-- (review of 1.10.0: the clock's steps forward used to count again after each step back). And
-- without ticks (the connection down), nothing is forgotten, however far the clock moves.
function tests.a_clock_stepping_back_and_forth_does_not_make_a_request_forgotten()
    withClock(function(advance)
        local Answers = answersModule()
        local runs, sent = {}, {}
        Answers.handle({ type = "e2e", id = "door" }, collect(sent), runner(runs))
        for step = 1, 8 do
            advance(step % 2 == 1 and -30 or 30)
            Answers.tick()
        end
        T.eq(Answers.counts(), 1, "still remembered")
        T.eq(select(2, Answers.handle({ type = "e2e", id = "door", resent = 1 }, collect(sent), runner(runs))), "answered again")
        T.eq(runs.door, 1, "the door opened once")

        advance(3 * 3600)
        T.eq(select(2, Answers.handle({ type = "e2e", id = "door", resent = 2 }, collect(sent), runner(runs))), "answered again")
        T.eq(runs.door, 1)
    end)
end

function tests.answers_are_kept_within_their_count_and_bytes_and_large_ones_not_at_all()
    local Answers = answersModule()
    local runs, sent = {}, {}
    -- More than 64 answers of one size: the oldest go first; their requests are still remembered
    -- as done.
    for index = 1, 70 do
        Answers.handle({ type = "e2e", id = string.format("n%02d", index) }, collect(sent), runner(runs))
    end
    local requests, kept = Answers.counts()
    T.eq(requests, 70)
    T.eq(kept, 64)
    T.eq(select(2, Answers.handle({ type = "e2e", id = "n01", resent = 1 }, collect(sent), runner(runs))), "answer not kept")
    T.same(Json.decode(sent[#sent]), { type = "e2e", id = "n01", ok = false, code = "ANSWER_NOT_KEPT" })
    T.eq(runs.n01, 1, "never run twice")
    T.eq(select(2, Answers.handle({ type = "e2e", id = "n70", resent = 1 }, collect(sent), runner(runs))), "answered again")

    -- 512 KB together: answers of 15 KB, only the newest 34 stay.
    Answers.reset()
    for index = 1, 40 do
        Answers.handle({ type = "e2e", id = string.format("b%02d", index) }, collect(sent), runner(runs, 15 * 1024))
    end
    local _, keptBig, bytes = Answers.counts()
    T.eq(keptBig, 34)
    T.truthy(bytes <= 512 * 1024, "within the budget: " .. bytes)
    T.eq(select(2, Answers.handle({ type = "e2e", id = "b06", resent = 1 }, collect(sent), runner(runs))), "answer not kept")
    T.eq(select(2, Answers.handle({ type = "e2e", id = "b07", resent = 1 }, collect(sent), runner(runs))), "answered again")

    -- Over 16 KiB (a camera picture, a long list): not kept at all.
    Answers.handle({ type = "e2e", id = "huge" }, collect(sent), runner(runs, 17 * 1024))
    T.eq(select(2, Answers.handle({ type = "e2e", id = "huge", resent = 1 }, collect(sent), runner(runs))), "answer not kept")
    T.eq(runs.huge, 1)
end

-- A press's answer stays while camera pictures (27 to 60 KB sealed) and lists fill the budget: the
-- pictures are not kept, and the largest answers go first (review of 1.10.0: eight pictures used to
-- push a press's answer out, and its resend got 502).
function tests.pictures_and_lists_do_not_push_out_a_press_answer()
    local Answers = answersModule()
    local runs, sent = {}, {}
    Answers.handle({ type = "e2e", id = "press" }, collect(sent), runner(runs, 300))
    for index = 1, 16 do
        Answers.handle({ type = "e2e", id = "picture" .. index }, collect(sent), runner(runs, (27 + 2 * index) * 1024))
    end
    for index = 1, 50 do
        Answers.handle({ type = "e2e", id = "list" .. index }, collect(sent), runner(runs, 12 * 1024))
    end
    local _, kept, bytes = Answers.counts()
    T.truthy(bytes <= Answers.MAX_BYTES and kept <= Answers.MAX_ANSWERS, "within the budget")
    T.eq(select(2, Answers.handle({ type = "e2e", id = "press", resent = 1 }, collect(sent), runner(runs))), "answered again")
    T.eq(runs.press, 1)

    -- Answers older than the relay could still ask for go first, whatever their size.
    for _ = 1, 6 do
        Answers.tick()
    end
    Answers.handle({ type = "e2e", id = "small" }, collect(sent), runner(runs, 100))
    for index = 1, 64 do
        Answers.handle({ type = "e2e", id = "new" .. index }, collect(sent), runner(runs, 200))
    end
    T.eq(select(2, Answers.handle({ type = "e2e", id = "small", resent = 1 }, collect(sent), runner(runs))), "answered again")
    T.eq(select(2, Answers.handle({ type = "e2e", id = "press", resent = 1 }, collect(sent), runner(runs))), "answer not kept",
        "older than 30 s: the relay no longer sends it again")
end

-- Beyond MAX_REQUESTS the oldest request is forgotten before its two minutes. A request sent again
-- that the driver does not know may then be one of those, when one forgotten had come within the
-- last 30 s (the relay sends again only within 10 s): it is answered ANSWER_NOT_KEPT rather than
-- run. Older ones forgotten do not count (review of 1.10.0: a busy home switched resending off for
-- two minutes); a new request (not sent again) always runs.
function tests.a_request_sent_again_after_recent_ones_were_forgotten_is_never_run()
    local Answers = answersModule()
    local limit = Answers.MAX_REQUESTS
    Answers.MAX_REQUESTS = 3
    local ok, err = pcall(function()
        local runs, sent = {}, {}
        Answers.handle({ type = "link", id = "l1" }, collect(sent), runner(runs))
        for _ = 1, 7 do
            Answers.tick()
        end
        for index = 2, 4 do
            Answers.handle({ type = "link", id = "l" .. index }, collect(sent), runner(runs))
        end
        T.eq(Answers.counts(), 3, "l1 forgotten, 35 s after it came")
        T.eq(select(2, Answers.handle({ type = "link", id = "never-got", resent = 1 }, collect(sent), runner(runs))), "new")
        T.eq(runs["never-got"], 1, "a press that never reached the driver runs when sent again")

        Answers.handle({ type = "link", id = "l5" }, collect(sent), runner(runs))
        local handled, what = Answers.handle({ type = "link", id = "l2", resent = 1 }, collect(sent), runner(runs))
        T.eq(handled, true)
        T.eq(what, "forgotten")
        T.eq(runs.l2, 1, "not run again")
        T.same(Json.decode(sent[#sent]), { type = "link_result", id = "l2", ok = false, code = "ANSWER_NOT_KEPT" })
        Answers.handle({ type = "link", id = "l9" }, collect(sent), runner(runs))
        T.eq(runs.l9, 1, "a new request runs")

        for _ = 1, 6 do
            Answers.tick()
        end
        T.eq(select(2, Answers.handle({ type = "link", id = "late", resent = 1 }, collect(sent), runner(runs))), "new",
            "30 s later, nothing forgotten could still come again")
    end)
    Answers.MAX_REQUESTS = limit
    if not ok then
        error(err, 0)
    end
end

-- Only what the relay may send again is remembered; anything else goes to remote.lua as before.
function tests.other_messages_pass_through()
    local Answers = answersModule()
    local seen = {}
    local result = Answers.handle({ type = "accounts", id = "x" }, function() end, function(message)
        seen[#seen + 1] = message.type
        return true
    end)
    T.eq(result, true)
    T.eq(Answers.handle({ type = "e2e" }, function() end, function()
        return "unchanged"
    end), "unchanged", "no id: as before")
    T.same(seen, { "accounts" })
    T.eq(Answers.counts(), 0)
end

return tests
