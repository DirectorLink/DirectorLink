-- Composer changes to the project, as Director announces them to drivers (DriverWorks system
-- events, C4:RegisterSystemEvent): an item (a device, a proxy, a room) added, removed, renamed or
-- moved, a driver added, a project loaded, and OnPIP (Composer's Refresh Navigators; Director also
-- sends it when bindings, device names or media change). An event is only a sign that the project
-- changed: the project is read again from Director (main.lua), once no event has come for QUIET_MS
-- (Composer sends bursts: a new device brings its proxies) and at the latest MAX_WAIT_MS after the
-- first one. OnPIP alone does it at most once every PIP_INTERVAL_MS, with one more read at the end
-- of that time for the OnPIP that came meanwhile: it may come often, and one read of a large
-- project is over a thousand Director calls. A read that fails (Director busy loading a project)
-- is tried once more RETRY_MS later. The payloads are not documented, OnItemMoved's least of all;
-- each one is logged at debug level so it can be read on a real controller, and one without a name
-- known here still counts: Director sends only the events registered here.
-- Without system events (no C4SystemEvents, or Director refuses them) the Composer action Refresh
-- Project does the same by hand.

local Clock = require("src.core.clock")
local Log = require("src.core.log")

local ProjectEvents = {}

ProjectEvents.QUIET_MS = 5000
ProjectEvents.MAX_WAIT_MS = 30000
ProjectEvents.PIP_INTERVAL_MS = 120000
ProjectEvents.RETRY_MS = 60000
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

-- What an event whose name is not known here is called in the log and a refresh's reason.
local UNNAMED = "unnamed event"

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
    retry = false, -- the refresh that waits is the second try of one that failed
    pipAt = nil, -- when OnPIP alone last started a refresh
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

-- options: onChange(events) runs the refresh (events: the names, e.g. "OnItemMoved, OnPIP") and
-- returns false when it failed; ownIds: DirectorLink's own device ids. Registers once per driver
-- run; a later call only takes the new options. Returns how many events are watched.
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
    state.retry = false
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
    state.pipAt = nil
end

local wait

local function pipOnly()
    return #state.pending == 1 and state.pending[1] == "OnPIP"
end

local function refresh()
    local names, retry = state.pending, state.retry
    local events = table.concat(names, ", ")
    if pipOnly() then
        state.pipAt = Clock.millis()
    end
    ProjectEvents.cancel()
    if not state.onChange then
        return
    end
    local ok, result = pcall(state.onChange, events)
    if not ok then
        Log.error("discovery", "project refresh failed", { events = events, error = tostring(result) })
    end
    if (not ok or result == false) and not retry then
        -- Director may be busy (loading a project, say): once more, a minute later.
        Log.info("discovery", "the project refresh is tried again", { events = events, in_seconds = ProjectEvents.RETRY_MS / 1000 })
        state.pending = names
        state.retry = true
        wait(ProjectEvents.RETRY_MS)
    end
end

-- Refreshes `delay` ms from now (instead of any refresh that waited).
wait = function(delay)
    cancelTimer()
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

local function schedule(name)
    local now = Clock.millis()
    local known = false
    for _, pending in ipairs(state.pending) do
        known = known or pending == name
    end
    if not known then
        state.pending[#state.pending + 1] = name
    end
    -- A new change: should its refresh fail, it is tried again too.
    state.retry = false
    -- OnPIP alone, sooner than PIP_INTERVAL_MS after the refresh it last started: one refresh at
    -- the end of that time, which later ones wait for too.
    if pipOnly() and state.pipAt and now - state.pipAt < ProjectEvents.PIP_INTERVAL_MS then
        if not state.timer then
            wait(state.pipAt + ProjectEvents.PIP_INTERVAL_MS - now)
        end
        return
    end
    state.firstAt = state.firstAt or now
    local delay = math.min(ProjectEvents.QUIET_MS, ProjectEvents.MAX_WAIT_MS - (now - state.firstAt))
    if delay <= 0 then
        refresh()
        return
    end
    wait(delay)
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
        Log.debug("discovery", "project event", { event = name or UNNAMED, data = text:sub(1, 1000) })
        if name ~= "OnPIP" and onlyDirectorLink(text) then
            return
        end
        schedule(name or UNNAMED)
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
