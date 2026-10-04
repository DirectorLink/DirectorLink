-- Fake Sonos players for the driver tests (the node twin, tests/sonos/fake-sonos.mjs, serves the
-- dev server, the contract test and the browser check on a port). They answer the SOAP calls
-- DirectorLink sends with the players' own XML: the owner's real answers, anonymised
-- (tests/sonos/real/), and answers made in the same shapes (tests/sonos/made/): a track from the
-- queue, a radio station, favorites, a group, a refused command. Rooms join and leave groups
-- (1.8.0): the zone group state they answer follows.
--
--   local home = SonosFake.household()             -- the owner's three rooms, each on its own
--   local home = SonosFake.household({ grouped = true })
--   mock.http = home:handler()

local SonosFake = {}

SonosFake.DIR = "tests/sonos/"

local cache = {}

function SonosFake.read(name)
    if not cache[name] then
        local file = assert(io.open(SonosFake.DIR .. name, "rb"), "missing fixture " .. name)
        cache[name] = file:read("*a")
        file:close()
    end
    return cache[name]
end

local URNS = {
    AVTransport = "urn:schemas-upnp-org:service:AVTransport:1",
    RenderingControl = "urn:schemas-upnp-org:service:RenderingControl:1",
    ZoneGroupTopology = "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
    ContentDirectory = "urn:schemas-upnp-org:service:ContentDirectory:1",
}

-- What each kind of thing playing looks like: GetPositionInfo and GetMediaInfo.
SonosFake.PLAYING = {
    connect = { position = "real/position_info_spotify_connect.xml", media = "real/media_info_spotify_connect.xml" },
    track = { position = "made/position_info_track.xml", media = "made/media_info_queue.xml" },
    track2 = { position = "made/position_info_track_hebrew.xml", media = "made/media_info_queue.xml" },
    radio = { position = "made/position_info_radio.xml", media = "made/media_info_radio.xml" },
    member = { position = "made/position_info_group_member.xml", media = "made/position_info_group_member.xml" },
}

local Household = {}
Household.__index = Household

-- The owner's household as read (three Sonos Amps, each room on its own, Spotify Connect paused),
-- or { grouped = true }: Kitchen leads Living Room, a stereo pair, a home theater, a Boost.
function SonosFake.household(options)
    options = options or {}
    local home = setmetatable({
        players = {},
        calls = {}, -- { ip, action, body, path }
        offline = {}, -- ip -> true: never answers
        refuse = {}, -- action -> UPnP error code
        favorites = options.favorites or "made/favorites.xml",
        art = {}, -- paths asked for
    }, Household)
    if options.grouped then
        home.topology = SonosFake.read("made/zone_group_state_grouped.xml")
        home:add("192.168.50.11", "RINCON_000E58A0000101400", "track", 30)
        home:add("192.168.50.12", "RINCON_000E58A0000201400", "member", 20)
        home:add("192.168.50.13", "RINCON_000E58A0000301400", "radio", 25)
        home:add("192.168.50.14", "RINCON_000E58A0000401400", "connect", 40)
        home:add("192.168.50.17", "RINCON_000E58A0000701400", "member", 25)
        home:add("192.168.50.15", "RINCON_000E58A0000501400", "member", 40)
        home:add("192.168.50.16", "RINCON_000E58A0000601400", "member", 0)
        home.players["192.168.50.11"].transport = "PLAYING"
        home.players["192.168.50.13"].transport = "PLAYING"
    else
        home.topology = SonosFake.read("real/zone_group_state.xml")
        home:add("192.168.50.11", "RINCON_000E58A0000101400", "connect", 58)
        home:add("192.168.50.12", "RINCON_000E58A0000201400", "connect", 45)
        home:add("192.168.50.13", "RINCON_000E58A0000301400", "connect", 100)
    end
    return home
end

function Household:add(ip, id, playing, volume)
    self.players[ip] = { ip = ip, id = id, playing = playing, transport = "PAUSED_PLAYBACK", volume = volume, muted = false, queue = {} }
end

-- The SSDP answer of each player, as the owner's players send it.
function Household:searchReplies()
    local replies = {}
    local template = SonosFake.read("real/ssdp_response.txt"):gsub("\r?\n", "\r\n")
    for ip, player in pairs(self.players) do
        if self.topology:find(player.id, 1, true) then
            replies[#replies + 1] = (template
                :gsub("192%.168%.50%.11", ip)
                :gsub("RINCON_000E58A0000101400", player.id))
        end
    end
    table.sort(replies)
    return replies
end

local function envelope(action, service, body)
    return '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:'
        .. action .. 'Response xmlns:u="' .. URNS[service] .. '">' .. (body or "") .. "</u:" .. action .. "Response></s:Body></s:Envelope>"
end

local function fault(code)
    return { code = 500, headers = { ["Content-Type"] = 'text/xml; charset="utf-8"' }, body = SonosFake.read("made/fault_701.xml"):gsub("701", tostring(code)) }
end

local function ok(body)
    return { code = 200, headers = { ["Content-Type"] = 'text/xml; charset="utf-8"' }, body = body }
end

local function argument(body, name)
    local value = tostring(body or ""):match("<" .. name .. ">(.-)</" .. name .. ">")
    if not value then
        return nil
    end
    return (value:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
SonosFake.argument = argument

-- ---- groups (1.8.0): the zone group state follows the rooms that join and leave groups ------

local function unescape(text)
    return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- The zone groups of a GetZoneGroupState answer: { { coordinator, parts = { { id, text } } } },
-- a part being a room as Sonos shows it (a stereo pair's hidden speaker goes with its room; a
-- Boost is a part of its own), and what goes around them.
local function zoneGroups(topology)
    local before, inner, after = topology:match("^(.-<ZoneGroupState>)(.-)(</ZoneGroupState>.*)$")
    local head, body, tail = unescape(inner):match("^(.-<ZoneGroups>)(.-)(</ZoneGroups>.*)$")
    local groups = {}
    for attrs, members in body:gmatch("<ZoneGroup ([^>]*)>(.-)</ZoneGroup>") do
        local group = { coordinator = attrs:match('Coordinator="([^"]+)"'), parts = {} }
        local at = 1
        while true do
            local first, last = members:find("<ZoneGroupMember ", at, true)
            if not first then
                break
            end
            local close = members:find(">", last, true)
            local stop = members:sub(close - 1, close) == "/>" and close or select(2, members:find("</ZoneGroupMember>", close, true))
            local text = members:sub(first, stop)
            local tag = text:match("^<ZoneGroupMember ([^>]*)")
            local hidden = tag:find('Invisible="1"', 1, true) and not tag:find('IsZoneBridge="1"', 1, true)
            if hidden and #group.parts > 0 then
                group.parts[#group.parts].text = group.parts[#group.parts].text .. text
            else
                group.parts[#group.parts + 1] = { id = tag:match('UUID="([^"]+)"'), text = text }
            end
            at = stop + 1
        end
        groups[#groups + 1] = group
    end
    return groups, { before, head, tail, after }
end

local function zoneGroupState(groups, frame)
    local list = {}
    for index, group in ipairs(groups) do
        local texts = {}
        for _, part in ipairs(group.parts) do
            texts[#texts + 1] = part.text
        end
        list[#list + 1] = '<ZoneGroup Coordinator="' .. group.coordinator .. '" ID="' .. group.coordinator .. ":" .. (900 + index) .. '">' .. table.concat(texts) .. "</ZoneGroup>"
    end
    return frame[1] .. escape(frame[2] .. table.concat(list) .. frame[3]) .. frame[4]
end

function Household:playerById(id)
    for _, player in pairs(self.players) do
        if player.id == id then
            return player
        end
    end
    return nil
end

-- The room `id` joins the group led by `coordinatorId` (nil: it leaves its group), as Sonos does
-- it: its zone group state changes. False when there is no such group or room.
function Household:regroup(id, coordinatorId)
    local groups, frame = zoneGroups(self.topology)
    local from, index, target
    for _, group in ipairs(groups) do
        for at, part in ipairs(group.parts) do
            if part.id == id then
                from, index = group, at
            end
        end
        if coordinatorId and group.coordinator == coordinatorId then
            target = group
        end
    end
    if not from or (coordinatorId and (not target or target == from)) or (not coordinatorId and #from.parts == 1) then
        return false
    end
    local part = table.remove(from.parts, index)
    local player = self:playerById(id)
    if #from.parts == 0 then
        for at, group in ipairs(groups) do
            if group == from then
                table.remove(groups, at)
                break
            end
        end
    elseif from.coordinator == id then
        -- The others go on together, led by the next of them.
        from.coordinator = from.parts[1].id
        local led = self:playerById(from.coordinator)
        if led and player then
            led.playing, led.transport = player.playing, player.transport
        end
    end
    if target then
        target.parts[#target.parts + 1] = part
        if player then
            player.playing = "member"
        end
    else
        groups[#groups + 1] = { coordinator = id, parts = { part } }
        if player then
            player.playing, player.transport = "track", "STOPPED"
        end
    end
    self.topology = zoneGroupState(groups, frame)
    return true
end

local SERVICE_OF = {
    ["/MediaRenderer/AVTransport/Control"] = "AVTransport",
    ["/MediaRenderer/RenderingControl/Control"] = "RenderingControl",
    ["/ZoneGroupTopology/Control"] = "ZoneGroupTopology",
    ["/MediaServer/ContentDirectory/Control"] = "ContentDirectory",
}

-- One request to one player: the response, or nil and an error (it does not answer).
function Household:answer(player, request, path)
    if request.method == "GET" then
        if path:match("^/getaa%?") then
            self.art[#self.art + 1] = path
            return { code = 200, headers = { ["Content-Type"] = "image/jpeg" }, body = "\255\216\255\224 JFIF art " .. path .. "\255\217" }
        end
        return { code = 404, headers = {}, body = "" }
    end
    local service = SERVICE_OF[path]
    local soapAction = tostring((request.headers or {}).SOAPACTION or "")
    local urn, action = soapAction:match('^"(.-)#(%w+)"$')
    if not service or urn ~= URNS[service] then
        return fault(401)
    end
    local body = request.body
    self.calls[#self.calls + 1] = { ip = player.ip, action = action, body = body }
    if self.refuse[action] then
        return fault(self.refuse[action])
    end
    local playing = SonosFake.PLAYING[player.playing]
    if action == "GetZoneGroupState" then
        return ok(self.topology)
    elseif action == "GetTransportInfo" then
        return ok((SonosFake.read("real/transport_info_paused.xml"):gsub("PAUSED_PLAYBACK", player.transport)))
    elseif action == "GetPositionInfo" then
        return ok(SonosFake.read(playing.position))
    elseif action == "GetMediaInfo" then
        return ok(SonosFake.read(playing.media))
    elseif action == "GetVolume" then
        return ok((SonosFake.read("real/volume.xml"):gsub("<CurrentVolume>%d+</CurrentVolume>", "<CurrentVolume>" .. player.volume .. "</CurrentVolume>")))
    elseif action == "GetMute" then
        return ok((SonosFake.read("real/mute.xml"):gsub("<CurrentMute>%d</CurrentMute>", "<CurrentMute>" .. (player.muted and 1 or 0) .. "</CurrentMute>")))
    elseif action == "Browse" then
        if argument(body, "ObjectID") ~= "FV:2" then
            return fault(701)
        end
        return ok(SonosFake.read(self.favorites))
    elseif action == "Play" then
        player.transport = "PLAYING"
    elseif action == "Pause" then
        -- A radio stream cannot pause.
        if player.playing == "radio" then
            return fault(701)
        end
        player.transport = "PAUSED_PLAYBACK"
    elseif action == "Stop" then
        player.transport = "STOPPED"
    elseif action == "Next" or action == "Previous" then
        if player.playing == "radio" then
            return fault(711)
        end
        player.playing = player.playing == "track" and "track2" or "track"
    elseif action == "SetVolume" then
        player.volume = tonumber(argument(body, "DesiredVolume"))
    elseif action == "SetMute" then
        player.muted = argument(body, "DesiredMute") == "1"
    elseif action == "RemoveAllTracksFromQueue" then
        player.queue = {}
    elseif action == "AddURIToQueue" then
        player.queue[#player.queue + 1] = argument(body, "EnqueuedURI")
        return ok(envelope(action, service, "<FirstTrackNumberEnqueued>1</FirstTrackNumberEnqueued><NumTracksAdded>1</NumTracksAdded><NewQueueLength>1</NewQueueLength>"))
    elseif action == "SetAVTransportURI" then
        local uri = argument(body, "CurrentURI") or ""
        player.uri = uri
        local coordinator = uri:match("^x%-rincon:(RINCON_%x+)$")
        if coordinator then
            -- Joins that group (1.8.0): only a group's coordinator, not itself.
            if not self:regroup(player.id, coordinator) then
                return fault(701)
            end
        else
            player.playing = uri:match("^x%-rincon%-queue:") and "track" or "radio"
            player.transport = "STOPPED"
        end
    elseif action == "BecomeCoordinatorOfStandaloneGroup" then
        self:regroup(player.id, nil)
    else
        return fault(401)
    end
    return ok(envelope(action, service))
end

-- For mock.http: answers requests to the players' addresses on port 1400, and leaves others.
function Household:handler()
    return function(request)
        local ip, port, path = tostring(request.url):match("^http://([%d%.]+):(%d+)(/.*)$")
        local player = ip and self.players[ip]
        if not player or port ~= "1400" then
            return false
        end
        if self.offline[ip] then
            return nil, "Connection timed out"
        end
        return self:answer(player, request, path)
    end
end

-- The calls the players received, as "ip Action" (or only the actions of one address).
function Household:sent(ip)
    local list = {}
    for _, call in ipairs(self.calls) do
        if ip == nil or call.ip == ip then
            list[#list + 1] = ip and call.action or (call.ip .. " " .. call.action)
        end
    end
    return list
end

function Household:clear()
    self.calls = {}
end

return SonosFake
