-- Handing the home to another admin (1.9.0, ADR-064; src/api/handlers/users.lua make_owner,
-- Access.mayMakeOwner): only the owner makes another admin user the owner, a member first made an
-- admin; the old owner stays an admin like any other, the new one is protected, and nobody leaves.
-- A home the account service knows moves there too, on this controller's word: the controller asks
-- (`owner`, with the new owner's account tag) and records the new owner only once the account
-- service has moved its record, or has none; the account service alone makes nobody the owner.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Harness = require("relay_harness")

local tests = {}

local TAG_OWNER = "a1a1a1a1a1a1a1a1"
local TAG_PARTNER = "b2b2b2b2b2b2b2b2"
local TAG_OTHER = "c3c3c3c3c3c3c3c3"

local function get(mock, key, path)
    return T.http(mock, "GET", path, { key = key })
end

local function current(mock, key)
    return get(mock, key, "/v1/api-keys/current").json
end

local function makeOwner(mock, key, profileId)
    return T.http(mock, "POST", "/v1/users/owner", { key = key, body = { profile_id = profileId } })
end

-- A new user with one device: an admin unless `role` says member.
local function newUser(mock, owner, name, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = owner, body = { name = name, role = role or "admin" } })
    T.eq(created.status, 201, created.body)
    return created.json
end

local function setAccess(mock, key, profileId, body)
    return T.http(mock, "PATCH", "/v1/profiles/" .. profileId .. "/access", { key = key, body = body })
end

local function history(mock, key, action)
    local found = {}
    for _, entry in ipairs(get(mock, key, "/v1/activity?kind=access&limit=200").json.items) do
        if entry.action == action then
            found[#found + 1] = entry
        end
    end
    return found
end

local function keyIds(mock, key)
    local ids = {}
    for _, item in ipairs(get(mock, key, "/v1/api-keys").json.items) do
        ids[#ids + 1] = item.id
    end
    table.sort(ids)
    return ids
end

-- A home on the home network only: the owner (the first admin paired), a partner (an admin) and a
-- kid (a member).
local function home()
    local mock = Mock.startDriver()
    local owner = T.pair(mock, "Chrome on Windows")
    local me = current(mock, owner)
    local partner = newUser(mock, owner, "Dana's phone")
    local kid = newUser(mock, owner, "Kid's tablet", "member")
    return { mock = mock, owner = owner, ownerProfile = me.profile_id, ownerId = me.id, partner = partner, kid = kid }
end

-- The same home, connected to the (fake) relay: the account service knows it.
local function linkedHome()
    local s = home()
    local _, connection = Harness.connected({ mock = s.mock })
    s.connection = connection
    return s
end

local function relaySends(message)
    ReceivedFromNetwork(Harness.BINDING, 443, Harness.serverFrame(1, Json.encode(message)))
end

-- What the driver sent the relay since the last look, without its key announcements.
local function sent(s, kind)
    local found = {}
    for _, frame in ipairs(Harness.answers(Harness.clientFrames(s.connection.sent))) do
        local message = Json.decode(frame.payload)
        if type(message) == "table" and (kind == nil or message.type == kind) then
            found[#found + 1] = message
        end
    end
    s.connection.sent = ""
    return found
end

-- The account service says which keys share an account.
local function accounts(s, keys)
    relaySends({ type = "accounts", id = "acc-" .. tostring(os.clock()), keys = keys })
    s.connection.sent = ""
end

-- ---- who may hand the home over ---------------------------------------------------------------

function tests.only_the_owner_makes_another_admin_the_owner()
    local s = home()
    local mock = s.mock
    -- Another admin may not, for themself or anyone.
    local partnerTries = makeOwner(mock, s.partner.key, s.partner.profile_id)
    T.eq(partnerTries.status, 403, partnerTries.body)
    T.eq(partnerTries.json.code, "OWNER_ONLY")
    T.eq(makeOwner(mock, s.partner.key, s.kid.profile_id).json.code, "OWNER_ONLY")
    -- A member may not ask at all.
    local kidTries = makeOwner(mock, s.kid.key, s.kid.profile_id)
    T.eq(kidTries.status, 403)
    T.eq(kidTries.json.code, "FORBIDDEN")
    -- The owner: only an admin user, not themself, one that exists.
    local member = makeOwner(mock, s.owner, s.kid.profile_id)
    T.eq(member.status, 409, member.body)
    T.eq(member.json.code, "NOT_AN_ADMIN")
    T.eq(member.json.user.name, "Kid's tablet")
    T.eq(makeOwner(mock, s.owner, s.ownerProfile).json.code, "ALREADY_OWNER")
    T.eq(makeOwner(mock, s.owner, "0000aaaa").status, 404)
    T.eq(makeOwner(mock, s.owner, "Dana").status, 400)
    T.eq(T.http(mock, "POST", "/v1/users/owner", { key = s.owner, body = { profile_id = s.partner.profile_id, keep = true } }).status, 400)
    T.eq(current(mock, s.owner).access.owner, true, "nothing changed")
    T.eq(#history(mock, s.owner, "owner_changed"), 0)
    -- A member made an admin first may then become the owner.
    T.eq(setAccess(mock, s.owner, s.kid.profile_id, { role = "admin" }).status, 200)
    local made = makeOwner(mock, s.owner, s.kid.profile_id)
    T.eq(made.status, 200, made.body)
    T.eq(made.json.owner.id, s.kid.profile_id)
    T.eq(current(mock, s.kid.key).access.owner, true)
end

function tests.the_old_owner_is_an_admin_like_any_other_and_the_new_one_is_protected()
    local s = home()
    local mock = s.mock
    local before = keyIds(mock, s.owner)
    local users = #get(mock, s.owner, "/v1/users").json.items
    local made = makeOwner(mock, s.owner, s.partner.profile_id)
    T.eq(made.status, 200, made.body)
    T.eq(made.json.owner.id, s.partner.profile_id)
    T.eq(made.json.owner.name, "Dana's phone")
    T.eq(made.json.previous.id, s.ownerProfile)
    T.eq(made.json.account_service, "not_linked", "a home the account service never knew: the controller's alone")
    -- Nobody leaves: every device still works, every user is still there.
    T.same(keyIds(mock, s.partner.key), before)
    T.eq(#get(mock, s.partner.key, "/v1/users").json.items, users)
    for _, key in ipairs({ s.owner, s.partner.key, s.kid.key }) do
        T.eq(get(mock, key, "/v1/lights").status, 200)
    end
    T.eq(current(mock, s.owner).access.role, "admin", "the old owner stays an admin")
    T.eq(current(mock, s.owner).access.owner, false)
    T.eq(current(mock, s.partner.key).access.owner, true)
    -- The new owner is protected: the old owner no longer changes their access or devices.
    T.eq(setAccess(mock, s.owner, s.partner.profile_id, { role = "member" }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. s.partner.id, { key = s.owner }).json.code, "OWNER_PROTECTED")
    T.eq(T.http(mock, "POST", "/v1/api-keys", { key = s.owner, body = { name = "Dana's tablet", profile_id = s.partner.profile_id } }).json.code, "OWNER_PROTECTED")
    T.eq(setAccess(mock, s.partner.key, s.partner.profile_id, { role = "member" }).json.code, "OWNER_STAYS_ADMIN")
    -- Nor hands the home over again; the new owner can.
    T.eq(makeOwner(mock, s.owner, s.partner.profile_id).json.code, "OWNER_ONLY")
    T.eq(makeOwner(mock, s.owner, s.ownerProfile).json.code, "OWNER_ONLY")
    -- The old owner is a normal admin: the new owner removes their device, or makes them a member.
    local phone = T.http(mock, "POST", "/v1/api-keys", { key = s.owner, body = { name = "Old owner's phone", profile_id = s.ownerProfile } })
    T.eq(phone.status, 201, "the old owner adds devices of their own")
    T.eq(T.http(mock, "DELETE", "/v1/api-keys/" .. phone.json.id, { key = s.partner.key }).status, 204)
    T.eq(setAccess(mock, s.partner.key, s.ownerProfile, { role = "member" }).status, 200)
    T.eq(current(mock, s.owner).access.role, "member")
    -- In History, with who did it.
    local entries = history(mock, s.partner.key, "owner_changed")
    T.eq(#entries, 1)
    T.eq(entries[1].what, "Dana's phone")
    T.eq(entries[1].from, "Chrome on Windows")
    T.eq(entries[1].who.key_id, s.ownerId)
    -- And after a restart.
    local again = Mock.updateDriver(mock)
    T.eq(current(again, s.partner.key).access.owner, true)
    T.eq(current(again, s.owner).access.owner, false)
end

-- What DirectorLink 1.8.0 reads after a downgrade: the people's store's owner, which it takes as
-- the one who claimed the home, while an admin.
function tests.the_people_store_names_the_new_owner_for_a_downgrade()
    local s = home()
    T.eq(makeOwner(s.mock, s.owner, s.partner.profile_id).status, 200)
    local stored = Json.decode(s.mock.persist["directorlink_people"]:sub(6))
    T.eq(stored.owner, s.partner.profile_id)
    T.eq(stored.version, 1, "the same store 1.8.0 writes")
end

function tests.a_new_owner_that_cannot_be_saved_changes_nothing()
    local s = home()
    local write = C4.PersistSetValue
    C4.PersistSetValue = function(self, name, value, encrypted)
        if name == "directorlink_people" then
            error("storage full")
        end
        return write(self, name, value, encrypted)
    end
    local failed = makeOwner(s.mock, s.owner, s.partner.profile_id)
    C4.PersistSetValue = write
    T.eq(failed.status, 500, failed.body)
    T.eq(current(s.mock, s.owner).access.owner, true)
    T.eq(current(s.mock, s.partner.key).access.owner, false)
    T.eq(#history(s.mock, s.owner, "owner_changed"), 0)
end

-- ---- the account service follows, on the controller's word ----------------------------------------

function tests.a_linked_home_moves_in_the_account_service_first_and_only_then_here()
    local s = linkedHome()
    -- Dana's devices: a shared tablet (two accounts: says nothing) and the phone, Dana's account.
    local tablet = T.http(s.mock, "POST", "/v1/api-keys", { key = s.owner, body = { name = "Shared tablet", profile_id = s.partner.profile_id } }).json
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [s.partner.id] = { TAG_PARTNER }, [tablet.id] = { TAG_OTHER, TAG_PARTNER } })
    T.eq(get(s.mock, tablet.key, "/v1/lights").status, 200, "the tablet used last")
    local pending = makeOwner(s.mock, s.owner, s.partner.profile_id)
    T.eq(pending.status, nil, "the answer waits for the account service")
    local asked = sent(s, "owner")
    T.eq(#asked, 1)
    T.eq(asked[1].account, TAG_PARTNER, "the new owner's account, as an opaque tag")
    T.truthy(type(asked[1].id) == "string" and asked[1].id ~= "")
    T.eq(asked[1].user, nil, "never a user's id or name")
    T.eq(current(s.mock, s.partner.key).access.owner, false, "nothing moved here before the account service did")
    relaySends({ type = "owner_result", id = asked[1].id, ok = true, previous = TAG_OWNER })
    local made = T.response(s.mock, pending.handle)
    T.eq(made.status, 200, made.body)
    T.eq(made.json.account_service, "moved")
    T.eq(current(s.mock, s.partner.key).access.owner, true)
    -- Only the new owner claims the home again (before, as claimed with 1.7.0, any admin could).
    local claim = T.http(s.mock, "POST", "/v1/remote/claim", { key = s.owner })
    T.eq(claim.status, 403)
    T.eq(claim.json.code, "OWNER_ONLY")
    T.eq(T.http(s.mock, "POST", "/v1/remote/claim", { key = s.partner.key }).status, 201)
end

function tests.the_account_service_alone_makes_nobody_the_owner()
    local s = linkedHome()
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [s.partner.id] = { TAG_PARTNER } })
    -- An answer nobody asked for, or a message of its own: nothing moves.
    relaySends({ type = "owner_result", id = "made-up", ok = true })
    relaySends({ type = "owner", id = "o1", account = TAG_PARTNER })
    T.eq(#sent(s, "owner_result"), 0, "the driver answers nothing")
    -- Tags that put the partner's device in the owner's account: a suggestion at most.
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [s.partner.id] = { TAG_OWNER } })
    T.eq(current(s.mock, s.owner).access.owner, true)
    T.eq(current(s.mock, s.partner.key).access.owner, false)
    T.eq(current(s.mock, s.partner.key).profile_id, s.partner.profile_id, "the partner's device stays theirs")

    -- The owner asks, and the account service refuses: nothing moves.
    accounts(s, { [s.ownerId] = { TAG_OWNER } })
    local pending = makeOwner(s.mock, s.owner, s.partner.profile_id)
    local asked = sent(s, "owner")
    T.eq(asked[1].account, Json.null, "Dana's devices use no account")
    relaySends({ type = "owner_result", id = asked[1].id, ok = false, code = "OWNER_NEEDS_ACCOUNT" })
    local refused = T.response(s.mock, pending.handle)
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "OWNER_NEEDS_ACCOUNT")
    T.eq(refused.json.user.name, "Dana's phone")
    T.eq(current(s.mock, s.owner).access.owner, true)
    -- Any other refusal: its code, and nothing moves.
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [s.partner.id] = { TAG_PARTNER } })
    local other = makeOwner(s.mock, s.owner, s.partner.profile_id)
    relaySends({ type = "owner_result", id = sent(s, "owner")[1].id, ok = false, code = "ACCOUNT_NOT_ADMIN" })
    local notAdmin = T.response(s.mock, other.handle)
    T.eq(notAdmin.status, 502, notAdmin.body)
    T.eq(notAdmin.json.code, "ACCOUNT_NOT_ADMIN")
    T.eq(current(s.mock, s.owner).access.owner, true)

    -- No answer at all: nothing moves, and the owner is told to try again.
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [s.partner.id] = { TAG_PARTNER } })
    local silent = makeOwner(s.mock, s.owner, s.partner.profile_id)
    T.eq(#sent(s, "owner"), 1)
    Mock.fireTimers(s.mock, 1)
    local timedOut = T.response(s.mock, silent.handle)
    T.eq(timedOut.status, 503, timedOut.body)
    T.eq(timedOut.json.code, "REMOTE_OFFLINE")
    T.eq(current(s.mock, s.owner).access.owner, true)
    T.eq(#history(s.mock, s.owner, "owner_changed"), 0)
end

function tests.a_home_no_account_owns_there_moves_on_the_controller_alone()
    local s = linkedHome()
    local pending = makeOwner(s.mock, s.owner, s.partner.profile_id)
    local asked = sent(s, "owner")
    T.eq(#asked, 1)
    relaySends({ type = "owner_result", id = asked[1].id, ok = false, code = "NOT_CLAIMED" })
    local made = T.response(s.mock, pending.handle)
    T.eq(made.status, 200, made.body)
    T.eq(made.json.account_service, "not_claimed")
    T.eq(current(s.mock, s.partner.key).access.owner, true)
end

function tests.a_linked_home_needs_remote_access_and_the_relay()
    local s = linkedHome()
    Properties["Remote Access"] = "Off"
    OnPropertyChanged("Remote Access")
    local off = makeOwner(s.mock, s.owner, s.partner.profile_id)
    T.eq(off.status, 409, off.body)
    T.eq(off.json.code, "REMOTE_ACCESS_OFF")
    Properties["Remote Access"] = "On"
    OnPropertyChanged("Remote Access")
    -- On, but not connected yet: nothing is asked, nothing moves.
    local away = makeOwner(s.mock, s.owner, s.partner.profile_id)
    if away.status == nil then
        away = T.response(s.mock, away.handle)
    end
    T.eq(away.status, 503, away.body)
    T.eq(away.json.code, "REMOTE_OFFLINE")
    T.eq(current(s.mock, s.partner.key).access.owner, false)
end

-- The account service moved its record, but meanwhile the new owner was made a member here: the
-- controller does not follow, and tells the account service to move it back.
function tests.a_user_changed_while_the_account_service_answered_is_not_made_the_owner()
    local s = linkedHome()
    local other = newUser(s.mock, s.owner, "Other admin")
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [s.partner.id] = { TAG_PARTNER } })
    local pending = makeOwner(s.mock, s.owner, s.partner.profile_id)
    local asked = sent(s, "owner")
    T.eq(setAccess(s.mock, other.key, s.partner.profile_id, { role = "member" }).status, 200, "another admin, meanwhile")
    s.connection.sent = ""
    relaySends({ type = "owner_result", id = asked[1].id, ok = true, previous = TAG_OWNER })
    local refused = T.response(s.mock, pending.handle)
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "NOT_AN_ADMIN")
    T.eq(current(s.mock, s.owner).access.owner, true)
    local back = sent(s, "owner")
    T.eq(#back, 1, "the account service is told to move its record back")
    T.eq(back[1].account, TAG_OWNER)
end

-- Once the old owner is an admin like any other, users of theirs that share an account and are
-- alike come together by themselves (ADR-061), which only the owner could confirm before.
function tests.the_old_owners_users_alike_come_together_once_they_are_not_the_owners()
    local s = linkedHome()
    local iphone = newUser(s.mock, s.owner, "Safari on iPhone")
    accounts(s, { [s.ownerId] = { TAG_OWNER }, [iphone.id] = { TAG_OWNER }, [s.partner.id] = { TAG_PARTNER } })
    local list = get(s.mock, s.owner, "/v1/users").json
    T.eq(#list.suggestions, 1, "the owner's devices: a suggestion only the owner confirms")
    T.eq(list.suggestions[1].owner, true)
    local pending = makeOwner(s.mock, s.owner, s.partner.profile_id)
    local asked = sent(s, "owner")
    relaySends({ type = "owner_result", id = asked[1].id, ok = true, previous = TAG_OWNER })
    T.eq(T.response(s.mock, pending.handle).status, 200)
    T.eq(current(s.mock, iphone.key).profile_id, s.ownerProfile, "the iPhone joined the old owner's user")
    T.eq(current(s.mock, iphone.key).access.role, "admin")
    T.eq(#get(s.mock, s.partner.key, "/v1/users").json.suggestions, 0)
    T.eq(#keyIds(s.mock, s.partner.key), 4, "every device is still there")
end

return tests
