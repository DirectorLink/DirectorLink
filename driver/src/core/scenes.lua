-- DirectorLink scenes (docs/SCENES.md): one tap runs several steps, e.g. "all lights off, bedroom
-- AC to 24°, living-room blinds closed". They are the home's, kept in the driver's persistent data;
-- admins make and change them, members and above run them (src/api/handlers/scenes.lua).
-- A step names its devices by id, or by room ("all lights in the living room"), which is worked out
-- when the scene runs, so a light added to the room later is included.

local Clock = require("src.core.clock")
local Random = require("src.core.random")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local Scenes = {}

local STORE_KEY = "directorlink_scenes"
Scenes.MAX_SCENES = 50
Scenes.MAX_STEPS = 40
Scenes.MAX_DEVICES = 100
Scenes.ICONS = { moon = true, sun = true, leave = true, movie = true, bulb = true, climate = true, blinds = true, home = true }
Scenes.TYPES = { lights = true, climate = true, fans = true, blinds = true, relays = true, music = true, refrigerators = true }
-- Music (1.5.0, ADR-044): a step pauses or stops the Sonos music in a room, or in the whole home.
-- 1.8.0 (ADR-057): it also resumes it, sets the volume, or plays a Sonos favorite in a room (with
-- other rooms grouped with it, at a volume if the step has one).
Scenes.MUSIC_ACTIONS = { pause = true, stop = true, resume = true, volume = true, play_favorite = true }
-- The music actions DirectorLink 1.7.0 does not know (see KEPT below).
Scenes.NEWER_MUSIC_ACTIONS = { resume = true, volume = true, play_favorite = true }
-- What a play_favorite step keeps of the favorite: its id and name, and what the favorites list
-- gives to start it (its address and description), as long as they are no longer than this.
Scenes.MAX_FAVORITE_TITLE = 1024
Scenes.MAX_FAVORITE_URI = 2048
Scenes.MAX_FAVORITE_META = 8192
-- Rooms that play a favorite grouped with the step's own.
Scenes.MAX_WITH_ROOMS = 32
Scenes.MODES = { off = true, heat = true, cool = true, auto = true }
Scenes.FAN_SPEEDS = { low = true, medium = true, high = true, auto = true, on = true, circulate = true }
-- Fans (1.2.0) take a speed from 1 (low) to 4 (high), as the Fan proxy lists them.
Scenes.MAX_FAN_SPEED = 4
Scenes.MIN_TEMPERATURE = 5
Scenes.MAX_TEMPERATURE = 40
-- Refrigerators (1.7.0, ADR-049): their features on (true) or off (false), at least one a step.
Scenes.REFRIGERATOR_FEATURES = { power_cool = true, power_freeze = true, sabbath_mode = true, ice_maker = true }
-- Step types DirectorLink 1.6.0 does not know. It leaves them out when it loads the scenes, and its
-- next save drops them; so they are also kept under EXTRAS_KEY, where it does not look, and put back
-- when the scenes come back without them (Scenes.load). The scenes record 1.7.0 writes says so
-- (STEPS_KEPT), a field 1.6.0 drops when it saves: steps are put back only into scenes an older
-- version wrote, never into scenes 1.7.0 saved without them (a step removed, even when the copy
-- under EXTRAS_KEY could not be written then).
Scenes.NEWER_TYPES = { refrigerators = true }
local EXTRAS_KEY = "directorlink_scene_steps"
local STEPS_KEPT = "steps_kept"
-- 1.8.0 (ADR-057) does the same for the music steps 1.7.0 does not know (it leaves them out as it
-- loads, and writes STEPS_KEPT when it saves): under a key of their own, which 1.7.0 neither reads
-- nor rewrites (it rewrites EXTRAS_KEY with its own steps), and with a mark of their own, which
-- 1.7.0 and 1.6.0 drop when they save. Each kind: its key, its mark, which steps it keeps.
local KEPT = {
    { key = EXTRAS_KEY, mark = STEPS_KEPT, newer = function(step)
        return Scenes.NEWER_TYPES[step.type] == true
    end },
    { key = "directorlink_scene_steps_2", mark = "music_steps_kept", newer = function(step)
        return step.type == "music" and Scenes.NEWER_MUSIC_ACTIONS[step.set.action] == true
    end },
}

-- `complete` is false after the stored scenes could not be read: saving then would overwrite them.
-- `extras[key]`: that key holds steps (or held them), so a save writes it again.
local state = { scenes = {}, complete = true, extras = {} }

local function randomHex(length)
    return Random.hex(length)
end

local function isWhole(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isTemperature(value)
    return type(value) == "number" and value == value and value >= Scenes.MIN_TEMPERATURE and value <= Scenes.MAX_TEMPERATURE
end

-- The favorite a play_favorite step keeps: { id, title, uri, meta }, the id as the favorites list
-- gives it ("12"), the others when they are text no longer than their limit (left out otherwise).
function Scenes.cleanFavorite(favorite)
    if type(favorite) ~= "table" or favorite == Json.null then
        return nil
    end
    local id = favorite.id
    if type(id) ~= "string" or #id > 9 or not id:match("^%d+$") then
        return nil
    end
    local result = { id = id }
    for field, limit in pairs({ title = Scenes.MAX_FAVORITE_TITLE, uri = Scenes.MAX_FAVORITE_URI, meta = Scenes.MAX_FAVORITE_META }) do
        local value = favorite[field]
        if type(value) == "string" and #value <= limit and (value ~= "" or field == "meta") then
            result[field] = value
        end
    end
    return result
end

-- The rooms a favorite is played in besides the step's own: room ids, each once, at most
-- MAX_WITH_ROOMS; nil when it is not such a list.
function Scenes.cleanRooms(list)
    if type(list) ~= "table" or list == Json.null then
        return nil
    end
    local rooms, seen = Json.array(), {}
    for _, id in ipairs(Store.items(list)) do
        id = tonumber(id)
        if not id or not isWhole(id, 1, math.huge) then
            return nil
        end
        if not seen[id] then
            seen[id] = true
            rooms[#rooms + 1] = id
        end
    end
    if #rooms > Scenes.MAX_WITH_ROOMS then
        return nil
    end
    return rooms
end

-- A music step's setting: { action } to pause, stop (1.5.0) or resume; { action, volume } for the
-- volume; { action, favorite, volume?, with_room_ids? } to play a favorite (1.8.0). Other fields are
-- left out.
function Scenes.cleanMusic(set)
    local action = set.action
    if type(action) ~= "string" or not Scenes.MUSIC_ACTIONS[action] then
        return nil
    end
    local result = { action = action }
    if action == "volume" or (action == "play_favorite" and set.volume ~= nil) then
        if not isWhole(set.volume, 0, 100) then
            return nil
        end
        result.volume = set.volume
    end
    if action == "play_favorite" then
        result.favorite = Scenes.cleanFavorite(set.favorite)
        if not result.favorite then
            return nil
        end
        if set.with_room_ids ~= nil then
            local rooms = Scenes.cleanRooms(set.with_room_ids)
            if not rooms then
                return nil
            end
            result.with_room_ids = #rooms > 0 and rooms or nil
        end
    end
    return result
end

-- What a step sets, when it is valid for the step's type: the fields kept, or nil. The API checks
-- the same rules with a message for each (handlers/scenes.lua); this also guards stored data.
function Scenes.cleanSet(stepType, set)
    if type(set) ~= "table" or set == Json.null then
        return nil
    end
    if stepType == "lights" then
        if set.on ~= nil and set.brightness ~= nil then
            return nil
        end
        if set.brightness ~= nil then
            return isWhole(set.brightness, 0, 100) and { brightness = set.brightness } or nil
        end
        return type(set.on) == "boolean" and { on = set.on } or nil
    elseif stepType == "climate" then
        local result = {}
        if set.mode ~= nil then
            if type(set.mode) ~= "string" or not Scenes.MODES[set.mode] then
                return nil
            end
            result.mode = set.mode
        end
        if set.fan_speed ~= nil then
            if type(set.fan_speed) ~= "string" or not Scenes.FAN_SPEEDS[set.fan_speed] then
                return nil
            end
            result.fan_speed = set.fan_speed
        end
        if set.target_temperature ~= nil then
            if not isTemperature(set.target_temperature) then
                return nil
            end
            result.target_temperature = set.target_temperature
        end
        -- Heat and cool setpoints (1.1.0), for thermostats that have both: instead of a target,
        -- and cool above heat.
        for _, field in ipairs({ "heat_setpoint", "cool_setpoint" }) do
            if set[field] ~= nil then
                if not isTemperature(set[field]) then
                    return nil
                end
                result[field] = set[field]
            end
        end
        local heat, cool = result.heat_setpoint, result.cool_setpoint
        if (heat or cool) and result.target_temperature then
            return nil
        end
        if heat and cool and cool <= heat then
            return nil
        end
        if next(result) == nil or (result.mode == "off" and (result.fan_speed or result.target_temperature or heat or cool)) then
            return nil
        end
        return result
    elseif stepType == "fans" then
        if set.on ~= nil and set.speed ~= nil then
            return nil
        end
        if set.speed ~= nil then
            return isWhole(set.speed, 1, Scenes.MAX_FAN_SPEED) and { speed = set.speed } or nil
        end
        return type(set.on) == "boolean" and { on = set.on } or nil
    elseif stepType == "blinds" then
        return isWhole(set.position, 0, 100) and { position = set.position } or nil
    elseif stepType == "relays" then
        -- Doors and gates only get what their Open button does: a pulse. Holding a door relay
        -- closed would keep the door unlocked or the gate input pressed.
        return set.action == "pulse" and { action = "pulse" } or nil
    elseif stepType == "music" then
        return Scenes.cleanMusic(set)
    elseif stepType == "refrigerators" then
        local result = {}
        for key, value in pairs(set) do
            if not Scenes.REFRIGERATOR_FEATURES[key] or type(value) ~= "boolean" then
                return nil
            end
            result[key] = value
        end
        return next(result) ~= nil and result or nil
    end
    return nil
end

local function copyList(list)
    local copy = Json.array()
    for _, value in ipairs(list or {}) do
        copy[#copy + 1] = value
    end
    return copy
end

-- A step's setting, copied (a music step's favorite and rooms too).
function Scenes.copySet(source)
    local set = {}
    for key, value in pairs(source or {}) do
        if key == "with_room_ids" and type(value) == "table" then
            value = copyList(value)
        elseif type(value) == "table" and value ~= Json.null then
            local inner = {}
            for field, item in pairs(value) do
                inner[field] = item
            end
            value = inner
        end
        set[key] = value
    end
    return set
end

local function copyStep(step)
    local set = Scenes.copySet(step.set)
    return {
        type = step.type,
        room_id = step.room_id,
        device_ids = step.device_ids and copyList(step.device_ids) or nil,
        set = set,
    }
end

local function copy(scene)
    local steps = Json.array()
    for _, step in ipairs(scene.steps) do
        steps[#steps + 1] = copyStep(step)
    end
    return {
        id = scene.id,
        name = scene.name,
        icon = scene.icon,
        show_on_home = scene.show_on_home,
        steps = steps,
        created_at = scene.created_at,
        updated_at = scene.updated_at,
        version = scene.version,
    }
end

-- The steps of each kind in KEPT, by scene id, each with its place in the scene, under the kind's
-- key (written when there are some, or were).
local function saveExtras()
    for _, kind in ipairs(KEPT) do
        local scenes, any = {}, false
        for _, scene in ipairs(state.scenes) do
            local kept = Json.array()
            for index, step in ipairs(scene.steps) do
                if kind.newer(step) then
                    kept[#kept + 1] = { index = index, step = copyStep(step) }
                end
            end
            if #kept > 0 then
                scenes[scene.id] = kept
                any = true
            end
        end
        if any or state.extras[kind.key] then
            if Store.write(kind.key, { version = 1, scenes = scenes }, false) then
                state.extras[kind.key] = any
            else
                Log.warn("scenes", "could not keep the newer scene steps apart; going back to an older DirectorLink may lose them", { key = kind.key })
            end
        end
    end
end

local function save()
    local records = Json.array()
    for _, scene in ipairs(state.scenes) do
        records[#records + 1] = copy(scene)
    end
    local record = { version = 1, scenes = records }
    for _, kind in ipairs(KEPT) do
        record[kind.mark] = true
    end
    local ok = Store.write(STORE_KEY, record, false)
    if not ok then
        Log.error("scenes", "could not save the scenes")
    else
        saveExtras()
    end
    return ok
end

-- A stored step, checked again: data from a damaged store, or from a later version after a
-- downgrade, must not reach a run.
local function loadStep(item)
    if type(item) ~= "table" or item == Json.null or not Scenes.TYPES[item.type] then
        return nil
    end
    local roomId = nil
    if item.room_id ~= nil and item.room_id ~= Json.null then
        roomId = tonumber(item.room_id)
        if not roomId or not isWhole(roomId, 1, math.huge) then
            return nil
        end
    end
    local ids = nil
    if item.device_ids ~= nil and item.device_ids ~= Json.null then
        if type(item.device_ids) ~= "table" then
            return nil
        end
        ids = {}
        for _, id in ipairs(Store.items(item.device_ids)) do
            id = tonumber(id)
            if id and isWhole(id, 1, math.huge) then
                ids[#ids + 1] = id
            end
        end
        if #ids == 0 or #ids > Scenes.MAX_DEVICES then
            return nil
        end
    end
    local set = Scenes.cleanSet(item.type, item.set)
    if not set or (item.type == "music" and ids) then
        return nil
    end
    if set.action == "play_favorite" and item.type == "music" then
        -- A favorite plays in a room (and those grouped with it, not that room again).
        if not roomId then
            return nil
        end
        local others = Json.array()
        for _, id in ipairs(set.with_room_ids or {}) do
            if id ~= roomId then
                others[#others + 1] = id
            end
        end
        set.with_room_ids = #others > 0 and others or nil
    end
    return { type = item.type, room_id = roomId, device_ids = ids, set = set }
end

-- The scenes of a stored record ({ version, scenes }, as the store or a backup holds them), each
-- checked again. Returns them, how many of their steps were left out and how many scenes.
function Scenes.read(data)
    local scenes, dropped, droppedScenes = {}, 0, 0
    for _, item in ipairs(Store.items(type(data) == "table" and data.scenes or nil)) do
        if type(item) == "table" and type(item.id) == "string" and item.id:match("^[%da-f]+$") and #item.id == 8 and type(item.name) == "string" then
            local steps = {}
            for _, stepItem in ipairs(Store.items(item.steps)) do
                local step = loadStep(stepItem)
                if step and #steps < Scenes.MAX_STEPS then
                    steps[#steps + 1] = step
                else
                    dropped = dropped + 1
                end
            end
            if #scenes >= Scenes.MAX_SCENES then
                droppedScenes = droppedScenes + 1
            else
                scenes[#scenes + 1] = {
                    id = item.id,
                    name = item.name,
                    icon = Scenes.ICONS[item.icon] and item.icon or "bulb",
                    show_on_home = item.show_on_home == true,
                    steps = steps,
                    created_at = type(item.created_at) == "string" and item.created_at or Clock.iso(),
                    updated_at = type(item.updated_at) == "string" and item.updated_at or Clock.iso(),
                    version = isWhole(tonumber(item.version), 1, math.huge) and tonumber(item.version) or 1,
                }
            end
        else
            droppedScenes = droppedScenes + 1
        end
    end
    return scenes, dropped, droppedScenes
end

-- Puts back the steps an older DirectorLink left out of a scene (KEPT): 1.6.0 saved the scenes
-- without refrigerator steps and without either mark, 1.7.0 without the newer music steps and
-- without their mark. A kind's steps go back in their places, all kinds together in the order of
-- their places, in a scene that has none of that kind now, and only when the scenes record lacks
-- the kind's mark (the version that wrote it did not know them). Returns how many.
local function putBackExtras(scenes, record)
    local back = {} -- scene id -> { { index, step } }
    for _, kind in ipairs(KEPT) do
        local data = Store.read(kind.key, false)
        if type(data) == "table" then
            state.extras[kind.key] = true
            local kept = not (type(record) == "table" and record[kind.mark] == true) and type(data.scenes) == "table" and data.scenes or {}
            for _, scene in ipairs(scenes) do
                local has = false
                for _, step in ipairs(scene.steps) do
                    has = has or kind.newer(step)
                end
                local items = not has and type(kept[scene.id]) == "table" and Store.items(kept[scene.id]) or {}
                for _, item in ipairs(items) do
                    local step = type(item) == "table" and loadStep(item.step) or nil
                    local index = type(item) == "table" and tonumber(item.index) or nil
                    if step and kind.newer(step) and index then
                        back[scene.id] = back[scene.id] or {}
                        table.insert(back[scene.id], { index = math.floor(index), step = step })
                    end
                end
            end
        end
    end
    local putBack = 0
    for _, scene in ipairs(scenes) do
        local items = back[scene.id] or {}
        table.sort(items, function(a, b)
            return a.index < b.index
        end)
        for _, item in ipairs(items) do
            if #scene.steps < Scenes.MAX_STEPS then
                table.insert(scene.steps, math.max(1, math.min(item.index, #scene.steps + 1)), item.step)
                putBack = putBack + 1
            end
        end
    end
    return putBack
end

-- Returns how many scenes there are and how the store came back ("json", "missing", "unreadable").
function Scenes.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    state.extras = {}
    local dropped
    state.scenes, dropped = Scenes.read(data)
    if dropped > 0 then
        Log.warn("scenes", "stored scene steps that are not valid were left out", { steps = dropped })
    end
    if state.complete then
        local putBack = putBackExtras(state.scenes, data)
        if putBack > 0 then
            Log.warn("scenes", "scene steps an older DirectorLink left out were put back", { steps = putBack })
            save()
        end
    end
    return #state.scenes, form
end

-- How many steps play a Sonos favorite: while there are some, the Sonos favorites are kept read
-- (src/sonos/sonos.lua, services.favoritesWanted).
function Scenes.favoriteSteps()
    local count = 0
    for _, scene in ipairs(state.scenes) do
        for _, step in ipairs(scene.steps) do
            if step.type == "music" and step.set.action == "play_favorite" then
                count = count + 1
            end
        end
    end
    return count
end

-- Backups (ADR-042, src/core/backup.lua): the scenes as the store keeps them.
function Scenes.backup()
    local records = Json.array()
    for _, scene in ipairs(state.scenes) do
        records[#records + 1] = copy(scene)
    end
    return { version = 1, scenes = records }
end

-- Replaces every scene with the ones of `data`, read as the store's are (a store that could not be
-- read at start is overwritten: a restore replaces everything). Returns true once saved.
function Scenes.restore(data)
    state.scenes = Scenes.read(data)
    local ok = save()
    if ok then
        state.complete = true
    end
    return ok
end

-- False after the stored scenes could not be read at start (they may come back at the next one).
function Scenes.complete()
    return state.complete
end

local function findRecord(id)
    for index, scene in ipairs(state.scenes) do
        if scene.id == id then
            return scene, index
        end
    end
    return nil
end

function Scenes.list()
    local items = {}
    for _, scene in ipairs(state.scenes) do
        items[#items + 1] = copy(scene)
    end
    return items
end

function Scenes.find(id)
    local scene = type(id) == "string" and findRecord(id) or nil
    return scene and copy(scene) or nil
end

-- `fields`: { name, icon, show_on_home, steps } already checked by the API.
function Scenes.create(fields)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    if #state.scenes >= Scenes.MAX_SCENES then
        return nil, "SCENE_LIMIT_REACHED"
    end
    local id = randomHex(8)
    while findRecord(id) do
        id = randomHex(8)
    end
    local now = Clock.iso()
    local scene = {
        id = id,
        name = fields.name,
        icon = fields.icon or "bulb",
        show_on_home = fields.show_on_home == true,
        steps = fields.steps or {},
        created_at = now,
        updated_at = now,
        version = 1,
    }
    state.scenes[#state.scenes + 1] = scene
    if not save() then
        table.remove(state.scenes)
        return nil, "PERSIST_FAILED"
    end
    return copy(scene)
end

-- Changes the given fields; `expected`: the version the caller saw, or nil not to check.
function Scenes.update(id, fields, expected)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    local scene = findRecord(id)
    if not scene then
        return nil, "NOT_FOUND"
    end
    if expected ~= nil and expected ~= scene.version then
        return nil, "VERSION_CONFLICT"
    end
    local before = {}
    for key, value in pairs(scene) do
        before[key] = value
    end
    for _, field in ipairs({ "name", "icon", "show_on_home", "steps" }) do
        if fields[field] ~= nil then
            scene[field] = fields[field]
        end
    end
    scene.version = scene.version + 1
    scene.updated_at = Clock.iso()
    if not save() then
        for key in pairs(scene) do
            scene[key] = before[key]
        end
        return nil, "PERSIST_FAILED"
    end
    return copy(scene)
end

function Scenes.delete(id)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    local scene, index = findRecord(id)
    if not scene then
        return nil, "NOT_FOUND"
    end
    table.remove(state.scenes, index)
    if not save() then
        table.insert(state.scenes, index, scene)
        return nil, "PERSIST_FAILED"
    end
    return true
end

return Scenes
