-- DirectorLink scenes (docs/SCENES.md): one tap runs several steps, e.g. "all lights off, bedroom
-- AC to 24°, living-room blinds closed". They are the home's, kept in the driver's persistent data;
-- admins make and change them, members and above run them (src/api/handlers/scenes.lua).
-- A step names its devices by id, or by room ("all lights in the living room"), which is worked out
-- when the scene runs, so a light added to the room later is included.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local Scenes = {}

local STORE_KEY = "directorlink_scenes"
Scenes.MAX_SCENES = 50
Scenes.MAX_STEPS = 40
Scenes.MAX_DEVICES = 100
Scenes.ICONS = { moon = true, sun = true, leave = true, movie = true, bulb = true, climate = true, blinds = true, home = true }
Scenes.TYPES = { lights = true, climate = true, blinds = true, relays = true }

local state = { scenes = {} }

local function randomHex(length)
    local hex = ""
    while #hex < length do
        hex = hex .. tostring(C4:UUID("RANDOM")):gsub("[^%x]", ""):lower()
    end
    return hex:sub(1, length)
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

-- A stored step, checked loosely (the API checked it when it was saved).
local function loadStep(item)
    if type(item) ~= "table" or not Scenes.TYPES[item.type] or type(item.set) ~= "table" then
        return nil
    end
    local ids = nil
    if type(item.device_ids) == "table" then
        ids = {}
        for _, id in ipairs(Store.items(item.device_ids)) do
            if tonumber(id) then
                ids[#ids + 1] = tonumber(id)
            end
        end
    end
    local set = {}
    for key, value in pairs(item.set) do
        if type(key) == "string" and (type(value) == "number" or type(value) == "string" or type(value) == "boolean") then
            set[key] = value
        end
    end
    return { type = item.type, room_id = tonumber(item.room_id), device_ids = ids, set = set }
end

function Scenes.load()
    state.scenes = {}
    local data, form = Store.read(STORE_KEY, false)
    for _, item in ipairs(Store.items(type(data) == "table" and data.scenes or nil)) do
        if type(item) == "table" and type(item.id) == "string" and item.id:match("^%x+$") and type(item.name) == "string" then
            local steps = {}
            for _, stepItem in ipairs(Store.items(item.steps)) do
                local step = loadStep(stepItem)
                if step then
                    steps[#steps + 1] = step
                end
            end
            state.scenes[#state.scenes + 1] = {
                id = item.id,
                name = item.name,
                icon = Scenes.ICONS[item.icon] and item.icon or "bulb",
                show_on_home = item.show_on_home == true,
                steps = steps,
                created_at = type(item.created_at) == "string" and item.created_at or Clock.iso(),
                updated_at = type(item.updated_at) == "string" and item.updated_at or Clock.iso(),
                version = tonumber(item.version) or 1,
            }
        end
    end
    return #state.scenes, form
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
    local scene = findRecord(id)
    if not scene then
        return nil, "NOT_FOUND"
    end
    if expected ~= nil and expected ~= scene.version then
        return nil, "VERSION_CONFLICT"
    end
    for _, field in ipairs({ "name", "icon", "show_on_home", "steps" }) do
        if fields[field] ~= nil then
            scene[field] = fields[field]
        end
    end
    scene.version = scene.version + 1
    scene.updated_at = Clock.iso()
    save()
    return copy(scene)
end

function Scenes.delete(id)
    local scene, index = findRecord(id)
    if not scene then
        return false
    end
    table.remove(state.scenes, index)
    save()
    return true
end

return Scenes
