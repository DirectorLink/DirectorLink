-- Composer changes to the project, as Director announces them to drivers (DriverWorks system
-- events, C4:RegisterSystemEvent): an item (a device, a proxy, a room) added, removed, renamed or
-- moved, a driver added, a project loaded, and Composer's Refresh Navigators (OnPIP). An event is
-- only a sign that the project changed: the project is read again from Director (main.lua), once
-- no event has come for QUIET_MS (Composer sends bursts: a new device brings its proxies) and at
-- the latest MAX_WAIT_MS after the first one. The payloads are not documented, OnItemMoved's least
-- of all; each one is logged at debug level so it can be read on a real controller.
-- Without system events (no C4SystemEvents, or Director refuses them) the Composer action Refresh
-- Project does the same by hand.

local Clock = require("src.core.clock")
local Log = require("src.core.log")

local ProjectEvents = {}

ProjectEvents.QUIET_MS = 5000
ProjectEvents.MAX_WAIT_MS = 30000
-- Not OnProjectChanged (deprecated since OS 2.10), nor OnItemDataChanged or OnDeviceDataChanged,
-- which may come with any driver's data write.
ProjectEvents.NAMES = {
    "OnItemAdded",
    "OnItemRemoved",
    "OnItemNameChanged",
    "OnItemMoved",
    "OnPIP",
    "OnDriverAdded",
    "OnProjectLoaded",
}

-- Parameters that name the item an event is about (the others name a parent, a position).
local ITEM_PARAMS = { iditem = true, iddevice = true, id = true, itemid = true, deviceid = true }

local state = {
    started = false,
    watched = {}, -- event name -> true
    count = 0,
    ownIds = {}, -- DirectorLink's own device
    onChange = nil,
    timer = nil,
    firstAt = nil,
    pending = {}, -- names of the events a refresh waits for, first seen first
}

local function cancelTimer()
    local timer = state.timer
    state.timer = nil
    if timer then
        pcall(function()
            timer:Cancel()
        end)
    end
end

-- options: onChange(events) runs the refresh (events: the names, e.g. "OnItemMoved, OnPIP");
-- ownIds: DirectorLink's own device ids. Registers once per driver run; a later call only takes
-- the new options. Returns how many events are watched.
function ProjectEvents.start(options)
    state.onChange = options.onChange
    state.ownIds = {}
    for _, id in ipairs(options.ownIds or {}) do
        if tonumber(id) then
            state.ownIds[tonumber(id)] = true
        end
    end
    if state.started then
        return state.count
    end
    state.started = true

    local ids = type(C4SystemEvents) == "table" and C4SystemEvents or nil
    local watched = {}
    for _, name in ipairs(ProjectEvents.NAMES) do
        local id = ids and tonumber(ids[name])
        if id then
            local ok = pcall(function()
                C4:RegisterSystemEvent(id, 0)
            end)
            if ok then
                state.watched[name] = true
                watched[#watched + 1] = name
            end
        end
    end
    state.count = #watched
    if #watched == 0 then
        Log.warn("discovery", "Director does not announce Composer changes to DirectorLink; after changing the project, run the action Refresh Project")
    else
        Log.info("discovery", "watching the project for Composer changes", { events = table.concat(watched, ", ") })
    end
    return state.count
end

-- A refresh that was waiting is not needed any more (one runs now, or the driver stops).
function ProjectEvents.cancel()
    cancelTimer()
    state.firstAt = nil
    state.pending = {}
end

function ProjectEvents.stop()
    ProjectEvents.cancel()
    if state.started then
        pcall(function()
            C4:UnregisterAllSystemEvents()
        end)
    end
    state.started = false
    state.watched = {}
    state.count = 0
end

local function refresh()
    local events = table.concat(state.pending, ", ")
    ProjectEvents.cancel()
    if state.onChange then
        local ok, err = pcall(state.onChange, events)
        if not ok then
            Log.error("discovery", "project refresh failed", { events = events, error = tostring(err) })
        end
    end
end

local function schedule(name)
    local now = Clock.millis()
    state.firstAt = state.firstAt or now
    local known = false
    for _, pending in ipairs(state.pending) do
        known = known or pending == name
    end
    if not known then
        state.pending[#state.pending + 1] = name
    end
    cancelTimer()
    local delay = math.min(ProjectEvents.QUIET_MS, ProjectEvents.MAX_WAIT_MS - (now - state.firstAt))
    if delay <= 0 then
        refresh()
        return
    end
    local ok, timer = pcall(function()
        return C4:SetTimer(delay, function()
            state.timer = nil
            refresh()
        end, false)
    end)
    if ok and timer then
        state.timer = timer
    else
        -- No timer: at once, rather than never.
        refresh()
    end
end

-- The event's name: the first name attribute of its XML (as Snap One's own drivers read it).
local function eventName(text)
    local name = text:match('name%s*=%s*"([^"]*)"')
    if name and state.watched[name] then
        return name
    end
    for _, candidate in ipairs(ProjectEvents.NAMES) do
        if state.watched[candidate] and text:find(candidate, 1, true) then
            return candidate
        end
    end
    return nil
end

-- True when every item the event names is DirectorLink itself: nothing the API serves changed.
local function onlyDirectorLink(text)
    local items = 0
    for param, value in text:gmatch('<param[^>]-name%s*=%s*"([^"]+)"[^>]*>%s*(%d+)%s*</param>') do
        if ITEM_PARAMS[string.lower(param)] then
            if not state.ownIds[tonumber(value)] then
                return false
            end
            items = items + 1
        end
    end
    return items > 0
end

-- Director's OnSystemEvent(data), for the events registered above.
function ProjectEvents.onSystemEvent(data)
    local ok, err = pcall(function()
        local text = tostring(data or "")
        local name = eventName(text)
        if not name then
            return
        end
        Log.debug("discovery", "project event", { event = name, data = text:sub(1, 1000) })
        if name ~= "OnPIP" and onlyDirectorLink(text) then
            return
        end
        schedule(name)
    end)
    if not ok then
        Log.warn("discovery", "a project event could not be handled", { error = tostring(err) })
    end
end

-- Whether a refresh is waiting for events to stop (for tests and the log).
function ProjectEvents.waiting()
    return state.timer ~= nil
end

return ProjectEvents
