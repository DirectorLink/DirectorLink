-- What DirectorLink knows of the Sonos players' local protocol (docs/SONOS.md, ADR-044): UPnP
-- SOAP on port 1400 with AVTransport, RenderingControl, ZoneGroupTopology and ContentDirectory, as
-- the Sonos app, Home Assistant and Control4's own drivers use it. Sonos does not document it.
-- Everything here is text in, tables out: no network (src/sonos/client.lua sends and receives).
-- The text comes from any device on the home network: each pattern takes time in proportion to it
-- (src/sonos/xml.lua says why).

local Xml = require("src.sonos.xml")

local Protocol = {}

Protocol.PORT = 1400
Protocol.SEARCH_TARGET = "urn:schemas-upnp-org:device:ZonePlayer:1"
-- What is shown of a title, an artist, an album, a station or a favorite's name; of a room's name;
-- the longest picture path taken (a player's own is about 200 bytes).
Protocol.MAX_TEXT = 1024
Protocol.MAX_NAME = 100
Protocol.MAX_ART_PATH = 2048

-- `text` without the spaces at either end. The end is trimmed byte by byte: "%s+$" would try again
-- from every space of a long run.
function Protocol.trim(text)
    local first = text:find("%S")
    if not first then
        return ""
    end
    local last = #text
    while text:find("^%s", last) do
        last = last - 1
    end
    return text:sub(first, last)
end

-- At most `limit` bytes of `text`, without cutting a character in two.
function Protocol.cut(text, limit)
    if #text <= limit then
        return text
    end
    local last = limit
    -- Back over continuation bytes (10xxxxxx), to just before the character cut in two.
    while last > 0 and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do
        last = last - 1
    end
    return text:sub(1, last)
end

Protocol.SERVICES = {
    AVTransport = { path = "/MediaRenderer/AVTransport/Control", urn = "urn:schemas-upnp-org:service:AVTransport:1" },
    RenderingControl = { path = "/MediaRenderer/RenderingControl/Control", urn = "urn:schemas-upnp-org:service:RenderingControl:1" },
    ZoneGroupTopology = { path = "/ZoneGroupTopology/Control", urn = "urn:schemas-upnp-org:service:ZoneGroupTopology:1" },
    ContentDirectory = { path = "/MediaServer/ContentDirectory/Control", urn = "urn:schemas-upnp-org:service:ContentDirectory:1" },
}

-- Every action DirectorLink sends, and its service: nothing else is ever sent to a player. Grouping
-- (1.8.0, ADR-057) is two of them: joining a group is SetAVTransportURI with the coordinator's
-- address (Protocol.groupUri), leaving one is BecomeCoordinatorOfStandaloneGroup; a group's volume
-- is each room's own SetVolume. No alarms, no settings.
Protocol.ACTIONS = {
    GetTransportInfo = "AVTransport",
    GetPositionInfo = "AVTransport",
    GetMediaInfo = "AVTransport",
    Play = "AVTransport",
    Pause = "AVTransport",
    Stop = "AVTransport",
    Next = "AVTransport",
    Previous = "AVTransport",
    SetAVTransportURI = "AVTransport",
    RemoveAllTracksFromQueue = "AVTransport",
    AddURIToQueue = "AVTransport",
    BecomeCoordinatorOfStandaloneGroup = "AVTransport",
    GetVolume = "RenderingControl",
    SetVolume = "RenderingControl",
    GetMute = "RenderingControl",
    SetMute = "RenderingControl",
    GetZoneGroupState = "ZoneGroupTopology",
    Browse = "ContentDirectory",
}

-- Addresses of the home network (RFC 1918): the only ones a player may have.
function Protocol.lanAddress(value)
    if type(value) ~= "string" then
        return nil
    end
    local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or a > 255 or b > 255 or c > 255 or d > 255 or d == 0 or d == 255 then
        return nil
    end
    if a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) then
        return string.format("%d.%d.%d.%d", a, b, c, d)
    end
    return nil
end

-- The player's address in its description's location ("http://192.168.1.20:1400/xml/..."), when
-- that is a home network address on port 1400.
function Protocol.locationAddress(location)
    local host = type(location) == "string" and location:match("^http://([%d%.]+):1400/") or nil
    return Protocol.lanAddress(host)
end

-- A player's id as Sonos writes it: RINCON_ and its hex digits.
function Protocol.validId(value)
    return type(value) == "string" and #value <= 40 and value:match("^RINCON_%x+$") ~= nil
end

-- The address a room is given to join the group of `coordinatorId` (SetAVTransportURI), as the
-- Sonos app does it; nil for anything that is not a player's id. The only place this address is
-- made (scripts/check_package.py); src/sonos/sonos.lua uses it only for a coordinator it found in
-- the household's zone group state.
function Protocol.groupUri(coordinatorId)
    if not Protocol.validId(coordinatorId) then
        return nil
    end
    return "x-rincon:" .. coordinatorId
end

-- ---- SOAP ----------------------------------------------------------------------------------

-- The request body and headers for `action`, its arguments in order ({ { name, value }, ... }).
function Protocol.request(action, args)
    local service = Protocol.SERVICES[Protocol.ACTIONS[action] or ""]
    if not service then
        return nil
    end
    local parts = {}
    for _, arg in ipairs(args or {}) do
        parts[#parts + 1] = "<" .. arg[1] .. ">" .. Xml.escape(arg[2]) .. "</" .. arg[1] .. ">"
    end
    local body = '<?xml version="1.0" encoding="utf-8"?>'
        .. '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        .. "<s:Body><u:" .. action .. ' xmlns:u="' .. service.urn .. '">' .. table.concat(parts)
        .. "</u:" .. action .. "></s:Body></s:Envelope>"
    return {
        path = service.path,
        body = body,
        headers = { ["Content-Type"] = 'text/xml; charset="utf-8"', SOAPACTION = '"' .. service.urn .. "#" .. action .. '"' },
    }
end

-- The values of an answer to `action` (name -> text), or nil and the UPnP error ("701") or why.
function Protocol.answer(action, body)
    local document, why = Xml.parse(body)
    if not document then
        return nil, why
    end
    local fault = Xml.find(document, "Fault")
    if fault then
        -- A UPnP error is a number; anything else is not repeated (into the log, or the API).
        local code = Protocol.trim(Xml.text(fault, "errorCode") or "")
        return nil, #code <= 10 and code:match("^%d+$") or "fault"
    end
    local response = Xml.find(document, action .. "Response")
    if not response then
        return nil, "unexpected answer"
    end
    local values = {}
    for _, child in ipairs(response.children) do
        values[child.name] = child.text
    end
    return values
end

-- ---- discovery -----------------------------------------------------------------------------

-- The players in an SSDP answer (one datagram, or several run together): { ip, id, household }, at
-- most `max` of them.
function Protocol.searchReplies(data, max)
    local replies = {}
    for chunk in (tostring(data or "") .. "\nHTTP/1.1 "):gmatch("(.-)\n[Hh][Tt][Tt][Pp]/1%.1 ") do
        local headers = {}
        for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
            local name, value = line:match("^([%w%.%-]+):(.*)$")
            if name then
                headers[string.upper(name)] = Protocol.trim(value)
            end
        end
        local target = headers.ST or headers.NT
        local ip = Protocol.locationAddress(headers.LOCATION)
        if target == Protocol.SEARCH_TARGET and ip then
            replies[#replies + 1] = {
                ip = ip,
                id = (headers.USN or ""):match("^uuid:(RINCON_%x+)"),
                household = headers["X-RINCON-HOUSEHOLD"],
            }
            if max and #replies >= max then
                break
            end
        end
    end
    return replies
end

function Protocol.searchRequest()
    return "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: "
        .. Protocol.SEARCH_TARGET .. "\r\n\r\n"
end

-- The household's rooms from GetZoneGroupState: { groups = { { id = coordinator, members =
-- { player ids } } }, players = { [id] = { id, name, ip } } }. A room is a player Sonos shows:
-- the second speaker of a stereo pair and a home theater's satellites are part of their room, and
-- a Boost or Bridge is no room. nil when the state cannot be read.
function Protocol.topology(zoneGroupState)
    local document = zoneGroupState and Xml.parse(zoneGroupState)
    local groups = document and Xml.find(document, "ZoneGroups")
    if not groups then
        return nil
    end
    local result = { groups = {}, players = {} }
    for _, group in ipairs(Xml.children(groups, "ZoneGroup")) do
        local coordinator = group.attrs.Coordinator
        -- The coordinator first, then the others as Sonos lists them.
        local entry = { id = coordinator, members = { coordinator } }
        for _, member in ipairs(Xml.children(group, "ZoneGroupMember")) do
            local id, ip = member.attrs.UUID, Protocol.locationAddress(member.attrs.Location)
            local hidden = member.attrs.Invisible == "1" or member.attrs.IsZoneBridge == "1"
            if Protocol.validId(id) and ip and not hidden then
                local name = Protocol.cut(Protocol.trim(member.attrs.ZoneName or ""), Protocol.MAX_NAME)
                result.players[id] = { id = id, name = name ~= "" and name or id, ip = ip }
                if id ~= coordinator then
                    entry.members[#entry.members + 1] = id
                end
            end
        end
        if Protocol.validId(coordinator) and result.players[coordinator] then
            result.groups[#result.groups + 1] = entry
        end
    end
    return result
end

-- ---- what plays ----------------------------------------------------------------------------

local STREAM_PREFIXES = {
    "x-sonosapi-stream:", "x-sonosapi-radio:", "x-rincon-mp3radio:", "x-sonosapi-hls:", "x-sonosapi-hls-static:",
    "hls-radio:", "aac:", "pndrradio:",
}

local function startsWith(text, prefix)
    return text:sub(1, #prefix) == prefix
end

-- A radio station or other stream (started with SetAVTransportURI), not a track for the queue.
function Protocol.isStream(uri)
    uri = tostring(uri or "")
    for _, prefix in ipairs(STREAM_PREFIXES) do
        if startsWith(uri, prefix) then
            return true
        end
    end
    return false
end

-- What a transport plays, from its addresses: "music" (the queue, a track), "radio", "connect"
-- (Spotify Connect, AirPlay: another app plays through the speaker), "tv", "line_in", "group"
-- (follows another room) or "none".
function Protocol.sourceKind(trackUri, mediaUri)
    local uri = tostring(trackUri or "")
    local media = tostring(mediaUri or "")
    if startsWith(uri, "x-rincon:") or startsWith(media, "x-rincon:") then
        return "group"
    elseif startsWith(media, "x-sonos-vli:") or startsWith(uri, "x-sonos-vli:") then
        return "connect"
    elseif startsWith(uri, "x-sonos-htastream:") or startsWith(media, "x-sonos-htastream:") then
        return "tv"
    elseif startsWith(uri, "x-rincon-stream:") or startsWith(media, "x-rincon-stream:") then
        return "line_in"
    elseif Protocol.isStream(uri) or Protocol.isStream(media) then
        return "radio"
    elseif uri == "" and media == "" then
        return "none"
    end
    return "music"
end

local function present(value)
    if type(value) ~= "string" then
        return nil
    end
    value = Protocol.trim(value)
    if value == "" or value == "NOT_IMPLEMENTED" then
        return nil
    end
    return value
end

-- Text the app shows (a title, a name), no longer than MAX_TEXT.
local function shown(value)
    value = present(value)
    return value and Protocol.cut(value, Protocol.MAX_TEXT)
end

-- A title that is only an address (radio stations often give the stream's).
local function addressLike(value)
    return value ~= nil and (value:find("://", 1, true) ~= nil or value:match("^[%w%-]+:[^%s]*[?/]") ~= nil)
end

-- The first item of a DIDL-Lite document: { title, artist, album, art, stream, class }.
function Protocol.metadata(didl)
    didl = present(didl)
    local document = didl and Xml.parse(didl)
    local item = document and (Xml.find(document, "item") or Xml.find(document, "container"))
    if not item then
        return {}
    end
    return {
        title = shown(Xml.text(item, "title")),
        artist = shown(Xml.text(item, "creator")) or shown(Xml.text(item, "artist")),
        album = shown(Xml.text(item, "album")),
        art = present(Xml.text(item, "albumArtURI")),
        stream = shown(Xml.text(item, "streamContent")),
        class = shown(Xml.text(item, "class")),
    }
end

-- The player's own picture for a track: a path on the player (/getaa?...), or an address on the
-- same player and port. Pictures elsewhere (a music service's servers) are not used: DirectorLink
-- contacts no other host.
function Protocol.artPath(art, ip)
    art = present(art)
    if not art or #art > Protocol.MAX_ART_PATH then
        return nil
    end
    if art:sub(1, 1) == "/" and art:sub(2, 2) ~= "/" then
        return art
    end
    local host, path = art:match("^http://([%d%.]+):1400(/.*)$")
    if host and host == ip then
        return path
    end
    return nil
end

local CONNECT_NAMES = { spotify = "Spotify", airplay = "AirPlay" }

-- What the app shows from GetPositionInfo and GetMediaInfo (nil when not read): { kind, title,
-- artist, album, station, source, art }.
function Protocol.nowPlaying(position, media, ip)
    position, media = position or {}, media or {}
    local kind = Protocol.sourceKind(position.TrackURI, media.CurrentURI)
    local track = Protocol.metadata(position.TrackMetaData)
    local current = Protocol.metadata(media.CurrentURIMetaData)
    local result = { kind = kind, art = Protocol.artPath(track.art, ip) }
    if kind == "radio" then
        result.station = current.title or (not addressLike(track.title) and track.title or nil)
        -- "Artist - Title" while a song plays; ZPSTR_CONNECTING and the like while it starts.
        local stream = track.stream
        if stream and not stream:match("^ZPSTR_") then
            -- At the first " - " (any spaces around the dash). A plain search: "^(.-)%s+%-%s+"
            -- would scan a long run of spaces again from each of them.
            local at = stream:find("%s%-%s")
            local artist = at and Protocol.trim(stream:sub(1, at - 1)) or ""
            local title = at and Protocol.trim(stream:sub(at + 3)) or ""
            result.title = title ~= "" and title or stream
            result.artist = title ~= "" and artist ~= "" and artist or nil
        end
        result.art = result.art or Protocol.artPath(current.art, ip)
    elseif kind == "connect" then
        local app = tostring(media.CurrentURI or position.TrackURI or ""):match(",([%w]+):") or ""
        result.source = current.title or CONNECT_NAMES[string.lower(app)]
        result.title, result.artist, result.album = track.title, track.artist, track.album
    elseif kind == "music" then
        result.title = not addressLike(track.title) and track.title or nil
        result.artist, result.album = track.artist, track.album
    end
    return result
end

-- ---- favorites -----------------------------------------------------------------------------

-- The household's Sonos favorites (Browse of FV:2), in Sonos's order: { id, title, description,
-- uri, meta, playable }. A shortcut (Sonos Radio's, for one) has no address and cannot be started
-- this way.
function Protocol.favorites(result)
    local document = result and Xml.parse(result)
    local list = {}
    for _, item in ipairs(document and Xml.children(Xml.find(document, "DIDL-Lite"), "item") or {}) do
        local id = tostring(item.attrs.id or ""):match("^FV:2/(%d+)$")
        local title = shown(Xml.text(item, "title"))
        if id and title then
            local uri = present(Xml.text(item, "res")) or ""
            list[#list + 1] = {
                id = id,
                title = title,
                description = shown(Xml.text(item, "description")),
                uri = uri,
                meta = Xml.text(item, "resMD") or "",
                ordinal = tonumber(Xml.text(item, "ordinal")) or #list,
                playable = uri ~= "",
            }
        end
    end
    table.sort(list, function(a, b)
        return a.ordinal < b.ordinal
    end)
    return list
end

return Protocol
