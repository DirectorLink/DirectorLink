-- Users and their devices (1.9.0, ADR-061; src/auth/users.lua, src/auth/accounts.lua,
-- src/api/handlers/users.lua): Settings → Users, up to five devices a user on every path that adds
-- one, the devices of one account brought into one user without the account service ever raising
-- anyone's access, pairing at home for a user an admin chose, members adding and removing their own
-- devices, a user going with their last device, and what 1.8.0 left behind.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

local TAG_A = "a1a1a1a1a1a1a1a1"
local TAG_B = "b2b2b2b2b2b2b2b2"

local function get(mock, key, path)
    return T.http(mock, "GET", path, { key = key })
end

local function start()
    local mock = Mock.startDriver()
    local admin = T.pair(mock, "Owner's laptop")
    return mock, admin
end

-- A connected driver (the fake relay) with the owner's key.
local function session()
    local mock, key = start()
    local _, connection, _, hello = Harness.connected({ mock = mock })
    local me = get(mock, key, "/v1/api-keys/current").json
    local remote = get(mock, key, "/v1/remote").json
    return { mock = mock, connection = connection, key = key, keyId = me.id, profile = me.profile_id, home = remote.home_id, hello = hello }
end

-- A new user with one key: a member (`access`) unless `role` says admin.
local function newUser(mock, admin, name, access, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name, role = role or "member", access = access or {} } })
    T.eq(created.status, 201, created.body)
    return created.json.key, created.json
end

-- Another device of an existing user.
local function addDevice(mock, admin, profileId, name)
    return T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name, profile_id = profileId } })
end

local function users(mock, key)
    local answer = get(mock, key, "/v1/users")
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function userById(list, id)
    for _, item in ipairs(list.items) do
        if item.id == id then
            return item
        end
    end
    return nil
end

local function profileOf(mock, key)
    return get(mock, key, "/v1/api-keys/current").json.profile_id
end

-- The relay says which keys share an account; returns the messages the driver sent meanwhile.
local function accounts(s, keys)
    s.connection.sent = ""
    ReceivedFromNetwork(Harness.BINDING, 443, Harness.serverFrame(1, Json.encode({ type = "accounts", id = "acc-" .. tostring(os.clock()), keys = keys })))
    local sent = {}
    for _, frame in ipairs(Harness.clientFrames(s.connection.sent)) do
        sent[#sent + 1] = Json.decode(frame.payload)
    end
    s.connection.sent = ""
    return sent
end

local function history(mock, admin, action)
    local found = {}
    for _, entry in ipairs(get(mock, admin, "/v1/activity?kind=access&limit=200").json.items) do
        if entry.action == action then
            found[#found + 1] = entry
        end
    end
    return found
end

local function idOf(mock, key)
    return get(mock, key, "/v1/api-keys/current").json.id
end

-- The suggestion for the account `tag` as `key` sees it in Settings → Users, or nil.
local function suggestionOf(mock, key, tag)
    for _, suggestion in ipairs(users(mock, key).suggestions) do
        if suggestion.id == tag then
            return suggestion
        end
    end
    return nil
end

-- Confirms the suggestion for `tag` as `key` sees it now, keeping `keep`.
local function confirm(mock, key, tag, keep, revision)
    if revision == nil then
        local suggestion = suggestionOf(mock, key, tag)
        revision = suggestion and suggestion.revision or "0000000000000000"
    end
    return T.http(mock, "POST", "/v1/users/merge", { key = key, body = { account = tag, keep = keep, revision = revision } })
end

-- ---- up to five devices a user ------------------------------------------------------------------

function tests.a_sixth_device_is_refused_with_the_users_devices()
    local mock, admin = start()
    local first, kid = newUser(mock, admin, "Kid's phone")
    for index = 2, 5 do
        T.eq(addDevice(mock, admin, kid.profile_id, "Kid's device " .. index).status, 201)
    end
    T.eq(get(mock, first, "/v1/lights").status, 200, "the first device was used")
    local refused = addDevice(mock, admin, kid.profile_id, "Kid's sixth")
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "USER_DEVICE_LIMIT")
    T.eq(refused.json.limit, 5)
    T.eq(refused.json.user.id, kid.profile_id)
    T.eq(#refused.json.devices, 5, "the user's devices, for the app to say which to remove")
    T.eq(refused.json.devices[1].name, "Kid's phone")
    T.truthy(refused.json.devices[1].last_used_at ~= Json.null, "with when each was last used")
    T.eq(refused.json.devices[1].removable, true, "an admin may remove a member's device")
    -- Moving a key into the user, an invitation for them, a pairing code for them: all refused.
    local _, other = newUser(mock, admin, "Spare tablet")
    local moved = T.http(mock, "PATCH", "/v1/api-keys/" .. other.id, { key = admin, body = { profile_id = kid.profile_id } })
    T.eq(moved.json.code, "USER_DEVICE_LIMIT")
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } }).json.code, "USER_DEVICE_LIMIT")
    T.eq(#users(mock, admin).items, 3, "the owner, the kid and the spare tablet")
    -- One removed: room for one more.
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. refused.json.devices[5].id, { key = admin }).status, 204)
    T.eq(addDevice(mock, admin, kid.profile_id, "Kid's new phone").status, 201)
end

function tests.a_user_with_more_than_five_from_before_keeps_them_and_gets_none()
    local mock, admin = start()
    local _, kid = newUser(mock, admin, "Kid 1")
    -- 1.8.0 had no limit: six devices in one user.
    local keys = { kid.key }
    for index = 2, 6 do
        local _, extra = newUser(mock, admin, "Kid " .. index)
        keys[#keys + 1] = extra.key
    end
    local stored = Json.decode(mock.persist["directorlink_api_key_hashes"]:sub(6))
    for _, key in ipairs(stored.keys) do
        if key.name:match("^Kid") then
            key.profile = kid.profile_id
        end
    end
    mock.persist["directorlink_api_key_hashes"] = "json:" .. Json.encode(stored)
    local again = Mock.updateDriver(mock)
    for _, key in ipairs(keys) do
        T.eq(get(again, key, "/v1/api-keys/current").json.profile_id, kid.profile_id, "every one of them still works")
    end
    T.eq(#userById(users(again, admin), kid.profile_id).devices, 6)
    T.eq(addDevice(again, admin, kid.profile_id, "Kid 7").json.code, "USER_DEVICE_LIMIT")
    T.eq(T.http(again, "DELETE", "/v1/api-keys/" .. idOf(again, keys[6]), { key = admin }).status, 204)
    T.eq(addDevice(again, admin, kid.profile_id, "Kid 7").json.code, "USER_DEVICE_LIMIT", "five: still none")
    T.eq(T.http(again, "DELETE", "/v1/api-keys/" .. idOf(again, keys[5]), { key = admin }).status, 204)
    T.eq(addDevice(again, admin, kid.profile_id, "Kid 7").status, 201, "four: one more")
end

-- ---- Settings → Users ---------------------------------------------------------------------------

function tests.admins_see_every_user_a_member_only_themself()
    local mock, admin = start()
    local kid, kidKey = newUser(mock, admin, "Kid's phone", { all_rooms = false, rooms = { 11 } })
    T.eq(addDevice(mock, admin, kidKey.profile_id, "Kid's tablet").status, 201)
    local all = users(mock, admin)
    T.eq(all.device_limit, 5)
    T.eq(#all.items, 2)
    local owner = userById(all, profileOf(mock, admin))
    T.eq(owner.you, true)
    T.eq(owner.access.role, "admin")
    T.eq(owner.access.owner, true)
    T.eq(owner.devices[1].current, true)
    T.eq(owner.devices[1].removable, false, "this device is forgotten, not removed here")
    local child = userById(all, kidKey.profile_id)
    T.eq(child.access.role, "member")
    T.same(child.access.rooms, { 11 })
    T.eq(#child.devices, 2)
    T.eq(child.accounts, 0, "no account seen: the home network only")
    local mine = users(mock, kid)
    T.eq(#mine.items, 1, "a member sees only their own user")
    T.eq(mine.items[1].id, kidKey.profile_id)
    T.eq(mine.items[1].you, true)
    T.eq(#mine.suggestions, 0)
    T.eq(mine.items[1].devices[2].removable, true, "their own other device")
    T.eq(get(mock, kid, "/v1/profiles").status, 403, "the admins' list stays theirs")
    T.eq(get(mock, admin, "/v1/system").json.features.users, true)
end

function tests.members_remove_their_own_other_devices_only()
    local mock, admin = start()
    local phone, kid = newUser(mock, admin, "Kid's phone")
    local tablet = addDevice(mock, admin, kid.profile_id, "Kid's tablet").json
    local _, sister = newUser(mock, admin, "Sister's phone")
    local ownerId = idOf(mock, admin)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. sister.id, { key = phone }).status, 404, "another user's device is not theirs to see")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. ownerId, { key = phone }).status, 404)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/deadbeef", { key = phone }).status, 404)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. tablet.id, { key = phone }).status, 204)
    T.eq(get(mock, tablet.key, "/v1/api-keys/current").status, 401, "the tablet's key is gone")
    T.eq(#history(mock, admin, "revoked"), 1)
    T.eq(T.http(mock, "PATCH", "/v1/api-keys/" .. sister.id, { key = phone, body = { profile_id = kid.profile_id } }).status, 403, "moving devices stays the admins'")
end

-- ---- pairing at home for a chosen user ----------------------------------------------------------

function tests.a_pairing_code_made_in_the_app_pairs_into_the_user_chosen()
    local mock, admin = start()
    local _, kid = newUser(mock, admin, "Kid's phone", { all_rooms = false, rooms = { 11 }, cameras = false })
    local made = T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } })
    T.eq(made.status, 201, made.body)
    T.truthy(made.json.code:match("^%d%d%d%d %d%d%d%d$"), made.json.code)
    T.eq(made.json.user.id, kid.profile_id)
    T.eq(made.json.user.role, "member")
    T.eq(mock.properties["Pairing Code"], made.json.code, "one code at a time, shown in Composer too")
    T.contains(mock.properties["Pairing Status"], "made in the app")
    -- The new device cannot choose its user.
    local asked = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = made.json.code, name = "Kid's iPad", profile_id = profileOf(mock, admin) } })
    T.eq(asked.status, 400, "no profile_id from the device")
    local paired = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = made.json.code, name = "Kid's iPad" } })
    T.eq(paired.status, 201, paired.body)
    local me = get(mock, paired.json.key, "/v1/api-keys/current").json
    T.eq(me.profile_id, kid.profile_id, "the kid's user")
    T.eq(me.access.role, "member")
    T.same(me.access.rooms, { 11 })
    T.eq(me.access.cameras, false)
    T.eq(me.name, "Kid's iPad", "named as the device says")
    -- A new user, with the name and access an admin chose.
    local fresh = T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { name = "Kitchen tablet", role = "member", access = { all_rooms = false, rooms = { 10 } } } }).json
    T.eq(fresh.user.id, Json.null)
    local tablet = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = fresh.code, name = "Chrome on Android" } }).json
    local tabletUser = get(mock, tablet.key, "/v1/api-keys/current").json
    T.same(tabletUser.access.rooms, { 10 })
    T.eq(get(mock, tablet.key, "/v1/profile").json.name, "Kitchen tablet")
    -- Composer's code still makes a new admin user.
    local installer = T.pair(mock, "Installer's laptop")
    local installerUser = get(mock, installer, "/v1/api-keys/current").json
    T.eq(installerUser.access.role, "admin")
    T.truthy(installerUser.profile_id ~= kid.profile_id and installerUser.profile_id ~= profileOf(mock, admin), "a user of its own")
    -- Only admins make codes; the owner's user only the owner; a code can be closed.
    local kidKey = newUser(mock, admin, "Another kid")
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = kidKey, body = { profile_id = kid.profile_id } }).status, 403)
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = installer, body = { profile_id = profileOf(mock, admin) } }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id, name = "x" } }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = {} }).json.code, "INVALID_FIELD")
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } }).status, 201)
    T.eq(T.http(mock, "DELETE", "/v1/pairing-code", { key = admin }).status, 204)
    T.eq(mock.properties["Pairing Code"], "-")
    T.eq(T.http(mock, "DELETE", "/v1/pairing-code", { key = admin }).status, 404)
    T.truthy(#history(mock, admin, "pairing_code") >= 3)
end

function tests.a_code_for_a_user_works_only_while_its_maker_and_its_user_are_there()
    local mock, admin = start()
    local partner = newUser(mock, admin, "Partner", nil, "admin")
    local kidKey, kid = newUser(mock, admin, "Kid's phone")
    local code = T.http(mock, "POST", "/v1/pairing-code", { key = partner, body = { profile_id = kid.profile_id } }).json.code
    -- The partner is no longer an admin: the code stops working when used.
    T.eq(T.http(mock, "PATCH", "/v1/profiles/" .. profileOf(mock, partner) .. "/access", { key = admin, body = { role = "member" } }).status, 200)
    local refused = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = code, name = "Kid's iPad" } })
    T.eq(refused.status, 403)
    T.eq(refused.json.code, "PAIRING_NOT_ACTIVE")
    -- A code for a user who then goes with their last device closes.
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } }).status, 201)
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/current", { key = kidKey }).status, 204)
    T.eq(mock.properties["Pairing Code"], "-", "the user went, and the code with them")
end

-- CPace (the app's pairing) goes into the code's user too, and a full user is said at its start.
function tests.pairing_with_cpace_joins_the_codes_user()
    local mock, admin = start()
    local _, kid = newUser(mock, admin, "Kid's phone")
    local Base64, Cpace, CpacePairing, Lock = require("src.core.base64"), require("src.core.cpace"), require("src.auth.cpace_pairing"), require("src.cloud.lock")
    local code = T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } }).json.code:gsub(" ", "")
    local nonce = string.rep(string.char(3), 16)
    local started = T.http(mock, "POST", "/v1/auth/pair", { body = { name = "Safari on iPhone", cpace = { nonce = Base64.encode(nonce) } } })
    T.eq(started.status, 200, started.body)
    local Ya = Base64.decode(started.json.cpace.share)
    local sid = nonce .. Base64.decode(started.json.cpace.nonce)
    local g = Cpace.generator(code, CpacePairing.channel("Safari on iPhone", nil), sid)
    local yb = string.rep(string.char(9), 32)
    local Yb = Cpace.share(yb, g)
    local isk = Cpace.isk(sid, Cpace.secret(yb, Ya), Ya, "", Yb, "")
    local finished = T.http(mock, "POST", "/v1/auth/pair", { body = { cpace = { session = started.json.cpace.session, share = Base64.encode(Yb), confirm = Base64.encode(Cpace.tag(Cpace.macKey(sid, isk), Yb, "")) } } })
    T.eq(finished.status, 201, finished.body)
    local created = Json.decode(Lock.open(Lock.cpaceKey(Base64.toHex(isk)), finished.json.sealed, "res"))
    T.eq(get(mock, created.key, "/v1/api-keys/current").json.profile_id, kid.profile_id)
    -- Full: the start says so, and nothing counts against the code.
    for index = 3, 5 do
        T.eq(addDevice(mock, admin, kid.profile_id, "Kid " .. index).status, 201)
    end
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } }).json.code, "USER_DEVICE_LIMIT")
end

-- ---- members add their own devices --------------------------------------------------------------

local counter = 0

local function join(s, invitation, name)
    local Lock = require("src.cloud.lock")
    local lock = Lock.invitationKey(invitation.secret)
    counter = counter + 1
    local request = { id = "join-" .. counter, ts = os.time(), method = "POST", path = "/v1/auth/join", body = { name = name } }
    local envelope = Lock.seal(lock, s.home, invitation.id, "req", Json.encode(request))
    local reply = Harness.relayRequest(s.mock, s.connection, { type = "join", id = "relay-join-" .. counter, invitation = invitation.id, envelope = envelope })
    if not reply.ok then
        return nil, reply.code
    end
    return Json.decode(Json.decode(Lock.open(lock, reply.envelope, "res")).body)
end

function tests.a_member_invites_their_own_other_device_within_five()
    local s = session()
    local phone, kid = newUser(s.mock, s.key, "Kid's phone", { all_rooms = false, rooms = { 11 } })
    local made = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true, expires_in = 600 } })
    T.eq(made.status, 201, made.body)
    T.eq(made.json.for_me, true)
    local joined = join(s, made.json, "Kid's iPad")
    local me = get(s.mock, joined.key, "/v1/api-keys/current").json
    T.eq(me.profile_id, kid.profile_id, "into their own user")
    T.same(me.access.rooms, { 11 }, "with their permissions, never more")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { role = "member" } }).status, 403, "only admins invite others")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { role = "admin", for_me = true } }).json.access, nil, "their own device is never an admin's")
    T.eq(get(s.mock, phone, "/v1/invitations").status, 403)
    -- They revoke what their devices invited, and no one else's.
    local again = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true } }).json
    local admins = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).json
    T.eq(T.http(s.mock, "DELETE", "/v1/invitations/" .. admins.id, { key = phone }).status, 404)
    T.eq(T.http(s.mock, "DELETE", "/v1/invitations/" .. again.id, { key = joined.key }).status, 204, "another device of theirs")
    -- Full at the join: refused, and the invitation stays for when one is removed.
    local late = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true } }).json
    for index = 3, 5 do
        T.eq(addDevice(s.mock, s.key, kid.profile_id, "Kid " .. index).status, 201)
    end
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true } }).json.code, "USER_DEVICE_LIMIT")
    local _, code = join(s, late, "Kid's sixth")
    T.eq(code, "USER_DEVICE_LIMIT")
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. me.id, { key = phone }).status, 204)
    T.truthy(join(s, late, "Kid's sixth"), "room again: the same invitation works")
end

-- The driver's messages to the relay since the last look (its key announcements left out).
local function relayed(s)
    local list = {}
    for _, frame in ipairs(Harness.answers(Harness.clientFrames(s.connection.sent))) do
        list[#list + 1] = Json.decode(frame.payload)
    end
    s.connection.sent = ""
    return list
end

local function relayAnswers(message)
    ReceivedFromNetwork(Harness.BINDING, 443, Harness.serverFrame(1, Json.encode(message)))
end

-- A member's invitation for their own other device is bound only to an account that already uses
-- the member's device at the home: the controller asks the account service to register it for that
-- key's account (`for_key`), never for whatever email a member names (probe p3).
function tests.a_members_invitation_is_bound_only_to_an_account_of_their_device()
    local s = session()
    local phone, kid = newUser(s.mock, s.key, "Kid's phone", { all_rooms = false, rooms = { 11 } })
    s.connection.sent = ""
    local pending = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true, email = "stranger@example.com" } })
    T.eq(pending.status, nil, "waits for the account service")
    local asked = relayed(s)
    T.eq(#asked, 1)
    T.eq(asked[1].type, "invitation")
    T.eq(asked[1].for_key, kid.id, "only for an account that uses this device's key")
    -- The account service says that email's account does not use this key here.
    relayAnswers({ type = "invitation_result", id = asked[1].id, ok = false, code = "ACCOUNT_NOT_OF_DEVICE" })
    local refused = T.response(s.mock, pending.handle)
    T.eq(refused.status, 403, refused.body)
    T.eq(refused.json.code, "ACCOUNT_NOT_OF_DEVICE")
    -- An account service that does not know for_key registers by the email alone: refused here.
    pending = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true, email = "stranger@example.com" } })
    asked = relayed(s)
    relayAnswers({ type = "invitation_result", id = asked[1].id, ok = true })
    refused = T.response(s.mock, pending.handle)
    T.eq(refused.status, 502, refused.body)
    T.eq(refused.json.code, "FOR_KEY_UNSUPPORTED")
    local cancelled = relayed(s)
    T.eq(cancelled[1] and cancelled[1].type, "invitation_cancel", "it is told to forget it")
    T.eq(#get(s.mock, s.key, "/v1/invitations").json.items, 0, "neither is left at home")
    -- The account service checked: registered.
    pending = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true, email = "kid@example.com" } })
    asked = relayed(s)
    relayAnswers({ type = "invitation_result", id = asked[1].id, ok = true, for_key = kid.id })
    local made = T.response(s.mock, pending.handle)
    T.eq(made.status, 201, made.body)
    -- An admin's invitation names its email, as before.
    pending = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", email = "friend@example.com" } })
    asked = relayed(s)
    T.eq(asked[1].for_key, nil)
    relayAnswers({ type = "invitation_result", id = asked[1].id, ok = true })
    T.eq(T.response(s.mock, pending.handle).status, 201)
end

-- A member's invitations for their own device last 10 minutes at most, and their user keeps two
-- waiting at most (a new one replaces the oldest), so a member never fills the controller's 20
-- (probe p12).
function tests.a_members_own_invitations_are_few_and_short()
    local s = session()
    local phone = newUser(s.mock, s.key, "Kid's phone", {})
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true, expires_in = 7200 } }).json.code, "INVALID_FIELD")
    local made = {}
    for index = 1, 20 do
        local answer = T.http(s.mock, "POST", "/v1/invitations", { key = phone, body = { for_me = true } })
        T.eq(answer.status, 201, answer.body)
        made[index] = answer.json
    end
    local seconds = 0
    do
        local function parse(text)
            local y, mo, d, h, mi, se = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
            return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) })
        end
        seconds = parse(made[20].expires_at) - parse(made[20].created_at)
    end
    T.eq(seconds, 600, "10 minutes")
    local waiting = {}
    for _, item in ipairs(get(s.mock, s.key, "/v1/invitations").json.items) do
        waiting[#waiting + 1] = item.id
    end
    T.same(waiting, { made[19].id, made[20].id }, "the two newest")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).status, 201, "an admin still invites")
end

-- Before a code is checked, a request without a key learns nothing of the user it is for (probe p4).
function tests.a_device_without_a_key_never_learns_the_codes_user()
    local mock, admin = start()
    local _, kid = newUser(mock, admin, "Kid's phone")
    for index = 2, 4 do
        T.eq(addDevice(mock, admin, kid.profile_id, "Kid " .. index).status, 201)
    end
    T.eq(T.http(mock, "POST", "/v1/pairing-code", { key = admin, body = { profile_id = kid.profile_id } }).status, 201)
    T.eq(addDevice(mock, admin, kid.profile_id, "Kid 5").status, 201)
    local asked = T.http(mock, "POST", "/v1/auth/pair", { body = { pairing_code = "0000 0000", name = "x" } })
    T.eq(asked.status, 409, asked.body)
    T.eq(asked.json.code, "USER_DEVICE_LIMIT")
    T.eq(asked.json.limit, 5)
    T.eq(asked.json.user, nil, "no name, no id")
    T.eq(asked.json.devices, nil)
    T.notContains(asked.body, "Kid")
end

function tests.an_admin_invites_another_device_of_a_user()
    local s = session()
    local _, kid = newUser(s.mock, s.key, "Kid's tablet", { cameras = false })
    local made = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", profile_id = kid.profile_id } })
    T.eq(made.status, 201, made.body)
    T.eq(made.json.for_me, false)
    T.eq(made.json.profile_id, kid.profile_id)
    local joined = join(s, made.json, "Kid's phone")
    local me = get(s.mock, joined.key, "/v1/api-keys/current").json
    T.eq(me.profile_id, kid.profile_id)
    T.eq(me.access.cameras, false)
    -- A user who is gone takes the invitations made for them.
    local gone = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", profile_id = kid.profile_id } }).json
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. kid.id, { key = s.key }).status, 204)
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. me.id, { key = s.key }).status, 204)
    local _, code = join(s, gone, "Late")
    T.eq(code, "INVITATION_NOT_FOUND", "never a new user of whoever opens it")
    T.eq(T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member", profile_id = kid.profile_id } }).json.code, "INVALID_FIELD")
end

-- ---- the devices of one account ----------------------------------------------------------------

function tests.the_hello_says_users_and_the_accounts_are_kept()
    local s = session()
    local hello = Json.decode(s.hello[1].payload)
    T.eq(hello.type, "hello")
    local listed = false
    for _, feature in ipairs(hello.features) do
        listed = listed or feature == "users"
    end
    T.truthy(listed, "the relay sends accounts only to a driver that says users")
    local _, kid = newUser(s.mock, s.key, "Kid's phone")
    T.eq(users(s.mock, s.key).accounts_known, false)
    -- Unknown keys, bad tags and a list instead of an object are left out or ignored.
    accounts(s, { [s.keyId] = { TAG_A, "NOT-HEX" }, ["deadbeef"] = { TAG_B }, [kid.id] = { TAG_B, TAG_A, TAG_A } })
    local list = users(s.mock, s.key)
    T.eq(list.accounts_known, true)
    T.eq(userById(list, s.profile).accounts, 1)
    T.eq(userById(list, kid.profile_id).devices[1].accounts, 2, "a device used by two accounts")
    local stored = Json.decode(s.mock.persist["directorlink_accounts"]:sub(6))
    T.eq(stored.keys["deadbeef"], nil, "only the keys there are")
    T.notContains(s.mock.persist["directorlink_accounts"], "@", "never an email")
    accounts(s, { "not", "an", "object" })
    T.eq(userById(users(s.mock, s.key), s.profile).accounts, 1, "a message of another shape changes nothing")
    local restarted = Mock.updateDriver(s.mock)
    T.eq(userById(users(restarted, s.key), s.profile).accounts, 1, "kept across a restart")
end

-- Every merge asks (the owner's decision of 2026-10-05): even users with the same permissions are
-- only a suggestion, which an admin confirms; the account service never moves a device.
function tests.alike_users_of_one_account_are_a_suggestion_an_admin_confirms()
    local s = session()
    local first, one = newUser(s.mock, s.key, "Dana's phone", { all_rooms = false, rooms = { 11 } })
    local second, two = newUser(s.mock, s.key, "Dana's iPad", { all_rooms = false, rooms = { 11 } })
    T.eq(T.http(s.mock, "PATCH", "/v1/profile", { key = second, body = { prefs = { favorites = { "light:21" } } } }).status, 200)
    accounts(s, { [one.id] = { TAG_A }, [two.id] = { TAG_A } })
    accounts(s, { [one.id] = { TAG_A }, [two.id] = { TAG_A } })
    T.eq(profileOf(s.mock, second), two.profile_id, "nothing moves by itself")
    T.eq(#history(s.mock, s.key, "users_merged"), 0)
    T.eq(#history(s.mock, s.key, "merge_suggested"), 1, "suggested once")
    local suggestion = suggestionOf(s.mock, s.key, TAG_A)
    T.truthy(suggestion, "a suggestion")
    T.eq(suggestion.keep, one.profile_id, "the same access: the older is offered")
    T.eq(suggestion.users[1].role, "member")
    T.eq(suggestion.users[2].role, "member")
    T.truthy(type(suggestion.revision) == "string" and #suggestion.revision == 16, "with its revision")
    s.connection.sent = ""
    local confirmed = confirm(s.mock, s.key, TAG_A, one.profile_id, suggestion.revision)
    T.eq(confirmed.status, 200, confirmed.body)
    local sent = Harness.clientFrames(s.connection.sent)
    T.eq(profileOf(s.mock, second), one.profile_id, "into the user the admin chose")
    T.eq(profileOf(s.mock, first), one.profile_id)
    local list = users(s.mock, s.key)
    T.eq(userById(list, two.profile_id), nil, "the user left without devices went")
    T.eq(#list.suggestions, 0)
    T.same(get(s.mock, first, "/v1/profile").json.prefs.favorites, { "light:21" }, "their favorites came along")
    local merged = history(s.mock, s.key, "users_merged")
    T.eq(#merged, 1)
    T.eq(merged[1].who.type, "key")
    T.eq(merged[1].note, nil)
    T.eq(merged[1].count, 1)
    local announced = false
    for _, frame in ipairs(sent) do
        local message = Json.decode(frame.payload)
        announced = announced or (type(message) == "table" and message.type == "keys")
    end
    T.truthy(announced, "the account service hears of the change")
end

-- What the admin confirms is what they saw: the account service adding a device to that account
-- after they looked (or anyone changing those users) refuses the confirmation, and nothing moves.
function tests.a_confirmation_is_for_the_suggestion_as_it_was_shown()
    local s = session()
    local _, partnerKey = newUser(s.mock, s.key, "Partner's iPad", { all_rooms = false, rooms = { 11 } })
    local partnerPhone, partnerAdmin = newUser(s.mock, s.key, "Partner's phone", nil, "admin")
    local guest, guestKey = newUser(s.mock, s.key, "Guest tablet", { all_rooms = false, rooms = {} })
    accounts(s, { [partnerKey.id] = { TAG_A }, [partnerAdmin.id] = { TAG_A } })
    local seen = suggestionOf(s.mock, s.key, TAG_A)
    T.eq(#seen.users, 2, "the admin sees the partner's iPad and phone")
    -- Meanwhile the account service adds the guest tablet to that account.
    accounts(s, { [partnerKey.id] = { TAG_A }, [partnerAdmin.id] = { TAG_A }, [guestKey.id] = { TAG_A } })
    local refused = confirm(s.mock, s.key, TAG_A, partnerAdmin.profile_id, seen.revision)
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "SUGGESTION_CHANGED")
    local after = get(s.mock, guest, "/v1/api-keys/current").json
    T.eq(after.profile_id, guestKey.profile_id, "the guest tablet, never shown, did not move")
    T.eq(after.access.role, "member")
    T.eq(#history(s.mock, s.key, "users_merged"), 0)
    -- The same devices, but the user to keep was made an admin after the admin looked.
    accounts(s, { [partnerKey.id] = { TAG_A }, [guestKey.id] = { TAG_A } })
    local looked = suggestionOf(s.mock, s.key, TAG_A)
    T.eq(looked.keep, guestKey.profile_id, "no rooms: within the iPad's access")
    T.eq(T.http(s.mock, "PATCH", "/v1/profiles/" .. guestKey.profile_id .. "/access", { key = s.key, body = { role = "admin" } }).status, 200)
    T.eq(confirm(s.mock, s.key, TAG_A, guestKey.profile_id, looked.revision).json.code, "SUGGESTION_CHANGED")
    T.eq(get(s.mock, s.key, "/v1/api-keys/current").json.access.owner, true)
    -- Looked at again: confirmed as shown.
    T.eq(confirm(s.mock, s.key, TAG_A, partnerKey.profile_id).status, 200)
    T.eq(profileOf(s.mock, guest), partnerKey.profile_id)
    T.eq(get(s.mock, guest, "/v1/api-keys/current").json.access.role, "member", "the iPad's access, as confirmed")
    T.eq(profileOf(s.mock, partnerPhone), partnerAdmin.profile_id, "the phone has another account now: it stays")
end

-- The owner's home right after the update (probe p1b): the owner looks at "Chrome on Windows,
-- Safari on iPhone"; the account service then tags an Android member's key with that account too.
function tests.the_owners_confirmation_never_takes_in_a_device_it_did_not_show()
    local s = session()
    local _, iphone = newUser(s.mock, s.key, "Safari on iPhone", nil, "admin")
    local android, androidKey = newUser(s.mock, s.key, "Chrome on Android", { doors = true })
    accounts(s, { [s.keyId] = { TAG_A }, [iphone.id] = { TAG_A } })
    local seen = suggestionOf(s.mock, s.key, TAG_A)
    T.eq(seen.owner, true)
    T.eq(seen.keep, s.profile, "the owner's user is the one that stays")
    accounts(s, { [s.keyId] = { TAG_A }, [iphone.id] = { TAG_A }, [androidKey.id] = { TAG_A } })
    T.eq(confirm(s.mock, s.key, TAG_A, s.profile, seen.revision).json.code, "SUGGESTION_CHANGED")
    local after = get(s.mock, android, "/v1/api-keys/current").json
    T.eq(after.access.role, "member")
    T.eq(after.access.owner, false)
end

-- The suggestion says each user's role, and offers the user with less access, never an admin over
-- a member; when neither user's access is within the other's, the admin chooses.
function tests.a_suggestion_says_each_users_role_and_offers_the_lesser_access()
    local s = session()
    local _, kid = newUser(s.mock, s.key, "Kid's phone", { all_rooms = false, rooms = { 11 } })
    local _, mum = newUser(s.mock, s.key, "Mum's iPad", nil, "admin")
    local _, small = newUser(s.mock, s.key, "Small", { all_rooms = false, rooms = { 10 }, doors = false })
    local _, big = newUser(s.mock, s.key, "Big", { all_rooms = false, rooms = { 10, 11 }, doors = true })
    local _, left = newUser(s.mock, s.key, "Left", { all_rooms = false, rooms = { 10 } })
    local _, right = newUser(s.mock, s.key, "Right", { all_rooms = false, rooms = { 11 } })
    local tagC = "c3c3c3c3c3c3c3c3"
    -- A kid signed in to their account on Mum's iPad; two members of one account, one with fewer
    -- rooms and no doors; two members with a room each.
    accounts(s, { [mum.id] = { TAG_A }, [kid.id] = { TAG_A }, [small.id] = { TAG_B }, [big.id] = { TAG_B }, [left.id] = { tagC }, [right.id] = { tagC } })
    local admins = suggestionOf(s.mock, s.key, TAG_A)
    local roles = {}
    for _, user in ipairs(admins.users) do
        roles[user.id] = user.role
        T.eq(user.owner, false)
    end
    T.eq(roles[mum.profile_id], "admin")
    T.eq(roles[kid.profile_id], "member")
    T.eq(admins.keep, kid.profile_id, "the member's access is offered, not the admin's")
    T.eq(suggestionOf(s.mock, s.key, TAG_B).keep, small.profile_id, "the fewer rooms and no doors")
    T.eq(suggestionOf(s.mock, s.key, tagC).keep, Json.null, "neither within the other: the admin chooses")
end

-- A merge that keeps a member's access makes an admin's device a member's: the invitations it made
-- as an admin go, as when its user is made a member (probe p2).
function tests.a_merge_that_makes_a_device_a_members_revokes_its_invitations()
    local s = session()
    local partner, partnerKey = newUser(s.mock, s.key, "Partner's phone", nil, "admin")
    local _, kid = newUser(s.mock, s.key, "Kid's phone", { all_rooms = false, rooms = { 11 } })
    local made = T.http(s.mock, "POST", "/v1/invitations", { key = partner, body = { role = "admin" } })
    T.eq(made.status, 201, made.body)
    local kept = T.http(s.mock, "POST", "/v1/invitations", { key = s.key, body = { role = "member" } }).json
    accounts(s, { [partnerKey.id] = { TAG_A }, [kid.id] = { TAG_A } })
    T.eq(confirm(s.mock, s.key, TAG_A, kid.profile_id).status, 200)
    T.eq(get(s.mock, partner, "/v1/api-keys/current").json.access.role, "member")
    local pending = {}
    for _, item in ipairs(get(s.mock, s.key, "/v1/invitations").json.items) do
        pending[#pending + 1] = item.id
    end
    T.same(pending, { kept.id }, "only the owner's invitation is left")
    local joined, code = join(s, made.json, "Stranger")
    T.eq(joined, nil)
    T.eq(code, "INVITATION_NOT_FOUND")
end

-- However its maker stopped being an admin (here a store a 1.8.0 driver changed, read at the next
-- start), an invitation for a new user works only while its maker is an admin.
function tests.an_invitation_for_a_new_user_needs_its_maker_to_be_an_admin_still()
    local s = session()
    local partner = newUser(s.mock, s.key, "Partner's phone", nil, "admin")
    local partnerProfile = profileOf(s.mock, partner)
    local made = T.http(s.mock, "POST", "/v1/invitations", { key = partner, body = { role = "admin" } }).json
    local stored = Json.decode(s.mock.persist["directorlink_people"]:sub(6))
    stored.people[partnerProfile].role = "member"
    s.mock.persist["directorlink_people"] = "json:" .. Json.encode(stored)
    local keys = Json.decode(s.mock.persist["directorlink_api_key_hashes"]:sub(6))
    for _, key in ipairs(keys.keys) do
        if key.profile == partnerProfile then
            key.role = "member"
        end
    end
    s.mock.persist["directorlink_api_key_hashes"] = "json:" .. Json.encode(keys)
    local again = Mock.updateDriver(s.mock)
    local _, connection = Harness.connected({ mock = again })
    local restarted = { mock = again, connection = connection, home = s.home }
    T.eq(get(again, partner, "/v1/api-keys/current").json.access.role, "member")
    T.truthy(#get(again, s.key, "/v1/invitations").json.items >= 1, "the invitation is still listed")
    local joined, code = join(restarted, made, "Stranger")
    T.eq(joined, nil)
    T.eq(code, "INVITATION_NOT_FOUND")
end

function tests.the_account_service_never_raises_anyones_access()
    local s = session()
    local phone, kid = newUser(s.mock, s.key, "Kid's phone", { all_rooms = false, rooms = { 11 } })
    local partner, partnerKey = newUser(s.mock, s.key, "Partner's phone", nil, "admin")
    local _, cousin = newUser(s.mock, s.key, "Cousin's phone", { all_rooms = false, rooms = { 10 } })
    -- A member and an admin, and two members with other rooms: nothing moves by itself.
    accounts(s, { [kid.id] = { TAG_A }, [partnerKey.id] = { TAG_A }, [cousin.id] = { TAG_B } })
    accounts(s, { [kid.id] = { TAG_A }, [partnerKey.id] = { TAG_A }, [cousin.id] = { TAG_B } })
    T.eq(profileOf(s.mock, phone), kid.profile_id, "the member's device is still a member's")
    T.eq(get(s.mock, phone, "/v1/api-keys/current").json.access.role, "member")
    local list = users(s.mock, s.key)
    T.eq(#list.suggestions, 1)
    local suggestion = list.suggestions[1]
    T.eq(suggestion.id, TAG_A)
    T.eq(suggestion.owner, false)
    T.eq(suggestion.may_confirm, true)
    T.eq(#suggestion.users, 2)
    T.eq(#history(s.mock, s.key, "merge_suggested"), 1, "recorded once, however often the account service says it")
    T.eq(#users(s.mock, phone).suggestions, 0, "members see none")
    T.eq(confirm(s.mock, phone, TAG_A, kid.profile_id).status, 403)
    -- An admin confirms, keeping the member's permissions: the partner's phone becomes a member's.
    local confirmed = confirm(s.mock, s.key, TAG_A, kid.profile_id)
    T.eq(confirmed.status, 200, confirmed.body)
    T.eq(confirmed.json.id, kid.profile_id)
    T.eq(#confirmed.json.devices, 2)
    T.eq(get(s.mock, partner, "/v1/api-keys/current").json.access.role, "member")
    T.eq(get(s.mock, partner, "/v1/api-keys/current").json.role, "member", "the 1.7.0 role follows")
    local merged = history(s.mock, s.key, "users_merged")
    T.eq(merged[1].who.type, "key")
    T.eq(#users(s.mock, s.key).suggestions, 0)
    T.eq(confirm(s.mock, s.key, TAG_A, kid.profile_id).status, 404, "nothing to bring together any more")
end

function tests.the_owners_devices_never_move_and_only_the_owner_brings_them_together()
    local s = session()
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    T.eq(Harness.relayRequest(s.mock, s.connection, { type = "claim", id = "c1", token = claim.json.claim_token }).ok, true)
    -- 1.8.0 split the owner's iPhone into a user of its own, an admin too.
    local iphone, iphoneKey = newUser(s.mock, s.key, "Safari on iPhone", nil, "admin")
    local partner = newUser(s.mock, s.key, "Partner", nil, "admin")
    accounts(s, { [s.keyId] = { TAG_A }, [iphoneKey.id] = { TAG_A } })
    T.eq(profileOf(s.mock, iphone), iphoneKey.profile_id, "the owner's user is involved: nothing by itself")
    local suggestion = users(s.mock, s.key).suggestions[1]
    T.eq(suggestion.owner, true)
    T.eq(suggestion.may_confirm, true)
    T.eq(users(s.mock, partner).suggestions[1].may_confirm, false, "another admin may not")
    T.eq(confirm(s.mock, partner, TAG_A, s.profile).json.code, "OWNER_PROTECTED")
    T.eq(confirm(s.mock, s.key, TAG_A, iphoneKey.profile_id).json.code, "INVALID_FIELD", "the owner's user stays")
    T.eq(confirm(s.mock, s.key, TAG_A, s.profile).status, 200)
    local me = get(s.mock, iphone, "/v1/api-keys/current").json
    T.eq(me.profile_id, s.profile)
    T.eq(me.access.owner, true, "one user, with the owner's permissions")
    T.eq(get(s.mock, s.key, "/v1/api-keys/current").json.access.owner, true)
end

function tests.bringing_devices_together_keeps_the_owner_an_admin_and_five_devices()
    local s = session()
    -- The owner's device and a member's share an account: the owner's permissions stay, so the
    -- owner, the home's admin, is never made a member.
    local _, kid = newUser(s.mock, s.key, "Kid's phone")
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.key })
    Harness.relayRequest(s.mock, s.connection, { type = "claim", id = "c2", token = claim.json.claim_token })
    accounts(s, { [s.keyId] = { TAG_B }, [kid.id] = { TAG_B } })
    T.eq(confirm(s.mock, s.key, TAG_B, kid.profile_id).json.code, "INVALID_FIELD")
    T.eq(get(s.mock, s.key, "/v1/api-keys/current").json.access.role, "admin")
    -- Two alike members whose account's devices would be more than five together in the older:
    -- it waits, and keeping the older is refused with the list; the other is allowed.
    local _, a = newUser(s.mock, s.key, "A 1")
    local _, b = newUser(s.mock, s.key, "B 1")
    for index = 2, 5 do
        T.eq(addDevice(s.mock, s.key, a.profile_id, "A " .. index).status, 201)
    end
    local bTwo = addDevice(s.mock, s.key, b.profile_id, "B 2").json
    accounts(s, { [s.keyId] = { TAG_B }, [kid.id] = { TAG_B }, [a.id] = { TAG_A }, [b.id] = { TAG_A }, [bTwo.id] = { TAG_A } })
    T.eq(profileOf(s.mock, b.key), b.profile_id, "seven devices in one user: not by itself")
    local found
    for _, suggestion in ipairs(users(s.mock, s.key).suggestions) do
        if suggestion.id == TAG_A then
            found = suggestion
        end
    end
    T.truthy(found, "it waits for an admin")
    T.eq(found.users[1].id, a.profile_id)
    T.eq(found.users[1].devices_after, 7)
    T.eq(found.users[2].devices_after, 3)
    local refused = confirm(s.mock, s.key, TAG_A, a.profile_id)
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "USER_DEVICE_LIMIT")
    T.eq(#refused.json.devices, 5)
    T.eq(confirm(s.mock, s.key, TAG_A, b.profile_id).status, 200)
    T.eq(profileOf(s.mock, a.key), b.profile_id)
    T.eq(#userById(users(s.mock, s.key), a.profile_id).devices, 4, "A keeps their devices of no account")
end

function tests.a_device_used_by_two_accounts_stays_where_it_is()
    local s = session()
    local tablet, tabletKey = newUser(s.mock, s.key, "Kitchen tablet")
    local _, dana = newUser(s.mock, s.key, "Dana's phone")
    accounts(s, { [tabletKey.id] = { TAG_A, TAG_B }, [dana.id] = { TAG_A } })
    T.eq(profileOf(s.mock, tablet), tabletKey.profile_id)
    T.eq(#users(s.mock, s.key).suggestions, 0, "a shared device is not one account's")
end

-- A device of user U signs in with the account of user V: it is V's device too, and an admin
-- chooses, even when U and V have the same access.
function tests.a_device_signed_in_with_another_users_account()
    local s = session()
    local kitchen, kitchenKey = newUser(s.mock, s.key, "Kitchen tablet", { all_rooms = false, rooms = { 10 } })
    local other, otherKey = newUser(s.mock, s.key, "Kitchen phone", { all_rooms = false, rooms = { 10 } })
    local _, dana = newUser(s.mock, s.key, "Dana's phone", { all_rooms = true })
    accounts(s, { [dana.id] = { TAG_A } })
    T.eq(#users(s.mock, s.key).suggestions, 0)
    -- Someone signs in to Dana's account on the kitchen phone, of another user with other rooms.
    accounts(s, { [dana.id] = { TAG_A }, [otherKey.id] = { TAG_A } })
    T.eq(profileOf(s.mock, other), otherKey.profile_id, "nothing moves by itself")
    T.eq(#users(s.mock, s.key).suggestions, 1)
    -- The kitchen tablet, of a user alike to the kitchen phone's, signs in to the same account as it.
    accounts(s, { [dana.id] = { TAG_A }, [otherKey.id] = { TAG_B }, [kitchenKey.id] = { TAG_B } })
    T.eq(profileOf(s.mock, kitchen), kitchenKey.profile_id)
    T.eq(profileOf(s.mock, other), otherKey.profile_id, "alike, and still nothing moves by itself")
    T.eq(suggestionOf(s.mock, s.key, TAG_B).keep, kitchenKey.profile_id, "the older of the two is offered")
    T.eq(confirm(s.mock, s.key, TAG_B, kitchenKey.profile_id).status, 200)
    T.eq(profileOf(s.mock, other), kitchenKey.profile_id)
end

-- The forged tags of the cloud review (probe_forged_tags): two members with the same access, Mom
-- and the nanny, tagged as one account. Nothing moves: the nanny gets none of Mom's devices, links
-- or prompts until an admin confirms it.
function tests.forged_tags_give_a_member_nothing_of_another()
    local s = session()
    local momPhone, mom = newUser(s.mock, s.key, "Mom's phone", { doors = true })
    local ipad = addDevice(s.mock, s.key, mom.profile_id, "Mom's iPad").json
    local nanny, nannyKey = newUser(s.mock, s.key, "Nanny's phone", { doors = true })
    accounts(s, { [nannyKey.id] = { TAG_A }, [mom.id] = { TAG_A } })
    T.eq(profileOf(s.mock, nanny), nannyKey.profile_id)
    T.eq(#users(s.mock, nanny).items[1].devices, 1, "the nanny sees only her own device")
    T.eq(T.http(s.mock, "DELETE", "/v1/api-keys/" .. ipad.id, { key = nanny }).status, 404)
    T.eq(get(s.mock, ipad.key, "/v1/api-keys/current").status, 200)
    T.eq(profileOf(s.mock, momPhone), mom.profile_id)
    T.eq(#history(s.mock, s.key, "users_merged"), 0)
end

-- A cloud that changes the tags at every message (probe p13) neither fills the history nor writes
-- the controller's flash at every message: the same devices are the same suggestion, and the tags
-- are written at most once a minute.
function tests.tags_that_keep_changing_are_one_suggestion_and_few_writes()
    local s = session()
    local _, kid = newUser(s.mock, s.key, "Kid", {})
    local writes = 0
    local set = C4.PersistSetValue
    C4.PersistSetValue = function(self, key, value, enc)
        if key == "directorlink_accounts" then
            writes = writes + 1
        end
        return set(self, key, value, enc)
    end
    local ok, err = pcall(function()
        for index = 1, 60 do
            local tag = string.format("%016x", 4096 + index)
            accounts(s, { [s.keyId] = { tag }, [kid.id] = { tag } })
        end
        T.eq(#history(s.mock, s.key, "merge_suggested"), 1, "one suggestion, whatever its tag")
        T.truthy(writes <= 2, "at most the first and one more in a minute, got " .. writes)
        local before = writes
        accounts(s, { [s.keyId] = { "0000000000001111" }, [kid.id] = { "0000000000001111" } })
        accounts(s, { [s.keyId] = { "0000000000001111" }, [kid.id] = { "0000000000001111" } })
        T.eq(writes, before, "within the minute: waits")
        -- A minute later the minute's tick writes what waited.
        local realTime = os.time
        os.time = function(t)
            return t and realTime(t) or realTime() + 120
        end
        local flushed = pcall(function()
            require("src.auth.accounts").flush()
        end)
        os.time = realTime
        T.truthy(flushed)
        T.eq(writes, before + 1, "written once, a minute later")
        local stored = Json.decode(s.mock.persist["directorlink_accounts"]:sub(6))
        T.same(stored.keys[kid.id], { "0000000000001111" })
    end)
    C4.PersistSetValue = set
    if not ok then
        error(err, 0)
    end
end

-- Many different suggestions in a day: only the first few are in the history.
function tests.at_most_a_few_suggestions_a_day_in_the_history()
    local s = session()
    local ids = {}
    for index = 1, 12 do
        local _, made = newUser(s.mock, s.key, "Member " .. index, { all_rooms = false, rooms = { 10 } })
        ids[index] = made.id
    end
    for index = 1, 11 do
        local tag = string.format("%016x", 8192 + index)
        accounts(s, { [ids[index]] = { tag }, [ids[index + 1]] = { tag } })
    end
    T.eq(#users(s.mock, s.key).suggestions, 1, "the last message's pair")
    T.eq(#history(s.mock, s.key, "merge_suggested"), 10, "ten a day")
end

-- ---- a restore -----------------------------------------------------------------------------------

local sealCounter = 0

-- A request sealed at home, as the app sends a backup's (POST /v1/sealed).
local function sealed(mock, key, keyId, request)
    local Lock = require("src.cloud.lock")
    local info = T.http(mock, "GET", "/v1/sealed").json
    sealCounter = sealCounter + 1
    request.id = "users-" .. sealCounter
    request.ts = info.time
    local lock = Lock.deviceKey(key)
    local response = T.http(mock, "POST", "/v1/sealed", { body = Json.encode({ envelope = Lock.seal(lock, info.home, keyId, "req", Json.encode(request)) }) })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer
end

-- The backup's users come back as they were, and the restoring device takes the place of one of
-- their devices or stays a user of its own: a restore never gives a user a sixth device.
function tests.a_restore_gives_no_user_a_sixth_device()
    local old, owner = start()
    local ownerProfile = profileOf(old, owner)
    local ownerId = idOf(old, owner)
    for index = 2, 5 do
        T.eq(addDevice(old, owner, ownerProfile, "Owner device " .. index).status, 201)
    end
    local document = sealed(old, owner, ownerId, { method = "GET", path = "/v1/backup" }).json
    -- The driver was removed and added again: a device paired anew restores the backup.
    local fresh, restorer = start()
    local restorerId = idOf(fresh, restorer)
    local done = sealed(fresh, restorer, restorerId, { method = "POST", path = "/v1/restore", body = { document = document, dry_run = false, replaces_key = ownerId } })
    T.eq(done.status, 200, done.body)
    local list = users(fresh, restorer)
    local mine = userById(list, ownerProfile)
    T.eq(#mine.devices, 5, "this device took the old key's place: five, as before")
    T.eq(mine.you, true)
    T.eq(addDevice(fresh, restorer, ownerProfile, "A sixth").json.code, "USER_DEVICE_LIMIT")
end

-- ---- what 1.8.0 left behind ---------------------------------------------------------------------

function tests.when_each_device_was_last_used_survives_a_restart()
    local mock, admin = start()
    local kid, kidKey = newUser(mock, admin, "Kid's phone")
    T.eq(get(mock, kid, "/v1/lights").status, 200)
    local before = userById(users(mock, admin), kidKey.profile_id).devices[1].last_used_at
    T.truthy(before ~= Json.null)
    local again = Mock.updateDriver(mock)
    local after = Json.decode(T.http(again, "GET", "/v1/api-keys", { key = admin }).body)
    local found
    for _, item in ipairs(after.items) do
        if item.id == kidKey.id then
            found = item
        end
    end
    T.eq(found.last_used_at, before, "the last use before the restart")
end

return tests
