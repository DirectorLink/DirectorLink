-- DirectorLink's notification agreement, version 1 (1.13.0, ADR-086, docs/NOTIFY_DRIVERS.md): the
-- drivers that show DirectorLink's alerts on a screen (the DirectorLink · LG TV Notifications driver,
-- any TV or other display driver), and how DirectorLink tells them.
--
-- A target driver sets its string variable DIRECTORLINK_NOTIFY to "1" (the agreement's version) at
-- every start, and DIRECTORLINK_NOTIFY_KINDS to the kinds it shows, comma separated, of doorbell,
-- camera, door, alarm and other (none set: all of them). It takes the command DIRECTORLINK_NOTIFY
-- (C4:SendToDevice to its own driver, never a proxy), with VERSION, ID, KIND, TITLE, MESSAGE and
-- PICTURE (src/core/notify.lua makes them). That command is the only thing DirectorLink ever sends a
-- target (scripts/check_package.py fails the build otherwise).
--
-- Found as the camera agreement's drivers are (ADR-065), by name, never by file name:
-- - At every project read (the start, Refresh Project, Composer's changes) the variables of every
--   driver of the project are read once (C4:GetDeviceVariables): each protocol driver with proxies
--   (Registry.protocols) and each driver without any (a device with no protocol driver of its own).
--   DirectorLink's own driver is not one.
-- - A target's DIRECTORLINK_NOTIFY and DIRECTORLINK_NOTIFY_KINDS are watched
--   (C4:RegisterVariableListener): new kinds count at once, and a marker that goes stops the
--   notifications at once (the target stays known, and one that says "1" again is told again).
-- - Each minute the scheduler's tick has DirectorLink look at the next LOOK_PER_TICK drivers, all in
--   turn: a marker set after the project was read is found then, and a target whose marker is gone
--   two looks in a row is forgotten (one read of a driver Composer is reloading drops nothing).

local CameraDrivers = require("src.control4.camera_drivers")
local Log = require("src.core.log")

local NotifyTargets = {}

NotifyTargets.MARKER = "DIRECTORLINK_NOTIFY"
NotifyTargets.KINDS_VARIABLE = "DIRECTORLINK_NOTIFY_KINDS"
NotifyTargets.COMMAND = "DIRECTORLINK_NOTIFY"
-- The agreement's version DirectorLink speaks; a target that says a higher one is read as this one
-- (a later version only adds).
NotifyTargets.VERSION = 1
-- The kinds a target may show, in the agreement's order.
NotifyTargets.KINDS = { "doorbell", "camera", "door", "alarm", "other" }
-- Drivers looked at again each minute (NotifyTargets.lookAgain).
NotifyTargets.LOOK_PER_TICK = 10

local KNOWN = {}
for _, kind in ipairs(NotifyTargets.KINDS) do
    KNOWN[kind] = true
end

local state = {
    -- driver id -> { id, name, room_id, room_name, version, kinds (kind -> true), markerVariable,
    -- kindsVariable, off (its marker went: told nothing), missing (one look found no marker) }
    targets = {},
    -- The drivers of the project, by id: { id, name, room_id, room_name }, looked at in turn.
    drivers = {},
    nextLook = 1,
}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The agreement's version a value of DIRECTORLINK_NOTIFY says: a whole number from 1, else nil.
function NotifyTargets.version(value)
    local version = tonumber(trim(value))
    if not version or version < 1 or version ~= math.floor(version) then
        return nil
    end
    return version
end

-- The kinds a value of DIRECTORLINK_NOTIFY_KINDS names (kind -> true): every kind for nil (the
-- variable is not there), else those it names, without case or spaces around; a name the agreement
-- does not know is left out, and an empty value shows nothing.
function NotifyTargets.parseKinds(value)
    local kinds = {}
    if value == nil then
        for kind in pairs(KNOWN) do
            kinds[kind] = true
        end
        return kinds
    end
    for part in (tostring(value) .. ","):gmatch("([^,]*),") do
        local kind = string.lower(trim(part))
        if KNOWN[kind] then
            kinds[kind] = true
        end
    end
    return kinds
end

-- The kinds as a list, in the agreement's order.
function NotifyTargets.kindList(kinds)
    local list = {}
    for _, kind in ipairs(NotifyTargets.KINDS) do
        if kinds and kinds[kind] then
            list[#list + 1] = kind
        end
    end
    return list
end

local function kindsText(kinds)
    return table.concat(NotifyTargets.kindList(kinds), ",")
end

-- The drivers of the project a target may be: protocol drivers with proxies, and drivers without
-- any (no protocol driver of their own), in the order of their ids; not DirectorLink itself.
local function driversOf(registry)
    local list, seen = {}, {}
    local own = tonumber(((registry and registry.metadata) or {}).bridgeDeviceId)
    local function add(id, item)
        id = tonumber(id)
        if id and id ~= own and not seen[id] and type(item) == "table" then
            seen[id] = true
            list[#list + 1] = { id = id, name = item.name, room_id = tonumber(item.room_id), room_name = item.room_name }
        end
    end
    for id, protocol in pairs((registry and registry.protocols) or {}) do
        add(id, protocol)
    end
    for id, device in pairs((registry and registry.devices) or {}) do
        if type(device) == "table" and (type(device.protocols) ~= "table" or #device.protocols == 0) then
            add(id, device)
        end
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

local function listen(driverId, variableId)
    if not variableId then
        return
    end
    local ok, err = pcall(function()
        C4:RegisterVariableListener(driverId, variableId)
    end)
    if not ok then
        Log.warn("notify", "a screen's variable could not be watched", { driver_id = driverId, variable_id = variableId, error = tostring(err) })
    end
end

local function unlisten(driverId, variableId)
    if variableId then
        pcall(function()
            C4:UnregisterVariableListener(driverId, variableId)
        end)
    end
end

-- Takes what `variables` (CameraDrivers.variables) say of the driver `driver`: a target from now
-- on, or a target's new kinds and variables (watched again when their ids changed). `how`: why it
-- is read, for the log.
local function take(driver, variables, version, how)
    local marker = variables[NotifyTargets.MARKER]
    local kindsVariable = variables[NotifyTargets.KINDS_VARIABLE]
    local kinds = NotifyTargets.parseKinds(kindsVariable and kindsVariable.value)
    local target = state.targets[driver.id]
    local markerId, kindsId = marker and marker.id, kindsVariable and kindsVariable.id
    if not target then
        target = { id = driver.id }
        state.targets[driver.id] = target
        Log.info("notify", "a screen of DirectorLink's notification agreement", {
            driver_id = driver.id,
            version = version,
            kinds = kindsText(kinds),
            found = how,
        })
    elseif kindsText(target.kinds) ~= kindsText(kinds) or target.off then
        Log.info("notify", "a screen's kinds changed", { driver_id = driver.id, kinds = kindsText(kinds), was = target.off and "off" or kindsText(target.kinds) })
    end
    target.name, target.room_id, target.room_name = driver.name, driver.room_id, driver.room_name
    target.version, target.kinds, target.off, target.missing = version, kinds, nil, nil
    -- Watched before each is registered: Director tells the driver the value as it registers.
    local before = { target.markerVariable, target.kindsVariable }
    target.markerVariable, target.kindsVariable = markerId, kindsId
    if before[1] ~= markerId then
        unlisten(driver.id, before[1])
        listen(driver.id, markerId)
    end
    if before[2] ~= kindsId then
        unlisten(driver.id, before[2])
        listen(driver.id, kindsId)
    end
end

local function forget(target, why)
    state.targets[target.id] = nil
    unlisten(target.id, target.markerVariable)
    unlisten(target.id, target.kindsVariable)
    Log.info("notify", "no longer a screen of DirectorLink's notification agreement", { driver_id = target.id, why = why })
end

-- Reads the project's drivers for targets (main.lua, at every project read, once the adapters have
-- started: they let go of every variable listener first). Returns how many targets there are.
function NotifyTargets.survey(registry)
    state.targets = {}
    state.drivers = driversOf(registry)
    state.nextLook = 1
    for _, driver in ipairs(state.drivers) do
        local variables = CameraDrivers.variables(driver.id)
        local version = variables and NotifyTargets.version(variables[NotifyTargets.MARKER] and variables[NotifyTargets.MARKER].value)
        if version then
            take(driver, variables, version, "project")
        end
    end
    local count = 0
    for _ in pairs(state.targets) do
        count = count + 1
    end
    Log.info("notify", "screens of DirectorLink's notification agreement", { screens = count, drivers = #state.drivers })
    return count
end

-- A watched variable changed (OnWatchedVariableChanged): a target's marker or kinds. Returns true
-- when it was one of them.
function NotifyTargets.onVariableChanged(driverId, variableId, value)
    local target = state.targets[tonumber(driverId)]
    variableId = tonumber(variableId)
    if not target or not variableId then
        return false
    end
    if variableId == target.markerVariable then
        local version = NotifyTargets.version(value)
        if version and target.off then
            target.off, target.version = nil, version
            Log.info("notify", "a screen says it is one again", { driver_id = target.id })
        elseif not version and not target.off then
            target.off = true
            Log.info("notify", "a screen says it is no longer one; told nothing until it says so again", { driver_id = target.id })
        elseif version then
            target.version = version
        end
        return true
    elseif variableId == target.kindsVariable then
        local kinds = NotifyTargets.parseKinds(value)
        if kindsText(kinds) ~= kindsText(target.kinds) then
            Log.info("notify", "a screen's kinds changed", { driver_id = target.id, kinds = kindsText(kinds), was = kindsText(target.kinds) })
            target.kinds = kinds
        end
        return true
    end
    return false
end

-- Looks at the next LOOK_PER_TICK drivers (the scheduler's tick, each minute): a marker that came
-- later makes a target, new kinds or variables are taken, and a target whose marker two looks in a
-- row do not find is forgotten. A driver Director gives no variables for is left as it is. Returns
-- the ids of the drivers it looked at.
function NotifyTargets.lookAgain()
    local looked = {}
    for _ = 1, math.min(NotifyTargets.LOOK_PER_TICK, #state.drivers) do
        if state.nextLook > #state.drivers then
            state.nextLook = 1
        end
        local driver = state.drivers[state.nextLook]
        state.nextLook = state.nextLook + 1
        looked[#looked + 1] = driver.id
        local variables = CameraDrivers.variables(driver.id)
        if variables then
            local marker = variables[NotifyTargets.MARKER]
            local version = NotifyTargets.version(marker and marker.value)
            local target = state.targets[driver.id]
            if version then
                take(driver, variables, version, "looked again")
            elseif target and target.missing then
                forget(target, "its marker is gone")
            elseif target then
                target.missing = true
            end
        end
    end
    return looked
end

-- The targets told now (their marker there), sorted by name: copies { id, name, room_id,
-- room_name, version, kinds (kind -> true) }.
function NotifyTargets.list()
    local list = {}
    for _, target in pairs(state.targets) do
        if not target.off then
            local kinds = {}
            for kind in pairs(target.kinds or {}) do
                kinds[kind] = true
            end
            list[#list + 1] = { id = target.id, name = target.name, room_id = target.room_id, room_name = target.room_name, version = target.version, kinds = kinds }
        end
    end
    table.sort(list, function(a, b)
        local nameA, nameB = string.lower(tostring(a.name or "")), string.lower(tostring(b.name or ""))
        if nameA == nameB then
            return a.id < b.id
        end
        return nameA < nameB
    end)
    return list
end

-- Sends the target `targetId` the agreement's command with `params` (strings). Never waits and never
-- throws: returns true, or false and what went wrong.
function NotifyTargets.send(targetId, params)
    local ok, err = pcall(function()
        C4:SendToDevice(targetId, NotifyTargets.COMMAND, params)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

function NotifyTargets.reset()
    state.targets = {}
    state.drivers = {}
    state.nextLook = 1
end

return NotifyTargets
