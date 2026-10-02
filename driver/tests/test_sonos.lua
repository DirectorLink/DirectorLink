-- Sonos on the home network (ADR-044, docs/SONOS.md): off by default; found with SSDP or from one
-- player's address; each Sonos room in the Control4 room of its name (or an admin's pick); what it
-- plays, its volume and mute, read cheaply; play, pause, skip, volume and favorites for members;
-- album art through the controller; a scene step that pauses the music. Only the players' own
-- addresses, on port 1400, are ever contacted. The players are fakes (driver/tests/sonos_fake.lua)
-- answering with the real players' XML (tests/sonos/).

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local SonosFake = require("sonos_fake")

local tests = {}

local KITCHEN, LIVING, BEDROOM, TV = "RINCON_000E58A0000101400", "RINCON_000E58A0000201400", "RINCON_000E58A0000301400", "RINCON_000E58A0000401400"

local function isNull(value)
    return type(value) == "table" and tostring(value) == "null"
end

-- The default project (Kitchen 10, Living Room 11) with a room "tvroom" (12): Sonos's "TV Room"
-- belongs there, whatever the case and the spaces.
local function project()
    local p = Mock.project()
    Mock.addRoom(p, 12, "tvroom")
    return p
end

-- A driver with Sonos On (unless on = false) and fake players; an admin key paired at home.
local function start(options)
    options = options or {}
    local home = SonosFake.household({ grouped = options.grouped })
    local mock = Mock.startDriver(options.project or project(), nil, nil, function(m)
        m.http = home:handler()
        if options.on ~= false then
            Properties["Sonos"] = "On"
        end
        if options.address then
            Properties["Sonos Address"] = options.address
        end
        if options.prepare then
            options.prepare(m)
        end
    end)
    local key = T.pair(mock)
    return mock, home, key
end

local function module()
    return require("src.sonos.sonos")
end

local function pending(mock, delay)
    local list = {}
    for _, timer in ipairs(mock.timers) do
        if not timer.fired and not timer.cancelled and timer.source:find("/sonos/", 1, true) and (delay == nil or timer.delay == delay) then
            list[#list + 1] = timer
        end
    end
    return list
end

local function fire(mock, delay)
    local timers = pending(mock, delay)
    for _, timer in ipairs(timers) do
        timer.fired = true
        timer.callback()
    end
    return #timers
end

-- Director says the search's connection is up, every player answers, and the search ends.
local function discover(mock, home)
    OnConnectionStatusChanged(6100, 1900, "ONLINE")
    for _, reply in ipairs(home:searchReplies()) do
        ReceivedFromNetwork(6100, 1900, reply)
    end
    fire(mock, 4000)
end

local function music(mock, key, query)
    local response = T.http(mock, "GET", "/v1/music" .. (query or ""), { key = key })
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

local function createKey(mock, admin, role)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = role .. " phone", role = role } })
    T.eq(created.status, 201)
    return created.json.key
end

-- Every request the driver made went to a player's address, on port 1400.
local function onlyPlayers(mock, home)
    for _, request in ipairs(mock.urlRequests) do
        local ip, port = tostring(request.url):match("^http://([%d%.]+):(%d+)/")
        T.truthy(ip and home.players[ip] and port == "1400", "a request went to " .. tostring(request.url))
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

-- ---- the protocol, against the players' real answers ---------------------------------------

function tests.the_owners_household_reads_as_three_rooms_each_on_its_own()
    local Protocol = require("src.sonos.protocol")
    local values = Protocol.answer("GetZoneGroupState", SonosFake.read("real/zone_group_state.xml"))
    local topology = Protocol.topology(values.ZoneGroupState)
    T.eq(#topology.groups, 3)
    T.same(topology.players[KITCHEN], { id = KITCHEN, name = "מטבח", ip = "192.168.50.11" })
    T.same(topology.players[LIVING], { id = LIVING, name = "סלון", ip = "192.168.50.12" })
    T.same(topology.players[BEDROOM], { id = BEDROOM, name = "חוץ", ip = "192.168.50.13" })
    for _, group in ipairs(topology.groups) do
        T.eq(#group.members, 1)
        T.eq(group.members[1], group.id)
    end
end

function tests.a_group_a_stereo_pair_a_home_theater_and_a_boost()
    local Protocol = require("src.sonos.protocol")
    local values = Protocol.answer("GetZoneGroupState", SonosFake.read("made/zone_group_state_grouped.xml"))
    local topology = Protocol.topology(values.ZoneGroupState)
    -- The Boost is no room; the pair's second speaker and the satellites belong to their room.
    T.eq(#topology.groups, 3)
    T.same(topology.groups[1], { id = KITCHEN, members = { KITCHEN, LIVING } })
    T.same(topology.groups[2], { id = BEDROOM, members = { BEDROOM } })
    T.same(topology.groups[3], { id = TV, members = { TV } })
    local count = 0
    for _ in pairs(topology.players) do
        count = count + 1
    end
    T.eq(count, 4)
end

function tests.what_plays_spotify_connect_a_track_and_the_radio()
    local Protocol = require("src.sonos.protocol")
    local function now(position, media)
        return Protocol.nowPlaying(Protocol.answer("GetPositionInfo", SonosFake.read(position)), Protocol.answer("GetMediaInfo", SonosFake.read(media)), "192.168.50.11")
    end
    -- The owner's players, paused in Spotify Connect: the app, no track.
    T.same(now("real/position_info_spotify_connect.xml", "real/media_info_spotify_connect.xml"), { kind = "connect", source = "Spotify" })
    T.same(now("made/position_info_track.xml", "made/media_info_queue.xml"), {
        kind = "music",
        title = "Morning Light",
        artist = "The Example Band",
        album = "First Album",
        art = "/getaa?s=1&u=x-sonos-spotify%3Aspotify%253atrack%253a0000000000000000000001%3Fsid%3D12%26flags%3D8224%26sn%3D1",
    })
    T.eq(now("made/position_info_track_hebrew.xml", "made/media_info_queue.xml").title, "שיר לדוגמה")
    T.same(now("made/position_info_radio.xml", "made/media_info_radio.xml"), {
        kind = "radio",
        station = "Example FM 99",
        title = "Evening Song",
        artist = "The Example Band",
        art = "/getaa?s=1&u=x-sonosapi-stream%3As0000%3Fsid%3D254%26flags%3D8224%26sn%3D0",
    })
    -- A room in a group follows its coordinator.
    T.eq(now("made/position_info_group_member.xml", "made/position_info_group_member.xml").kind, "group")
end

function tests.album_art_only_from_the_player_itself()
    local Protocol = require("src.sonos.protocol")
    T.eq(Protocol.artPath("/getaa?s=1&u=x", "192.168.50.11"), "/getaa?s=1&u=x")
    T.eq(Protocol.artPath("http://192.168.50.11:1400/getaa?s=1", "192.168.50.11"), "/getaa?s=1")
    T.eq(Protocol.artPath("http://192.168.50.12:1400/getaa?s=1", "192.168.50.11"), nil, "another player's address")
    T.eq(Protocol.artPath("https://i.scdn.co/image/abc", "192.168.50.11"), nil, "a music service's server")
    T.eq(Protocol.artPath("//evil.example/x", "192.168.50.11"), nil)
    T.eq(Protocol.artPath("NOT_IMPLEMENTED", "192.168.50.11"), nil)
end

function tests.favorites_the_owners_shortcuts_and_playable_ones()
    local Protocol = require("src.sonos.protocol")
    local real = Protocol.favorites(Protocol.answer("Browse", SonosFake.read("real/favorites_shortcuts.xml")).Result)
    T.eq(#real, 3)
    T.eq(real[1].title, "Discover Sonos Radio")
    T.eq(real[1].description, "Sonos Radio")
    for _, favorite in ipairs(real) do
        T.eq(favorite.playable, false, favorite.title .. ": a Sonos Radio shortcut has no address to start")
    end
    local made = Protocol.favorites(Protocol.answer("Browse", SonosFake.read("made/favorites.xml")).Result)
    T.eq(#made, 4)
    T.same({ made[1].id, made[1].title, made[1].playable, made[1].uri }, { "10", "Example FM 99", true, "x-sonosapi-stream:s0000?sid=254&flags=8224&sn=0" })
    T.contains(made[1].meta, "<dc:title>Example FM 99</dc:title>")
    T.same({ made[2].id, made[2].title, made[2].playable }, { "11", "Dinner Jazz", true })
    T.eq(made[3].title, "רדיו לדוגמה")
    T.same({ made[4].id, made[4].playable }, { "1", false })
end

function tests.the_search_answer_and_addresses_of_the_home_network()
    local Protocol = require("src.sonos.protocol")
    local replies = Protocol.searchReplies(SonosFake.read("real/ssdp_response.txt"):gsub("\n", "\r\n"))
    T.same(replies, { { ip = "192.168.50.11", id = KITCHEN, household = "Sonos_ExampleHousehold00000000" } })
    -- Without CR too, and two answers run together.
    local twice = SonosFake.read("real/ssdp_response.txt") .. SonosFake.read("real/ssdp_response.txt"):gsub("192%.168%.50%.11", "10.0.0.7")
    T.eq(#Protocol.searchReplies(twice), 2)
    for _, address in ipairs({ "192.168.1.20", "10.1.2.3", "172.16.0.9", "172.31.255.254" }) do
        T.eq(Protocol.lanAddress(address), address)
    end
    for _, address in ipairs({ "8.8.8.8", "127.0.0.1", "172.32.0.1", "192.169.1.1", "192.168.1.255", "192.168.1.0", "192.168.1", "192.168.1.300", "host.local", "" }) do
        T.eq(Protocol.lanAddress(address), nil, address)
    end
    T.eq(Protocol.locationAddress("http://192.168.1.20:1400/xml/device_description.xml"), "192.168.1.20")
    T.eq(Protocol.locationAddress("http://192.168.1.20:8080/xml/device_description.xml"), nil, "not port 1400")
    T.eq(Protocol.locationAddress("http://203.0.113.5:1400/xml/device_description.xml"), nil, "not the home network")
end

function tests.a_soap_request_is_escaped_and_a_fault_is_its_upnp_error()
    local Protocol = require("src.sonos.protocol")
    local request = Protocol.request("SetAVTransportURI", { { "InstanceID", 0 }, { "CurrentURI", "x-a?b=1&c=2" }, { "CurrentURIMetaData", '<DIDL-Lite a="1"/>' } })
    T.eq(request.path, "/MediaRenderer/AVTransport/Control")
    T.eq(request.headers.SOAPACTION, '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"')
    T.contains(request.body, "<InstanceID>0</InstanceID><CurrentURI>x-a?b=1&amp;c=2</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite a=&quot;1&quot;/&gt;</CurrentURIMetaData>")
    T.eq(Protocol.request("BecomeCoordinatorOfStandaloneGroup", {}), nil, "only the actions DirectorLink uses")
    local values, failure = Protocol.answer("Pause", SonosFake.read("made/fault_701.xml"))
    T.eq(values, nil)
    T.eq(failure, "701")
    T.same(Protocol.answer("GetVolume", SonosFake.read("real/volume.xml")), { CurrentVolume = "58" })
end

-- ---- answers made to hold the controller --------------------------------------------------

-- Any device on the home network can answer the search, and is then asked for the household's
-- rooms: what it answers must not keep Director's single Lua thread busy. `run` is timed (Lua
-- time); the inputs are as large as the caps let through. Before the fix, patterns that tried
-- again from each character of a run took time as the square of it: 40 KB of attribute text
-- 16 s, a 60 KB search answer 12 s, and a 512 KB answer about two hours.
local function quick(label, run)
    local started = os.clock()
    local results = { run() }
    local took = os.clock() - started
    T.truthy(took < 1, string.format("%s took %.2f s of Lua time", label, took))
    return unpack(results)
end

local function soap(action, inner)
    return '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:' .. action
        .. 'Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">' .. inner .. "</u:" .. action .. "Response></s:Body></s:Envelope>"
end

local function escaped(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function tests.crafted_answers_are_read_in_time_in_proportion_to_their_size()
    local Protocol = require("src.sonos.protocol")
    local Xml = require("src.sonos.xml")
    -- An answer may be MAX_BYTES, one tag MAX_TAG.
    local room, tag = Xml.MAX_BYTES - 8192, Xml.MAX_TAG - 64
    local count = math.floor(room / (tag + 64))
    local function answer(label, inner)
        local body = soap("GetTransportInfo", inner .. "<CurrentTransportState>PLAYING</CurrentTransportState>")
        T.truthy(#body <= Xml.MAX_BYTES, label .. ": " .. #body .. " bytes")
        local values, why = quick(label, function()
            return Protocol.answer("GetTransportInfo", body)
        end)
        T.eq(values and values.CurrentTransportState, "PLAYING", label .. ": " .. tostring(why))
    end
    -- Attribute text: a long run of name characters with no "=", "a=a=a=...", a quote never
    -- closed, quotes of both kinds, spaces before the "=".
    for label, attributes in pairs({
        run = string.rep("b", tag),
        equals = string.rep("a=", tag / 2),
        unclosed = "a='" .. string.rep('"', tag - 3),
        mixed = string.rep([[a="b='c=]], tag / 8),
        spaces = "a" .. string.rep(" ", tag - 2) .. "=",
    }) do
        answer("attributes: " .. label, string.rep("<x " .. attributes .. ">1</x>", count))
    end
    -- Text: entities never ended, spaces.
    answer("entities", "<x>" .. string.rep("&a", room / 2) .. "</x>")
    answer("numeric entities", "<x>&#" .. string.rep("9", room) .. "</x>")
    answer("spaces", "<x>a" .. string.rep(" ", room) .. "b</x>")
    -- A tag never ended, or longer than a tag may be: refused at once.
    local _, why = quick("a tag never ended", function()
        return Protocol.answer("GetTransportInfo", "<" .. string.rep("a", room))
    end)
    T.eq(why, "bad tag")
    _, why = quick("a closing tag never ended", function()
        return Protocol.answer("GetTransportInfo", "<a></" .. string.rep("a", room))
    end)
    T.eq(why, "bad closing tag")
    _, why = quick("a tag too long", function()
        return Protocol.answer("GetTransportInfo", soap("GetTransportInfo", "<x " .. string.rep("b", room) .. ">"))
    end)
    T.eq(why, "too large")
    -- What plays: a run of spaces in each field of the metadata, as the player sends it (DIDL-Lite
    -- escaped in the answer), on a station and on a track.
    local run = "a" .. string.rep(" ", room - 4096) .. "b"
    local function didl(field, value)
        return '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"><item id="-1" parentID="-1"><res>x-sonosapi-stream:s1?sid=254</res><'
            .. field .. ">" .. value .. "</" .. field .. "><upnp:class>object.item</upnp:class></item></DIDL-Lite>"
    end
    for _, uri in ipairs({ "x-sonosapi-stream:s1?sid=254", "x-sonos-spotify:spotify%3atrack%3a1?sid=12" }) do
        for _, field in ipairs({ "dc:title", "dc:creator", "upnp:album", "r:streamContent", "upnp:albumArtURI" }) do
            local position = soap("GetPositionInfo", "<TrackMetaData>" .. escaped(didl(field, run)) .. "</TrackMetaData><TrackURI>" .. uri .. "</TrackURI>")
            local media = soap("GetMediaInfo", "<CurrentURI>" .. uri .. "</CurrentURI><CurrentURIMetaData>" .. escaped(didl("dc:title", run)) .. "</CurrentURIMetaData>")
            local now = quick(field .. " " .. uri, function()
                return Protocol.nowPlaying(Protocol.answer("GetPositionInfo", position), Protocol.answer("GetMediaInfo", media), "192.168.50.11")
            end)
            for name, value in pairs(now) do
                T.truthy(#value <= Protocol.MAX_TEXT, name .. " is " .. #value .. " bytes")
            end
        end
    end
    -- "Artist - Title" of a station, with long runs of spaces and dashes.
    for label, stream in pairs({ spaces = run, dashes = "a" .. string.rep(" -", room / 2) .. "b" }) do
        local position = soap("GetPositionInfo", "<TrackMetaData>" .. escaped(didl("r:streamContent", stream)) .. "</TrackMetaData><TrackURI>x-sonosapi-stream:s1</TrackURI>")
        quick("stream " .. label, function()
            return Protocol.nowPlaying(Protocol.answer("GetPositionInfo", position), {}, "192.168.50.11")
        end)
    end
    -- Favorites and the household's rooms.
    local items = {}
    for index = 1, 20 do
        items[index] = '<item id="FV:2/' .. index .. '"><dc:title>' .. string.rep(" ", room / 25) .. "x</dc:title></item>"
    end
    local favorites = soap("Browse", "<Result>" .. escaped("<DIDL-Lite>" .. table.concat(items) .. "</DIDL-Lite>") .. "</Result>")
    local list = quick("favorites", function()
        return Protocol.favorites(Protocol.answer("Browse", favorites).Result)
    end)
    T.eq(#list, 20)
    local members = {}
    for index = 1, 12 do
        members[index] = '<ZoneGroup Coordinator="RINCON_' .. index .. '" ' .. string.rep("b", tag / 2) .. '><ZoneGroupMember UUID="RINCON_' .. index
            .. '" Location="http://192.168.50.' .. index .. ':1400/x" ZoneName="a' .. string.rep(" ", tag / 3) .. 'b"/></ZoneGroup>'
    end
    local zones = soap("GetZoneGroupState", "<ZoneGroupState>" .. escaped("<ZoneGroupState><ZoneGroups>" .. table.concat(members) .. "</ZoneGroups></ZoneGroupState>") .. "</ZoneGroupState>")
    local topology = quick("rooms", function()
        return Protocol.topology(Protocol.answer("GetZoneGroupState", zones).ZoneGroupState)
    end)
    T.eq(#topology.groups, 12)
    T.eq(#topology.players.RINCON_1.name, Protocol.MAX_NAME)
    -- Search answers: a run of spaces in a header, in one datagram and in many run together.
    local reply = SonosFake.read("real/ssdp_response.txt"):gsub("\r?\n", "\r\n")
    local spaced = "HTTP/1.1 200 OK\r\nX-PAD: a" .. string.rep(" ", 65000) .. "b\r\n" .. reply:gsub("^HTTP/1%.1 200 OK\r\n", "")
    T.eq(#quick("a datagram", function()
        return Protocol.searchReplies(spaced)
    end), 1)
    quick("datagrams run together", function()
        return Protocol.searchReplies(string.rep(spaced, 7))
    end)
    -- A fault's error code that is no number is not repeated (in the log, in the API's answer).
    local fault = SonosFake.read("made/fault_701.xml"):gsub("701", string.rep("x ", room / 4))
    T.eq(select(2, quick("a fault", function()
        return Protocol.answer("Pause", fault)
    end)), "fault")
    T.eq(select(2, Protocol.answer("Pause", SonosFake.read("made/fault_701.xml"))), "701")
    -- Ordinary attributes are still read.
    T.same(Xml.parse([[<a x = "1" y='2' p:z="3"/>]]).children[1].attrs, { x = "1", y = "2", z = "3" })
end

-- The same through the driver: a device answers the search with a datagram made to be slow to
-- read, then answers GetZoneGroupState with the largest answer taken, made the same way.
function tests.a_device_on_the_network_cannot_hold_the_lua_thread()
    local Xml = require("src.sonos.xml")
    local evil = "192.168.50.66"
    local tag = Xml.MAX_TAG - 256
    local members = {}
    for index = 1, 14 do
        members[index] = '<ZoneGroup Coordinator="RINCON_' .. index .. '" ' .. string.rep("b", tag) .. '><ZoneGroupMember UUID="RINCON_' .. index
            .. '" Location="http://' .. evil .. ':1400/x" ' .. string.rep("c", tag) .. "/></ZoneGroup>"
    end
    local zones = soap("GetZoneGroupState", "<ZoneGroupState>" .. escaped("<ZoneGroupState><ZoneGroups>" .. table.concat(members) .. "</ZoneGroups></ZoneGroupState>") .. "</ZoneGroupState>")
    T.truthy(#zones <= Xml.MAX_BYTES and #zones > Xml.MAX_BYTES * 0.8, #zones)
    local asked = 0
    local mock = start({ prepare = function(m)
        local players = m.http
        m.http = function(request)
            if tostring(request.url):find("http://" .. evil .. ":1400/", 1, true) then
                asked = asked + 1
                return { code = 200, headers = { ["Content-Type"] = "text/xml" }, body = zones }
            end
            return players(request)
        end
    end })
    OnConnectionStatusChanged(6100, 1900, "ONLINE")
    local reply = SonosFake.read("real/ssdp_response.txt"):gsub("\r?\n", "\r\n"):gsub("192%.168%.50%.11", evil)
    local datagram = "HTTP/1.1 200 OK\r\nX-PAD: a" .. string.rep(" ", 65000) .. "b\r\n" .. reply:gsub("^HTTP/1%.1 200 OK\r\n", "")
    quick("the search answer", function()
        ReceivedFromNetwork(6100, 1900, datagram)
    end)
    quick("the search's end, and the answer to GetZoneGroupState", function()
        fire(mock, 4000)
    end)
    T.eq(asked, 1)
end

-- ---- off ----------------------------------------------------------------------------------

function tests.off_by_default_it_looks_for_nothing_and_sends_nothing()
    local mock, home, key = start({ on = false })
    T.eq(mock.network[6100], nil, "no search")
    T.eq(mock.properties["Sonos Players"], "Off")
    T.same(music(mock, key), { enabled = false, status = "off", items = Json.array() })
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.features.sonos, false)
    local refused = T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/play", { key = key })
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "SONOS_OFF")
    T.eq(T.http(mock, "GET", "/v1/music/" .. KITCHEN .. "/art", { key = key }).json.code, "SONOS_OFF")
    module().tick(os.time() + 3600)
    T.eq(#mock.urlRequests, 0)
    T.eq(#home.calls, 0)
end

-- ---- finding the players -------------------------------------------------------------------

function tests.on_it_searches_the_home_network_and_reads_the_rooms_from_a_player()
    local mock, home, key = start()
    local search = mock.network[6100]
    T.same({ search.host, search.port, search.kind, search.connects }, { "239.255.255.250", 1900, "UDP", 1 })
    T.eq(mock.properties["Sonos Players"], "Looking for players...")
    OnConnectionStatusChanged(6100, 1900, "ONLINE")
    T.eq(#search.datagrams, 2)
    T.eq(search.datagrams[1].port, 1900)
    T.contains(search.datagrams[1].data, "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n")
    T.contains(search.datagrams[1].data, "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n")
    -- The search's own message comes back on the multicast group: not an answer.
    ReceivedFromNetwork(6100, 1900, search.datagrams[1].data)
    for _, reply in ipairs(home:searchReplies()) do
        ReceivedFromNetwork(6100, 1900, reply)
    end
    T.eq(#home.calls, 0, "nothing asked before the search ends")
    fire(mock, 4000)
    T.eq(search.disconnects >= 1, true, "the search's connection is closed")
    T.same(home:sent(), { "192.168.50.11 GetZoneGroupState" })
    T.eq(mock.properties["Sonos Players"], "3 players: חוץ (192.168.50.13), מטבח (192.168.50.11), סלון (192.168.50.12)")
    local list = music(mock, key)
    T.eq(list.enabled, true)
    T.eq(list.status, "ok")
    T.eq(#list.items, 3)
    T.eq(T.http(mock, "GET", "/v1/system", { key = key }).json.features.sonos, true)
    onlyPlayers(mock, home)
end

function tests.sonos_address_finds_them_when_the_search_does_not()
    local mock, home, key = start({ address = "192.168.50.12" })
    -- Read at once from the installer's player, which lists the other two.
    T.same(home:sent(), { "192.168.50.12 GetZoneGroupState" })
    T.eq(#music(mock, key).items, 3)
    -- No answer to the search changes nothing.
    fire(mock, 4000)
    T.eq(#music(mock, key).items, 3)
    onlyPlayers(mock, home)
end

function tests.nothing_found_says_what_to_do_in_composer()
    local mock = start()
    fire(mock, 4000)
    T.eq(mock.properties["Sonos Players"], "None found. Set Sonos Address to one player's IP address.")
end

function tests.only_home_network_addresses_on_port_1400_are_ever_contacted()
    local mock, home, key = start({ address = "8.8.8.8" })
    -- An address outside the home network is not taken from Composer either.
    T.eq(#mock.urlRequests, 0)
    OnConnectionStatusChanged(6100, 1900, "ONLINE")
    local reply = SonosFake.read("real/ssdp_response.txt"):gsub("\n", "\r\n")
    ReceivedFromNetwork(6100, 1900, (reply:gsub("192%.168%.50%.11:1400", "203.0.113.9:1400")))
    ReceivedFromNetwork(6100, 1900, (reply:gsub("192%.168%.50%.11:1400", "192.168.50.11:8080")))
    ReceivedFromNetwork(6100, 1900, (reply:gsub("ZonePlayer", "MediaRenderer")))
    fire(mock, 4000)
    T.eq(#mock.urlRequests, 0, "no answer named a player DirectorLink may contact")
    -- A player lists one member outside the home network: it is left out.
    home.topology = home.topology:gsub("192%.168%.50%.13:1400", "203.0.113.13:1400")
    module().tick(os.time() + 400)
    ReceivedFromNetwork(6100, 1900, reply)
    fire(mock, 4000)
    local list = music(mock, key)
    T.eq(#list.items, 2)
    T.eq(item(list, BEDROOM), nil)
    onlyPlayers(mock, home)
    -- An API request cannot name an address.
    for _, path in ipairs({ "/v1/music/192.168.50.11/play", "/v1/music/http:%2F%2F203.0.113.9%2F/play", "/v1/music/" .. BEDROOM .. "/play" }) do
        local refused = T.http(mock, "POST", path, { key = key })
        T.truthy(refused.status == 400 or refused.status == 404, path .. " " .. tostring(refused.status))
    end
    onlyPlayers(mock, home)
end

-- ---- rooms ---------------------------------------------------------------------------------

function tests.each_sonos_room_in_the_control4_room_of_its_name()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    local list = music(mock, key)
    T.eq(#list.items, 4)
    T.same({ item(list, KITCHEN).room_id, item(list, KITCHEN).room_match }, { 10, "name" })
    T.same({ item(list, LIVING).room_id, item(list, LIVING).room_match }, { 11, "name" })
    -- "TV Room" and "tvroom": the same name.
    T.same({ item(list, TV).room_id, item(list, TV).room_match }, { 12, "name" })
    T.truthy(isNull(item(list, BEDROOM).room_id), "Bedroom matches no room")
    T.truthy(isNull(item(list, BEDROOM).room_match))
    -- In a room: only its Sonos rooms.
    local kitchen = music(mock, key, "?room_id=10")
    T.eq(#kitchen.items, 1)
    T.eq(kitchen.items[1].id, KITCHEN)
end

function tests.a_room_named_in_another_language_matches_too()
    local mock, home, key = start()
    -- The owner's Sonos rooms are named in Hebrew; the Control4 rooms in English, with their
    -- Hebrew names set in the app.
    T.eq(T.http(mock, "PATCH", "/v1/rooms/10", { key = key, body = { names = { he = "מטבח" } } }).status, 200)
    discover(mock, home)
    local list = music(mock, key)
    T.eq(item(list, KITCHEN).room_id, 10)
    T.truthy(isNull(item(list, LIVING).room_id))
end

function tests.an_admin_picks_the_room_and_it_is_kept_across_restarts()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    local placed = T.http(mock, "PUT", "/v1/music/" .. BEDROOM .. "/room", { key = key, body = { room_id = 11 } })
    T.eq(placed.status, 200, placed.body)
    T.same({ placed.json.room_id, placed.json.room_match }, { 11, "admin" })
    -- The admin's pick wins over the name.
    T.eq(T.http(mock, "PUT", "/v1/music/" .. KITCHEN .. "/room", { key = key, body = { room_id = 12 } }).json.room_id, 12)
    local member = createKey(mock, key, "member")
    local refused = T.http(mock, "PUT", "/v1/music/" .. BEDROOM .. "/room", { key = member, body = { room_id = 10 } })
    T.eq(refused.status, 403)
    T.eq(T.http(mock, "PUT", "/v1/music/" .. BEDROOM .. "/room", { key = key, body = { room_id = 99 } }).status, 400, "not a room")
    T.eq(T.http(mock, "PUT", "/v1/music/" .. BEDROOM .. "/room", { key = key, body = {} }).status, 400)

    -- Director keeps the properties across an update; the fake one starts them afresh.
    local updated = Mock.updateDriver(mock, project())
    updated.http = home:handler()
    Properties["Sonos"] = "On"
    OnPropertyChanged("Sonos")
    discover(updated, home)
    local list = music(updated, key)
    T.eq(item(list, BEDROOM).room_id, 11)
    T.eq(item(list, KITCHEN).room_id, 12)
    -- null: back to its name.
    local back = T.http(updated, "PUT", "/v1/music/" .. KITCHEN .. "/room", { key = key, body = { room_id = Json.null } })
    T.same({ back.json.room_id, back.json.room_match }, { 10, "name" })
end

-- ---- reading -------------------------------------------------------------------------------

function tests.what_each_room_plays_its_volume_and_its_group()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    local list = music(mock, key)
    local kitchen, living, bedroom, tv = item(list, KITCHEN), item(list, LIVING), item(list, BEDROOM), item(list, TV)
    T.eq(kitchen.state, "playing")
    T.same(kitchen.now_playing, {
        kind = "music", title = "Morning Light", artist = "The Example Band", album = "First Album", station = Json.null, source = Json.null,
        art_href = "/v1/music/" .. KITCHEN .. "/art", art_key = kitchen.now_playing.art_key,
    })
    T.truthy(kitchen.now_playing.art_key:match("^%x%x%x%x%x%x%x%x$"))
    T.same({ kitchen.volume, kitchen.muted, kitchen.can_skip, kitchen.reachable }, { 30, false, true, true })
    T.same(kitchen.group, { id = KITCHEN, coordinator = true, rooms = { { id = KITCHEN, name = "Kitchen" }, { id = LIVING, name = "Living Room" } } })
    -- Living Room follows Kitchen: the group's music, its own volume.
    T.eq(living.state, "playing")
    T.eq(living.now_playing.title, "Morning Light")
    T.eq(living.volume, 20)
    T.eq(living.group.coordinator, false)
    T.eq(living.group.id, KITCHEN)
    T.same({ bedroom.now_playing.kind, bedroom.now_playing.station, bedroom.now_playing.title, bedroom.can_skip }, { "radio", "Example FM 99", "Evening Song", false })
    T.same({ tv.state, tv.now_playing.kind, tv.now_playing.source }, { "paused", "connect", "Spotify" })
    T.truthy(isNull(tv.now_playing.title))
    -- The coordinator alone is asked what plays; each room for its own volume and mute.
    T.same(home:sent("192.168.50.12"), { "GetVolume", "GetMute" })
    local coordinator = home:sent("192.168.50.11")
    T.same({ coordinator[1], coordinator[2], coordinator[3] }, { "GetZoneGroupState", "GetTransportInfo", "GetPositionInfo" })
    onlyPlayers(mock, home)
end

function tests.a_room_open_in_the_app_is_read_every_few_seconds_the_others_every_minute()
    local mock, home, key = start({ grouped = true })
    local Sonos = module()
    withClock(1000000, function(advance)
        discover(mock, home)
        music(mock, key, "?room_id=10")
        local function reads(ip)
            local count = 0
            for _, action in ipairs(home:sent(ip)) do
                count = count + (action == "GetTransportInfo" and 1 or 0)
            end
            return count
        end
        local kitchen, bedroom = reads("192.168.50.11"), reads("192.168.50.13")
        T.eq(kitchen, 1)
        T.eq(bedroom, 1, "every room is read once at first")
        -- The app asks every 5 seconds; the driver's tick comes every 2.
        for _ = 1, 6 do
            Sonos.tick(advance(2))
            Sonos.tick(advance(3))
            music(mock, key, "?room_id=10")
        end
        T.truthy(reads("192.168.50.11") - kitchen >= 6, "the open room every few seconds: " .. reads("192.168.50.11"))
        T.eq(reads("192.168.50.13") - bedroom, 0, "Bedroom is not open: not read again within a minute")
        -- Nobody looks (once the last look is over): every room every minute only.
        Sonos.tick(advance(16))
        local before = reads("192.168.50.11")
        for _ = 1, 30 do
            Sonos.tick(advance(2))
        end
        T.truthy(reads("192.168.50.11") - before <= 2, "kitchen read " .. (reads("192.168.50.11") - before) .. " times in a minute nobody looked")
        T.truthy(reads("192.168.50.13") - bedroom >= 1, "Bedroom read within the minute")
        -- Home shows them all.
        before = reads("192.168.50.13")
        for _ = 1, 3 do
            music(mock, key)
            Sonos.tick(advance(5))
        end
        T.truthy(reads("192.168.50.13") - before >= 3, "Home: every room every few seconds")
    end)
end

function tests.reads_never_wait_and_few_go_out_at_once()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    mock.httpDeferred = true
    local before = #mock.httpQueue
    local answered = T.http(mock, "GET", "/v1/music", { key = key })
    T.eq(answered.status, 200, "answered at once, with what is known")
    local Client = require("src.sonos.client")
    T.truthy(#mock.httpQueue - before <= Client.MAX_IN_FLIGHT, "at most " .. Client.MAX_IN_FLIGHT .. " on their way")
    T.truthy(#mock.httpQueue > before)
    Mock.deliverHttp(mock)
    mock.httpDeferred = false
    T.eq(item(music(mock, key), BEDROOM).now_playing.station, "Example FM 99")
end

function tests.a_player_that_does_not_answer_is_shown_so_and_found_again()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    music(mock, key)
    home.offline["192.168.50.13"] = true
    mock.httpDeferred = true
    withClock(os.time() + 120, function()
        module().tick()
        Mock.deliverHttp(mock)
    end)
    mock.httpDeferred = false
    local list = music(mock, key)
    T.eq(item(list, BEDROOM).reachable, false)
    T.eq(item(list, KITCHEN).reachable, true)
    T.contains(mock.properties["Sonos Players"], "Bedroom (192.168.50.13, not answering)")
    -- A command to it fails plainly.
    local failed = T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/pause", { key = key })
    T.eq(failed.status, 502)
    T.eq(failed.json.code, "PLAYER_UNREACHABLE")
end

function tests.a_player_that_never_reports_back_times_out()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    mock.httpDeferred = true
    local response = T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/next", { key = key })
    T.eq(response.status, nil, "answered once the player has")
    -- The transfer never reports back: the guard timer ends it.
    T.truthy(fire(mock, 6000) >= 1)
    local answer = T.response(mock, response.handle)
    T.eq(answer.status, 502)
    T.eq(answer.json.code, "PLAYER_UNREACHABLE")
    mock.httpQueue = {}
    mock.httpDeferred = false
end

-- ---- control -------------------------------------------------------------------------------

function tests.play_pause_and_skip_go_to_the_groups_coordinator()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    home:clear()
    -- Living Room follows Kitchen: Kitchen is told.
    local paused = T.http(mock, "POST", "/v1/music/" .. LIVING .. "/pause", { key = key })
    T.eq(paused.status, 200, paused.body)
    T.eq(paused.json.state, "paused")
    T.eq(paused.json.id, LIVING)
    T.same(home:sent(), { "192.168.50.11 Pause" })
    T.eq(home.players["192.168.50.11"].transport, "PAUSED_PLAYBACK")
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/play", { key = key }).json.state, "playing")
    T.contains(home.calls[#home.calls].body, "<InstanceID>0</InstanceID><Speed>1</Speed>")
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/next", { key = key }).status, 200)
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/previous", { key = key }).status, 200)
    T.same(home:sent(), { "192.168.50.11 Pause", "192.168.50.11 Play", "192.168.50.11 Next", "192.168.50.11 Previous" })
    -- After Next, the next read shows the next track.
    T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/next", { key = key })
    module().tick(os.time() + 1)
    T.eq(item(music(mock, key), KITCHEN).now_playing.title, "שיר לדוגמה")
end

function tests.a_radio_station_cannot_pause_so_it_stops_and_cannot_skip()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    home:clear()
    local paused = T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/pause", { key = key })
    T.eq(paused.status, 200, paused.body)
    T.same(home:sent(), { "192.168.50.13 Pause", "192.168.50.13 Stop" })
    T.eq(paused.json.state, "stopped")
    local skipped = T.http(mock, "POST", "/v1/music/" .. BEDROOM .. "/next", { key = key })
    T.eq(skipped.status, 409)
    T.eq(skipped.json.code, "ACTION_NOT_POSSIBLE")
end

function tests.volume_and_mute_are_each_rooms_own()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    home:clear()
    local changed = T.http(mock, "PATCH", "/v1/music/" .. LIVING, { key = key, body = { volume = 35 } })
    T.eq(changed.status, 200, changed.body)
    T.eq(changed.json.volume, 35)
    T.same(home:sent(), { "192.168.50.12 SetVolume" })
    T.contains(home.calls[1].body, "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>35</DesiredVolume>")
    T.eq(home.players["192.168.50.12"].volume, 35)
    T.eq(home.players["192.168.50.11"].volume, 30, "Kitchen, in the same group, keeps its own")
    local muted = T.http(mock, "PATCH", "/v1/music/" .. KITCHEN, { key = key, body = { muted = true } })
    T.eq(muted.json.muted, true)
    T.contains(home.calls[#home.calls].body, "<DesiredMute>1</DesiredMute>")
    for _, body in ipairs({ { volume = 101 }, { volume = -1 }, { volume = 10.5 }, { volume = "10" }, { muted = "yes" }, { loud = true }, {} }) do
        local refused = T.http(mock, "PATCH", "/v1/music/" .. KITCHEN, { key = key, body = body })
        T.eq(refused.status, 400, Json.encode(body))
    end
end

function tests.a_command_answered_after_the_rooms_were_read_again_still_shows()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    music(mock, key)
    mock.httpDeferred = true
    -- The household is read again (a new Sonos Address), and the volume is set meanwhile: the
    -- player answers the volume after the household.
    Properties["Sonos Address"] = "192.168.50.12"
    OnPropertyChanged("Sonos Address")
    T.eq(mock.httpQueue[#mock.httpQueue].url, "http://192.168.50.12:1400/ZoneGroupTopology/Control")
    local response = T.http(mock, "PATCH", "/v1/music/" .. LIVING, { key = key, body = { volume = 35 } })
    Mock.deliverHttp(mock)
    mock.httpDeferred = false
    T.eq(T.response(mock, response.handle).status, 200)
    T.eq(T.http(mock, "GET", "/v1/music/" .. LIVING, { key = key }).json.volume, 35)
end

function tests.viewers_read_members_control()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    local viewer = createKey(mock, key, "viewer")
    local member = createKey(mock, key, "member")
    music(mock, key)
    home:clear()
    T.eq(T.http(mock, "GET", "/v1/music", { key = viewer }).status, 200)
    T.eq(T.http(mock, "GET", "/v1/music/" .. KITCHEN, { key = viewer }).status, 200)
    T.eq(T.http(mock, "GET", "/v1/music/" .. KITCHEN .. "/favorites", { key = viewer }).status, 200)
    T.eq(T.http(mock, "GET", "/v1/music/" .. KITCHEN .. "/art", { key = viewer }).status, 200)
    for _, request in ipairs({
        { "POST", "/play" }, { "POST", "/pause" }, { "POST", "/next" }, { "POST", "/previous" }, { "PATCH", "", { volume = 5 } },
        { "POST", "/favorites/10/play" }, { "PUT", "/room", { room_id = 10 } },
    }) do
        local refused = T.http(mock, request[1], "/v1/music/" .. KITCHEN .. request[2], { key = viewer, body = request[3] })
        T.eq(refused.status, 403, request[1] .. " " .. request[2])
    end
    for _, action in ipairs(home:sent()) do
        T.truthy(action:match(" Get") or action:match(" Browse"), "a viewer only read: " .. action)
    end
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/pause", { key = member }).status, 200)
    T.eq(T.http(mock, "PATCH", "/v1/music/" .. KITCHEN, { key = member, body = { volume = 12 } }).status, 200)
    T.eq(T.http(mock, "GET", "/v1/music", {}).status, 401)
end

function tests.favorites_start_a_station_or_replace_the_queue()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    local favorites = T.http(mock, "GET", "/v1/music/" .. LIVING .. "/favorites", { key = key })
    T.eq(favorites.status, 200, favorites.body)
    T.same(favorites.json.items[1], { id = "10", title = "Example FM 99", description = "TuneIn Station", playable = true })
    T.same(favorites.json.items[4], { id = "1", title = "Discover Sonos Radio", description = "Sonos Radio", playable = false })
    home:clear()
    -- A station, on Living Room's group: Kitchen plays it.
    local station = T.http(mock, "POST", "/v1/music/" .. LIVING .. "/favorites/10/play", { key = key })
    T.eq(station.status, 200, station.body)
    T.same(home:sent(), { "192.168.50.11 SetAVTransportURI", "192.168.50.11 Play" })
    T.eq(SonosFake.argument(home.calls[1].body, "CurrentURI"), "x-sonosapi-stream:s0000?sid=254&flags=8224&sn=0")
    T.contains(SonosFake.argument(home.calls[1].body, "CurrentURIMetaData"), "<dc:title>Example FM 99</dc:title>")
    -- A playlist goes in place of the queue, which then plays.
    home:clear()
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/favorites/11/play", { key = key }).status, 200)
    T.same(home:sent(), { "192.168.50.11 RemoveAllTracksFromQueue", "192.168.50.11 AddURIToQueue", "192.168.50.11 SetAVTransportURI", "192.168.50.11 Play" })
    T.eq(SonosFake.argument(home.calls[2].body, "EnqueuedURI"), "x-rincon-cpcontainer:1006206cspotify%3aplaylist%3a0000000000000000000002?sid=12&flags=8300&sn=1")
    T.contains(SonosFake.argument(home.calls[2].body, "EnqueuedURIMetaData"), "SA_RINCON3079_X_#Svc3079-0-Token")
    T.eq(SonosFake.argument(home.calls[3].body, "CurrentURI"), "x-rincon-queue:" .. KITCHEN .. "#0")
    -- The favorites were read once, a minute ago at most.
    local browsed = 0
    for _, action in ipairs(home:sent()) do
        browsed = browsed + (action:match("Browse") and 1 or 0)
    end
    T.eq(browsed, 0)
    local shortcut = T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/favorites/1/play", { key = key })
    T.eq(shortcut.status, 409)
    T.eq(shortcut.json.code, "FAVORITE_NOT_PLAYABLE")
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/favorites/77/play", { key = key }).status, 404)
    T.eq(T.http(mock, "POST", "/v1/music/" .. KITCHEN .. "/favorites/FV:2%2F10/play", { key = key }).status, 400)
end

function tests.album_art_through_the_controller_from_the_coordinator()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    music(mock, key)
    local art = T.http(mock, "GET", "/v1/music/" .. LIVING .. "/art", { key = key })
    T.eq(art.status, 200, art.body)
    T.eq(art.headers["content-type"], "image/jpeg")
    T.contains(art.body, "JFIF art /getaa?s=1&u=x-sonos-spotify")
    T.same(home.art, { "/getaa?s=1&u=x-sonos-spotify%3Aspotify%253atrack%253a0000000000000000000001%3Fsid%3D12%26flags%3D8224%26sn%3D1" })
    T.eq(mock.urlRequests[#mock.urlRequests].url:match("^http://([%d%.]+):1400/getaa"), "192.168.50.11", "from the coordinator")
    -- Kept: the app asking again does not reach the player.
    T.eq(T.http(mock, "GET", "/v1/music/" .. KITCHEN .. "/art", { key = key }).status, 200)
    T.eq(#home.art, 1)
    local none = T.http(mock, "GET", "/v1/music/" .. TV .. "/art", { key = key })
    T.eq(none.status, 404)
    T.eq(none.json.code, "NO_ART")
end

-- ---- scenes --------------------------------------------------------------------------------

function tests.a_scene_pauses_the_music_in_a_room_or_the_whole_home()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    home:clear()
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = { { type = "music", room_id = 11, set = { action = "pause" } } } } })
    T.eq(tried.status, 202, tried.body)
    T.eq(tried.json.ran, 1)
    -- Living Room's group is Kitchen's: the group pauses.
    T.same(home:sent(), { "192.168.50.11 Pause" })
    home:clear()
    local created = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Good night", steps = { { type = "music", set = { action = "stop" } } } } })
    T.eq(created.status, 201, created.body)
    T.same(created.json.steps[1], { type = "music", room_id = Json.null, device_ids = Json.null, set = { action = "stop" } })
    local ran = T.http(mock, "POST", "/v1/scenes/" .. created.json.id .. "/run", { key = key })
    T.eq(ran.json.ran, 3)
    local sent = home:sent()
    table.sort(sent)
    T.same(sent, { "192.168.50.11 Stop", "192.168.50.13 Stop", "192.168.50.14 Stop" })
    -- A schedule runs it like a member's key.
    home:clear()
    local Handlers = require("src.api.handlers.scenes")
    local result = Handlers.runSaved({ registry = require("src.core.registry"), adapters = require("src.adapters.manager"), doorControlEnabled = function() return false end, log = require("src.core.log") }, created.json.id, { id = "schedule:x", role = "member" })
    T.eq(result.ran, 3)
end

function tests.a_music_step_names_a_room_or_nothing_and_pauses_or_stops()
    local mock, home, key = start()
    discover(mock, home)
    for _, step in ipairs({
        { type = "music", set = { action = "play" } },
        { type = "music", set = { action = "pulse" } },
        { type = "music", set = {} },
        { type = "music", device_ids = { 20 }, set = { action = "pause" } },
        { type = "music", room_id = 99, set = { action = "pause" } },
        { type = "music", set = { action = "pause", volume = 3 } },
    }) do
        local refused = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "x", steps = { step } } })
        T.eq(refused.status, 400, Json.encode(step))
    end
    T.eq(T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Quiet kitchen", steps = { { type = "music", room_id = 10, set = { action = "pause" } } } } }).status, 201)
end

function tests.a_music_step_is_kept_and_shown_to_the_installer()
    local mock, home, key = start()
    discover(mock, home)
    local created = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Quiet", steps = {
        { type = "music", room_id = 10, set = { action = "pause" } },
        { type = "music", set = { action = "stop" } },
    } } })
    T.eq(created.status, 201, created.body)
    local printed = {}
    local realPrint = print
    print = function(line)
        printed[#printed + 1] = line
    end
    local ok, err = pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "PRINT_AUTOMATION" })
    print = realPrint
    T.truthy(ok, err)
    local text = table.concat(printed, "\n")
    T.contains(text, "the Sonos music in Kitchen (10) -> pause")
    T.contains(text, "the Sonos music in the whole home -> stop")
    -- Kept across an update of the driver.
    local updated = Mock.updateDriver(mock, project())
    local scene = T.http(updated, "GET", "/v1/scenes/" .. created.json.id, { key = key }).json
    T.same(scene.steps[1], { type = "music", room_id = 10, device_ids = Json.null, set = { action = "pause" } })
    T.eq(#scene.steps, 2)
end

function tests.with_sonos_off_a_music_step_is_skipped_and_says_why()
    local mock, home, key = start({ on = false })
    local tried = T.http(mock, "POST", "/v1/scenes/try", { key = key, body = { steps = { { type = "music", set = { action = "pause" } } } } })
    T.eq(tried.status, 202)
    T.same({ tried.json.ran, tried.json.skipped }, { 0, 1 })
    T.same({ tried.json.problems[1].code, tried.json.problems[1].device_id }, { "SONOS_OFF", 0 })
    T.eq(#home.calls, 0)
end

-- ---- turned off again ----------------------------------------------------------------------

function tests.turned_off_in_composer_it_stops_at_once()
    local mock, home, key = start({ grouped = true })
    discover(mock, home)
    T.eq(#music(mock, key).items, 4)
    mock.httpDeferred = true
    T.http(mock, "GET", "/v1/music", { key = key })
    Properties["Sonos"] = "Off"
    OnPropertyChanged("Sonos")
    T.eq(mock.properties["Sonos Players"], "Off")
    T.same(music(mock, key), { enabled = false, status = "off", items = Json.array() })
    -- Answers on their way change nothing, and nothing more is asked.
    Mock.deliverHttp(mock)
    mock.httpDeferred = false
    home:clear()
    local requests = #mock.urlRequests
    module().tick(os.time() + 3600)
    fire(mock)
    T.eq(#mock.urlRequests, requests)
    T.eq(#pending(mock), 0, "no timer left")
    -- On again: found again.
    Properties["Sonos"] = "On"
    OnPropertyChanged("Sonos")
    discover(mock, home)
    T.eq(#music(mock, key).items, 4)
end

function tests.a_new_sonos_address_is_tried_at_once()
    local mock, home, key = start()
    fire(mock, 4000)
    T.eq(#music(mock, key).items, 0)
    Properties["Sonos Address"] = "192.168.50.13"
    OnPropertyChanged("Sonos Address")
    T.same(home:sent(), { "192.168.50.13 GetZoneGroupState" })
    T.eq(#music(mock, key).items, 3)
end

return tests
