-- Sonos on the home network (docs/SONOS.md, ADR-044). The home has no Sonos driver in Control4, so
-- DirectorLink talks to the players itself, the way the Sonos app does, and only while the
-- installer has set the Composer property Sonos to On. It finds them (SSDP, or the player at
-- Sonos Address, whose topology lists the rest), reads what each Sonos room plays, its volume and
-- mute, and plays, pauses and skips on the room's group, as Sonos groups them. A Sonos room is shown
-- in the Control4 room of the same name, or the one an admin picked (src/sonos/rooms.lua).
--
-- Reading is cheap and never waits: a room someone has open in the app (its room screen, or Home)
-- is read every FAST_SECONDS, the others every SLOW_SECONDS; one request at a time per group.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Client = require("src.sonos.client")
local Protocol = require("src.sonos.protocol")
local Rooms = require("src.sonos.rooms")

local Sonos = {}

Sonos.PROPERTY = "Sonos"
Sonos.ADDRESS_PROPERTY = "Sonos Address"
Sonos.STATUS_PROPERTY = "Sonos Players"
Sonos.TICK_SECONDS = 2
-- A room shown in the app; a room nobody looks at.
Sonos.FAST_SECONDS = 4
Sonos.SLOW_SECONDS = 60
-- How long a look from the app counts (it asks again every 5 seconds while it shows the room).
Sonos.WATCH_SECONDS = 15
Sonos.TOPOLOGY_FAST_SECONDS = 30
Sonos.TOPOLOGY_SLOW_SECONDS = 300
-- New players, or new addresses: the home network is asked again this often.
Sonos.SEARCH_SECONDS = 300
-- After a player stopped answering, not sooner than this.
Sonos.RETRY_SEARCH_SECONDS = 60
Sonos.FAVORITES_SECONDS = 60
Sonos.MAX_FAVORITES = 100
Sonos.ART_MAX_BYTES = 300 * 1024
Sonos.ART_CACHE = 4
Sonos.MAX_PLAYERS = 64
-- Addresses kept from one search (the search takes no more), and how many of them (or of the
-- players known) are asked for the household's rooms in a row when one does not answer.
Sonos.MAX_FOUND = Client.MAX_SEARCH_REPLIES
Sonos.MAX_TOPOLOGY_TRIES = 4
Sonos.MAX_STATUS_LENGTH = 400
-- A picture the player did not give is not asked for again for this long.
Sonos.ART_RETRY_SECONDS = 30

local TRANSPORT = {
    PLAYING = "playing",
    PAUSED_PLAYBACK = "paused",
    STOPPED = "stopped",
    NO_MEDIA_PRESENT = "stopped",
    TRANSITIONING = "transitioning",
}
local COMMANDS = { play = "Play", pause = "Pause", next = "Next", previous = "Previous", stop = "Stop" }
local AFTER = { play = "PLAYING", pause = "PAUSED_PLAYBACK", stop = "STOPPED" }

local state = {
    services = {},
    running = false,
    generation = 0,
    players = {}, -- id -> { id, name, ip, group, volume, muted, reachable }
    groups = {}, -- coordinator id -> { id, members, transport, position, media, now, polledAt, busy, reachable }
    topologyAt = nil,
    topologyBusy = false,
    searchAt = nil,
    searching = false,
    found = {}, -- addresses that answered the last search, in order
    foundSet = {}, -- the same, address -> true
    failedAt = {}, -- address -> when it last did not answer GetZoneGroupState
    status = "off",
    shown = nil, -- the Sonos Players text last shown in Composer
    watchHome = 0,
    watchRooms = {},
    timer = nil,
    favorites = nil, -- { at, items }
    art = {}, -- { key, body, type }, newest first
    artFailed = {}, -- key -> { at, code, detail }: a picture the player did not give
    artWaiting = {}, -- key -> the callbacks waiting for the picture on its way
}

function Sonos.enabled()
    return Properties ~= nil and Properties[Sonos.PROPERTY] == "On"
end

-- services: registry (the project's rooms), roomNames(roomId) -> language -> name, onStatus(text)
-- for Composer's Sonos Players.
function Sonos.configure(services)
    state.services = services or {}
end

local function now()
    return Clock.now()
end

local function publish(text)
    if #text > Sonos.MAX_STATUS_LENGTH then
        text = Protocol.cut(text, Sonos.MAX_STATUS_LENGTH - 3) .. "..."
    end
    if text ~= state.shown then
        state.shown = text
        if state.services.onStatus then
            pcall(state.services.onStatus, text)
        end
    end
end

local function sortedPlayers()
    local list = {}
    for _, player in pairs(state.players) do
        list[#list + 1] = player
    end
    table.sort(list, function(a, b)
        local x, y = string.lower(a.name), string.lower(b.name)
        if x == y then
            return a.id < b.id
        end
        return x < y
    end)
    return list
end

-- The installer's Sonos Address as a player's address, or nil; and false when something is typed
-- that is not one. Spaces around it, "http://" before it and ":1400" (or a path) after it are
-- taken as typed from a browser or the Sonos app.
function Sonos.parseAddress(text)
    text = Protocol.trim(type(text) == "string" and text or "")
    if text == "" then
        return nil
    end
    local host, rest = text:gsub("^[Hh][Tt][Tt][Pp]://", ""):match("^([%d%.]+)(.*)$")
    local ip = Protocol.lanAddress(host)
    if not ip or not (rest == "" or rest == ":1400" or rest:match("^:1400/") or rest:match("^/")) then
        return nil, false
    end
    return ip
end

local function propertyAddress()
    return Sonos.parseAddress(Properties and Properties[Sonos.ADDRESS_PROPERTY] or nil)
end

local BAD_ADDRESS = "Sonos Address is not understood: type one player's IP address on the home network (10.x, 172.16-31.x or 192.168.x)."

-- Composer's Sonos Players: what DirectorLink found, with each player's address.
local function publishStatus()
    local address, understood = propertyAddress()
    local warning = understood == false and BAD_ADDRESS or nil
    if state.status == "off" then
        publish("Off")
    elseif state.status == "searching" then
        publish((warning and warning .. " " or "") .. "Looking for players...")
    elseif state.status == "not_found" then
        if warning then
            publish("None found. " .. warning)
        elseif address then
            publish("None found. No Sonos player answered at " .. address .. " (Sonos Address).")
        else
            publish("None found. Set Sonos Address to one player's IP address.")
        end
    else
        local parts = {}
        for _, player in ipairs(sortedPlayers()) do
            parts[#parts + 1] = player.name .. " (" .. player.ip .. (player.reachable == false and ", not answering" or "") .. ")"
        end
        publish((warning and warning .. " " or "") .. #parts .. (#parts == 1 and " player: " or " players: ") .. table.concat(parts, ", "))
    end
end

local function setStatus(status)
    state.status = status
    publishStatus()
end

-- ---- finding the players -------------------------------------------------------------------

-- An address that answered the search, once (at most MAX_FOUND, as the search takes).
local function addFound(ip)
    if not state.foundSet[ip] and #state.found < Sonos.MAX_FOUND then
        state.foundSet[ip] = true
        state.found[#state.found + 1] = ip
    end
end

local function applyTopology(topology)
    local before = state.players
    local players, count = {}, 0
    local renamed = {}
    local listed = {}
    for id, found in pairs(topology.players) do
        if count < Sonos.MAX_PLAYERS and Client.allow(found.ip, "topology") then
            -- The same table for a player known before: reads and commands on their way still
            -- land on it.
            local player = before[id] or { id = id }
            renamed[id] = player.ip ~= found.ip or player.name ~= found.name
            player.name, player.ip, player.group = found.name, found.ip, nil
            players[id] = player
            listed[found.ip] = true
            count = count + 1
        end
    end
    -- A player no longer in the household is no longer contacted (unless the search or the
    -- installer gave its address).
    Client.forget("topology", listed)
    local groups = {}
    for _, found in ipairs(topology.groups) do
        if players[found.id] then
            local old = state.groups[found.id] or { id = found.id }
            old.members = {}
            for _, memberId in ipairs(found.members) do
                if players[memberId] then
                    old.members[#old.members + 1] = memberId
                    players[memberId].group = found.id
                end
            end
            groups[found.id] = old
        end
    end
    local changed = false
    for id in pairs(players) do
        changed = changed or not before[id] or renamed[id]
    end
    for id in pairs(before) do
        changed = changed or not players[id]
    end
    state.players, state.groups = players, groups
    if changed then
        Log.info("sonos", "Sonos players found", { players = count, groups = #topology.groups })
    end
    setStatus(count > 0 and "ok" or "not_found")
end

-- Asks a player for the household's rooms (GetZoneGroupState): the installer's address first, then
-- the players known, then those that answered the search. One that does not answer is followed at
-- once by another, MAX_TOPOLOGY_TRIES in a row at most; the rest wait for the next read.
local function readTopology(tries)
    if state.topologyBusy or not state.running then
        return
    end
    tries = tries or 1
    local candidates, seen = {}, {}
    local function add(ip)
        if ip and not seen[ip] and Client.allowed(ip) then
            seen[ip] = #candidates + 1
            candidates[#candidates + 1] = ip
        end
    end
    add((propertyAddress()))
    for _, player in ipairs(sortedPlayers()) do
        if player.reachable ~= false then
            add(player.ip)
        end
    end
    for _, ip in ipairs(state.found) do
        add(ip)
    end
    for _, player in pairs(state.players) do
        add(player.ip)
    end
    for address in pairs(state.failedAt) do
        if not seen[address] then
            state.failedAt[address] = nil
        end
    end
    -- One that did not answer lately goes last; the others keep the order above.
    table.sort(candidates, function(a, b)
        local x, y = state.failedAt[a] or 0, state.failedAt[b] or 0
        if x ~= y then
            return x < y
        end
        return seen[a] < seen[b]
    end)
    local ip = candidates[1]
    if not ip then
        if not state.searching then
            setStatus(next(state.players) and "ok" or "not_found")
        end
        return
    end
    state.topologyBusy = true
    local generation = state.generation
    Client.call(ip, "GetZoneGroupState", {}, function(values, failure)
        if generation ~= state.generation then
            return
        end
        state.topologyBusy = false
        if failure == "busy" then
            -- Not asked: too many requests wait. Asked at the next tick.
            state.topologyAt = nil
            return
        end
        state.topologyAt = now()
        local topology = values and Protocol.topology(values.ZoneGroupState)
        if topology then
            state.failedAt[ip] = nil
            applyTopology(topology)
        else
            state.failedAt[ip] = now()
            Log.warn("sonos", "a Sonos player did not list the household's rooms", { address = ip, reason = tostring(failure or "unreadable") })
            -- Another address not tried yet is tried at once.
            if tries < Sonos.MAX_TOPOLOGY_TRIES then
                for _, other in ipairs(candidates) do
                    if not state.failedAt[other] then
                        readTopology(tries + 1)
                        return
                    end
                end
            end
            if not next(state.players) and not state.searching then
                setStatus("not_found")
            end
        end
    end)
end

-- The installer's address may be contacted (the one typed before no longer).
local function allowProperty()
    Client.forget("property")
    local property = propertyAddress()
    if property then
        Client.allow(property, "property")
    end
    return property
end

local function search()
    if state.searching or not state.running then
        return
    end
    state.searching = true
    state.searchAt = now()
    state.found, state.foundSet = {}, {}
    if allowProperty() then
        -- The installer's player answers at once; the search may add others.
        readTopology()
    end
    local generation = state.generation
    local started, failure = Client.search(function(reply)
        if generation == state.generation then
            addFound(reply.ip)
        end
    end, function()
        if generation ~= state.generation then
            return
        end
        state.searching = false
        -- Read again only when the search found a player not known yet (or none is).
        local known = {}
        for _, player in pairs(state.players) do
            known[player.ip] = true
        end
        local news = not next(state.players)
        for _, ip in ipairs(state.found) do
            news = news or not known[ip]
        end
        if news then
            readTopology()
        end
    end)
    if not started then
        state.searching = false
        Log.warn("sonos", "could not search the home network for Sonos players", { reason = tostring(failure) })
        readTopology()
    end
end

-- ---- reading what plays --------------------------------------------------------------------

local function watched(group, at)
    if at < state.watchHome then
        return true
    end
    for _, memberId in ipairs(group.members or {}) do
        local roomId = Sonos.roomOf(state.players[memberId])
        if roomId and at < (state.watchRooms[roomId] or 0) then
            return true
        end
    end
    return false
end

local function due(group, at)
    if group.busy then
        return false
    end
    local age = at - (group.polledAt or 0)
    return age >= (watched(group, at) and Sonos.FAST_SECONDS or Sonos.SLOW_SECONDS)
end

-- One read of a group: its transport and track on the coordinator, then each room's volume and
-- mute, one request after the other.
local function refreshGroup(group)
    local coordinator = state.players[group.id]
    if not coordinator or group.busy then
        return
    end
    group.busy = true
    local generation = state.generation
    local steps = {
        { coordinator.ip, "GetTransportInfo", { { "InstanceID", 0 } }, function(values)
            group.transport = values.CurrentTransportState
        end },
        { coordinator.ip, "GetPositionInfo", { { "InstanceID", 0 } }, function(values)
            -- What plays changed (or was never read): the media info gives the station or the app.
            local changed = not group.position or group.position.TrackURI ~= values.TrackURI or not group.media
            group.position = values
            return changed
        end },
    }
    local function finish(failure)
        if generation ~= state.generation then
            return
        end
        group.busy = false
        if failure == "busy" then
            -- Not read this time (too many requests wait), which says nothing of the player: read
            -- at the next tick, shown as it was.
            return
        end
        group.polledAt = now()
        local reachable = failure == nil
        if group.reachable ~= reachable then
            Log.info("sonos", reachable and "a Sonos player answers again" or "a Sonos player does not answer", { player = group.id, reason = failure })
        end
        group.reachable = reachable
        coordinator.reachable = reachable
        if reachable then
            group.now = Protocol.nowPlaying(group.position, group.media, coordinator.ip)
        elseif not state.searching and now() - (state.searchAt or 0) >= Sonos.RETRY_SEARCH_SECONDS then
            -- Its address may have changed.
            search()
        end
        publishStatus()
    end
    local index = 0
    local function step()
        if generation ~= state.generation then
            return
        end
        index = index + 1
        local current = steps[index]
        if not current then
            finish(nil)
            return
        end
        Client.call(current[1], current[2], current[3], function(values, failure)
            if generation ~= state.generation then
                return
            end
            if not values then
                -- A room of the group that does not answer is left as it was.
                if current.optional then
                    step()
                else
                    finish(tostring(failure))
                end
                return
            end
            local wantMedia = current[4](values)
            if wantMedia then
                table.insert(steps, index + 1, { coordinator.ip, "GetMediaInfo", { { "InstanceID", 0 } }, function(media)
                    group.media = media
                end })
            end
            step()
        end)
    end
    for _, memberId in ipairs(group.members or {}) do
        local player = state.players[memberId]
        if player then
            steps[#steps + 1] = { player.ip, "GetVolume", { { "InstanceID", 0 }, { "Channel", "Master" } }, function(values)
                player.volume = tonumber(values.CurrentVolume)
            end, optional = true }
            steps[#steps + 1] = { player.ip, "GetMute", { { "InstanceID", 0 }, { "Channel", "Master" } }, function(values)
                player.muted = values.CurrentMute == "1"
            end, optional = true }
        end
    end
    step()
end

function Sonos.tick(at)
    if not state.running then
        return
    end
    at = at or now()
    if not state.searching and (not state.searchAt or at - state.searchAt >= Sonos.SEARCH_SECONDS) then
        search()
    end
    local anyWatched = at < state.watchHome or next(state.watchRooms) ~= nil
    if not state.searching and (not state.topologyAt or at - state.topologyAt >= (anyWatched and Sonos.TOPOLOGY_FAST_SECONDS or Sonos.TOPOLOGY_SLOW_SECONDS)) then
        readTopology()
    end
    for roomId, expires in pairs(state.watchRooms) do
        if at >= expires then
            state.watchRooms[roomId] = nil
        end
    end
    for _, group in pairs(state.groups) do
        if due(group, at) then
            refreshGroup(group)
        end
    end
end

-- The app shows a room (`roomId`) or Home (nil): its Sonos rooms are read every FAST_SECONDS for a
-- while, starting now if what is known is older than that.
function Sonos.wanted(roomId, at)
    if not state.running then
        return
    end
    at = at or now()
    if roomId then
        state.watchRooms[roomId] = at + Sonos.WATCH_SECONDS
    else
        state.watchHome = at + Sonos.WATCH_SECONDS
    end
    for _, group in pairs(state.groups) do
        if due(group, at) then
            refreshGroup(group)
        end
    end
end

-- ---- on and off ----------------------------------------------------------------------------

local function stop()
    state.running = false
    state.generation = state.generation + 1
    if state.timer then
        pcall(function()
            state.timer:Cancel()
        end)
        state.timer = nil
    end
    Client.reset()
    state.players, state.groups, state.found, state.foundSet, state.failedAt = {}, {}, {}, {}, {}
    state.topologyAt, state.topologyBusy, state.searchAt, state.searching = nil, false, nil, false
    state.watchHome, state.watchRooms, state.favorites, state.art = 0, {}, nil, {}
    state.artFailed, state.artWaiting = {}, {}
    setStatus("off")
end

local function start()
    stop()
    state.running = true
    setStatus("searching")
    local ok, timer = pcall(function()
        return C4:SetTimer(Sonos.TICK_SECONDS * 1000, function()
            Sonos.tick()
        end, true)
    end)
    state.timer = ok and timer or nil
    search()
end

-- At start, and when Sonos or Sonos Address changes in Composer: starts, stops, or (a new
-- address) looks again.
function Sonos.apply(changed)
    if not Sonos.enabled() then
        if state.running then
            stop()
            Log.info("sonos", "Sonos off in Composer")
        else
            setStatus("off")
        end
        return
    end
    if not state.running then
        start()
        Log.info("sonos", "Sonos on in Composer")
    elseif changed == Sonos.ADDRESS_PROPERTY then
        state.failedAt = {}
        state.searchAt = nil
        publishStatus()
        if not state.searching then
            search()
        elseif allowProperty() then
            readTopology()
        end
    end
end

function Sonos.shutdown()
    if state.running then
        stop()
    end
end

-- ---- what the API shows --------------------------------------------------------------------

-- The Control4 room a player is shown in, and how ("admin", "name"), or nil.
function Sonos.roomOf(player)
    if not player then
        return nil
    end
    local registry = state.services.registry
    return Rooms.place(player, registry and registry.rooms or {}, state.services.roomNames)
end

function Sonos.find(id)
    return state.running and state.players[id] or nil
end

-- A short, stable fingerprint of a picture's address, so the app fetches it again only when it
-- changes.
local function fingerprint(text)
    local hash = 5381
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function nullable(value)
    if value == nil then
        return Json.null
    end
    return value
end

function Sonos.view(player)
    local group = state.groups[player.group or ""] or { id = player.id, members = { player.id } }
    local roomId, how = Sonos.roomOf(player)
    local members = Json.array()
    for _, memberId in ipairs(group.members or {}) do
        local member = state.players[memberId]
        if member then
            members[#members + 1] = { id = member.id, name = member.name }
        end
    end
    local playing = Json.null
    local current = group.now
    local transport = group.transport and (TRANSPORT[group.transport] or "unknown") or "unknown"
    if current and current.kind ~= "none" and current.kind ~= "group" then
        local coordinator = state.players[group.id]
        playing = {
            kind = current.kind,
            title = nullable(current.title),
            artist = nullable(current.artist),
            album = nullable(current.album),
            station = nullable(current.station),
            source = nullable(current.source),
            art_href = current.art and ("/v1/music/" .. player.id .. "/art") or Json.null,
            art_key = (current.art and coordinator) and fingerprint(coordinator.ip .. current.art) or Json.null,
        }
    end
    return {
        id = player.id,
        name = player.name,
        room_id = nullable(roomId),
        room_match = nullable(how),
        group = { id = group.id, coordinator = group.id == player.id, rooms = members },
        state = transport,
        volume = nullable(player.volume),
        muted = nullable(player.muted),
        now_playing = playing,
        can_skip = current ~= nil and (current.kind == "music" or current.kind == "connect"),
        reachable = group.reachable ~= false and player.reachable ~= false,
        updated_at = group.polledAt and Clock.iso(group.polledAt) or Json.null,
    }
end

-- Every Sonos room (or those shown in `roomId`), by name.
function Sonos.list(roomId)
    local items = Json.array()
    if not state.running then
        return items
    end
    for _, player in ipairs(sortedPlayers()) do
        if roomId == nil or Sonos.roomOf(player) == roomId then
            items[#items + 1] = Sonos.view(player)
        end
    end
    return items
end

-- "off", "searching", "ok", "not_found" or "unreachable" (no player answers).
function Sonos.status()
    if state.status == "ok" then
        for _, group in pairs(state.groups) do
            if group.reachable ~= false then
                return "ok"
            end
        end
        return next(state.groups) and "unreachable" or "ok"
    end
    return state.status
end

-- ---- commands ------------------------------------------------------------------------------

-- A failure from a player as the API reports it: a UPnP error is a refusal (Pause on a radio
-- stream, Next on the radio); anything else means it did not answer.
local function refusal(failure)
    if tostring(failure):match("^%d+$") then
        return "ACTION_NOT_POSSIBLE", "The Sonos player refused this (error " .. tostring(failure) .. ")"
    elseif failure == "busy" then
        return "PLAYER_BUSY", "Too many requests to the Sonos players at once; try again in a moment"
    end
    return "PLAYER_UNREACHABLE", "The Sonos player did not answer (" .. tostring(failure) .. ")"
end

local function coordinatorOf(player)
    local group = state.groups[player.group or ""]
    return group and state.players[group.id] or player, group
end

-- Runs `calls` ({ ip, action, args }) one after the other; done(failure) after the last, or at the
-- first that fails.
local function sequence(calls, done)
    local generation = state.generation
    local index = 0
    local function step()
        index = index + 1
        local call = calls[index]
        if not call then
            done(nil)
            return
        end
        Client.call(call[1], call[2], call[3], function(values, failure)
            if generation ~= state.generation then
                done("stopped")
            elseif not values then
                done(failure or "no answer")
            else
                step()
            end
        end)
    end
    step()
end

local function soon(group)
    if group then
        -- Read again at the next tick, once the player has moved on.
        group.polledAt = now() - Sonos.SLOW_SECONDS
    end
end

-- Pause refused (UPnP 701, "transition not available"): Stop instead, but only when the group
-- plays a radio stream, which Sonos cannot pause. Its media is read again first: what was read
-- before may be a minute old. Sonos answers 701 to other things too (a group already stopped, the
-- TV): those are left as they are and the refusal reported. done(failure, sent).
local function stopRadio(coordinator, done)
    Client.call(coordinator.ip, "GetMediaInfo", { { "InstanceID", 0 } }, function(media, failure)
        if not media then
            done(failure or "no answer")
        elseif Protocol.sourceKind(nil, media.CurrentURI) ~= "radio" then
            done("701")
        else
            sequence({ { coordinator.ip, "Stop", { { "InstanceID", 0 } } } }, function(again)
                done(again, "stop")
            end)
        end
    end)
end

-- play, pause, next, previous or stop on the player's group (its coordinator). done(view) or
-- done(nil, code, detail). Pause stops a radio stream, which Sonos cannot pause (stopRadio).
function Sonos.transport(player, action, done)
    local coordinator, group = coordinatorOf(player)
    local args = { { "InstanceID", 0 } }
    if action == "play" then
        args[#args + 1] = { "Speed", 1 }
    end
    local function finish(failure, sent)
        if failure then
            if failure == "stopped" then
                done(nil, "SONOS_OFF", "Sonos was turned off")
                return
            end
            Log.warn("sonos", "a Sonos command was refused", { player = coordinator.id, action = action, reason = tostring(failure) })
            done(nil, refusal(failure))
            return
        end
        if group and AFTER[sent] then
            group.transport = AFTER[sent]
        end
        soon(group)
        Log.info("sonos", "Sonos " .. action, { player = coordinator.id })
        done(Sonos.view(player))
    end
    local generation = state.generation
    sequence({ { coordinator.ip, COMMANDS[action], args } }, function(failure)
        if failure == "701" and action == "pause" then
            stopRadio(coordinator, function(again, sent)
                finish(generation ~= state.generation and "stopped" or again, sent)
            end)
            return
        end
        finish(failure, action)
    end)
end

-- Volume (0-100) and mute of one Sonos room (its own speaker, not the group's).
function Sonos.setLevels(player, changes, done)
    local calls = {}
    if changes.volume ~= nil then
        calls[#calls + 1] = { player.ip, "SetVolume", { { "InstanceID", 0 }, { "Channel", "Master" }, { "DesiredVolume", changes.volume } } }
    end
    if changes.muted ~= nil then
        calls[#calls + 1] = { player.ip, "SetMute", { { "InstanceID", 0 }, { "Channel", "Master" }, { "DesiredMute", changes.muted and 1 or 0 } } }
    end
    sequence(calls, function(failure)
        if failure then
            if failure == "stopped" then
                done(nil, "SONOS_OFF", "Sonos was turned off")
                return
            end
            done(nil, refusal(failure))
            return
        end
        if changes.volume ~= nil then
            player.volume = changes.volume
        end
        if changes.muted ~= nil then
            player.muted = changes.muted
        end
        done(Sonos.view(player))
    end)
end

-- The household's Sonos favorites (any player has them), kept a minute. done(list) or done(nil,
-- code, detail).
function Sonos.favorites(player, done)
    local cached = state.favorites
    if cached and now() - cached.at < Sonos.FAVORITES_SECONDS then
        done(cached.items)
        return
    end
    local generation = state.generation
    Client.call(player.ip, "Browse", {
        { "ObjectID", "FV:2" },
        { "BrowseFlag", "BrowseDirectChildren" },
        { "Filter", "*" },
        { "StartingIndex", 0 },
        { "RequestedCount", Sonos.MAX_FAVORITES },
        { "SortCriteria", "" },
    }, function(values, failure)
        if generation ~= state.generation then
            done(nil, "SONOS_OFF", "Sonos was turned off")
            return
        end
        if not values then
            done(nil, refusal(failure))
            return
        end
        local items = Protocol.favorites(values.Result)
        state.favorites = { at = now(), items = items }
        done(items)
    end)
end

-- Starts a favorite on the player's group: a station as it is, anything else (a playlist, an album,
-- a track) in place of the group's queue, as the Sonos app's Play now does.
function Sonos.playFavorite(player, favoriteId, done)
    Sonos.favorites(player, function(items, code, detail)
        if not items then
            done(nil, code, detail)
            return
        end
        local favorite
        for _, item in ipairs(items) do
            if item.id == favoriteId then
                favorite = item
            end
        end
        if not favorite then
            done(nil, "NOT_FOUND", "Sonos favorite " .. tostring(favoriteId) .. " does not exist")
            return
        end
        if not favorite.playable then
            done(nil, "FAVORITE_NOT_PLAYABLE", "This favorite can only be started in the Sonos app")
            return
        end
        local coordinator, group = coordinatorOf(player)
        local ip, calls = coordinator.ip, nil
        if Protocol.isStream(favorite.uri) then
            calls = {
                { ip, "SetAVTransportURI", { { "InstanceID", 0 }, { "CurrentURI", favorite.uri }, { "CurrentURIMetaData", favorite.meta } } },
            }
        else
            calls = {
                { ip, "RemoveAllTracksFromQueue", { { "InstanceID", 0 } } },
                { ip, "AddURIToQueue", { { "InstanceID", 0 }, { "EnqueuedURI", favorite.uri }, { "EnqueuedURIMetaData", favorite.meta },
                    { "DesiredFirstTrackNumberEnqueued", 0 }, { "EnqueueAsNext", 0 } } },
                { ip, "SetAVTransportURI", { { "InstanceID", 0 }, { "CurrentURI", "x-rincon-queue:" .. coordinator.id .. "#0" }, { "CurrentURIMetaData", "" } } },
            }
        end
        calls[#calls + 1] = { ip, "Play", { { "InstanceID", 0 }, { "Speed", 1 } } }
        sequence(calls, function(failure)
            if failure then
                if failure == "stopped" then
                    done(nil, "SONOS_OFF", "Sonos was turned off")
                    return
                end
                Log.warn("sonos", "a Sonos favorite did not start", { player = coordinator.id, reason = tostring(failure) })
                done(nil, refusal(failure))
                return
            end
            if group then
                group.transport = "TRANSITIONING"
                group.position = nil
            end
            soon(group)
            Log.info("sonos", "Sonos favorite started", { player = coordinator.id })
            done(Sonos.view(player))
        end)
    end)
end

-- The picture of what the player's group plays, from the coordinator (the page is HTTPS, the
-- player plain HTTP on the home network). done(bytes, type) or done(nil, code, detail). One
-- request for a picture however many ask for it at once; one the player did not give is not asked
-- for again for ART_RETRY_SECONDS. A picture never changes whether a room is shown as answering.
function Sonos.art(player, done)
    local coordinator, group = coordinatorOf(player)
    local path = group and group.now and group.now.art
    if not path then
        done(nil, "NO_ART", "Nothing with a picture is playing here")
        return
    end
    local key = coordinator.ip .. path
    for _, entry in ipairs(state.art) do
        if entry.key == key then
            done(entry.body, entry.type)
            return
        end
    end
    local failed = state.artFailed[key]
    if failed and now() - failed.at < Sonos.ART_RETRY_SECONDS then
        done(nil, failed.code, failed.detail)
        return
    end
    local waiting = state.artWaiting[key]
    if waiting then
        waiting[#waiting + 1] = done
        return
    end
    waiting = { done }
    state.artWaiting[key] = waiting
    local function answer(...)
        if state.artWaiting[key] == waiting then
            state.artWaiting[key] = nil
        end
        for _, callback in ipairs(waiting) do
            local ok, err = pcall(callback, ...)
            if not ok then
                Log.warn("sonos", "an album art answer failed", { reason = tostring(err) })
            end
        end
    end
    local function fail(code, detail)
        local count = 0
        for other, entry in pairs(state.artFailed) do
            if now() - entry.at >= Sonos.ART_RETRY_SECONDS then
                state.artFailed[other] = nil
            else
                count = count + 1
            end
        end
        -- Kept a while, a few at most: asking again at once would only fill the queue.
        if count < Sonos.ART_CACHE * 4 then
            state.artFailed[key] = { at = now(), code = code, detail = detail }
        end
        answer(nil, code, detail)
    end
    local generation = state.generation
    Client.picture(coordinator.ip, path, function(body, mediaType)
        if generation ~= state.generation then
            answer(nil, "SONOS_OFF", "Sonos was turned off")
            return
        end
        if not body then
            if mediaType == "busy" then
                answer(nil, refusal(mediaType))
            else
                fail(refusal(mediaType))
            end
            return
        end
        if #body > Sonos.ART_MAX_BYTES then
            fail("NO_ART", "The picture is too large")
            return
        end
        state.artFailed[key] = nil
        table.insert(state.art, 1, { key = key, body = body, type = mediaType })
        while #state.art > Sonos.ART_CACHE do
            table.remove(state.art)
        end
        answer(body, mediaType)
    end)
end

-- Puts a Sonos room in a Control4 room (nil: back to its name).
function Sonos.choose(player, roomId)
    return Rooms.choose(player.id, roomId, player.name)
end

-- ---- scenes --------------------------------------------------------------------------------

-- What a group does when it plays nothing a scene needs to pause or stop.
local QUIET = { PAUSED_PLAYBACK = true, STOPPED = true, NO_MEDIA_PRESENT = true }

-- A scene's music step: pauses (or stops) every group with a room in `roomId`, or every group in
-- the home. A group plays as one: pausing it pauses each of its rooms. Each group is first asked
-- what it does (GetTransportInfo; what was read before may be a minute old): one that is paused
-- or stopped is left as it is, so a paused queue keeps its place in the track and a paused Spotify
-- Connect session is not ended. Returns the groups it handles ({ id, name }), or nil and why not:
-- "SONOS_OFF", "NO_PLAYERS", or "NO_SONOS_ROOM" (no Sonos room is shown in `roomId`). Answers are
-- not waited for; a refusal is logged.
function Sonos.sceneStep(roomId, action)
    if not state.running then
        return nil, "SONOS_OFF"
    end
    if not next(state.groups) then
        return nil, "NO_PLAYERS"
    end
    local handled = {}
    local ids = {}
    for id in pairs(state.groups) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local generation = state.generation
    for _, id in ipairs(ids) do
        local group = state.groups[id]
        local inRoom = roomId == nil
        for _, memberId in ipairs(group.members or {}) do
            inRoom = inRoom or Sonos.roomOf(state.players[memberId]) == roomId
        end
        local coordinator = state.players[id]
        if inRoom and coordinator then
            handled[#handled + 1] = { id = id, name = coordinator.name }
            Client.call(coordinator.ip, "GetTransportInfo", { { "InstanceID", 0 } }, function(values, failure)
                if generation ~= state.generation then
                    return
                end
                local transport = values and values.CurrentTransportState
                if not values then
                    Log.warn("sonos", "a scene could not pause the music", { player = id, code = (refusal(failure)) })
                    return
                end
                group.transport = transport or group.transport
                if QUIET[transport] then
                    Log.debug("sonos", "a scene left a Sonos group that does not play", { player = id, state = transport })
                    return
                end
                Sonos.transport(coordinator, action == "stop" and "stop" or "pause", function(view, code)
                    if not view then
                        Log.warn("sonos", "a scene could not pause the music", { player = id, code = code })
                    end
                end)
            end)
        end
    end
    if #handled == 0 then
        return nil, roomId == nil and "NO_PLAYERS" or "NO_SONOS_ROOM"
    end
    return handled
end

-- For tests: everything as at a fresh start, Sonos off.
function Sonos.reset()
    stop()
    state.shown = nil
end

return Sonos
