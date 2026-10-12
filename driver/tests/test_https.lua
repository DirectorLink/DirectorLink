-- Direct HTTPS (1.12.0, ADR-082): the installer turns it on in Composer, the only switch since
-- 1.12.2 (Direct HTTPS: Off or On; 1.12.1's "Allowed" is On, and PUT /v1/https answers 409
-- SET_IN_COMPOSER); the controller then makes its name and key once, asks DirectorLink's servers
-- for a certificate over the relay's connection (docs/RELAY.md: https_certificate, https), keeps one
-- only for its own key and name, and serves the API over TLS on port 28443 exactly as on 41999. It
-- asks again when a third of the certificate's lifetime is left, tells the Worker its address when
-- it changes, and has the name's record deleted when it is turned off. The key never leaves the
-- controller's store.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local X509Fake = require("x509_fake")
local Harness = require("relay_harness")

local tests = {}

local PORT = 28443
local DAY = 86400
local INTERMEDIATE = X509Fake.pem(X509Fake.certificate({ point = X509Fake.point(7), names = {}, subject_cn = "YE1", issuer_cn = "Root YE" }), "CERTIFICATE")

local function iso(seconds)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", seconds)
end

-- ---- a home ---------------------------------------------------------------------------------------

local function sentMessages(s)
    local out = {}
    for _, frame in ipairs(Harness.clientFrames(s.connection.sent)) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" then
            out[#out + 1] = message
        end
    end
    s.connection.sent = ""
    return out
end

-- The Direct HTTPS messages the driver sent since the last look (https_certificate, https).
local function httpsMessages(s)
    local out = {}
    for _, message in ipairs(sentMessages(s)) do
        if message.type == "https_certificate" or message.type == "https" then
            out[#out + 1] = message
        end
    end
    return out
end

local function relaySays(s, message)
    s.connection.sent = s.connection.sent or ""
    Harness.relaySays(message)
end

-- The relay says what it does on this connection.
local function relayFeatures(s, features)
    relaySays(s, { type = "relay_features", id = "f-" .. tostring(math.random(1e6)), features = features or { "alert_acks", "https" } })
end

local function claim(s)
    local made = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(made.status, 201, made.body)
    local answer = Harness.relayRequest(s.mock, s.connection, { type = "claim", id = "claim-1", token = made.json.claim_token })
    T.eq(answer.ok, true, "the home is claimed")
end

-- Claims the home on a connection whose relay issues certificates; returns the Direct HTTPS
-- messages the driver sent after its answer.
local function claimAndWatch(s)
    local made = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(made.status, 201, made.body)
    s.connection.sent = ""
    relaySays(s, { type = "claim", id = "claim-1", token = made.json.claim_token })
    local claimed, out = false, {}
    for _, message in ipairs(sentMessages(s)) do
        if message.type == "claim_result" then
            claimed = message.ok == true
        elseif message.type == "https_certificate" or message.type == "https" then
            out[#out + 1] = message
        end
    end
    T.eq(claimed, true, "the home is claimed")
    return out
end

-- A driver with Composer's Direct HTTPS Off at its start (options.composer: the value it has then,
-- such as "On", or 1.12.1's "Allowed"), paired (the owner's key), with Remote Access on and
-- connected to the fake relay (options.remote false: off), the home claimed (options.claimed false:
-- not), and the relay saying it issues certificates (options.features: its list; false: it says
-- nothing yet). s.early: the Direct HTTPS messages the driver sent while it got there.
local function home(options)
    options = options or {}
    local mock = Mock.startDriver(nil, nil, options.initType, function(m)
        Properties["Direct HTTPS"] = options.composer or "Off"
        if options.prepare then
            options.prepare(m)
        end
    end)
    local s = { mock = mock, early = {} }
    s.key = options.key or T.pair(mock, "Owner's laptop")
    if options.remote ~= false then
        local _, connection = Harness.connected({ mock = mock })
        s.connection = connection
        if options.claimed ~= false then
            claim(s)
        end
        if options.features ~= false then
            relayFeatures(s, options.features or nil)
        end
        s.early = httpsMessages(s)
    end
    return s
end

local function status(s, key)
    local answer = T.http(s.mock, "GET", "/v1/https", { key = key or s.key })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

-- The 1.12.0 and 1.12.1 apps' switch: refused since 1.12.2.
local function switch(s, on, key)
    return T.http(s.mock, "PUT", "/v1/https", { key = key or s.key, body = { enabled = on } })
end

local function setProperty(name, value)
    Properties[name] = value
    OnPropertyChanged(name)
end

-- The installer sets Direct HTTPS in Composer.
local function composer(value)
    setProperty("Direct HTTPS", value)
end

-- The SubjectPublicKeyInfo of a PEM CSR, for a certificate issued for it.
local function requestedKey(csr)
    local X509 = require("src.core.x509")
    return X509.readRequest(X509.pemBlocks(csr, "CERTIFICATE REQUEST")[1]).spki
end

-- A certificate for the CSR the driver sent (`asked`), valid from `from` to `to` (Unix seconds:
-- 90 days from yesterday by default); options.spki, names, issuer_cn.
local function certificateFor(asked, options)
    options = options or {}
    local from = options.from or (os.time() - DAY)
    local to = options.to or (from + 90 * DAY)
    return X509Fake.pem(X509Fake.certificate({
        spki = options.spki or requestedKey(asked.csr),
        names = options.names or { asked.name },
        issuer_cn = options.issuer_cn or "YE1",
        not_before = iso(from),
        not_after = iso(to),
        serial = options.serial,
    }), "CERTIFICATE"), iso(to)
end

-- Turns it on in Composer and returns the request for a certificate the driver sent, and the state.
local function turnOn(s)
    composer("On")
    local sent = httpsMessages(s)
    T.eq(#sent, 1, "one request for a certificate")
    T.eq(sent[1].type, "https_certificate")
    return sent[1], status(s)
end

local function issued(s, asked, options)
    local leaf, notAfter = certificateFor(asked, options)
    relaySays(s, { type = "https_certificate_result", id = (options and options.id) or asked.id, ok = true, status = "issued",
        name = asked.name, certificate = leaf, chain = (options and options.chain) or INTERMEDIATE, not_after = notAfter })
    return leaf, notAfter
end

-- On, with a certificate (options as certificateFor) and the TLS server ONLINE. Returns s, the
-- request, the leaf and its end.
local function listening(options)
    local s = home(options)
    local asked = turnOn(s)
    relaySays(s, { type = "https_certificate_result", id = asked.id, ok = true, status = "pending" })
    local leaf, notAfter = issued(s, asked, options)
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(status(s).state, "listening")
    s.connection.sent = ""
    return s, asked, leaf, notAfter
end

-- Director's timers of Direct HTTPS: the repeating tick, or the one-shot ones (retries, waits).
local function httpsTimers(mock, repeating)
    local found = {}
    for _, timer in ipairs(mock.timers) do
        if not timer.fired and not timer.cancelled and (timer.source or ""):find("direct_https", 1, true)
            and (timer.repeating == true) == (repeating == true) then
            found[#found + 1] = timer
        end
    end
    return found
end

local function tick(mock)
    local timers = httpsTimers(mock, true)
    T.eq(#timers, 1, "one repeating timer")
    T.eq(timers[1].delay, 600 * 1000, "every 10 minutes")
    timers[1].callback()
end

-- The one-shot timer of Direct HTTPS with this delay (seconds), fired.
local function fire(mock, seconds)
    for _, timer in ipairs(httpsTimers(mock, false)) do
        if timer.delay == seconds * 1000 then
            timer.fired = true
            timer.callback()
            return
        end
    end
    local delays = {}
    for _, timer in ipairs(httpsTimers(mock, false)) do
        delays[#delays + 1] = tostring(timer.delay / 1000)
    end
    error("no Direct HTTPS timer of " .. seconds .. " s (there are: " .. table.concat(delays, ", ") .. ")")
end

local function hasTimer(mock, seconds)
    for _, timer in ipairs(httpsTimers(mock, false)) do
        if timer.delay == seconds * 1000 then
            return true
        end
    end
    return false
end

-- Runs `fn` with the clock `offset` seconds ahead.
local function later(offset, fn)
    local realTime = os.time
    os.time = function(date)
        if date then
            return realTime(date)
        end
        return realTime() + offset
    end
    local ok, err = pcall(fn)
    os.time = realTime
    if not ok then
        error(err, 0)
    end
end

local function logText(mock)
    return table.concat(mock.debugLog, "\n")
end

-- What Direct HTTPS keeps in the driver's data.
local function stored(mock)
    return Json.decode((mock.persist.directorlink_https:gsub("^json:", "")))
end

-- The history's Direct HTTPS entries, the newest first (since the last driver update with
-- `sinceUpdate`).
local function directEntries(mock, key, sinceUpdate)
    local answer = T.http(mock, "GET", "/v1/activity?limit=200", { key = key })
    T.eq(answer.status, 200, answer.body)
    local found = {}
    for _, item in ipairs(answer.json.items) do
        if sinceUpdate and item.kind == "system" and item.action == "driver_updated" then
            break
        end
        if item.kind == "system" and item.action == "direct_https" then
            found[#found + 1] = item
        end
    end
    return found
end

-- A driver update in Composer: the stored data and the Composer properties stay.
local function reload(previous, prepare)
    local properties = {}
    for name, value in pairs(Properties) do
        properties[name] = value
    end
    return Mock.startDriver(nil, nil, "DIT_UPDATING", function(m)
        m.uuidCount = previous.uuidCount
        for name, value in pairs(previous.persist) do
            m.persist[name] = value
        end
        for name, value in pairs(properties) do
            Properties[name] = value
        end
        if prepare then
            prepare(m)
        end
    end)
end

-- ---- Composer, the only switch (1.12.2) -------------------------------------------------------------

function tests.off_by_default_makes_nothing()
    local s = home()
    T.same(status(s), {
        allowed = false, enabled = false, remote = true, name = Json.null, port = PORT, state = "off",
        certificate = Json.null, error = Json.null,
    })
    T.eq(s.mock.properties["Direct HTTPS Status"], "Off")
    T.eq(#s.mock.csrCalls, 0, "no key")
    T.eq(#s.mock.tlsCalls, 0, "no TLS server")
    T.eq(s.mock.persist.directorlink_https, nil)
    T.eq(#s.early, 0, "nothing told to the relay")
    T.eq(#httpsMessages(s), 0)
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.direct_https, Json.null)
    T.truthy(s.mock.servers[41999], "the API's own server is there as always")
    T.eq(#directEntries(s.mock, s.key), 0, "nothing in the history")
end

function tests.the_apps_switch_says_it_is_set_in_composer()
    local s = home()
    local admin = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Partner's phone", role = "admin" } })
    T.eq(admin.status, 201, admin.body)
    local member = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Kid's phone", role = "member" } })
    T.eq(member.status, 201, member.body)
    -- The home's owner, another admin, any body: 409, and nothing changes.
    for _, request in ipairs({ { s.key, { enabled = true } }, { s.key, { enabled = false } }, { admin.json.key, { enabled = true } },
        { s.key, {} }, { s.key, { enabled = "yes" } } }) do
        local answer = T.http(s.mock, "PUT", "/v1/https", { key = request[1], body = request[2] })
        T.eq(answer.status, 409, answer.body)
        T.eq(answer.json.code, "SET_IN_COMPOSER")
        T.eq(answer.json.detail, "Direct HTTPS is turned on and off in Composer: DirectorLink → Direct HTTPS.")
    end
    T.eq(status(s).state, "off")
    T.eq(#s.mock.csrCalls, 0)
    T.eq(#httpsMessages(s), 0)
    T.eq(s.mock.persist.directorlink_https, nil)
    -- Members neither read nor switch it; without a key, nothing.
    T.eq(switch(s, true, member.json.key).status, 403)
    T.eq(T.http(s.mock, "GET", "/v1/https", { key = member.json.key }).status, 403)
    T.eq(T.http(s.mock, "GET", "/v1/https").status, 401)
    T.eq(T.http(s.mock, "PUT", "/v1/https", { body = { enabled = true } }).status, 401)
    -- On in Composer, the owner's Off changes nothing either.
    local on = listening()
    local refused = switch(on, false)
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "SET_IN_COMPOSER")
    T.eq(status(on).state, "listening")
    T.truthy(on.mock.tlsServers[PORT], "the TLS server stays")
    T.eq(#httpsMessages(on), 0, "the name's record stays")
    T.eq(#directEntries(on.mock, on.key), 1, "only Composer's On in the history")
end

function tests.it_needs_remote_access_and_a_linked_home()
    -- Remote Access off: on in Composer, and it says what it needs.
    local off = home({ remote = false })
    composer("On")
    local current = status(off)
    T.eq(current.allowed, true)
    T.eq(current.enabled, true)
    T.eq(current.remote, false)
    T.eq(current.state, "error")
    T.eq(current.error, "It needs Remote Access and the home linked to an account.")
    T.eq(off.mock.properties["Direct HTTPS Status"], "Error: It needs Remote Access and the home linked to an account")
    T.eq(#off.mock.tlsCalls, 0)

    -- Connected, but no account has the home: it waits.
    local unclaimed = home({ claimed = false })
    composer("On")
    T.eq(#httpsMessages(unclaimed), 0)
    T.eq(status(unclaimed).remote, false)
    T.eq(status(unclaimed).error, "It needs Remote Access and the home linked to an account.")
    -- Claimed: the certificate is asked for at once, not at the next look 10 minutes later.
    local asked = claimAndWatch(unclaimed)
    T.eq(status(unclaimed).remote, true)
    T.eq(#asked, 1, "asked once the home is linked")
    T.eq(asked[1].type, "https_certificate")
    T.eq(status(unclaimed).state, "requesting")

    -- A home claimed before 1.8.0 recorded no owner: an account using one of its keys says it is in one.
    local older = home({ claimed = false })
    composer("On")
    T.eq(#httpsMessages(older), 0)
    local me = T.http(older.mock, "GET", "/v1/api-keys/current", { key = older.key }).json
    relaySays(older, { type = "accounts", id = "a1", keys = { [me.id] = { "0123456789abcdef" } } })
    T.eq(status(older).remote, true)
    T.eq(#httpsMessages(older), 1, "asked at once")

    -- Turning off needs neither.
    local s = listening()
    setProperty("Remote Access", "Off")
    current = status(s)
    T.eq(current.remote, false)
    T.eq(current.state, "listening", "the certificate keeps working until it is due")
    T.eq(current.error, Json.null)
    composer("Off")
    T.eq(status(s).state, "off")
    T.eq(s.mock.tlsServers[PORT], nil)
end

-- ---- a certificate --------------------------------------------------------------------------------

function tests.on_in_composer_starts_it_with_nobody_else_to_ask()
    local s = home()
    local asked, answer = turnOn(s)
    T.eq(#s.mock.csrCalls, 1, "a key and CSR, once")
    local call = s.mock.csrCalls[1]
    T.eq(call.digest, "SHA256")
    T.eq(call.curve, "prime256v1")
    T.eq(call.subject, "/CN=" .. asked.name)
    -- No subjectAltName: Director writes it as raw text, which Let's Encrypt refuses.
    T.eq(call.extensions == nil or next(call.extensions) == nil, true)
    T.truthy(asked.name:match("^[a-z2-7]+%.dlhome%.cc$") and #asked.name == 20 + #".dlhome.cc", asked.name)
    T.contains(asked.csr, "-----BEGIN CERTIFICATE REQUEST-----")
    T.eq(asked.ip, "192.168.1.10", "the controller's LAN address, for the A record")
    T.truthy(type(asked.id) == "string" and #asked.id > 0)
    T.eq(answer.allowed, true, "a 1.12.0 or 1.12.1 app sees it on")
    T.eq(answer.enabled, true)
    T.eq(answer.state, "requesting")
    T.eq(answer.name, asked.name)
    T.eq(answer.certificate, Json.null)
    T.eq(answer.error, Json.null)
    T.eq(s.mock.properties["Direct HTTPS Status"], "Asking for a certificate for " .. asked.name)
    T.eq(#s.mock.tlsCalls, 0, "no TLS server without a certificate")

    -- The Worker is issuing it.
    relaySays(s, { type = "https_certificate_result", id = asked.id, ok = true, status = "pending" })
    T.eq(status(s).state, "requesting")
    T.truthy(hasTimer(s.mock, 900), "it waits up to 15 minutes for the certificate")

    -- Issued.
    local leaf, notAfter = issued(s, asked)
    T.eq(#s.mock.tlsCalls, 1)
    local server = s.mock.tlsCalls[1]
    T.eq(server.port, PORT)
    T.eq(server.delimiter, "")
    T.eq(server.options, 0, "TLS 1.2 and 1.3 (Director's default)")
    T.eq(server.verifyMode, 1, "no client certificate asked for (0 would ask)")
    T.eq(server.cipherList, "")
    T.eq(server.certificate, leaf)
    T.eq(server.privateKey, s.mock.privateKeys[1])
    T.eq(server.password, "")
    T.eq(server.chain, INTERMEDIATE)
    T.eq(server.identifier, "https")
    T.eq(status(s).state, "requesting", "until Director says the server is online")
    OnServerStatusChanged(PORT, "ONLINE", "https")
    local current = status(s)
    T.eq(current.state, "listening")
    T.same(current.certificate, { not_after = notAfter, issuer_cn = "YE1" })
    T.eq(current.error, Json.null)
    T.eq(s.mock.properties["Direct HTTPS Status"], "Listening on " .. asked.name .. ":28443, certificate until " .. notAfter)
    T.eq(s.mock.properties["API Status"], "Online - port 41999", "the API's own status is the plain server's")
    T.same(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.direct_https, { name = asked.name, port = PORT, not_after = notAfter })
    T.eq(#httpsMessages(s), 0, "nothing more asked")

    -- In the history, by Composer.
    local entries = directEntries(s.mock, s.key)
    T.eq(#entries, 1)
    T.eq(entries[1].to, "on")
    T.eq(entries[1].who.type, "composer")
    local log = logText(s.mock)
    T.contains(log, "certificate asked for")
    T.contains(log, "certificate installed")
    T.contains(log, "TLS server started")
    T.contains(log, "Direct HTTPS turned on in Composer")
    T.notContains(log, "BEGIN CERTIFICATE", "never a certificate's text in the log")

    -- On again in Composer: nothing new.
    composer("On")
    T.eq(status(s).state, "listening")
    T.eq(#httpsMessages(s), 0)
    T.eq(#directEntries(s.mock, s.key), 1)
end

function tests.a_member_sees_where_to_reach_it_in_the_system()
    local s = listening()
    local member = T.http(s.mock, "POST", "/v1/api-keys", { key = s.key, body = { name = "Kid's phone", role = "member" } }).json.key
    local system = T.http(s.mock, "GET", "/v1/system", { key = member })
    T.eq(system.status, 200)
    T.eq(system.json.direct_https.port, PORT)
    T.truthy(system.json.direct_https.name:match("%.dlhome%.cc$"))
    -- Not listening (Director said OFFLINE): null.
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = member }).json.direct_https, Json.null)
end

function tests.a_certificate_for_another_key_or_name_is_refused()
    local cases = {
        { spki = X509Fake.spki(X509Fake.point(4242)) },
        { names = { "abcdefghijabcdefghij.dlhome.cc" } },
        { from = os.time() - 100 * DAY, to = os.time() - DAY },
        { chain = "" },
        { chain = "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n" },
    }
    for index, options in ipairs(cases) do
        local s = home()
        local asked = turnOn(s)
        issued(s, asked, options)
        T.eq(#s.mock.tlsCalls, 0, "case " .. index)
        local current = status(s)
        T.eq(current.state, "error", "case " .. index)
        T.eq(current.error, "The certificate received isn't for this controller. Trying again in 5 minutes.", "case " .. index)
        T.eq(current.certificate, Json.null, "case " .. index)
        T.contains(logText(s.mock), "certificate refused")
        T.truthy(hasTimer(s.mock, 300), "asked again after 5 minutes")
    end
    -- A wildcard for the name's parent covers it.
    local s = home()
    local asked = turnOn(s)
    issued(s, asked, { names = { "*.dlhome.cc" } })
    T.eq(#s.mock.tlsCalls, 1)
end

function tests.the_workers_refusals_are_shown_and_asked_again_with_a_backoff()
    local s = home()
    local asked = turnOn(s)
    relaySays(s, { type = "https_certificate_result", id = asked.id, ok = false, code = "RATE_LIMITED", retry_s = 7200 })
    local current = status(s)
    T.eq(current.state, "error")
    T.eq(current.error, "Too many certificates were asked for. Trying again in 2 hours.")
    T.eq(s.mock.properties["Direct HTTPS Status"], "Error: Too many certificates were asked for. Trying again in 2 hours")
    T.eq(#httpsMessages(s), 0)
    -- Nothing at the next tick: it waits.
    tick(s.mock)
    T.eq(#httpsMessages(s), 0)
    fire(s.mock, 7200)
    local again = httpsMessages(s)
    T.eq(#again, 1)
    T.eq(again[1].type, "https_certificate")
    T.eq(again[1].csr, asked.csr, "the same key")
    T.truthy(again[1].id ~= asked.id)
    -- The second refusal in a row: 15 minutes; the third, an hour.
    relaySays(s, { type = "https_certificate_result", id = again[1].id, ok = false, code = "ACME_FAILED" })
    T.eq(status(s).error, "Let's Encrypt didn't issue the certificate. Trying again in 15 minutes.")
    fire(s.mock, 900)
    local third = httpsMessages(s)[1]
    relaySays(s, { type = "https_certificate_result", id = third.id, ok = false, code = "HTTPS_UNAVAILABLE" })
    T.eq(status(s).error, "DirectorLink's servers can't issue certificates right now. Trying again in an hour.")
    fire(s.mock, 3600)
    local fourth = httpsMessages(s)[1]
    -- No answer within a minute counts too.
    fire(s.mock, 60)
    T.contains(status(s).error, "DirectorLink's servers didn't answer in time.")
    T.truthy(hasTimer(s.mock, 6 * 3600))
    -- An answer to an earlier request changes nothing.
    relaySays(s, { type = "https_certificate_result", id = fourth.id, ok = false, code = "INTERNAL" })
    T.contains(status(s).error, "DirectorLink's servers didn't answer in time.")
    T.contains(logText(s.mock), "no certificate from DirectorLink's servers")

    -- Pending, then nothing for 15 minutes: asked again later.
    local quiet = home()
    local waiting = turnOn(quiet)
    relaySays(quiet, { type = "https_certificate_result", id = waiting.id, ok = true, status = "pending" })
    fire(quiet.mock, 900)
    T.eq(status(quiet).state, "error")
    T.truthy(hasTimer(quiet.mock, 300))

    -- A success ends the backoff.
    fire(quiet.mock, 300)
    local last = httpsMessages(quiet)[1]
    issued(quiet, last)
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(status(quiet).error, Json.null)
    T.eq(#httpsTimers(quiet.mock, false), 0, "no retry left")
end

function tests.the_homes_name_at_the_worker_wins_and_a_taken_name_is_replaced()
    -- This controller's store was lost or replaced: the Worker has the home's name.
    local s = home()
    local asked = turnOn(s)
    local homeName = "abcdefghij234567abcd.dlhome.cc"
    relaySays(s, { type = "https_certificate_result", id = asked.id, ok = false, code = "NAME_MISMATCH", name = homeName })
    local again = httpsMessages(s)
    T.eq(#again, 1, "asked again at once, for the home's name")
    T.eq(again[1].name, homeName)
    T.eq(s.mock.csrCalls[2].subject, "/CN=" .. homeName, "a new key for it")
    T.eq(status(s).name, homeName)
    T.eq(status(s).state, "requesting")
    -- A name that is no name is not taken.
    relaySays(s, { type = "https_certificate_result", id = again[1].id, ok = false, code = "NAME_MISMATCH", name = "evil.example" })
    T.eq(status(s).name, homeName)
    T.eq(status(s).state, "error")

    -- Another home has this name: a new one.
    local taken = home()
    local first = turnOn(taken)
    relaySays(taken, { type = "https_certificate_result", id = first.id, ok = false, code = "NAME_TAKEN" })
    local next = httpsMessages(taken)
    T.eq(#next, 1)
    T.truthy(next[1].name ~= first.name and next[1].name:match("%.dlhome%.cc$"))
    T.truthy(next[1].csr ~= first.csr)
    -- At most three new names a start.
    for _ = 1, 3 do
        local message = httpsMessages(taken)[1] or next[1]
        relaySays(taken, { type = "https_certificate_result", id = message.id, ok = false, code = "NAME_TAKEN" })
        next = httpsMessages(taken)
    end
    T.eq(#next, 0, "then it waits")
    T.eq(#taken.mock.csrCalls, 4)
    T.eq(status(taken).state, "error")

    -- The Worker refused the CSR: a new key, asked for after the backoff.
    local refused = home()
    local csr = turnOn(refused)
    relaySays(refused, { type = "https_certificate_result", id = csr.id, ok = false, code = "INVALID_CSR" })
    T.eq(#refused.mock.csrCalls, 2)
    T.eq(#httpsMessages(refused), 0)
    fire(refused.mock, 300)
    local renewed = httpsMessages(refused)[1]
    T.eq(renewed.name, csr.name)
    T.truthy(renewed.csr ~= csr.csr)
end

function tests.it_asks_again_when_a_third_of_the_lifetime_is_left()
    local now = os.time()
    -- 90 days from 59 days ago: 31 days left, more than a third.
    local s, asked = listening({ from = now - 59 * DAY, to = now + 31 * DAY })
    tick(s.mock)
    T.eq(#httpsMessages(s), 0, "not yet")
    later(2 * DAY, function()
        tick(s.mock)
        local renewal = httpsMessages(s)
        T.eq(#renewal, 1)
        T.eq(renewal[1].type, "https_certificate")
        T.eq(renewal[1].csr, asked.csr)
        T.eq(status(s).state, "listening", "the certificate in use keeps working meanwhile")
        T.contains(logText(s.mock), '"renewal":true')
        local leaf = issued(s, renewal[1], { from = os.time(), serial = 2 })
        T.eq(#s.mock.tlsCalls, 2, "the TLS server again, with the new certificate")
        T.eq(s.mock.tlsCalls[2].certificate, leaf)
        T.eq(s.mock.destroyedServers[#s.mock.destroyedServers], PORT, "only the TLS server, by its port")
        T.truthy(s.mock.servers[41999], "the API's own server stays")
        OnServerStatusChanged(PORT, "OFFLINE", "https")
        OnServerStatusChanged(PORT, "ONLINE", "https")
        T.eq(status(s).state, "listening")
        tick(s.mock)
        T.eq(#httpsMessages(s), 0)
    end)
    -- The Worker gives the same certificate (its clock and the controller's differ): asked again
    -- 6 hours later, not at once.
    local same, sameAsked, sameLeaf = listening({ from = now - 50 * DAY, to = now + 40 * DAY })
    later(21 * DAY, function()
        tick(same.mock)
        local due = httpsMessages(same)
        T.eq(#due, 1)
        relaySays(same, { type = "https_certificate_result", id = due[1].id, ok = true, status = "issued", name = sameAsked.name,
            certificate = sameLeaf, chain = INTERMEDIATE, not_after = iso(now + 40 * DAY) })
        T.eq(#httpsMessages(same), 0, "not asked again at once")
        T.eq(#same.mock.tlsCalls, 1, "the same certificate: the server stays")
        T.eq(status(same).error, Json.null)
        tick(same.mock)
        T.eq(#httpsMessages(same), 0)
        fire(same.mock, 6 * 3600)
        T.eq(#httpsMessages(same), 1, "asked again 6 hours later")
    end)

    -- A refused renewal: still listening, with the error.
    local r = listening({ from = now - 50 * DAY, to = now + 40 * DAY })
    later(21 * DAY, function()
        tick(r.mock)
        local due = httpsMessages(r)
        T.eq(#due, 1, "19 days left")
        relaySays(r, { type = "https_certificate_result", id = due[1].id, ok = false, code = "ACME_FAILED" })
        local current = status(r)
        T.eq(current.state, "listening")
        T.contains(current.error, "Let's Encrypt")
    end)
    -- Expired: forgotten, the TLS server stops.
    later(41 * DAY, function()
        tick(r.mock)
        T.eq(r.mock.tlsServers[PORT], nil)
        local after = status(r)
        T.eq(after.certificate, Json.null)
        T.truthy(after.state == "error" or after.state == "requesting")
        T.eq(T.http(r.mock, "GET", "/v1/system", { key = r.key }).json.direct_https, Json.null)
    end)
end

function tests.the_worker_hears_of_a_new_address()
    local s = listening()
    tick(s.mock)
    T.eq(#httpsMessages(s), 0, "the address it gave with the request")
    s.mock.controllerAddress = "192.168.1.77"
    tick(s.mock)
    local told = httpsMessages(s)
    T.eq(#told, 1)
    T.eq(told[1].type, "https")
    T.eq(told[1].ip, "192.168.1.77")
    T.eq(told[1].name, status(s).name)
    relaySays(s, { type = "https_result", id = told[1].id, ok = true })
    tick(s.mock)
    T.eq(#httpsMessages(s), 0, "told once")
    -- Refused: told again at the next tick.
    s.mock.controllerAddress = "10.0.0.5"
    tick(s.mock)
    local refused = httpsMessages(s)[1]
    relaySays(s, { type = "https_result", id = refused.id, ok = false, code = "DNS_FAILED" })
    tick(s.mock)
    T.eq(httpsMessages(s)[1].ip, "10.0.0.5")
    -- At every new connection, once the relay said what it does.
    local hello = Harness.reconnect(s.mock, s.connection)
    T.eq(hello.type, "hello")
    T.eq(#httpsMessages(s), 0, "not before the relay's features")
    relayFeatures(s)
    local again = httpsMessages(s)
    T.eq(#again, 1)
    T.eq(again[1].ip, "10.0.0.5")
    -- A public address or none is never told.
    relaySays(s, { type = "https_result", id = again[1].id, ok = true })
    s.mock.controllerAddress = "8.8.8.8"
    tick(s.mock)
    s.mock.controllerAddress = false
    tick(s.mock)
    T.eq(#httpsMessages(s), 0)

    -- A request with such an address is not sent: the controller says why.
    local public = home({ prepare = function(m)
        m.controllerAddress = "203.0.113.9"
    end })
    composer("On")
    T.eq(#httpsMessages(public), 0)
    T.contains(status(public).error, "The controller's address isn't a home network address.")
end

function tests.a_request_whose_connection_ended_is_asked_again_on_the_next()
    local s = home()
    local asked = turnOn(s)
    relaySays(s, { type = "https_certificate_result", id = asked.id, ok = true, status = "pending" })
    Harness.reconnect(s.mock, s.connection)
    relayFeatures(s)
    local again = httpsMessages(s)
    T.eq(#again, 1)
    T.eq(again[1].csr, asked.csr)
    T.truthy(again[1].id ~= asked.id)
    -- The certificate the first request got still counts.
    issued(s, asked)
    T.eq(#s.mock.tlsCalls, 1)
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(status(s).state, "listening")
end

function tests.a_relay_that_issues_no_certificates_is_said()
    local s = home({ features = { "alert_acks" } })
    composer("On")
    T.eq(#httpsMessages(s), 0, "nothing asked of a relay that does not say https")
    local current = status(s)
    T.eq(current.state, "error")
    T.eq(current.error, "DirectorLink's servers can't issue certificates yet.")
    -- Not connected: it waits, without an error.
    local down = home({ features = false })
    composer("On")
    T.eq(status(down).state, "requesting")
    T.eq(status(down).error, Json.null)
end

-- ---- off ------------------------------------------------------------------------------------------

function tests.off_in_composer_stops_the_server_and_the_record_is_deleted()
    local s, asked = listening()
    composer("Off")
    local answer = status(s)
    T.eq(answer.allowed, false)
    T.eq(answer.enabled, false)
    T.eq(answer.state, "off")
    T.eq(answer.certificate, Json.null)
    T.eq(answer.name, asked.name, "the name stays")
    T.eq(s.mock.properties["Direct HTTPS Status"], "Off")
    T.eq(s.mock.tlsServers[PORT], nil, "stopped at once")
    T.eq(s.mock.destroyedServers[#s.mock.destroyedServers], PORT)
    T.truthy(s.mock.servers[41999], "the API's own server stays")
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.direct_https, Json.null)
    local record = stored(s.mock)
    T.eq(record.certificate, nil, "the certificate is forgotten")
    T.truthy(record.key, "the key stays")
    T.eq(record.enabled, nil)
    T.eq(record.dns_off, true, "until the Worker deleted the record")
    local off = httpsMessages(s)
    T.eq(#off, 1)
    T.eq(off[1].type, "https")
    T.eq(off[1].name, Json.null, "the Worker deletes the name's record")
    T.eq(off[1].ip, nil)
    relaySays(s, { type = "https_result", id = off[1].id, ok = true })
    T.eq(stored(s.mock).dns_off, nil)
    tick(s.mock)
    T.eq(#httpsMessages(s), 0, "told once")
    T.contains(logText(s.mock), "TLS server stopped")
    T.contains(logText(s.mock), "Direct HTTPS turned off in Composer")
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    T.eq(status(s).state, "off")

    -- In the history, by Composer: on, then off (and Composer's own setting entries as before).
    local entries = directEntries(s.mock, s.key)
    T.eq(#entries, 2)
    T.eq(entries[1].to, "off")
    T.eq(entries[1].who.type, "composer")
    T.eq(entries[2].to, "on")
    T.contains(T.http(s.mock, "GET", "/v1/activity", { key = s.key }).body, "Direct HTTPS")

    -- On again: the same key, a certificate asked for again (the Worker has it already).
    local again = turnOn(s)
    T.eq(again.csr, asked.csr)
    T.eq(#s.mock.csrCalls, 1)
    T.eq(#directEntries(s.mock, s.key), 3)
    -- Off twice: one entry.
    composer("Off")
    composer("Off")
    T.eq(#directEntries(s.mock, s.key), 4)
end

function tests.turned_off_while_away_the_record_goes_at_the_next_connection_even_after_a_restart()
    local s = listening()
    OnConnectionStatusChanged(Harness.BINDING, 443, "OFFLINE")
    composer("Off")
    T.eq(#httpsMessages(s), 0, "not connected")
    T.eq(stored(s.mock).dns_off, true, "kept until the Worker answers")
    local again = reload(s.mock)
    local after = { mock = again }
    local _, connection = Harness.connected({ mock = again })
    after.connection = connection
    relayFeatures(after)
    local off = httpsMessages(after)
    T.eq(#off, 1)
    T.eq(off[1].name, Json.null)
    -- Not answered: asked again at the next connection.
    Harness.reconnect(again, connection)
    relayFeatures(after)
    off = httpsMessages(after)
    T.eq(#off, 1)
    relaySays(after, { type = "https_result", id = off[1].id, ok = true })
    T.eq(stored(again).dns_off, nil)
    Harness.reconnect(again, connection)
    relayFeatures(after)
    T.eq(#httpsMessages(after), 0, "once deleted, never again")
end

function tests.a_new_remote_identity_forgets_the_name()
    local s, asked = listening()
    ExecuteCommand("LUA_ACTION", { ACTION = "RESET_REMOTE_IDENTITY" })
    local told = httpsMessages(s)
    T.eq(#told, 1, "told on the old connection")
    T.eq(told[1].name, Json.null)
    T.eq(s.mock.tlsServers[PORT], nil)
    local current = status(s)
    T.truthy(current.name ~= asked.name, "a new name for the new home")
    T.eq(current.certificate, Json.null)
    T.eq(current.enabled, true, "Composer still says On")
    T.eq(current.remote, false, "until the new home is connected")
    T.eq(#httpsMessages(s), 0, "nothing asked on the old connection")
end

-- ---- what is kept, and the update from 1.12.1 -------------------------------------------------------

function tests.a_certificate_survives_a_reload()
    local s, asked = listening()
    local again = reload(s.mock)
    T.eq(#again.csrCalls, 0)
    T.eq(#again.tlsCalls, 1, "the TLS server starts again at load")
    T.eq(again.tlsCalls[1].certificate, s.mock.tlsCalls[1].certificate)
    T.eq(again.tlsCalls[1].privateKey, s.mock.privateKeys[1])
    OnServerStatusChanged(PORT, "ONLINE", "https")
    local current = status({ mock = again, key = s.key })
    T.eq(current.state, "listening")
    T.eq(current.enabled, true)
    T.eq(current.name, asked.name)
    T.eq(T.http(again, "GET", "/v1/health", { tls = true, host = asked.name .. ":28443" }).status, 200)
    T.eq(#directEntries(again, s.key, true), 0, "nothing turned on or off by the reload")
end

-- How many entries of Composer's settings the history has.
local function settingEntries(mock, key)
    local _, count = T.http(mock, "GET", "/v1/activity?limit=200", { key = key }).body:gsub('"action":"setting"', "")
    return count
end

-- The owner's controller on 2026-10-11: 1.12.1 with Composer's Direct HTTPS on "Allowed", the
-- owner's switch on, a certificate, the TLS server listening. Director keeps "Allowed" across the
-- update, although 1.12.2's list is Off and On.
function tests.a_stored_allowed_keeps_it_on_after_the_update_and_composer_shows_on()
    local s, asked = listening()
    local record = stored(s.mock)
    T.eq(record.version, 2)
    T.eq(record.enabled, true, "as 1.12.1 stores the owner's switch")
    Properties["Direct HTTPS"] = "Allowed"
    local tlsBefore = #s.mock.tlsCalls
    local again = reload(s.mock)
    T.eq(again.properties["Direct HTTPS"], "On", "Composer shows On from now on")
    T.contains(logText(again), "Composer's Allowed (1.12.0 and 1.12.1) is On from now on")
    T.eq(#again.csrCalls, 0, "the same key")
    T.eq(#again.tlsCalls, 1, "the TLS server starts again at load")
    T.eq(again.tlsCalls[1].certificate, s.mock.tlsCalls[tlsBefore].certificate, "with the same certificate")
    OnServerStatusChanged(PORT, "ONLINE", "https")
    local current = status({ mock = again, key = s.key })
    T.eq(current.state, "listening")
    T.eq(current.allowed, true)
    T.eq(current.enabled, true)
    T.eq(current.name, asked.name)
    T.same(T.http(again, "GET", "/v1/system", { key = s.key }).json.direct_https, { name = asked.name, port = PORT, not_after = record.not_after })
    T.eq(#directEntries(again, s.key, true), 0, "not turned off and on again")
    T.eq(stored(again).dns_off, nil, "the name's record stays")
    -- Connected again: only the address is told, no new certificate and no delete.
    local after = { mock = again }
    local _, connection = Harness.connected({ mock = again })
    after.connection = connection
    relayFeatures(after)
    local told = httpsMessages(after)
    T.eq(#told, 1)
    T.eq(told[1].type, "https")
    T.eq(told[1].name, asked.name)
    -- Director reports DirectorLink's own On back: no change of the installer's, nothing recorded.
    local settingsBefore = settingEntries(again, s.key)
    Properties["Direct HTTPS"] = "On"
    OnPropertyChanged("Direct HTTPS")
    T.eq(settingEntries(again, s.key), settingsBefore, "not a Composer change")
    T.eq(status({ mock = again, key = s.key }).state, "listening")
    -- A Composer still open from before sends 1.12.1's Allowed back: On all the same, shown as On
    -- again, and no installer's change.
    Properties["Direct HTTPS"] = "Allowed"
    again.properties["Direct HTTPS"] = "Allowed"
    OnPropertyChanged("Direct HTTPS")
    T.eq(again.properties["Direct HTTPS"], "On")
    T.eq(settingEntries(again, s.key), settingsBefore)
    T.eq(#directEntries(again, s.key, true), 0)
    T.eq(status({ mock = again, key = s.key }).state, "listening")
    T.truthy(again.tlsServers[PORT])
    -- The installer's Off afterwards is one.
    composer("Off")
    T.eq(status({ mock = again, key = s.key }).state, "off")
    T.eq(settingEntries(again, s.key), settingsBefore + 1)
    T.eq(directEntries(again, s.key)[1].to, "off")
end

-- 1.12.1 with "Allowed" whose owner had not turned it on (or turned it off): Composer decides.
function tests.a_stored_owners_off_does_not_keep_it_off()
    for _, enabled in ipairs({ false, Json.null }) do
        local s = home({ composer = "Allowed", prepare = function(m)
            m.persist.directorlink_https = "json:" .. Json.encode({
                version = 2, name = "abcdefghijabcdefghij.dlhome.cc", created_at = "2026-10-10T19:00:00Z", enabled = enabled, dns_off = true,
                key = X509Fake.privateKey(1), csr = X509Fake.pem(X509Fake.request("abcdefghijabcdefghij.dlhome.cc", X509Fake.point(1)), "CERTIFICATE REQUEST"),
            })
        end })
        T.eq(s.mock.properties["Direct HTTPS"], "On")
        local current = status(s)
        T.eq(current.enabled, true, "on: Composer says so")
        T.eq(current.state, "requesting")
        T.eq(current.name, "abcdefghijabcdefghij.dlhome.cc")
        T.eq(#s.mock.csrCalls, 0, "its key")
        T.eq(#s.early, 1, "a certificate asked for once connected")
        T.eq(s.early[1].type, "https_certificate")
        T.eq(s.early[1].name, "abcdefghijabcdefghij.dlhome.cc")
        local record = stored(s.mock)
        T.eq(record.enabled, true)
        T.eq(record.dns_off, nil, "no delete pending")
        local entries = directEntries(s.mock, s.key)
        T.eq(#entries, 1)
        T.eq(entries[1].to, "on")
        T.eq(entries[1].who.type, "composer")
    end
end

-- Composer changed while the driver did not run (or Director gave a list property its default):
-- seen at the start, as a change in Composer.
function tests.composer_off_at_the_start_turns_off_what_was_on()
    local s, asked = listening()
    Properties["Direct HTTPS"] = "Off"
    local again = reload(s.mock)
    T.eq(#again.tlsCalls, 0, "no TLS server")
    local record = stored(again)
    T.eq(record.enabled, nil)
    T.eq(record.dns_off, true)
    T.eq(record.certificate, nil)
    T.eq(record.name, asked.name)
    local after = { mock = again }
    local _, connection = Harness.connected({ mock = again })
    after.connection = connection
    relayFeatures(after)
    local off = httpsMessages(after)
    T.eq(#off, 1)
    T.eq(off[1].name, Json.null, "the name's record is deleted")
    local entries = directEntries(again, s.key, true)
    T.eq(#entries, 1)
    T.eq(entries[1].to, "off")
    T.eq(entries[1].who.type, "composer")
end

function tests.the_test_builds_key_is_used_once_composer_says_on()
    local s = home({ prepare = function(m)
        m.persist.directorlink_https = Json.encode({
            version = 1, name = "abcdefghijabcdefghij.dlhome.cc", created_at = "2026-10-10T19:00:00Z",
            key = X509Fake.privateKey(1), csr = X509Fake.pem(X509Fake.request("abcdefghijabcdefghij.dlhome.cc", X509Fake.point(1)), "CERTIFICATE REQUEST"),
        })
    end })
    local current = status(s)
    T.eq(current.state, "off")
    T.eq(current.name, "abcdefghijabcdefghij.dlhome.cc")
    local asked = turnOn(s)
    T.eq(asked.name, "abcdefghijabcdefghij.dlhome.cc")
    T.eq(#s.mock.csrCalls, 0, "its key")
end

function tests.the_private_key_never_leaves_the_store()
    local s = listening()
    local secret = s.mock.privateKeys[1]
    local body = secret:match("%-%-%-%-%-\n(.-)\n%-%-%-%-%-END")
    T.truthy(body and #body > 8)
    local relayFrames = {}
    for _, frame in ipairs(Harness.clientFrames(s.connection.sent)) do
        relayFrames[#relayFrames + 1] = frame.payload
    end
    composer("Off")
    composer("On")
    for _, frame in ipairs(Harness.clientFrames(s.connection.sent)) do
        relayFrames[#relayFrames + 1] = frame.payload
    end
    local answers = {
        T.http(s.mock, "GET", "/v1/https", { key = s.key }).body,
        T.http(s.mock, "GET", "/v1/logs", { key = s.key }).body,
        T.http(s.mock, "GET", "/v1/system", { key = s.key }).body,
        T.http(s.mock, "GET", "/v1/activity", { key = s.key }).body,
        switch(s, true).body,
        logText(s.mock),
        Json.encode(s.mock.properties),
        Json.encode(require("src.core.backup").export(require("src.core.registry"))),
    }
    for index, text in ipairs(answers) do
        T.notContains(text, body, "answer " .. index)
        T.notContains(text, "PRIVATE KEY", "answer " .. index)
        T.notContains(text, "CERTIFICATE REQUEST", "answer " .. index .. ": not even the CSR")
    end
    -- The relay gets the CSR, never the key.
    local relayed = table.concat(relayFrames, "\n")
    T.contains(relayed, "CERTIFICATE REQUEST")
    T.notContains(relayed, body)
    T.notContains(relayed, "PRIVATE KEY")
    -- Only Direct HTTPS's own store holds it.
    for name, value in pairs(s.mock.persist) do
        if name ~= "directorlink_https" then
            T.notContains(tostring(value), body, name)
        end
    end
    T.contains(s.mock.persist.directorlink_https, body)
end

-- ---- what goes wrong on the controller ------------------------------------------------------------

function tests.an_os_without_the_private_key_says_it_is_not_supported()
    local s = home({ prepare = function(m)
        m.csrMode = "csr_only"
    end })
    composer("On")
    local answer = status(s)
    T.eq(answer.state, "error")
    T.eq(answer.error, "This controller's OS is too old for Direct HTTPS. It needs OS 3.3.1 or later.")
    T.eq(s.mock.properties["Direct HTTPS Status"], "Error: This controller's OS is too old for Direct HTTPS. It needs OS 3.3.1 or later")
    T.contains(logText(s.mock), "gave no private key", "what Director did, in the log")
    T.eq(#httpsMessages(s), 0, "nothing asked without a key")
    T.eq(#s.mock.tlsCalls, 0)

    local missing = home({ prepare = function()
        C4.GenerateCSR_ECC = nil
    end })
    composer("On")
    T.eq(status(missing).error, "This controller's OS is too old for Direct HTTPS. It needs OS 3.3.1 or later.")

    local failing = home({ prepare = function(m)
        m.csrMode = "fail"
    end })
    composer("On")
    T.eq(status(failing).error, "The controller couldn't make its key.")
    T.contains(logText(failing.mock), "EC key generation failed")
    -- Off and on again in Composer tries again.
    failing.mock.csrMode = nil
    composer("Off")
    composer("On")
    T.eq(status(failing).state, "requesting")
end

function tests.a_tls_server_that_fails_to_start_says_why()
    local s = home({ prepare = function(m)
        m.tlsFails = "bind failed"
    end })
    local asked = turnOn(s)
    issued(s, asked)
    local current = status(s)
    T.eq(current.state, "error")
    T.eq(current.error, "The controller couldn't start its HTTPS server. Trying again in a minute.")
    T.eq(s.mock.properties["Direct HTTPS Status"], "Error: The controller couldn't start its HTTPS server. Trying again in a minute")
    T.contains(logText(s.mock), "TLS server failed")
    T.contains(logText(s.mock), "bind failed", "Director's words in the log")
    -- Started again after 10 s, 30 s, a minute…: it works once the port is free.
    T.eq(#s.mock.tlsCalls, 1)
    fire(s.mock, 10)
    T.eq(#s.mock.tlsCalls, 2)
    T.truthy(hasTimer(s.mock, 30))
    s.mock.tlsFails = nil
    fire(s.mock, 30)
    T.eq(#s.mock.tlsCalls, 3)
    OnServerStatusChanged(PORT, "ONLINE", "https")
    current = status(s)
    T.eq(current.state, "listening")
    T.eq(current.error, Json.null)
end

-- ---- requests on the TLS server -------------------------------------------------------------------

function tests.a_request_on_the_tls_server_is_answered_as_on_41999()
    local s, asked = listening()
    local key, mock, host = s.key, s.mock, asked.name .. ":28443"
    local plain = T.http(mock, "GET", "/v1/system", { key = key })
    local secure = T.http(mock, "GET", "/v1/system", { key = key, tls = true, host = host })
    T.eq(secure.status, 200, secure.body)
    T.eq(plain.status, 200)
    T.eq(secure.json.bridge.version, plain.json.bridge.version)
    T.eq(secure.headers["content-type"], plain.headers["content-type"])
    T.eq(secure.closed, true)
    T.eq(T.http(mock, "GET", "/v1/lights", { tls = true, host = host }).status, 401)
    local origin = { Origin = "https://app.directorlink.io", ["Access-Control-Request-Private-Network"] = "true" }
    local preflight = T.http(mock, "OPTIONS", "/v1/sealed", { tls = true, host = host, headers = origin })
    T.eq(preflight.status, 204)
    T.eq(preflight.headers["access-control-allow-origin"], "https://app.directorlink.io")
    T.eq(preflight.headers["access-control-allow-private-network"], "true")
    local health = T.http(mock, "GET", "/v1/health", { tls = true, host = host, headers = { Origin = "https://app.directorlink.io" } })
    T.eq(health.status, 200)
    T.eq(health.headers["access-control-allow-origin"], "https://app.directorlink.io")
    T.eq(T.http(mock, "GET", "/v1/health", { tls = true, host = host, headers = { Origin = "https://evil.example" } }).status, 403)
    T.eq(T.http(mock, "GET", "/v1/system", { key = key, tls = "port", host = host }).status, 200)
    T.contains(logText(mock), '"tls":true')
end

function tests.the_host_check_takes_the_name_only_on_the_tls_server()
    local s, asked = listening()
    local mock, name = s.mock, asked.name
    for _, host in ipairs({ name, name .. ":28443", string.upper(name) .. ":28443", "192.168.1.10:28443", "director.local:28443" }) do
        T.eq(T.http(mock, "GET", "/v1/health", { tls = true, host = host }).status, 200, host)
    end
    for _, host in ipairs({ "other.dlhome.cc", "x" .. name, name .. ":41999", name .. ".", "dlhome.cc", "evil.example:28443" }) do
        local answer = T.http(mock, "GET", "/v1/health", { tls = true, host = host })
        T.eq(answer.status, 421, host)
        T.eq(answer.json.code, "MISDIRECTED_REQUEST")
    end
    for _, host in ipairs({ name, name .. ":28443", name .. ":41999" }) do
        T.eq(T.http(mock, "GET", "/v1/health", { host = host }).status, 421, host)
    end
end

-- ---- what the app relies on (1.12.0 app) ----------------------------------------------------------

function tests.the_system_always_says_direct_https()
    local off = home({ remote = false })
    local body = T.http(off.mock, "GET", "/v1/system", { key = off.key }).body
    T.contains(body, '"direct_https":null', "the key is there, null, while off")
    -- Whatever the module offers, the key stays.
    require("src.api.direct_https").published = nil
    T.contains(T.http(off.mock, "GET", "/v1/system", { key = off.key }).body, '"direct_https":null')
end

function tests.sealed_requests_on_the_tls_server_get_cors_for_the_app()
    local s, asked = listening()
    local mock, host = s.mock, asked.name .. ":28443"
    local origin = "https://app.directorlink.io"
    -- The preflight of the app's JSON POST.
    local preflight = T.http(mock, "OPTIONS", "/v1/sealed", { tls = true, host = host, headers = {
        Origin = origin, ["Access-Control-Request-Method"] = "POST", ["Access-Control-Request-Headers"] = "content-type",
        ["Access-Control-Request-Private-Network"] = "true",
    } })
    T.eq(preflight.status, 204)
    T.eq(preflight.headers["access-control-allow-origin"], origin)
    T.contains(preflight.headers["access-control-allow-methods"], "POST")
    T.contains(preflight.headers["access-control-allow-headers"], "Content-Type")
    -- GET /v1/sealed: answered at once, in the same call (nothing waits on that path), with CORS.
    local started = os.clock()
    local info = T.http(mock, "GET", "/v1/sealed", { tls = true, host = host, headers = { Origin = origin } })
    T.truthy(os.clock() - started < 0.5, "answered at once")
    T.eq(info.status, 200)
    T.eq(info.closed, true)
    T.eq(info.headers["access-control-allow-origin"], origin)
    T.eq(info.json.home, "lan")
    -- POST /v1/sealed: a sealed request, answered sealed, with CORS.
    local Lock = require("src.cloud.lock")
    local me = T.http(mock, "GET", "/v1/api-keys/current", { key = s.key }).json
    local lock = Lock.deviceKey(s.key)
    local envelope = Lock.seal(lock, info.json.home, me.id, "req", Json.encode({ id = "tls-1", ts = info.json.time, method = "GET", path = "/v1/https" }))
    local response = T.http(mock, "POST", "/v1/sealed", { tls = true, host = host, headers = { Origin = origin }, body = { envelope = envelope } })
    T.eq(response.status, 200, response.body)
    T.eq(response.headers["access-control-allow-origin"], origin)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    T.eq(answer.status, 200)
    T.eq(Json.decode(answer.body).state, "listening")
end

function tests.the_apps_switch_over_the_tls_server_changes_nothing()
    local s, asked = listening()
    local host = asked.name .. ":28443"
    local answer = T.http(s.mock, "PUT", "/v1/https", { key = s.key, tls = true, host = host, body = { enabled = false } })
    T.eq(answer.status, 409, answer.body)
    T.eq(answer.json.code, "SET_IN_COMPOSER")
    T.eq(answer.closed, true, "the whole answer, then the connection closed")
    T.truthy(s.mock.tlsServers[PORT], "the TLS server still runs")
    T.eq(#httpsTimers(s.mock, false) > 0 and hasTimer(s.mock, 2), false, "no stop on its way")
    T.eq(status(s).state, "listening")
    -- Composer's Off stops it at once.
    composer("Off")
    T.eq(s.mock.tlsServers[PORT], nil)
end

function tests.not_after_is_iso_8601_everywhere()
    local s, _, _, notAfter = listening()
    local pattern = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"
    T.truthy(notAfter:match(pattern))
    T.truthy(status(s).certificate.not_after:match(pattern), status(s).certificate.not_after)
    T.eq(status(s).certificate.not_after, notAfter)
    local system = T.http(s.mock, "GET", "/v1/system", { key = s.key }).json
    T.truthy(system.direct_https.not_after:match(pattern), system.direct_https.not_after)
    T.eq(system.direct_https.not_after, notAfter)
end

function tests.errors_are_short_sentences_for_the_owner()
    local texts = {}
    local function collect(s)
        local text = status(s).error
        T.truthy(type(text) == "string", "an error")
        texts[#texts + 1] = text
    end
    for _, code in ipairs({ "HTTPS_UNAVAILABLE", "NOT_CLAIMED", "RATE_LIMITED", "ACME_FAILED", "DNS_FAILED", "ADDRESS_NEEDED",
        "INVALID_REQUEST", "INTERNAL", "SOMETHING_NEW" }) do
        local s = home()
        local asked = turnOn(s)
        relaySays(s, { type = "https_certificate_result", id = asked.id, ok = false, code = code })
        collect(s)
    end
    local oldOs = home({ prepare = function(m)
        m.csrMode = "csr_only"
    end })
    composer("On")
    collect(oldOs)
    local noRemote = listening({ from = os.time() - 80 * DAY, to = os.time() + 10 * DAY })
    setProperty("Remote Access", "Off")
    collect(noRemote)
    for _, text in ipairs(texts) do
        T.truthy(#text <= 120, text)
        T.truthy(text:match("^%u") and text:match("%.$"), "a sentence: " .. text)
        T.truthy(not text:match("%u%u+_%u"), "no code: " .. text)
        T.truthy(not text:find("C4:", 1, true), "nothing of Director's: " .. text)
    end
end

function tests.a_handle_reused_after_a_tls_connection_never_takes_the_name_on_41999()
    local s, asked = listening()
    local mock, name = s.mock, asked.name
    local handle = 9001
    local function request(identifier)
        mock.sent[handle], mock.closed[handle] = nil, nil
        OnServerDataIn(handle, "GET /v1/health HTTP/1.1\r\nHost: " .. name .. "\r\n\r\n", "192.168.1.50", "50123", identifier)
        return T.response(mock, handle).status
    end
    -- A TLS connection (a Director without identifiers: by its port) whose close was never told,
    -- then a plain connection on 41999 with the same handle.
    OnServerConnectionStatusChanged(handle, 28443, "ONLINE", "192.168.1.50")
    OnServerConnectionStatusChanged(handle, 41999, "ONLINE", "192.168.1.51")
    T.eq(request(nil), 421, "the mark went with its connection")
    -- One that sent half a request first.
    OnServerConnectionStatusChanged(handle, 28443, "ONLINE", "192.168.1.50")
    OnServerDataIn(handle, "GET /v1/health HTTP/1.1\r\n", "192.168.1.50", "50123", nil)
    OnServerConnectionStatusChanged(handle, 41999, "ONLINE", "192.168.1.51")
    T.eq(request(nil), 421)
    -- Closed: nothing left.
    OnServerConnectionStatusChanged(handle, 28443, "ONLINE", "192.168.1.50")
    OnServerConnectionStatusChanged(handle, 28443, "OFFLINE", "192.168.1.50")
    T.eq(request(nil), 421)
    -- A mark whose connection said nothing for longer than a stale connection lives.
    OnServerConnectionStatusChanged(handle, 28443, "ONLINE", "192.168.1.50")
    later(31, function()
        T.eq(request(nil), 421)
    end)
    -- The TLS connection itself still takes it.
    OnServerConnectionStatusChanged(handle, 28443, "ONLINE", "192.168.1.50")
    T.eq(request(nil), 200)
    T.eq(request("https"), 200)
end

-- Director's clock (C4:GetTime) `seconds` on (5 by default): an OFFLINE then is no longer part of
-- the TLS server's start.
local function afterStart(mock, seconds)
    mock.clock = mock.clock + (seconds or 5) * 1000
end

-- The log's warnings about the TLS server.
local function serverWarnings(mock)
    local found = {}
    for _, line in ipairs(mock.debugLog) do
        if line:find("[WARN][https] TLS server", 1, true) then
            found[#found + 1] = line
        end
    end
    return found
end

function tests.a_tls_server_that_goes_offline_is_started_again()
    local s = listening()
    local calls = #s.mock.tlsCalls
    afterStart(s.mock)
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    local current = status(s)
    T.eq(current.state, "error")
    T.eq(current.error, "The controller's HTTPS server stopped. Trying again in a minute.")
    T.eq(T.http(s.mock, "GET", "/v1/system", { key = s.key }).json.direct_https, Json.null)
    -- Not a failure yet (Director may bring it back first): no warning until the retry acts.
    T.eq(#serverWarnings(s.mock), 0)
    T.contains(logText(s.mock), "TLS server offline; started again in 10 s unless it comes back")
    s.mock.tlsFails = "address in use"
    fire(s.mock, 10)
    T.eq(#s.mock.tlsCalls, calls + 1, "started again after 10 s")
    T.eq(s.mock.destroyedServers[#s.mock.destroyedServers], PORT, "the old one by its port first")
    -- Still offline when the retry acted: an outage, warned about and counted; then it could not start.
    T.contains(serverWarnings(s.mock)[1], "TLS server still offline 10 s later; started again")
    T.contains(serverWarnings(s.mock)[1], '"failures":1')
    T.contains(serverWarnings(s.mock)[2], "TLS server not running; started again later")
    T.contains(serverWarnings(s.mock)[2], '"failures":2')
    T.eq(status(s).error, "The controller couldn't start its HTTPS server. Trying again in a minute.")
    s.mock.tlsFails = nil
    fire(s.mock, 30)
    T.eq(#s.mock.tlsCalls, calls + 2, "then after 30 s")
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(status(s).state, "listening")
    T.eq(status(s).error, Json.null)
    -- Started, and Director never says it is online: counts as not started.
    afterStart(s.mock)
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    fire(s.mock, 10)
    T.eq(status(s).state, "error")
    fire(s.mock, 30)
    T.truthy(hasTimer(s.mock, 30), "started again after the next wait")
    T.eq(status(s).error, "The controller couldn't start its HTTPS server. Trying again in a minute.")
    -- Off: nothing is started again.
    composer("Off")
    T.eq(#httpsTimers(s.mock, false), 0)
end

-- The owner's controller at the 1.12.2 update: the TLS server started at late init, then Director
-- stopped and started every driver's servers (OFFLINE, ONLINE 5 ms later), the API's on 41999 too.
-- 1.12.2 warned "TLS server not running; started again later" for it (1.13.0).
function tests.director_stopping_and_starting_the_server_at_start_is_no_failure()
    local s = home()
    local asked = turnOn(s)
    relaySays(s, { type = "https_certificate_result", id = asked.id, ok = true, status = "pending" })
    issued(s, asked)
    local calls = #s.mock.tlsCalls
    T.eq(s.mock.tlsServers[PORT] ~= nil, true, "started")
    -- Director's OFFLINE a moment after our CreateTLSServer: part of the start.
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    T.eq(hasTimer(s.mock, 10), false, "no retry")
    T.eq(status(s).state, "requesting", "starting, not an error")
    T.contains(logText(s.mock), "TLS server offline right after it was started; the start goes on")
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(status(s).state, "listening")
    T.eq(#serverWarnings(s.mock), 0, "no warning")
    T.eq(#s.mock.tlsCalls, calls, "not started again")
    T.eq(#httpsTimers(s.mock, false) > 0 and hasTimer(s.mock, 30), false, "its watch ended too")

    -- The same once it has been listening a while: OFFLINE, and ONLINE before the retry acts.
    afterStart(s.mock)
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    T.truthy(hasTimer(s.mock, 10), "a retry, should it stay offline")
    T.eq(status(s).state, "error", "offline meanwhile")
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(hasTimer(s.mock, 10), false, "the retry is off")
    T.eq(status(s).state, "listening")
    T.eq(status(s).error, Json.null)
    T.eq(#serverWarnings(s.mock), 0, "still no warning")
    T.eq(#s.mock.tlsCalls, calls)
    T.contains(logText(s.mock), '"retry_s":10')
    -- Again: still the first step of the backoff (nothing was counted).
    afterStart(s.mock)
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    T.truthy(hasTimer(s.mock, 10))
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(#serverWarnings(s.mock), 0)
end

-- An OFFLINE right after the start that Director never follows with ONLINE is still an outage: the
-- start's watch warns and the server is started again.
function tests.an_offline_at_start_without_online_is_still_started_again()
    local s = home()
    local asked = turnOn(s)
    issued(s, asked)
    local calls = #s.mock.tlsCalls
    OnServerStatusChanged(PORT, "OFFLINE", "https")
    T.eq(#serverWarnings(s.mock), 0)
    fire(s.mock, 30)
    T.eq(#serverWarnings(s.mock), 2, "not online 30 s after the start, and started again later")
    T.contains(serverWarnings(s.mock)[1], "TLS server not online 30 s after it was started")
    T.eq(status(s).state, "error")
    T.eq(status(s).error, "The controller couldn't start its HTTPS server. Trying again in a minute.")
    fire(s.mock, 10)
    T.eq(#s.mock.tlsCalls, calls + 1, "started again")
    OnServerStatusChanged(PORT, "ONLINE", "https")
    T.eq(status(s).state, "listening")
end

function tests.a_new_certificate_that_cannot_start_the_server_leaves_the_old_one_running()
    local now = os.time()
    local s, _, oldLeaf, oldEnd = listening({ from = now - 50 * DAY, to = now + 40 * DAY })
    later(21 * DAY, function()
        tick(s.mock)
        local renewal = httpsMessages(s)[1]
        local newLeaf = certificateFor(renewal, { from = os.time(), serial = 2 })
        s.mock.tlsRefuses = { [newLeaf] = "unusable certificate" }
        local calls = #s.mock.tlsCalls
        relaySays(s, { type = "https_certificate_result", id = renewal.id, ok = true, status = "issued", name = renewal.name,
            certificate = newLeaf, chain = INTERMEDIATE, not_after = "x" })
        T.eq(#s.mock.tlsCalls, calls + 2, "the new one tried, then the old one again")
        T.eq(s.mock.tlsCalls[calls + 1].certificate, newLeaf)
        T.eq(s.mock.tlsServers[PORT].certificate, oldLeaf, "the old certificate serves")
        T.eq(stored(s.mock).certificate, oldLeaf, "and stays stored")
        OnServerStatusChanged(PORT, "ONLINE", "https")
        local current = status(s)
        T.eq(current.state, "listening")
        T.eq(current.certificate.not_after, oldEnd)
        T.eq(current.error, "The new certificate couldn't start the HTTPS server. Trying again in 5 minutes.")
        T.contains(logText(s.mock), "unusable certificate")
        -- A good one later replaces it.
        fire(s.mock, 300)
        local again = httpsMessages(s)[1]
        local good = issued(s, again, { from = os.time(), serial = 3 })
        T.eq(s.mock.tlsServers[PORT].certificate, good)
        T.eq(stored(s.mock).certificate, good)
    end)
end

function tests.the_host_check_takes_no_name_before_there_is_one()
    local s = home()
    T.eq(T.http(s.mock, "GET", "/v1/health", { tls = true, host = "abcdefghijabcdefghij.dlhome.cc" }).status, 421)
end

return tests
