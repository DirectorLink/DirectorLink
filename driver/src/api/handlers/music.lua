-- Music: the home's Sonos rooms (docs/SONOS.md, ADR-044, src/sonos/sonos.lua). Everyone reads what
-- plays, members and above play, pause, skip, set the volume and start a favorite, and admins pick
-- the Control4 room of a Sonos room whose name matches none. Off until the installer sets the
-- Composer property Sonos to On: GET /v1/music then says only that, and the rest answers
-- 409 SONOS_OFF. A request names a Sonos room by its id; the address it is reached at is the one
-- DirectorLink found, never anything in the request. Since 1.8.0 (ADR-057) members also join a
-- room to another room's group, take it out again, and set a group's volume; a command that acts
-- on a group needs every room in it (Access.canControl, src/auth/access.lua).

local Json = require("src.core.json")
local Access = require("src.auth.access")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Protocol = require("src.sonos.protocol")
local Sonos = require("src.sonos.sonos")

local Music = {}

local STATUS = {
    SONOS_OFF = 409,
    NOT_FOUND = 404,
    ACTION_NOT_POSSIBLE = 409,
    FAVORITE_NOT_PLAYABLE = 409,
    NO_ART = 404,
    PLAYER_UNREACHABLE = 502,
    PLAYER_BUSY = 503,
    FORBIDDEN = 403,
}

local function off()
    return Problem.new(409, "SONOS_OFF", "Sonos is off; an installer turns it on with the Sonos property of DirectorLink in Composer")
end

local function failed(code, detail)
    local status = STATUS[code] or 502
    return Problem.new(status, code, detail), status == 503 and { { "Retry-After", "1" } } or nil
end

local function findPlayer(ctx)
    local id = tostring(ctx.params.musicId or "")
    if not Protocol.validId(id) then
        return nil, Problem.invalidParameter("musicId", "musicId is a Sonos room's id, as GET /v1/music lists it")
    end
    if not Sonos.enabled() then
        return nil, off()
    end
    local player = Sonos.find(id)
    if not player then
        return nil, Problem.notFound("Sonos room", id)
    end
    return player
end

-- The Sonos rooms `ctx` may not control among `players` (Access.canControl, each in the Control4
-- room it is shown in): a problem naming them, or nil.
local function refused(ctx, players)
    local names = {}
    for _, player in ipairs(players) do
        if not Access.canControl(ctx.apiKey, { kind = "music", id = player.id, room_id = Sonos.roomOf(player) }) then
            names[#names + 1] = player.name
        end
    end
    if #names == 0 then
        return nil
    end
    return Problem.new(403, "FORBIDDEN", "This key may not control the music in " .. table.concat(names, ", "))
end

-- A command answered once the player has: the room as it is then.
local function later(start)
    return Response.later(function(respond)
        start(function(view, code, detail)
            if view then
                respond(200, view)
            else
                respond(failed(code, detail))
            end
        end)
    end)
end

-- GET /v1/music[?room_id=]: the Sonos rooms (in a room: those shown there). Asking also keeps them
-- read every few seconds for a while (the app asks every 5 while it shows them).
function Music.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    if not Sonos.enabled() then
        return 200, { enabled = false, status = "off", items = Json.array() }
    end
    Sonos.wanted(roomId)
    return 200, { enabled = true, status = Sonos.status(), items = Sonos.list(roomId), groups = Sonos.groups(roomId) }
end

function Music.get(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    local roomId = Sonos.roomOf(player)
    Sonos.wanted(roomId)
    return 200, Sonos.view(player)
end

local function transport(action)
    return function(ctx)
        local player, problem = findPlayer(ctx)
        if not player then
            return problem
        end
        -- It goes to the group: every room in it.
        problem = refused(ctx, Sonos.groupPlayers(player))
        if problem then
            return problem
        end
        return later(function(done)
            Sonos.transport(player, action, done)
        end)
    end
end

Music.play = transport("play")
Music.pause = transport("pause")
Music.next = transport("next")
Music.previous = transport("previous")

-- PATCH {"volume": 0-100, "muted": true|false}: this Sonos room's own volume and mute.
function Music.update(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    local body = ctx.body
    problem = Validate.body(body, { volume = true, muted = true }, true)
    if problem then
        return problem
    end
    if body.volume ~= nil and (type(body.volume) ~= "number" or body.volume ~= math.floor(body.volume) or body.volume < 0 or body.volume > 100) then
        return Problem.invalidField("volume", "volume must be a whole number from 0 to 100")
    end
    if body.muted ~= nil and type(body.muted) ~= "boolean" then
        return Problem.invalidField("muted", "muted must be true or false")
    end
    problem = refused(ctx, { player })
    if problem then
        return problem
    end
    return later(function(done)
        Sonos.setLevels(player, { volume = body.volume, muted = body.muted }, done)
    end)
end

-- GET: the household's Sonos favorites; `playable` is false for those only the Sonos app starts.
function Music.favorites(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    return Response.later(function(respond)
        Sonos.favorites(player, function(list, code, detail)
            if not list then
                respond(failed(code, detail))
                return
            end
            local items = Json.array()
            for _, favorite in ipairs(list) do
                items[#items + 1] = {
                    id = favorite.id,
                    title = favorite.title,
                    description = favorite.description or Json.null,
                    playable = favorite.playable,
                }
            end
            respond(200, { items = items })
        end)
    end)
end

function Music.play_favorite(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    local favoriteId = tostring(ctx.params.favoriteId or "")
    if not favoriteId:match("^%d+$") or #favoriteId > 9 then
        return Problem.invalidParameter("favoriteId", "favoriteId is a favorite's id, as GET /v1/music/{musicId}/favorites lists it")
    end
    problem = refused(ctx, Sonos.groupPlayers(player))
    if problem then
        return problem
    end
    return later(function(done)
        Sonos.playFavorite(player, favoriteId, done)
    end)
end

-- ---- groups (1.8.0, ADR-057) ---------------------------------------------------------------

-- POST {"with": "<musicId>"}: this Sonos room joins the group of that one (any room of it), as the
-- Sonos app's Group does. Every room of both groups must be one the key may control.
function Music.join(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    local body = ctx.body
    problem = Validate.body(body, { with = true }, true)
    if problem then
        return problem
    end
    if not Protocol.validId(body.with) then
        return Problem.invalidField("with", "with is the id of the Sonos room whose group this one joins, as GET /v1/music lists it")
    end
    local other = Sonos.find(body.with)
    if not other then
        return Problem.notFound("Sonos room", body.with)
    end
    local touched = Sonos.groupPlayers(player)
    for _, member in ipairs(Sonos.groupPlayers(other)) do
        touched[#touched + 1] = member
    end
    problem = refused(ctx, touched)
    if problem then
        return problem
    end
    return later(function(done)
        Sonos.join(player, other, done)
    end)
end

-- DELETE: this Sonos room leaves its group and plays on its own; the others go on together.
function Music.leave(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    problem = refused(ctx, Sonos.groupPlayers(player))
    if problem then
        return problem
    end
    return later(function(done)
        Sonos.leave(player, done)
    end)
end

-- PATCH {"volume": 0-100}: the volume of this room's group, set through each room's own volume,
-- keeping their balance (there is no group volume in what DirectorLink sends).
function Music.group_volume(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    local body = ctx.body
    problem = Validate.body(body, { volume = true }, true)
    if problem then
        return problem
    end
    if type(body.volume) ~= "number" or body.volume ~= math.floor(body.volume) or body.volume < 0 or body.volume > 100 then
        return Problem.invalidField("volume", "volume must be a whole number from 0 to 100")
    end
    problem = refused(ctx, Sonos.groupPlayers(player))
    if problem then
        return problem
    end
    return later(function(done)
        Sonos.setGroupVolume(player, body.volume, done)
    end)
end

-- GET: the picture of what plays (album art, a station's logo), through the controller: the app's
-- page is HTTPS and the player answers plain HTTP on the home network.
function Music.art(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    return Response.later(function(respond)
        Sonos.art(player, function(body, typeOrCode, detail)
            if body then
                respond(200, Response.raw(body, typeOrCode))
            else
                respond(failed(typeOrCode, detail))
            end
        end)
    end)
end

-- PUT {"room_id": 12 | null} (admins): the Control4 room this Sonos room is shown in; null goes
-- back to the room of the same name.
function Music.room(ctx)
    local player, problem = findPlayer(ctx)
    if not player then
        return problem
    end
    local body = ctx.body
    problem = Validate.body(body, { room_id = true }, true)
    if problem then
        return problem
    end
    local roomId = body.room_id
    if roomId == Json.null then
        roomId = nil
    elseif type(roomId) ~= "number" or roomId ~= math.floor(roomId) or roomId < 1 or not (ctx.services.registry.rooms or {})[roomId] then
        return Problem.invalidField("room_id", "room_id must be one of the home's rooms, or null")
    end
    local ok, failure = Sonos.choose(player, roomId)
    if not ok then
        if failure == "STORE_UNREADABLE" then
            return Problem.new(503, "UNAVAILABLE", "The saved Sonos rooms could not be read when DirectorLink started; restart the driver and try again")
        elseif failure == "LIMIT_REACHED" then
            return Problem.new(409, "LIMIT_REACHED", "As many Sonos rooms are placed as DirectorLink keeps")
        end
        return Problem.internal("The room could not be saved")
    end
    ctx.services.log.info("sonos", "Sonos room placed", { player = player.id, room_id = roomId or Json.null, by = ctx.apiKey.id })
    return 200, Sonos.view(player)
end

return Music
