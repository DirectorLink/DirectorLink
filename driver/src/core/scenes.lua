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
Scenes.TYPES = { lights = true, climate = true, fans = true, blinds = true, relays = true }
Scenes.MODES = { off = true, heat = true, cool = true, auto = true }
Scenes.FAN_SPEEDS = { low = true, medium = true, high = true, auto = true, on = true, circulate = true }
-- Fans (1.2.0) take a speed from 1 (low) to 4 (high), as the Fan proxy lists them.
Scenes.MAX_FAN_SPEED = 4
Scenes.MIN_TEMPERATURE = 5
Scenes.MAX_TEMPERATURE = 40

-- `complete` is false after the stored scenes could not be read: saving then would overwrite them.
local state = { scenes = {}, complete = true }

local function randomHex(length)
    return Random.hex(length)
end

local function isWhole(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isTemperature(value)
    return type(value) == "number" and value == value and value >= Scenes.MIN_TEMPERATURE and value <= Scenes.MAX_TEMPERATURE
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

local function copyStep(step)
    local set = {}
    for key, value in pairs(step.set or {}) do
        set[key] = value
    end
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

local function save()
    local records = Json.array()
    for _, scene in ipairs(state.scenes) do
        records[#records + 1] = copy(scene)
    end
    local ok = Store.write(STORE_KEY, { version = 1, scenes = records }, false)
    if not ok then
        Log.error("scenes", "could not save the scenes")
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
    if not set then
        return nil
    end
    return { type = item.type, room_id = roomId, device_ids = ids, set = set }
end

-- Returns how many scenes there are and how the store came back ("json", "missing", "unreadable").
function Scenes.load()
    state.scenes = {}
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    local dropped = 0
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
            if #state.scenes < Scenes.MAX_SCENES then
                state.scenes[#state.scenes + 1] = {
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
        end
    end
    if dropped > 0 then
        Log.warn("scenes", "stored scene steps that are not valid were left out", { steps = dropped })
    end
    return #state.scenes, form
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
