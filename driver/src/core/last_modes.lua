-- The mode each thermostat was last in that was not off (1.10.0, ADR-070, docs/SCENES.md). A
-- scene's climate step with mode "on" turns a thermostat that is off back on in it, sending nothing
-- else, so it comes back as it was before it was turned off; the app's commands do the same ("turn
-- on the AC in the living room"), from `last_mode` in GET /v1/thermostats. It is seen whenever
-- DirectorLink sees a thermostat in a mode other than off, whoever set it (Control4's apps, a
-- keypad, Composer programming, DirectorLink): when its adapter starts it (the driver starting, a
-- project refresh, a driver update) and at every change of its variables (src/adapters/manager.lua).
-- Kept in a small store of its own, written only when a thermostat's last mode changes; not in
-- backups (it is seen again).

local Log = require("src.core.log")
local Store = require("src.core.store")

local LastModes = {}

local STORE_KEY = "directorlink_last_modes"
-- More thermostats than a home has: past that, those no longer in the project make room.
LastModes.MAX = 200

-- `modes`: thermostat id -> mode, read from the store at the first use (nil until then).
local state = { modes = nil, count = 0 }

-- A mode as the API names it ("cool", "heat", "auto", "dry"), or nil for off and for none.
local function modeOf(value)
    local text = string.lower(tostring(value or "")):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if text == "" or text == "off" or #text > 32 then
        return nil
    end
    return text
end

local function load()
    if state.modes then
        return
    end
    state.modes, state.count = {}, 0
    local data, form = Store.read(STORE_KEY, false)
    if form == "unreadable" then
        Log.warn("climate", "the thermostats' last modes could not be read; they are seen again as the thermostats change")
    end
    if type(data) == "table" and type(data.modes) == "table" then
        for id, mode in pairs(data.modes) do
            id, mode = tonumber(id), modeOf(mode)
            if id and id == math.floor(id) and id > 0 and mode and state.count < LastModes.MAX then
                state.modes[id] = mode
                state.count = state.count + 1
            end
        end
    end
end

local function save()
    local modes = {}
    for id, mode in pairs(state.modes) do
        modes[tostring(id)] = mode
    end
    if not Store.write(STORE_KEY, { version = 1, modes = modes }, false) then
        Log.warn("climate", "could not save the thermostats' last modes")
    end
end

-- Thermostats no longer in the project leave the store.
local function prune(registry)
    for id in pairs(state.modes) do
        local device = registry and registry.getDevice(id)
        if not device or device.kind ~= "climate" then
            state.modes[id] = nil
            state.count = state.count - 1
        end
    end
end

-- `device`: a thermostat as its adapter keeps it. Remembers its mode when it is not off; returns
-- true when its last mode changed (and was saved).
function LastModes.saw(device, registry)
    if type(device) ~= "table" or device.kind ~= "climate" or type(device.state) ~= "table" then
        return false
    end
    local id, mode = tonumber(device.id), modeOf(device.state.hvac_mode)
    if not id or not mode then
        return false
    end
    load()
    if state.modes[id] == mode then
        return false
    end
    if not state.modes[id] then
        if state.count >= LastModes.MAX then
            prune(registry)
        end
        if state.count >= LastModes.MAX then
            return false
        end
        state.count = state.count + 1
    end
    state.modes[id] = mode
    save()
    Log.debug("climate_state", "thermostat's last mode", { device_id = id, mode = mode })
    return true
end

-- The last mode of thermostat `id` that was not off, or nil when none is known yet.
function LastModes.get(id)
    load()
    return state.modes[tonumber(id)]
end

return LastModes
