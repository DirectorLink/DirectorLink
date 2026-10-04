-- Sonos in several rooms and in scenes (1.8.0, ADR-057, docs/SONOS.md): a room joins another
-- room's group (SetAVTransportURI with x-rincon:<coordinator>, only a coordinator found in the zone
-- group state) and leaves it (BecomeCoordinatorOfStandaloneGroup); a group's volume through each
-- room's own SetVolume, keeping their balance; every room involved must be one the key may control
-- (Access.canControl). Scene steps play a favorite (in several rooms, grouped first, at a volume),
-- set a volume and resume; a favorite since removed in Sonos is reported and runs nothing; the
-- steps survive a downgrade to 1.7.0 and come back. The players are fakes (driver/tests/
-- sonos_fake.lua) answering with the real players' XML; their zone group state follows the groups.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local SonosFake = require("sonos_fake")

local tests = {}

local KITCHEN, LIVING, BEDROOM, TV = "RINCON_000E58A0000101400", "RINCON_000E58A0000201400", "RINCON_000E58A0000301400", "RINCON_000E58A0000401400"
local KITCHEN_IP, LIVING_IP, BEDROOM_IP, TV_IP = "192.168.50.11", "192.168.50.12", "192.168.50.13", "192.168.50.14"
local STATION = "x-sonosapi-stream:s0000?sid=254&flags=8224&sn=0"

-- The default project (Kitchen 10, Living Room 11) with "tvroom" (12), where Sonos's TV Room goes.
-- Bedroom is in no room. The fake household: Kitchen leads Living Room and plays a track, Bedroom
-- plays the radio, TV Room is paused in Spotify Connect.
local function project()
    local p = Mock.project()
    Mock.addRoom(p, 12, "tvroom")
    return p
end

-- The search's connection is up, every player answers, and the search ends.
local function discover(mock, home)
    OnConnectionStatusChanged(6100, 1900, "ONLINE")
    for _, reply in ipairs(home:searchReplies()) do
        ReceivedFromNetwork(6100, 1900, reply)
    end
    for _, timer in ipairs(mock.timers) do
        if not timer.fired and not timer.cancelled and timer.source:find("/sonos/", 1, true) and timer.delay == 4000 then
            timer.fired = true
            timer.callback()
        end
    end
    home:clear()
end

local function start(options)
    options = options or {}
    local home = SonosFake.household({ grouped = options.grouped ~= false })
    local mock = Mock.startDriver(project(), nil, nil, function(m)
        m.http = home:handler()
        Properties["Sonos"] = "On"
    end)
    local key = T.pair(mock)
    discover(mock, home)
    return mock, home, key
end

-- The driver updated in Composer: it starts again with its stored data and finds the players.
local function restart(mock, home)
    local updated = Mock.startDriver(project(), nil, "DIT_UPDATING", function(m)
        m.uuidCount = mock.uuidCount
        for name, value in pairs(mock.persist) do
            m.persist[name] = value
        end
        m.http = home:handler()
        Properties["Sonos"] = "On"
    end)
    discover(updated, home)
    return updated
end

local function sonos()
    return require("src.sonos.sonos")
end

local function music(mock, key)
    local response = T.http(mock, "GET", "/v1/music", { key = key })
    T.eq(response.status, 200, response.body)
    return response.json
end

local function item(list, id)
    for _, entry in ipairs(list.items) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

local function roomIds(view)
    local ids = {}
    for _, room in ipairs(view.group.rooms) do
        ids[#ids + 1] = room.id
    end
    return ids
end

-- The household as the players now say it (GetZoneGroupState, read at the next tick).
local function readAgain(mock)
    sonos().tick(os.time() + 1)
end

local function createKey(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role .. " phone", role = role } })
    T.eq(created.status, 201)
    return created.json.key
end

-- Access.canControl says no for the Sonos rooms in `denied` (ids), as the roles of 1.8.0 can.
local function denying(denied, run)
    local Access = require("src.auth.access")
    local real = Access.canControl
    local asked = {}
    Access.canControl = function(actor, device)
        asked[#asked + 1] = device
        if device.kind == "music" and denied[device.id] then
            return false
        end
        return real(actor, device)
    end
    local ok, err = pcall(run, asked)
    Access.canControl = real
    if not ok then
        error(err, 0)
    end
end

local function withClock(at, run)
    local Clock = require("src.core.clock")
    local real = Clock.now
    local current = at
    Clock.now = function()
        return current
    end
    local ok, err = pcall(run, function(seconds)
        current = current + seconds
        return current
    end)
    Clock.now = real
    if not ok then
        error(err, 0)
    end
end

-- ---- joining and leaving ---------------------------------------------------------------------

function tests.a_room_joins_a_group_as_the_sonos_app_does_it()
    local mock, home, key = start()
    -- Bedroom joins the group Living Room is in: Kitchen leads it.
    local joined = T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/group", { key = key, body = { with = LIVING } })
    T.eq(joined.status, 200, joined.body)
    T.same(home:sent(), { BEDROOM_IP .. " SetAVTransportURI" }, "one request, to the room that joins")
    local call = mock.urlRequests[#mock.urlRequests]
    T.eq(call.url, "http://" .. BEDROOM_IP .. ":1400/MediaRenderer/AVTransport/Control")
    T.eq(call.headers.SOAPACTION, '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"')
    T.contains(call.body, '<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID>'
        .. "<CurrentURI>x-rincon:" .. KITCHEN .. "</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI>")
    -- Shown at once, then as the players say it.
    T.same(roomIds(joined.json), { KITCHEN, LIVING, BEDROOM })
    T.eq(joined.json.group.id, KITCHEN)
    readAgain(mock)
    local list = music(mock, key)
    T.same(roomIds(item(list, BEDROOM)), { KITCHEN, LIVING, BEDROOM })
    T.eq(item(list, KITCHEN).group.coordinator, true)
    -- GET /v1/music lists the groups: the coordinator, its rooms, what plays.
    local groups = {}
    for _, group in ipairs(list.groups) do
        groups[group.id] = group
    end
    T.same(groups[KITCHEN].rooms, { KITCHEN, LIVING, BEDROOM })
    T.eq(groups[KITCHEN].state, "playing")
    T.eq(groups[KITCHEN].now_playing.title, "Morning Light")
    T.eq(groups[KITCHEN].volume, 25, "(30 + 20 + 25) / 3")
    T.same(groups[TV].rooms, { TV })
    T.eq(groups[BEDROOM], nil, "no longer a group of its own")
    -- Already in it: nothing is sent.
    home:clear()
    T.eq(T.http(mock, "POST", "/v1/music/" .. LIVING .. "/group", { key = key, body = { with = BEDROOM } }).status, 200)
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/group", { key = key, body = { with = KITCHEN } }).status, 200)
    T.same(home:sent(), {})
end

function tests.a_room_leaves_its_group_and_the_others_go_on()
    local mock, home, key = start()
    local left = T.http(mock, "DELETE", "/v1/music/" .. LIVING .. "/group", { key = key })
    T.eq(left.status, 200, left.body)
    T.same(home:sent(), { LIVING_IP .. " BecomeCoordinatorOfStandaloneGroup" })
    T.contains(home.calls[1].body, '<u:BecomeCoordinatorOfStandaloneGroup xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:BecomeCoordinatorOfStandaloneGroup>')
    T.same(roomIds(left.json), { LIVING })
    T.eq(left.json.group.coordinator, true)
    readAgain(mock)
    local list = music(mock, key)
    T.same(roomIds(item(list, KITCHEN)), { KITCHEN })
    T.same(roomIds(item(list, LIVING)), { LIVING })
    T.eq(item(list, KITCHEN).state, "playing", "the kitchen plays on")
    -- On its own already: nothing is sent.
    home:clear()
    T.eq(T.http(mock, "DELETE", "/v1/music/" .. BEDROOM .. "/group", { key = key }).status, 200)
    T.same(home:sent(), {})
end

function tests.when_the_coordinator_leaves_the_next_room_leads()
    local mock, home, key = start()
    T.eq(T.http(mock, "POST", "/v1/music/" .. TV .. "/group", { key = key, body = { with = KITCHEN } }).status, 200)
    readAgain(mock)
    home:clear()
    local left = T.http(mock, "DELETE", "/v1/music/" .. KITCHEN .. "/group", { key = key })
    T.eq(left.status, 200, left.body)
    T.same(home:sent(), { KITCHEN_IP .. " BecomeCoordinatorOfStandaloneGroup" })
    -- Shown at once: Living Room leads Living Room and TV Room; the players then say the same.
    local shown = T.http(mock, "GET", "/v1/music/" .. TV, { key = key }).json
    T.same(roomIds(shown), { LIVING, TV })
    readAgain(mock)
    T.same(roomIds(T.http(mock, "GET", "/v1/music/" .. TV, { key = key }).json), { LIVING, TV })
end

-- Only a coordinator DirectorLink found in the zone group state: an id that names no player, an
-- address, anything else is refused and nothing is sent.
function tests.an_unknown_coordinator_is_refused_and_nothing_is_sent()
    local mock, home, key = start()
    local function refused(body, status)
        local response = T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/group", { key = key, body = body })
        T.eq(response.status, status, Json.encode(body) .. " " .. response.body)
        return response.json
    end
    T.eq(refused({ with = "RINCON_0BADF00D01400" }, 404).code, "NOT_FOUND")
    refused({ with = KITCHEN_IP }, 400)
    refused({ with = "x-rincon:" .. KITCHEN }, 400)
    refused({ with = 12 }, 400)
    refused({}, 400)
    refused({ with = KITCHEN, also = true }, 400)
    -- The stereo pair's hidden speaker and the Boost are no rooms, so no coordinators.
    refused({ with = "RINCON_000E58A0000701400" }, 404)
    refused({ with = "RINCON_000E58A0000601400" }, 404)
    T.eq(T.http(mock, "POST", "/v1/music/RINCON_0BADF00D01400/group", { key = key, body = { with = KITCHEN } }).status, 404)
    -- In the module too: a player whose group is not in the zone group state.
    local answered
    sonos().join(sonos().find(BEDROOM), { id = "RINCON_0BADF00D01400", group = "RINCON_0BADF00D01400" }, function(view, code)
        answered = code
    end)
    T.eq(answered, "NOT_FOUND")
    T.same(home:sent(), {})
    local Protocol = require("src.sonos.protocol")
    T.eq(Protocol.groupUri(KITCHEN), "x-rincon:" .. KITCHEN)
    for _, bad in ipairs({ "192.168.50.11", "RINCON_1:2", "x-rincon:RINCON_1", "", 12 }) do
        T.eq(Protocol.groupUri(bad), nil, tostring(bad))
    end
    -- Sonos off: nothing at all.
    Properties["Sonos"] = "Off"
    OnPropertyChanged("Sonos")
    T.eq(T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/group", { key = key, body = { with = KITCHEN } }).json.code, "SONOS_OFF")
    T.same(home:sent(), {})
end

function tests.a_player_that_refuses_to_join_is_reported()
    local mock, home, key = start()
    home.refuse.SetAVTransportURI = 800
    local refused = T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/group", { key = key, body = { with = KITCHEN } })
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "ACTION_NOT_POSSIBLE")
    T.same(roomIds(T.http(mock, "GET", "/v1/music/" .. BEDROOM, { key = key }).json), { BEDROOM }, "not shown in the group")
    home.offline[LIVING_IP] = true
    T.eq(T.http(mock, "DELETE", "/v1/music/" .. LIVING .. "/group", { key = key }).json.code, "PLAYER_UNREACHABLE")
end

-- ---- the group's volume ----------------------------------------------------------------------

function tests.a_groups_volume_is_each_rooms_own_keeping_their_balance()
    local mock, home, key = start()
    music(mock, key)
    home:clear()
    -- Kitchen 30 and Living Room 20: the group is at 25.
    local function group(volume)
        local response = T.http(mock, "PATCH", "/v1/music/" .. LIVING .. "/group", { key = key, body = { volume = volume } })
        T.eq(response.status, 200, response.body)
        return response.json
    end
    local louder = group(50)
    T.same(home:sent(), { KITCHEN_IP .. " SetVolume", LIVING_IP .. " SetVolume" }, "only each room's own SetVolume")
    T.contains(home.calls[1].body, "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>60</DesiredVolume>")
    T.contains(home.calls[2].body, "<DesiredVolume>40</DesiredVolume>")
    T.same({ home.players[KITCHEN_IP].volume, home.players[LIVING_IP].volume }, { 60, 40 })
    T.eq(louder.volume, 40, "Living Room's own")
    T.eq(louder.group.volume, 50)
    -- Down to nothing and back: the same balance.
    group(0)
    T.same({ home.players[KITCHEN_IP].volume, home.players[LIVING_IP].volume }, { 0, 0 })
    group(50)
    T.same({ home.players[KITCHEN_IP].volume, home.players[LIVING_IP].volume }, { 60, 40 })
    -- A room's own volume changed since: the balance is taken again from what the rooms have.
    T.eq(T.http(mock, "PATCH", "/v1/music/" .. KITCHEN, { key = key, body = { volume = 20 } }).status, 200)
    group(60)
    T.same({ home.players[KITCHEN_IP].volume, home.players[LIVING_IP].volume }, { 40, 80 })
    -- Up to the top: each stops at 100.
    group(100)
    T.same({ home.players[KITCHEN_IP].volume, home.players[LIVING_IP].volume }, { 67, 100 })
    -- A room on its own: its volume.
    home:clear()
    T.eq(T.http(mock, "PATCH", "/v1/music/" .. TV .. "/group", { key = key, body = { volume = 12 } }).json.volume, 12)
    T.same(home:sent(), { TV_IP .. " SetVolume" })
    for _, body in ipairs({ { volume = 101 }, { volume = -1 }, { volume = 2.5 }, { volume = "10" }, { muted = true }, {} }) do
        T.eq(T.http(mock, "PATCH", "/v1/music/" .. TV .. "/group", { key = key, body = body }).status, 400, Json.encode(body))
    end
end

-- ---- who may ---------------------------------------------------------------------------------

-- Music is a kind a member is given (ADR-054): without it (or a viewer of 1.7.0, with no rooms) a
-- Sonos room is, for them, one that does not exist; with it they group.
function tests.members_not_given_music_do_not_group_and_members_do()
    local mock, home, key = start()
    local viewer = createKey(mock, key, "viewer")
    local without = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Guest", role = "member", access = { kinds = { music = false } } } }).json.key
    local member = createKey(mock, key, "member")
    for _, other in ipairs({ viewer, without }) do
        T.eq(T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/group", { key = other, body = { with = KITCHEN } }).status, 404)
        T.eq(T.http(mock, "DELETE", "/v1/music/" .. LIVING .. "/group", { key = other }).status, 404)
        T.eq(T.http(mock, "PATCH", "/v1/music/" .. LIVING .. "/group", { key = other, body = { volume = 3 } }).status, 404)
    end
    T.same(home:sent(), {})
    T.eq(T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/group", { key = member, body = { with = KITCHEN } }).status, 200)
end

-- A member sees a group only through the Sonos rooms they see (ADR-054): the others are counted,
-- never named (no id, no name), the group's volume is that of their rooms, and when the coordinator
-- is not theirs, a room of theirs stands for the group (its id, the address of what plays).
function tests.a_member_sees_of_a_group_only_the_sonos_rooms_they_see()
    local mock, home, key = start()
    local kitchen = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Kid", role = "member", access = { all_rooms = false, rooms = { 10 } } } }).json.key
    local living = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Guest", role = "member", access = { all_rooms = false, rooms = { 11 } } } }).json.key
    -- Kitchen (in room 10) leads Living Room (in room 11).
    local list = music(mock, kitchen)
    T.notContains(Json.encode(list), "Living Room")
    T.notContains(Json.encode(list), LIVING)
    local item = list.items[1]
    T.eq(item.id, KITCHEN)
    T.same(item.group.rooms, { { id = KITCHEN, name = "Kitchen" } })
    T.eq(item.group.others, 1)
    T.eq(item.group.volume, item.volume, "their rooms' volume")
    local one = T.http(mock, "GET", "/v1/music/" .. KITCHEN, { key = kitchen })
    T.notContains(one.body, "Living Room")
    T.notContains(one.body, LIVING)
    local muted = T.http(mock, "PATCH", "/v1/music/" .. KITCHEN, { key = kitchen, body = { muted = true } })
    T.eq(muted.status, 200, muted.body)
    T.notContains(muted.body, LIVING, "nor in a command's answer")
    -- The coordinator is not theirs: the living room stands for the group.
    list = music(mock, living)
    T.notContains(Json.encode(list), KITCHEN)
    T.notContains(Json.encode(list), "Kitchen")
    T.eq(list.items[1].group.id, LIVING)
    T.eq(list.groups[1].id, LIVING)
    T.eq(list.groups[1].now_playing.art_href, "/v1/music/" .. LIVING .. "/art")
    T.eq(T.http(mock, "GET", "/v1/music/" .. LIVING .. "/art", { key = living }).status ~= 404, true, "an address that answers them")
    -- An admin sees the whole group.
    local all = music(mock, key)
    for _, entry in ipairs(all.items) do
        if entry.id == KITCHEN then
            T.eq(#entry.group.rooms, 2)
            T.eq(entry.group.others, 0)
        end
    end
end

-- Every room involved goes through Access.canControl, in the Control4 room it is shown in; a
-- command on a group needs every room in it.
function tests.every_room_involved_must_be_one_the_key_may_control()
    local mock, home, key = start()
    local member = createKey(mock, key, "member")
    denying({ [LIVING] = true }, function(asked)
        local function refused(method, path, body)
            local response = T.http(mock, method, "/v1/music/" .. path, { key = member, body = body })
            T.eq(response.status, 403, method .. " " .. path .. " " .. response.body)
            T.eq(response.json.code, "FORBIDDEN")
            T.contains(response.json.detail, "Living Room")
        end
        -- Kitchen leads Living Room: its group's commands need Living Room too.
        refused("POST", KITCHEN .. "/pause")
        refused("POST", KITCHEN .. "/favorites/10/play")
        refused("PATCH", KITCHEN .. "/group", { volume = 10 })
        refused("DELETE", KITCHEN .. "/group")
        refused("POST", BEDROOM .. "/group", { with = KITCHEN })
        refused("PATCH", LIVING, { volume = 10 })
        T.same(home:sent(), {})
        -- Asked as a Sonos room in its Control4 room.
        local seen = false
        for _, device in ipairs(asked) do
            seen = seen or (device.kind == "music" and device.id == LIVING and device.room_id == 11)
        end
        T.truthy(seen, "kind music, the Sonos room's id, its Control4 room")
        -- Kitchen's own volume, and the rooms on their own, are fine.
        T.eq(T.http(mock, "PATCH", "/v1/music/" .. KITCHEN, { key = member, body = { volume = 10 } }).status, 200)
        T.eq(T.http(mock, "POST", "/v1/music/" .. TV .. "/group", { key = member, body = { with = BEDROOM } }).status, 200)
    end)
end

-- ---- scenes ----------------------------------------------------------------------------------

local function favorites(mock, key)
    local list = T.http(mock, "GET", "/v1/music/" .. KITCHEN .. "/favorites", { key = key })
    T.eq(list.status, 200, list.body)
    return list.json.items
end

local function scene(mock, key, steps, name)
    local created = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = name or "Music", steps = steps } })
    T.eq(created.status, 201, created.body)
    return created.json
end

local function run(mock, key, sceneId)
    local ran = T.http(mock, "POST", "/v1/scenes/" .. sceneId .. "/run", { key = key })
    T.eq(ran.status, 202, ran.body)
    return ran.json
end

function tests.a_scene_plays_a_favorite_in_a_room_at_a_volume()
    local mock, home, key = start()
    favorites(mock, key)
    home:clear()
    -- TV Room (12), on its own: Example FM 99 at 35.
    local radio = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, volume = 35 } } }, "Radio")
    -- Kept with what starts it again later, from the favorites list.
    local set = radio.steps[1].set
    T.same({ set.favorite.id, set.favorite.title, set.favorite.uri }, { "10", "Example FM 99", STATION })
    T.contains(set.favorite.meta, "<dc:title>Example FM 99</dc:title>")
    T.eq(set.volume, 35)
    local result = run(mock, key, radio.id)
    T.same({ result.ran, result.skipped, result.failed }, { 1, 0, 0 })
    T.same(home:sent(), { TV_IP .. " SetVolume", TV_IP .. " SetAVTransportURI", TV_IP .. " Play" })
    T.contains(home.calls[1].body, "<DesiredVolume>35</DesiredVolume>")
    T.eq(SonosFake.argument(home.calls[2].body, "CurrentURI"), STATION)
    T.eq(home.players[TV_IP].transport, "PLAYING")
    -- Without a volume, the volume is left as it is; a playlist replaces the queue.
    home:clear()
    local list = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "11" } } } }, "Playlist")
    run(mock, key, list.id)
    T.same(home:sent(), { TV_IP .. " RemoveAllTracksFromQueue", TV_IP .. " AddURIToQueue", TV_IP .. " SetAVTransportURI", TV_IP .. " Play" })
    T.eq(SonosFake.argument(home.calls[3].body, "CurrentURI"), "x-rincon-queue:" .. TV .. "#0")
end

-- A room that follows another room's group leaves it first and plays on its own; a group the room
-- leads keeps its rooms, which play the favorite too.
function tests.a_favorite_plays_in_the_steps_room_whatever_group_it_was_in()
    local mock, home, key = start()
    favorites(mock, key)
    home:clear()
    local living = scene(mock, key, { { type = "music", room_id = 11, set = { action = "play_favorite", favorite = { id = "10" } } } })
    T.eq(run(mock, key, living.id).ran, 1)
    T.same(home:sent(), { LIVING_IP .. " BecomeCoordinatorOfStandaloneGroup", LIVING_IP .. " SetAVTransportURI", LIVING_IP .. " Play" })
    T.eq(home.players[KITCHEN_IP].transport, "PLAYING", "the kitchen plays on")
    readAgain(mock)
    T.same(roomIds(T.http(mock, "GET", "/v1/music/" .. LIVING, { key = key }).json), { LIVING })
end

function tests.a_favorite_in_several_rooms_groups_them_first_then_plays_on_the_coordinator()
    local mock, home, key = start()
    favorites(mock, key)
    home:clear()
    -- TV Room (12) with the kitchen (10): Kitchen leaves Living Room and joins TV Room.
    local party = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "11" }, volume = 20, with_room_ids = { 10, 12, 10 } } } })
    T.same(party.steps[1].set.with_room_ids, { 10 }, "each room once, not its own")
    local result = run(mock, key, party.id)
    T.same({ result.ran, result.skipped }, { 2, 0 })
    T.same(home:sent(), {
        KITCHEN_IP .. " SetAVTransportURI",
        TV_IP .. " SetVolume", KITCHEN_IP .. " SetVolume",
        TV_IP .. " RemoveAllTracksFromQueue", TV_IP .. " AddURIToQueue", TV_IP .. " SetAVTransportURI", TV_IP .. " Play",
    })
    T.eq(SonosFake.argument(home.calls[1].body, "CurrentURI"), "x-rincon:" .. TV)
    readAgain(mock)
    local list = music(mock, key)
    T.same(roomIds(item(list, TV)), { TV, KITCHEN })
    T.same(roomIds(item(list, LIVING)), { LIVING }, "the room Kitchen led goes on alone")
    -- Run again: already together, nothing to group.
    home:clear()
    run(mock, key, party.id)
    T.same(home:sent()[1], TV_IP .. " SetVolume")
    -- A room that does not join still lets the others play.
    readAgain(mock)
    T.eq(T.http(mock, "DELETE", "/v1/music/" .. KITCHEN .. "/group", { key = key }).status, 200)
    readAgain(mock)
    home:clear()
    home.offline[KITCHEN_IP] = true
    run(mock, key, party.id)
    local sent = home:sent()
    T.eq(sent[#sent], TV_IP .. " Play")
end

-- A favorite since removed in Sonos: the step says so and runs nothing for it.
function tests.a_favorite_removed_in_sonos_is_reported_and_nothing_runs()
    local mock, home, key = start()
    local gone = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", volume = 30,
        favorite = { id = "77", title = "Old FM", uri = "x-sonosapi-stream:s9999?sid=254", meta = "" } } } })
    T.same(gone.steps[1].set.favorite, { id = "77", title = "Old FM", uri = "x-sonosapi-stream:s9999?sid=254", meta = "" }, "kept as sent: the list was not read")
    favorites(mock, key)
    home:clear()
    local result = run(mock, key, gone.id)
    T.same({ result.ran, result.skipped, result.failed }, { 0, 1, 0 })
    T.same(result.problems[1], { step = 1, device_id = 0, outcome = "skipped", code = "FAVORITE_GONE", detail = 'The Sonos favorite "Old FM" is no longer in Sonos favorites' })
    T.same(home:sent(), {}, "no volume, no grouping, nothing")
    -- Its id given to another favorite since: gone too. The same address under another id: found.
    local Sonos = sonos()
    local items = { { id = "10", title = "Example FM 99", uri = STATION, playable = true } }
    T.eq(Sonos.matchFavorite(items, { id = "10", title = "Other FM", uri = "x-sonosapi-stream:other" }), nil)
    T.eq(Sonos.matchFavorite(items, { id = "42", title = "Example FM 99", uri = STATION }), items[1])
    T.eq(Sonos.matchFavorite(items, { id = "10", title = "Example FM 99", uri = "x-sonosapi-stream:renewed" }), items[1], "a new address, the same name")
    T.eq(Sonos.matchFavorite(items, { id = "10" }), items[1])
end

-- Not read within the hour (DirectorLink just started): the list is read first. A favorite still
-- there plays; one gone is only logged (the run has answered by then).
function tests.a_favorite_not_read_lately_is_looked_up_first()
    local mock, home, key = start()
    local radio = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10", title = "Example FM 99", uri = STATION } } } })
    local result = run(mock, key, radio.id)
    T.eq(result.ran, 1)
    T.same(home:sent(), { TV_IP .. " Browse", TV_IP .. " SetAVTransportURI", TV_IP .. " Play" })
    home.favorites = "real/favorites_shortcuts.xml"
    local updated = restart(mock, home)
    T.eq(run(updated, key, radio.id).ran, 1)
    T.same(home:sent(), { TV_IP .. " Browse" }, "gone: nothing more")
    T.contains(table.concat(updated.debugLog, "\n"), "no longer in Sonos favorites")
end

function tests.a_shortcut_only_the_sonos_app_starts_is_refused_and_reported()
    local mock, home, key = start()
    -- Saved while the list was not read: kept as sent.
    local shortcut = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "1", title = "Discover Sonos Radio" } } } })
    favorites(mock, key)
    home:clear()
    local result = run(mock, key, shortcut.id)
    T.same({ result.ran, result.skipped }, { 0, 1 })
    T.eq(result.problems[1].code, "FAVORITE_NOT_PLAYABLE")
    T.same(home:sent(), {})
    -- Saved while the list is known: refused.
    local refused = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "x", steps = {
        { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "1" } } },
    } } })
    T.eq(refused.status, 400, refused.body)
    T.eq(refused.json.errors[1].field, "steps[0].set.favorite")
end

function tests.a_scene_sets_the_volume_of_each_room()
    local mock, home, key = start()
    local quiet = scene(mock, key, { { type = "music", room_id = 10, set = { action = "volume", volume = 15 } } })
    T.same(quiet.steps[1].set, { action = "volume", volume = 15 })
    T.eq(run(mock, key, quiet.id).ran, 1)
    T.same(home:sent(), { KITCHEN_IP .. " SetVolume" }, "the kitchen's own, not Living Room's in its group")
    T.eq(home.players[KITCHEN_IP].volume, 15)
    home:clear()
    local everywhere = scene(mock, key, { { type = "music", set = { action = "volume", volume = 8 } } })
    T.eq(run(mock, key, everywhere.id).ran, 4, "each Sonos room")
    local sent = home:sent()
    table.sort(sent)
    T.same(sent, { KITCHEN_IP .. " SetVolume", LIVING_IP .. " SetVolume", BEDROOM_IP .. " SetVolume", TV_IP .. " SetVolume" })
end

function tests.a_scene_resumes_what_was_paused_or_stopped()
    local mock, home, key = start()
    -- Kitchen's group paused, Bedroom's radio stopped (a scene stopped it), TV Room plays.
    home.players[KITCHEN_IP].transport = "PAUSED_PLAYBACK"
    home.players[BEDROOM_IP].transport = "STOPPED"
    home.players[TV_IP].transport = "PLAYING"
    local morning = scene(mock, key, { { type = "music", set = { action = "resume" } } })
    T.eq(run(mock, key, morning.id).ran, 3, "each group")
    local sent = home:sent()
    table.sort(sent)
    T.same(sent, {
        KITCHEN_IP .. " GetTransportInfo", KITCHEN_IP .. " Play",
        BEDROOM_IP .. " GetTransportInfo", BEDROOM_IP .. " Play",
        TV_IP .. " GetTransportInfo",
    })
    -- In a room: its group (Living Room's is Kitchen's). Nothing to play: left as it is.
    home.players[KITCHEN_IP].transport = "NO_MEDIA_PRESENT"
    home:clear()
    local living = scene(mock, key, { { type = "music", room_id = 11, set = { action = "resume" } } })
    T.eq(run(mock, key, living.id).ran, 1)
    T.same(home:sent(), { KITCHEN_IP .. " GetTransportInfo" })
end

-- A scene runs in full for whoever may run it (ADR-054: an admin chose what it does): a member
-- whose rooms leave out the living room, with no music of their own, still runs its music there.
function tests.a_scene_runs_its_music_in_full_for_a_member_it_was_chosen_for()
    local mock, home, key = start()
    favorites(mock, key)
    local steps = scene(mock, key, {
        { type = "music", set = { action = "pause" } },
        { type = "music", set = { action = "volume", volume = 5 } },
        { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, with_room_ids = { 11 } } },
        { type = "music", room_id = 11, set = { action = "play_favorite", favorite = { id = "10" } } },
    })
    local member = T.http(mock, "POST", "/v1/api-keys", { key = key, body = { name = "Kid", role = "member", access = {
        all_rooms = false, rooms = { 12 }, kinds = { music = false }, scenes = { steps.id },
    } } }).json.key
    T.eq(T.http(mock, "GET", "/v1/music/" .. LIVING, { key = member }).status, 404, "the living room's music is not theirs")
    home:clear()
    local result = run(mock, member, steps.id)
    -- Pause: three groups; volume: four rooms; the favorites: two and one.
    T.same({ result.ran, result.skipped }, { 3 + 4 + 2 + 1, 0 })
    local living = false
    for _, action in ipairs(home:sent()) do
        living = living or action:find(LIVING_IP, 1, true) ~= nil
    end
    T.truthy(living, "the living room too")
end

-- Schedules run scenes as a member's key: music steps too.
function tests.a_schedule_plays_a_favorite_at_its_time()
    local mock, home, key = start()
    favorites(mock, key)
    local now = os.time()
    withClock(now, function()
        local Scheduler = require("src.core.scheduler")
        local fields = os.date("*t", now + 86400)
        fields.hour, fields.min, fields.sec = 7, 0, 0
        local runAt = os.time(fields)
        local morning = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, volume = 25 } } }, "Morning radio")
        local created = T.http(mock, "POST", "/v1/schedules", { key = key, body = {
            scene_id = morning.id, trigger = { type = "time", at = "07:00" }, days = { fields.wday - 1 },
        } })
        T.eq(created.status, 201, created.body)
        home:clear()
        require("src.core.clock").now = function()
            return runAt + 5
        end
        T.eq(Scheduler.tick(), 1)
        T.same(home:sent(), { TV_IP .. " Browse", TV_IP .. " SetVolume", TV_IP .. " SetAVTransportURI", TV_IP .. " Play" }, "the list a day old is read again first")
        T.eq(T.http(mock, "GET", "/v1/schedules/" .. created.json.id, { key = key }).json.last_run.ran, 1)
    end)
end

-- While a scene plays a favorite, the favorites are read every half hour, so a run knows at once
-- whether its favorite is still there; without one, they are not read at all.
function tests.the_favorites_are_kept_read_only_while_a_scene_plays_one()
    local mock, home, key = start()
    local Sonos = sonos()
    local now = os.time()
    withClock(now, function(advance)
        local function browsed()
            local count = 0
            for _, action in ipairs(home:sent()) do
                count = count + (action:match(" Browse$") and 1 or 0)
            end
            return count
        end
        Sonos.tick(advance(2))
        Sonos.tick(advance(Sonos.FAVORITES_REFRESH_SECONDS))
        T.eq(browsed(), 0, "no scene plays one")
        scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" } } } })
        home:clear()
        Sonos.tick(advance(2))
        T.eq(browsed(), 0, "whether a scene plays one is asked once a minute")
        Sonos.tick(advance(Sonos.FAVORITES_ASK_SECONDS))
        T.eq(browsed(), 1)
        Sonos.tick(advance(Sonos.FAVORITES_REFRESH_SECONDS - 10))
        T.eq(browsed(), 1, "not again within the half hour")
        Sonos.tick(advance(20))
        T.eq(browsed(), 2)
        -- A failed read waits five minutes.
        home.refuse.Browse = 501
        Sonos.tick(advance(Sonos.FAVORITES_REFRESH_SECONDS + 1))
        Sonos.tick(advance(60))
        T.eq(browsed(), 3)
        home.refuse.Browse = nil
        Sonos.tick(advance(Sonos.FAVORITES_RETRY_SECONDS))
        T.eq(browsed(), 4)
    end)
end

function tests.a_play_favorite_step_is_checked()
    local mock, home, key = start()
    local function refused(set, roomId, field)
        local response = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = { { type = "music", room_id = roomId == nil and 12 or roomId or nil, set = set } } } })
        T.eq(response.status, 400, Json.encode(set) .. " " .. response.body)
        if field then
            T.eq(response.json.errors[1].field, field)
        end
    end
    refused({ action = "play_favorite", favorite = { id = "10" } }, false, "steps[0].room_id")
    refused({ action = "play_favorite" }, nil, "steps[0].set.favorite")
    refused({ action = "play_favorite", favorite = "10" }, nil, "steps[0].set.favorite")
    refused({ action = "play_favorite", favorite = { id = "FV:2/10" } }, nil, "steps[0].set.favorite.id")
    refused({ action = "play_favorite", favorite = { id = 10 } }, nil, "steps[0].set.favorite.id")
    refused({ action = "play_favorite", favorite = { id = "10", res = "x" } }, nil, "steps[0].set.favorite.res")
    refused({ action = "play_favorite", favorite = { id = "10", uri = string.rep("x", 2049) } }, nil, "steps[0].set.favorite.uri")
    refused({ action = "play_favorite", favorite = { id = "10" }, volume = 101 }, nil, "steps[0].set.volume")
    refused({ action = "play_favorite", favorite = { id = "10" }, with_room_ids = 11 }, nil, "steps[0].set.with_room_ids")
    refused({ action = "play_favorite", favorite = { id = "10" }, with_room_ids = { "x" } }, nil, "steps[0].set.with_room_ids")
    refused({ action = "volume" }, nil, "steps[0].set.volume")
    refused({ action = "volume", volume = 5, favorite = { id = "10" } }, nil, "steps[0].set.favorite")
    refused({ action = "resume", volume = 5 }, nil, "steps[0].set.volume")
    refused({ action = "shuffle" }, nil, "steps[0].set.action")
    -- A room removed since is left out of the rooms grouped with it.
    local kept = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10", title = "Example FM 99" }, with_room_ids = { 11, 999 } } } })
    T.same(kept.steps[1].set.with_room_ids, { 11 })
    local alone = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, with_room_ids = { 999 } } } })
    T.eq(alone.steps[1].set.with_room_ids, nil)
end

-- What an app sends back unchanged is taken again; what the favorites list says wins.
function tests.a_scene_saved_again_keeps_its_favorite()
    local mock, home, key = start()
    favorites(mock, key)
    local saved = scene(mock, key, { { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, volume = 35, with_room_ids = { 10 } } } })
    local again = T.http(mock, "PATCH", "/v1/scenes/" .. saved.id, { key = key, body = { steps = saved.steps } })
    T.eq(again.status, 200, again.body)
    T.same(again.json.steps, saved.steps)
    local forged = T.http(mock, "PATCH", "/v1/scenes/" .. saved.id, { key = key, body = { steps = {
        { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10", title = "Mine", uri = "http://203.0.113.9/stream.mp3", meta = "" } } },
    } } })
    T.eq(forged.status, 200, forged.body)
    T.eq(forged.json.steps[1].set.favorite.uri, STATION, "the favorites list's address, never one sent")
    T.eq(forged.json.steps[1].set.favorite.title, "Example FM 99")
end

function tests.the_composer_printout_shows_the_music_steps()
    local mock, home, key = start()
    favorites(mock, key)
    scene(mock, key, {
        { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, volume = 35, with_room_ids = { 10 } } },
        { type = "music", room_id = 10, set = { action = "volume", volume = 15 } },
        { type = "music", set = { action = "resume" } },
    })
    local lines = {}
    local realPrint = print
    _G.print = function(line)
        lines[#lines + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    _G.print = realPrint
    T.truthy(ok, err)
    local text = table.concat(lines, "\n")
    T.contains(text, 'the Sonos music in tvroom (12) -> play favorite "Example FM 99" at volume 35, grouped with Kitchen (10)')
    T.contains(text, "the Sonos music in Kitchen (10) -> volume 15")
    T.contains(text, "the Sonos music in the whole home -> resume")
end

-- ---- going back to 1.7.0 and returning ------------------------------------------------------

local function storedScenes(mock)
    return Json.decode((mock.persist.directorlink_scenes:gsub("^json:", "")))
end

-- DirectorLink 1.7.0 knows only pause and stop: it leaves the other music steps out when it loads
-- the scenes, and its next save writes them without them (with steps_kept, which it writes, and
-- without music_steps_kept, which it does not know). Back on 1.8.0 they come back in their places.
function tests.music_steps_come_back_after_a_downgrade_to_1_7_0()
    local mock, home, key = start()
    favorites(mock, key)
    local morning = scene(mock, key, {
        { type = "lights", device_ids = { 20 }, set = { on = true } },
        { type = "music", room_id = 12, set = { action = "play_favorite", favorite = { id = "10" }, volume = 20 } },
        { type = "music", room_id = 10, set = { action = "pause" } },
        { type = "music", set = { action = "volume", volume = 9 } },
    }, "Morning")
    T.truthy(mock.persist.directorlink_scene_steps_2, "kept apart")
    T.eq(mock.persist.directorlink_scene_steps, nil, "no refrigerator step")
    local record = storedScenes(mock)
    T.same({ record.steps_kept, record.music_steps_kept }, { true, true })

    -- What 1.7.0 does with its own scenes module: the steps are left out as it loads.
    local Scenes = require("src.core.scenes")
    for action in pairs(Scenes.NEWER_MUSIC_ACTIONS) do
        Scenes.MUSIC_ACTIONS[action] = nil
    end
    local loaded = Scenes.read(storedScenes(mock))
    for action in pairs(Scenes.NEWER_MUSIC_ACTIONS) do
        Scenes.MUSIC_ACTIONS[action] = true
    end
    T.eq(#loaded[1].steps, 2, "1.7.0 runs the lights and the pause")
    -- Its save: the steps it knows, steps_kept, its own copy of refrigerator steps (none).
    local data = storedScenes(mock)
    table.remove(data.scenes[1].steps, 4)
    table.remove(data.scenes[1].steps, 2)
    data.scenes[1].name = "Morning (1.7.0)"
    data.music_steps_kept = nil
    mock.persist.directorlink_scenes = "json:" .. Json.encode(data)
    mock.persist.directorlink_scene_steps = "json:" .. Json.encode({ version = 1, scenes = {} })

    local updated = Mock.updateDriver(mock, project())
    local back = T.http(updated, "GET", "/v1/scenes/" .. morning.id, { key = key }).json
    T.eq(back.name, "Morning (1.7.0)")
    local actions = {}
    for _, step in ipairs(back.steps) do
        actions[#actions + 1] = step.type .. (step.set.action and (" " .. step.set.action) or "")
    end
    T.same(actions, { "lights", "music play_favorite", "music pause", "music volume" }, "in their places")
    T.eq(back.steps[2].set.favorite.uri, STATION)
    T.same(storedScenes(updated).music_steps_kept, true)
    T.contains(table.concat(updated.debugLog, "\n"), "put back")
    -- Removed on 1.8.0, they stay removed.
    T.eq(T.http(updated, "PATCH", "/v1/scenes/" .. morning.id, { key = key, body = { steps = { back.steps[1] } } }).status, 200)
    local again = Mock.updateDriver(updated, project())
    T.eq(#T.http(again, "GET", "/v1/scenes/" .. morning.id, { key = key }).json.steps, 1)
end

-- From 1.6.0, which knows neither refrigerators nor these music steps: both come back, in the order
-- they had.
function tests.refrigerator_and_music_steps_come_back_together_after_1_6_0()
    local p = project()
    Mock.withRefrigerator(p)
    local home = SonosFake.household({ grouped = true })
    local mock = Mock.startDriver(p, nil, nil, function(m)
        m.http = home:handler()
    end)
    local key = T.pair(mock)
    local created = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Shabbat", steps = {
        { type = "lights", device_ids = { 20 }, set = { on = false } },
        { type = "music", room_id = 12, set = { action = "volume", volume = 10 } },
        { type = "refrigerators", device_ids = { 141 }, set = { sabbath_mode = true } },
        { type = "music", room_id = 12, set = { action = "resume" } },
        { type = "climate", device_ids = { 30 }, set = { mode = "off" } },
    } } })
    T.eq(created.status, 201, created.body)
    local data = storedScenes(mock)
    for _, index in ipairs({ 4, 3, 2 }) do
        table.remove(data.scenes[1].steps, index)
    end
    data.steps_kept, data.music_steps_kept = nil, nil
    mock.persist.directorlink_scenes = "json:" .. Json.encode(data)
    local updated = Mock.updateDriver(mock, p)
    local steps = T.http(updated, "GET", "/v1/scenes/" .. created.json.id, { key = key }).json.steps
    local kinds = {}
    for _, step in ipairs(steps) do
        kinds[#kinds + 1] = step.type .. (step.set.action and (" " .. step.set.action) or "")
    end
    T.same(kinds, { "lights", "music volume", "refrigerators", "music resume", "climate" })
end

return tests

