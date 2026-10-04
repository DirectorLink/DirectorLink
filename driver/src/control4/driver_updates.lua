-- A device whose driver is updated in Composer is set up again (1.8.0, ADR-059): what an adapter
-- reads only when it sets a device up (its variables, what it supports) may change with its driver.
-- The owner's refrigerator driver 1.1.0 added REPORTED_VARIABLES and TEMPERATURE_UNIT, which the
-- refrigerator adapter reads at its setup: nothing changed until a Refresh Project.
--
-- Director announces no driver update to other drivers: Snap One's list of system events has
-- OnDriverAdded and OnDriverDisabled, nothing for an update, and the project events DirectorLink
-- watches (src/control4/project_events.lua) did not come for the refrigerator's. So DirectorLink
-- looks: each driver's <version> (C4:GetDeviceData(id, "version"), documented from OS 2.10, the
-- number Composer compares when it updates a driver) is read when its devices are set up, and again,
-- a few drivers a minute (CHECK_PER_TICK, from the scheduler's minute tick), one after another. A
-- driver whose version changed has every device an adapter took on it set up again
-- (src/adapters/manager.lua setUpAgain), each logged; nothing else is touched. A home with 200
-- drivers has each looked at within 8 minutes, one Director call a driver.
--
-- What it does not see: an update that keeps the driver's version number (the installer runs
-- Refresh Project then), and a driver Director gives no version for (it is not watched).

local Log = require("src.core.log")

local DriverUpdates = {}

-- Drivers looked at each minute.
DriverUpdates.CHECK_PER_TICK = 25

local state = {
    manager = nil,
    order = {}, -- driver ids, in the order they are looked at
    next = 1, -- the next to look at
    drivers = {}, -- driver id -> { version, devices = { device id, ... } }
    unavailable = false, -- Director gave no driver a version (logged once)
}

-- The driver's version as Director gives it, or nil.
local function versionOf(driverId)
    local ok, value = pcall(function()
        return C4:GetDeviceData(driverId, "version")
    end)
    if not ok or value == nil then
        return nil
    end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or #text > 40 then
        return nil
    end
    return text
end

-- After a project read set every device up (main.lua): the version of each driver behind a device
-- an adapter took is what they were set up with. `manager`: src/adapters/manager.lua. Returns how
-- many drivers are watched.
function DriverUpdates.track(manager)
    state.manager = manager
    state.order, state.next, state.drivers = {}, 1, {}
    local drivers = 0
    for id, device in pairs(manager.matchedDevices()) do
        for _, driverId in ipairs(manager.driverIds(device)) do
            local driver = state.drivers[driverId]
            if not driver then
                local version = versionOf(driverId)
                drivers = drivers + 1
                driver = { version = version, devices = {} }
                state.drivers[driverId] = driver
                if version then
                    state.order[#state.order + 1] = driverId
                end
            end
            driver.devices[#driver.devices + 1] = id
        end
    end
    table.sort(state.order)
    -- Logged once a run: an older Director, or one that keeps no versions.
    if drivers > 0 and #state.order == 0 and not state.unavailable then
        state.unavailable = true
        Log.warn("adapters", "Director gives no driver versions: a driver updated in Composer is read again only by Refresh Project", { drivers = drivers })
    end
    return #state.order
end

-- Looks at the next CHECK_PER_TICK drivers (the scheduler's minute tick). Returns how many devices
-- were set up again.
function DriverUpdates.tick()
    local manager = state.manager
    local count = #state.order
    if not manager or count == 0 then
        return 0
    end
    local updated = {}
    for _ = 1, math.min(DriverUpdates.CHECK_PER_TICK, count) do
        if state.next > count then
            state.next = 1
        end
        local driverId = state.order[state.next]
        state.next = state.next + 1
        local driver = state.drivers[driverId]
        local version = versionOf(driverId)
        if version and version ~= driver.version then
            updated[#updated + 1] = { id = driverId, from = driver.version, to = version, devices = driver.devices }
            driver.version = version
        end
    end
    local total = 0
    for _, driver in ipairs(updated) do
        local results = manager.setUpAgain(driver.devices)
        for _, deviceId in ipairs(driver.devices) do
            if results[deviceId] ~= nil then
                total = total + 1
                local device = manager.matchedDevices()[deviceId] or {}
                Log.info("adapters", "a device's driver was updated in Composer; set up again", {
                    device_id = deviceId,
                    driver_id = driver.id,
                    from = driver.from,
                    to = driver.to,
                    supported = results[deviceId],
                    error = not results[deviceId] and device.adapter_error or nil,
                })
            end
        end
    end
    return total
end

-- The version DirectorLink last saw for a driver (tests and the log).
function DriverUpdates.version(driverId)
    local driver = state.drivers[tonumber(driverId)]
    return driver and driver.version or nil
end

return DriverUpdates
