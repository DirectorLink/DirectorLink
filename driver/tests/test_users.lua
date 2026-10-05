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

function tests.alike_users_of_one_account_become_one_by_themselves()
    local s = session()
    local first, one = newUser(s.mock, s.key, "Dana's phone", { all_rooms = false, rooms = { 11 } })
    local second, two = newUser(s.mock, s.key, "Dana's iPad", { all_rooms = false, rooms = { 11 } })
    T.eq(T.http(s.mock, "PATCH", "/v1/profile", { key = second, body = { prefs = { favorites = { "light:21" } } } }).status, 200)
    local sent = accounts(s, { [one.id] = { TAG_A }, [two.id] = { TAG_A } })
    T.eq(profileOf(s.mock, second), one.profile_id, "into the older user")
    T.eq(profileOf(s.mock, first), one.profile_id)
    local list = users(s.mock, s.key)
    T.eq(userById(list, two.profile_id), nil, "the user left without devices went")
    T.eq(#list.suggestions, 0)
    T.same(get(s.mock, first, "/v1/profile").json.prefs.favorites, { "light:21" }, "their favorites came along")
    local merged = history(s.mock, s.key, "users_merged")
    T.eq(#merged, 1)
    T.eq(merged[1].who.type, "controller")
    T.eq(merged[1].note, "automatic")
    T.eq(merged[1].count, 1)
    local announced = false
    for _, message in ipairs(sent) do
        announced = announced or (type(message) == "table" and message.type == "keys")
    end
    T.truthy(announced, "the account service hears of the change")
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
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = phone, body = { account = TAG_A, keep = kid.profile_id } }).status, 403)
    -- An admin confirms, keeping the member's permissions: the partner's phone becomes a member's.
    local confirmed = T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_A, keep = kid.profile_id } })
    T.eq(confirmed.status, 200, confirmed.body)
    T.eq(confirmed.json.id, kid.profile_id)
    T.eq(#confirmed.json.devices, 2)
    T.eq(get(s.mock, partner, "/v1/api-keys/current").json.access.role, "member")
    T.eq(get(s.mock, partner, "/v1/api-keys/current").json.role, "member", "the 1.7.0 role follows")
    local merged = history(s.mock, s.key, "users_merged")
    T.eq(merged[1].who.type, "key")
    T.eq(#users(s.mock, s.key).suggestions, 0)
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_A, keep = kid.profile_id } }).status, 404, "nothing to bring together any more")
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
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = partner, body = { account = TAG_A, keep = s.profile } }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_A, keep = iphoneKey.profile_id } }).json.code, "INVALID_FIELD", "the owner's user stays")
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_A, keep = s.profile } }).status, 200)
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
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_B, keep = kid.profile_id } }).json.code, "INVALID_FIELD")
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
    local refused = T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_A, keep = a.profile_id } })
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "USER_DEVICE_LIMIT")
    T.eq(#refused.json.devices, 5)
    T.eq(T.http(s.mock, "POST", "/v1/users/merge", { key = s.key, body = { account = TAG_A, keep = b.profile_id } }).status, 200)
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

-- A device of user U signs in with the account of user V: it is V's device too. Alike, it moves
-- by itself; otherwise an admin chooses.
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
    T.eq(profileOf(s.mock, kitchen), kitchenKey.profile_id, "the older user stays")
    T.eq(profileOf(s.mock, other), kitchenKey.profile_id, "alike: brought together by itself")
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
