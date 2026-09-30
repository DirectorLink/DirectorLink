-- Keys that expire (ADR-040): POST /v1/auth/pair with expires_in (the console asks for a day), the
-- refusal with KEY_EXPIRED and the removal once it has passed, expires_at in the key views, and the
-- one-time change at the first start of 1.3.0 that gives the console's older keys a day.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

local STORE = "directorlink_api_key_hashes"
local DAY = 24 * 60 * 60

local function pairWith(mock, body)
    if not tostring(mock.properties["Pairing Code"] or ""):match("^%d%d%d%d %d%d%d%d$") then
        ExecuteCommand("LUA_ACTION", { ACTION = "NEW_PAIRING_CODE" })
    end
    body.pairing_code = mock.properties["Pairing Code"]
    return T.http(mock, "POST", "/v1/auth/pair", { body = body })
end

-- Runs f with the clock `seconds` ahead.
local function later(seconds, f)
    local realTime = os.time
    os.time = function(...)
        if select("#", ...) > 0 then
            return realTime(...)
        end
        return realTime() + seconds
    end
    local ok, result = pcall(f)
    os.time = realTime
    if not ok then
        error(result, 0)
    end
    return result
end

local function isoSeconds(text)
    local y, m, d, hh, mm, ss = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
    -- Seconds since 1970 of a UTC time, without the local time zone.
    local days = 0
    for year = 1970, tonumber(y) - 1 do
        local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
        days = days + (leap and 366 or 365)
    end
    local lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if (tonumber(y) % 4 == 0 and tonumber(y) % 100 ~= 0) or tonumber(y) % 400 == 0 then
        lengths[2] = 29
    end
    for month = 1, tonumber(m) - 1 do
        days = days + lengths[month]
    end
    days = days + tonumber(d) - 1
    return ((days * 24 + tonumber(hh)) * 60 + tonumber(mm)) * 60 + tonumber(ss)
end

function tests.expires_in_is_checked_and_shown()
    local mock = Mock.startDriver()
    for _, bad in ipairs({ 59, 2592001, 90.5, "86400", true }) do
        local refused = pairWith(mock, { name = "Console", expires_in = bad })
        T.eq(refused.status, 400, tostring(bad))
        T.eq(refused.json.errors[1].field, "expires_in")
    end
    local before = os.time()
    local paired = pairWith(mock, { name = "DirectorLink Console", expires_in = DAY })
    T.eq(paired.status, 201, paired.body)
    local expiresAt = isoSeconds(paired.json.expires_at)
    T.truthy(expiresAt >= before + DAY and expiresAt <= os.time() + DAY, "a day from now: " .. paired.json.expires_at)
    local key = paired.json.key
    T.eq(T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json.expires_at, paired.json.expires_at, "the current key")
    local listed = T.http(mock, "GET", "/v1/api-keys", { key = key }).json.items
    T.eq(listed[1].expires_at, paired.json.expires_at, "the list")

    local script = pairWith(mock, { name = "Script" })
    T.eq(script.json.expires_at, Json.null, "without expires_in, never")
    T.eq(pairWith(mock, { name = "Short", expires_in = 60 }).status, 201, "a minute is the least")
end

function tests.keys_made_in_the_keys_tab_do_not_expire()
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Admin")
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "Home Assistant", role = "member" } })
    T.eq(created.status, 201)
    T.eq(created.json.expires_at, Json.null)
    T.eq(T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = "X", expires_in = 60 } }).json.errors[1].field, "expires_in", "not asked for there")
end

function tests.an_expired_key_is_refused_with_key_expired_and_removed()
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Admin")
    local console = pairWith(mock, { name = "DirectorLink Console", expires_in = DAY }).json
    T.eq(mock.properties["API Keys"], "2")
    -- An invitation it made goes with it, as with a revoked key.
    local Invitations = require("src.auth.invitations")
    T.truthy(Invitations.create("member", 3600, console.id))
    T.eq(#Invitations.list(), 1)

    T.eq(later(DAY - 5, function()
        return T.http(mock, "GET", "/v1/system", { key = console.key }).status
    end), 200, "still valid just before")
    local refused = later(DAY + 1, function()
        return T.http(mock, "GET", "/v1/system", { key = console.key })
    end)
    T.eq(refused.status, 401)
    T.eq(refused.json.code, "KEY_EXPIRED")
    T.contains(refused.json.detail, "New Pairing Code")
    T.eq(mock.properties["API Keys"], "1", "removed")
    T.notContains(mock.persist[STORE], console.id, "and gone from the store")
    T.eq(#Invitations.list(), 0, "its invitation too")
    T.eq(T.http(mock, "GET", "/v1/system", { key = console.key }).json.code, "UNAUTHORIZED", "then it is just unknown")
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).status, 200, "other keys are not touched")
end

function tests.an_expired_key_goes_when_the_keys_are_listed_or_counted()
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Admin")
    pairWith(mock, { name = "Short", expires_in = 60 })
    local items = later(61, function()
        return T.http(mock, "GET", "/v1/api-keys", { key = admin }).json.items
    end)
    T.eq(#items, 1, "not listed")
    T.eq(mock.properties["API Keys"], "1")
end

function tests.a_sealed_request_with_an_expired_key_is_refused()
    local mock = Mock.startDriver()
    local Keys = require("src.auth.keys")
    local paired = pairWith(mock, { name = "Phone", expires_in = 60 }).json
    T.truthy(Keys.remote(paired.id), "a lock key while it lasts")
    later(61, function()
        T.eq(Keys.remote(paired.id), nil, "none after")
    end)
    T.eq(Keys.count(), 0, "and it is gone")
end

-- The store as 1.2.0 wrote it: version 3, and no expiry.
local function asVersion3(mock)
    local text = mock.persist[STORE]:gsub("^json:", "")
    local stored = Json.decode(text)
    stored.version = 3
    for _, key in ipairs(stored.keys) do
        key.expires = nil
    end
    mock.persist[STORE] = "json:" .. Json.encode(stored)
end

function tests.the_consoles_older_keys_get_a_day_at_the_first_start_of_1_3_0()
    local mock = Mock.startDriver()
    local app = T.pair(mock, "Chrome on Windows")
    T.pair(mock, "DirectorLink Console")
    asVersion3(mock)

    local started = os.time()
    local updated = Mock.updateDriver(mock)
    local items = T.http(updated, "GET", "/v1/api-keys", { key = app }).json.items
    local byName = {}
    for _, item in ipairs(items) do
        byName[item.name] = item
    end
    T.eq(byName["Chrome on Windows"].expires_at, Json.null, "other keys never expire")
    local expiresAt = isoSeconds(byName["DirectorLink Console"].expires_at)
    T.truthy(expiresAt >= started + DAY and expiresAt <= os.time() + DAY, "a day from the first start: " .. byName["DirectorLink Console"].expires_at)
    T.contains(updated.persist[STORE], '"version":4')

    -- Once only: a later start gives it no other day, and a key made later with that name in the
    -- Keys tab (for a script) never expires.
    local script = T.http(updated, "POST", "/v1/api-keys", { key = app, body = { name = "DirectorLink Console", role = "viewer" } }).json
    local again = later(3600, function()
        return Mock.updateDriver(updated)
    end)
    local kept = later(3600, function()
        return T.http(again, "GET", "/v1/api-keys", { key = app }).json.items
    end)
    T.eq(#kept, 3)
    for _, item in ipairs(kept) do
        if item.id == script.id then
            T.eq(item.expires_at, Json.null, "the script's key")
        elseif item.name == "DirectorLink Console" then
            T.eq(item.expires_at, byName["DirectorLink Console"].expires_at, "the console's")
        end
    end
end

return tests
