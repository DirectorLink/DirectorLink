-- Ask to open (ADR-058, src/core/ask_links.lua, src/api/handlers/ask_links.lua): a link bound to one
-- door and to the key (and person) that made it. Only someone who may open the door makes one, with
-- Door Control on. Its run opens nothing: it sends the person's devices that have alerts on a sealed
-- request (kind open_request), and only a pulse from one of those devices with the request's id, its
-- own key and the usual checks opens the door, within two minutes and once. Revoked as scene links
-- are; every step in History.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Harness = require("relay_harness")

local tests = {}

local STORE = "directorlink_ask_links"
local GATE = 70 -- "Main Door", in the Kitchen (c4mock)

-- The driver's messages to the relay since the last look, without its key id lists.
local function sent(connection)
    local messages = {}
    for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" and message.type ~= "keys" then
            messages[#messages + 1] = message
        end
    end
    connection.sent = ""
    return messages
end

local function ofType(messages, kind)
    local found = {}
    for _, message in ipairs(messages) do
        if message.type == kind then
            found[#found + 1] = message
        end
    end
    return found
end

local function count(map)
    local total = 0
    for _ in pairs(map or {}) do
        total = total + 1
    end
    return total
end

local function hmacHex(key, data)
    return C4:HMAC("SHA256", key, data, { key_encoding = "HEX", data_encoding = "NONE", return_encoding = "HEX" }):lower()
end

-- Opens `sealed` as the device of `apiKey` does (its service worker).
local function open(apiKey, home, keyId, sealed)
    local Lock = require("src.cloud.lock")
    local alertKey = require("src.cloud.alerts").alertKey(Lock.deviceKey(apiKey))
    local enc, mac = hmacHex(alertKey, "enc"), hmacHex(alertKey, "mac")
    local expected = Base64.encode(Base64.fromHex(hmacHex(mac, "alert v1|" .. home .. "|" .. keyId .. "|" .. sealed.iv .. "|" .. sealed.ct)))
    T.eq(sealed.mac, expected, "sealed to this key, for this home")
    local plaintext = C4:Decrypt("AES-256-CBC", enc, Base64.toHex(Base64.decode(sealed.iv)), Base64.toHex(Base64.decode(sealed.ct)), {
        key_encoding = "HEX",
        iv_encoding = "HEX",
        data_encoding = "HEX",
        return_encoding = "NONE",
        padding = true,
    })
    return Json.decode(plaintext)
end

-- A connected, linked home with Door Control on and the clock in the test's hands; Dana pairs an
-- admin phone. Options: doors = false (Door Control off), remote = false (no relay).
local function start(options)
    options = options or {}
    local mock = Mock.startDriver(nil, nil, nil, function()
        Properties["Door Control"] = options.doors == false and "Disabled" or "Enabled"
    end)
    local connection, home
    if options.remote ~= false then
        local _
        _, connection = Harness.connected({ mock = mock })
        home = require("src.cloud.relay").identity().home_id
    end
    local Clock = require("src.core.clock")
    local clock = { now = os.time() }
    Clock.now = function()
        return clock.now
    end
    local key = T.pair(mock, "Dana's iPhone")
    local keyId = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json.id
    local profile = T.http(mock, "GET", "/v1/profile", { key = key }).json
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profile.id, { key = key, body = { name = "Dana" } }).status, 200)
    local s = { mock = mock, connection = connection, home = home, clock = clock, key = key, keyId = keyId, profile = profile.id, keys = {} }
    s.keys.phone = { key = key, id = keyId }
    -- Another key: `profile` true for Dana's own other device.
    function s.add(name, role, sameProfile)
        local body = { name = name, role = role }
        if sameProfile then
            body.profile_id = s.profile
        end
        local created = T.http(mock, "POST", "/v1/api-keys", { key = s.key, body = body })
        T.eq(created.status, 201, created.body)
        s.keys[name] = { key = created.json.key, id = created.json.id }
        return created.json.key, created.json.id
    end
    -- The device of `name` switches alerts on.
    function s.alertsOn(name)
        local answer = T.http(mock, "PUT", "/v1/alerts/choices", { key = s.keys[name].key, body = { on = true } })
        T.eq(answer.status, 200, answer.body)
    end
    if connection then
        sent(connection)
    end
    return s
end

local function make(s, key, body)
    return T.http(s.mock, "POST", "/v1/ask-links", { key = key or s.key, body = body or { relay_id = GATE, label = "Arriving home" } })
end

local counter = 0

-- A run as the account service passes it on: the driver's answer, and the notify messages it sent.
local function run(s, linkId, secret)
    counter = counter + 1
    s.connection.sent = ""
    ReceivedFromNetwork(6001, 443, Harness.serverFrame(1, Json.encode({ type = "link", id = "ask-" .. counter, link = linkId, secret = secret })))
    local messages = sent(s.connection)
    local results = ofType(messages, "link_result")
    T.eq(#results, 1, "one answer")
    T.eq(results[1].id, "ask-" .. counter)
    return results[1], ofType(messages, "notify")
end

local function history(s, kind)
    return T.http(s.mock, "GET", "/v1/activity?kind=" .. (kind or "door,access"), { key = s.key }).json.items
end

local function pulse(s, key, requestId, relayId)
    return T.http(s.mock, "POST", "/v1/relays/" .. (relayId or GATE) .. "/pulse", { key = key, body = requestId and { request = requestId } or nil })
end

local function relayCommands(s, since)
    local found = 0
    for index = (since or 0) + 1, #s.mock.commands do
        if s.mock.commands[index].device == GATE then
            found = found + 1
        end
    end
    return found
end

-- Dana's phone has alerts on and made a link; it ran and asked. Returns the link, the request's
-- detail as the phone opens it, and the notify message.
local function asked(s)
    s.alertsOn("phone")
    local link = make(s).json
    local reply, notices = run(s, link.link_id, link.secret)
    T.eq(reply.ok, true)
    T.eq(reply.result, "asked")
    T.eq(#notices, 1)
    local detail = open(s.key, s.home, s.keyId, notices[1]["for"][s.keyId])
    return link, detail, notices[1]
end

-- ---- making one ---------------------------------------------------------------------------------

function tests.someone_who_may_open_the_door_makes_a_link_and_only_its_hash_is_kept()
    local s = start()
    local made = make(s, nil, { relay_id = GATE, label = "  Arriving home " })
    T.eq(made.status, 201, made.body)
    local link = made.json
    T.truthy(link.link_id:match("^%x%x%x%x%x%x%x%x$"))
    T.truthy(#link.secret == 40 and link.secret:match("^[0-9a-f]+$"), "160 bits")
    T.eq(link.relay_id, GATE)
    T.eq(link.relay_name, "Main Door")
    T.eq(link.label, "Arriving home")
    T.eq(link.made_by, s.keyId)
    T.eq(link.person, "Dana")
    T.eq(link.this_device, true)
    T.eq(link.replaced, false)
    T.eq(link.url, "https://api.directorlink.io/run/" .. s.home .. "." .. link.link_id .. "#" .. link.secret)
    T.notContains(s.mock.persist[STORE], link.secret, "only the hash")
    T.eq(s.mock.persist["directorlink_scene_links"], nil, "scene links' store (1.7.0 reads it) untouched")
    local list = T.http(s.mock, "GET", "/v1/ask-links", { key = s.key })
    T.eq(list.status, 200, list.body)
    T.eq(#list.json.items, 1)
    T.notContains(list.body, link.secret)
    T.eq(list.json.door_control, true)
    T.eq(list.json.remote_access, true)
    T.eq(list.json.home_linked, true)
    local entry = history(s, "access")[1]
    T.eq(entry.action, "ask_link_created")
    T.eq(entry.what, "Main Door")
    T.eq(entry.note, "Arriving home")
    T.eq(entry.ids.link_id, link.link_id)
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.features.ask_links, true)

    -- Another one for the same door from the same key replaces it.
    local again = make(s)
    T.eq(again.json.replaced, true)
    T.eq(#T.http(s.mock, "GET", "/v1/ask-links", { key = s.key }).json.items, 1)
    T.eq(history(s, "access")[1].action, "ask_link_replaced")
end

function tests.only_someone_who_may_open_it_with_door_control_on_and_a_linked_home()
    local s = start()
    local member = s.add("Tablet", "member")
    local viewer = s.add("Wall panel", "viewer")
    T.eq(make(s, member).status, 403, "a member not given doors and gates may not open them")
    T.eq(make(s, viewer).status, 404, "a viewer of 1.7.0 has no rooms (ADR-054): the door is not theirs")
    local listed = T.http(s.mock, "GET", "/v1/ask-links", { key = member })
    T.eq(listed.status, 200, "each person lists their own")
    T.eq(#listed.json.items, 0)
    local doors = s.add("Guard", "doors")
    T.eq(make(s, doors).status, 201, "a doors key may")
    T.eq(make(s, nil, { relay_id = 20 }).status, 404, "a light is no door")
    T.eq(make(s, nil, { relay_id = 9999 }).status, 404)
    T.eq(make(s, nil, { relay_id = "70" }).status, 400)
    T.eq(make(s, nil, { label = "x" }).status, 400, "relay_id is needed")
    T.eq(make(s, nil, { relay_id = GATE, label = string.rep("x", 65) }).status, 400)
    T.eq(make(s, nil, { relay_id = GATE, secret = "mine" }).status, 400, "nobody chooses the secret")

    Properties["Door Control"] = "Disabled"
    local off = make(s)
    T.eq(off.status, 403)
    T.eq(off.json.code, "DOOR_CONTROL_DISABLED")
    T.eq(T.http(s.mock, "GET", "/v1/ask-links", { key = s.key }).json.door_control, false)

    local away = start({ remote = false })
    local refused = make(away)
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "REMOTE_ACCESS_OFF")
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    T.eq(make(away).json.code, "HOME_NOT_LINKED")
end

function tests.each_person_sees_their_own_links_and_admins_every_one()
    local s = start()
    local doors = s.add("Guard", "doors")
    local mine = make(s).json
    local theirs = make(s, doors).json
    local seen = T.http(s.mock, "GET", "/v1/ask-links", { key = doors }).json.items
    T.eq(#seen, 1, "the guard sees only theirs")
    T.eq(seen[1].link_id, theirs.link_id)
    T.eq(#T.http(s.mock, "GET", "/v1/ask-links", { key = s.key }).json.items, 2, "an admin sees both")
    T.eq(T.http(s.mock, "DELETE", "/v1/ask-links/" .. mine.link_id, { key = doors }).status, 404, "not theirs")
    T.eq(T.http(s.mock, "DELETE", "/v1/ask-links/nothex", { key = doors }).status, 400)
    T.eq(T.http(s.mock, "DELETE", "/v1/ask-links/" .. theirs.link_id, { key = s.key }).status, 204, "an admin removes anyone's")
    T.eq(run(s, theirs.link_id, theirs.secret).code, "NOT_FOUND")
    local entry = history(s, "access")[1]
    T.eq(entry.action, "ask_link_removed")
    T.eq(entry.who.type, "key")
    T.eq(T.http(s.mock, "DELETE", "/v1/ask-links/" .. mine.link_id, { key = s.key }).status, 204)
    T.eq(T.http(s.mock, "DELETE", "/v1/ask-links/" .. mine.link_id, { key = s.key }).status, 404)
end

-- ---- the run ------------------------------------------------------------------------------------

function tests.the_run_asks_the_persons_devices_and_opens_nothing()
    local s = start()
    -- Dana's other device (same person) and someone else, both with alerts on; a device of Dana's
    -- without alerts.
    s.add("Dana's iPad", "admin", true)
    s.add("Dana's laptop", "admin", true)
    s.add("Avi's phone", "admin")
    s.alertsOn("Dana's iPad")
    s.alertsOn("Avi's phone")
    local before = #s.mock.commands
    local link, detail, notice = asked(s)
    T.eq(relayCommands(s, before), 0, "nothing opened")
    T.eq(notice.brief, true, "kept a minute by the push services")
    T.eq(count(notice["for"]), 2, "Dana's phone and iPad: not her laptop (alerts off), not Avi")
    T.truthy(notice["for"][s.keys["Dana's iPad"].id])
    T.eq(notice["for"][s.keys["Avi's phone"].id], nil)
    T.eq(detail.kind, "open_request")
    T.eq(detail.id, GATE)
    T.eq(detail.name, "Main Door")
    T.eq(detail.room, "Kitchen")
    T.eq(detail.via, "Arriving home")
    T.eq(detail.seconds, 120)
    T.truthy(type(detail.request) == "string" and detail.request:match("^%x+$") and #detail.request == 16, tostring(detail.request))
    -- The cloud sees parts of one size, nothing it can read.
    T.eq(#notice["for"][s.keyId].ct, 684)
    T.notContains(Json.encode(notice), "Main Door")

    local entry = history(s, "door")[1]
    T.eq(entry.action, "asked")
    T.eq(entry.what, "Main Door")
    T.eq(entry.who.type, "link")
    T.eq(entry.who.name, "Arriving home")
    T.eq(entry.count, 2)
    T.eq(entry.reason, nil)
    T.eq(entry.ids.link_id, link.link_id)
    T.eq(entry.ids.device_id, GATE)
    T.notContains(T.http(s.mock, "GET", "/v1/logs?limit=500", { key = s.key }).body, link.secret, "the secret is never logged")
    T.truthy(T.http(s.mock, "GET", "/v1/ask-links", { key = s.key }).json.items[1].last_used_at ~= Json.null)
end

function tests.the_answer_opens_once_with_the_devices_own_key_while_the_request_lasts()
    local s = start()
    local _, otherId = s.add("Dana's iPad", "admin", true)
    local avi = s.add("Avi's phone", "admin")
    s.alertsOn("Dana's iPad")
    local link, detail = asked(s)
    local before = #s.mock.commands

    -- Not a device it was sent to, another door, nonsense: nothing opens.
    local wrong = pulse(s, avi, detail.request)
    T.eq(wrong.status, 409)
    T.eq(wrong.json.code, "OPEN_REQUEST_EXPIRED")
    T.eq(pulse(s, s.key, "nothex").status, 400)
    T.eq(pulse(s, s.key, string.rep("0", 16)).json.code, "OPEN_REQUEST_EXPIRED")
    T.eq(relayCommands(s, before), 0)
    -- Door Control turned off meanwhile: refused as any opening, and the request still stands.
    Properties["Door Control"] = "Disabled"
    T.eq(pulse(s, s.key, detail.request).json.code, "DOOR_CONTROL_DISABLED")
    Properties["Door Control"] = "Enabled"
    T.eq(relayCommands(s, before), 0)

    -- The iPad (Dana's, it got the request) opens it, with its own key.
    local opened = pulse(s, s.keys["Dana's iPad"].key, detail.request)
    T.eq(opened.status, 202, opened.body)
    T.eq(relayCommands(s, before) > 0, true, "the gate got its pulse")
    local after = #s.mock.commands
    -- Once.
    local again = pulse(s, s.key, detail.request)
    T.eq(again.status, 409)
    T.eq(again.json.code, "OPEN_REQUEST_ANSWERED")
    T.eq(relayCommands(s, after), 0)

    -- History: asked by the link, then opened by Dana (her iPad), answering it.
    local entries = history(s, "door")
    T.eq(entries[1].action, "pulse")
    T.eq(entries[1].who.type, "key")
    T.eq(entries[1].who.key_id, otherId)
    T.eq(entries[1].who.profile, "Dana")
    T.eq(entries[1].ids.link_id, link.link_id)
    T.eq(entries[1].note, "Arriving home")
    T.eq(entries[2].action, "asked")
end

function tests.a_request_lasts_two_minutes()
    local s = start()
    local _, detail = asked(s)
    local before = #s.mock.commands
    s.clock.now = s.clock.now + 121
    local late = pulse(s, s.key, detail.request)
    T.eq(late.status, 409)
    T.eq(late.json.code, "OPEN_REQUEST_EXPIRED")
    T.eq(relayCommands(s, before), 0, "nothing opened")
    -- A plain pulse (the door's own button) still works for a key that may open it.
    T.eq(pulse(s, s.key).status, 202)
end

function tests.one_request_at_a_time_for_a_door_and_person()
    local s = start()
    local link = asked(s)
    local reply, notices = run(s, link.link_id, link.secret)
    T.eq(reply.result, "waiting", "already asked")
    T.eq(#notices, 0, "no second notification")
    T.eq(#history(s, "door"), 1, "and no second entry")
    s.clock.now = s.clock.now + 121
    reply, notices = run(s, link.link_id, link.secret)
    T.eq(reply.result, "asked", "the first one is over: asked again")
    T.eq(#notices, 1)
end

function tests.nobody_to_ask_or_door_control_off_says_so()
    local s = start()
    local link = make(s).json
    local before = #s.mock.commands
    local reply, notices = run(s, link.link_id, link.secret)
    T.eq(reply.ok, true)
    T.eq(reply.result, "nobody", "no device of Dana's has alerts on")
    T.eq(#notices, 0)
    local entry = history(s, "door")[1]
    T.eq(entry.action, "asked")
    T.eq(entry.reason, "nobody")
    T.eq(entry.outcome, "skipped")
    T.eq(entry.count, 0)

    s.alertsOn("phone")
    Properties["Door Control"] = "Disabled"
    reply, notices = run(s, link.link_id, link.secret)
    T.eq(reply.result, "doors_off")
    T.eq(#notices, 0)
    T.eq(history(s, "door")[1].reason, "doors_off")
    T.eq(relayCommands(s, before), 0)
end

function tests.runs_are_limited_a_minute_and_an_hour()
    local s = start()
    local link = make(s).json
    for index = 1, 6 do
        T.eq(run(s, link.link_id, link.secret).ok, true, "run " .. index)
    end
    local limited = run(s, link.link_id, link.secret)
    T.eq(limited.code, "RATE_LIMITED")
    T.truthy(limited.retry_s >= 1 and limited.retry_s <= 60)
    -- Ten that asked (or said why not) an hour.
    for index = 7, 10 do
        s.clock.now = s.clock.now + 61
        T.eq(run(s, link.link_id, link.secret).result, "nobody", "run " .. index)
    end
    s.clock.now = s.clock.now + 61
    local hourly = run(s, link.link_id, link.secret)
    T.eq(hourly.code, "RATE_LIMITED")
    T.truthy(hourly.retry_s > 60, "until the first is an hour old")
    T.eq(#history(s, "door"), 10, "the refused one is no entry")
end

function tests.a_wrong_secret_is_refused_like_an_unknown_link()
    local s = start()
    s.alertsOn("phone")
    local link = make(s).json
    local wrong = link.secret:sub(1, 39) .. (link.secret:sub(40) == "0" and "1" or "0")
    local reply, notices = run(s, link.link_id, wrong)
    T.eq(reply.ok, false)
    T.eq(reply.code, "NOT_FOUND")
    T.eq(#notices, 0)
    T.eq(#history(s, "door"), 0)
end

-- ---- revocation -------------------------------------------------------------------------------

function tests.a_link_goes_with_its_key_and_with_its_persons_door_access()
    local s = start()
    local guard, guardId = s.add("Guard", "doors")
    local theirs = make(s, guard).json
    -- Their door access is taken away (made a member): the link goes.
    T.eq(T.http(s.mock, "PATCH", "/v1/api-keys/" .. guardId, { key = s.key, body = { role = "member" } }).status, 200)
    T.eq(run(s, theirs.link_id, theirs.secret).code, "NOT_FOUND")
    local entry = history(s, "access")[1]
    T.eq(entry.action, "ask_link_removed")
    T.eq(entry.reason, "no_access")
    T.eq(entry.note, "Arriving home")

    local tablet, tabletId = s.add("Tablet", "admin")
    local again = make(s, tablet).json
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. tabletId, { key = s.key }).status, 204)
    T.eq(run(s, again.link_id, again.secret).code, "NOT_FOUND", "revoked: its link stopped")
    T.eq(history(s, "access")[1].reason, "key_gone")
    T.eq(#T.http(s.mock, "GET", "/v1/ask-links", { key = s.key }).json.items, 0)
end

function tests.composer_ends_every_ask_link()
    for _, action in ipairs({ "REMOVE_SCENE_LINKS", "REVOKE_API_KEYS", "RESET_REMOTE_IDENTITY" }) do
        local s = start()
        local link = make(s).json
        ExecuteCommand("LUA_ACTION", { ACTION = action })
        T.eq(Json.decode(s.mock.persist[STORE]:gsub("^json:", "")).links[1], nil, action .. ": none kept")
        if action ~= "RESET_REMOTE_IDENTITY" then
            T.eq(run(s, link.link_id, link.secret).code, "NOT_FOUND", action)
        end
    end
    -- Remove All Scene Links counts them with the scene links.
    local s = start()
    make(s)
    ExecuteCommand("LUA_ACTION", { ACTION = "REMOVE_SCENE_LINKS" })
    local entry = history(s, "access")[1]
    T.eq(entry.action, "links_removed")
    T.eq(entry.count, 1)
end

function tests.links_survive_an_update_and_requests_do_not()
    local s = start()
    s.alertsOn("phone")
    local link, detail = asked(s)
    local updated = Mock.updateDriver(s.mock)
    Properties["Door Control"] = "Enabled"
    local _, connection = Harness.connected({ mock = updated })
    s.mock, s.connection = updated, connection
    sent(connection)
    T.eq(#T.http(updated, "GET", "/v1/ask-links", { key = s.key }).json.items, 1)
    T.eq(pulse(s, s.key, detail.request).json.code, "OPEN_REQUEST_EXPIRED", "requests are memory only")
    local reply = run(s, link.link_id, link.secret)
    T.eq(reply.ok, true)

    -- A 1.7.0 store has none: none, and nothing breaks; a store that cannot be read is not written.
    local fresh = start()
    T.eq(#T.http(fresh.mock, "GET", "/v1/ask-links", { key = fresh.key }).json.items, 0)
    make(fresh)
    fresh.mock.persist[STORE] = "json:{not json"
    local broken = Mock.updateDriver(fresh.mock)
    Properties["Door Control"] = "Enabled"
    Harness.connected({ mock = broken })
    local refused = T.http(broken, "POST", "/v1/ask-links", { key = fresh.key, body = { relay_id = GATE } })
    T.eq(refused.status, 503)
    T.eq(broken.persist[STORE], "json:{not json", "left as it was")
end

function tests.a_scene_link_and_an_ask_link_share_the_run()
    local s = start()
    s.alertsOn("phone")
    local scene = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Lights", steps = { { type = "lights", device_ids = { 20 }, set = { on = true } } } } }).json
    local sceneLink = T.http(s.mock, "POST", "/v1/scenes/" .. scene.id .. "/link", { key = s.key }).json
    local askLink = make(s).json
    T.truthy(sceneLink.link_id ~= askLink.link_id)
    T.eq(run(s, sceneLink.link_id, sceneLink.secret).result, "ran")
    T.eq(run(s, askLink.link_id, askLink.secret).result, "asked")
    T.eq(run(s, askLink.link_id, sceneLink.secret).code, "NOT_FOUND", "secrets are not interchangeable")
    T.eq(run(s, sceneLink.link_id, askLink.secret).code, "NOT_FOUND")
end

return tests
