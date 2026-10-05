local CameraDrivers = require("src.control4.camera_drivers")
local Clock = require("src.core.clock")
local DeviceEvents = require("src.control4.device_events")
local Log = require("src.core.log")

-- Camera proxy (camera.c4i). Cameras have no state to watch; snapshots are fetched on demand by
-- src/control4/camera.lua.
--
-- A camera whose driver follows DirectorLink's camera agreement (1.10.0, ADR-065,
-- src/control4/camera_drivers.lua, docs/CAMERA_DRIVERS.md) raises alerts: the driver sets LAST_ALERT
-- (what it saw, by its label: "Person", "Vehicle", "Line Crossing", ...), then fires its event named
-- Alert, once per alert, as its own settings let it through (the DirectorLink · Hikvision Camera
-- driver: the camera's Alert On, the hub's switch and its snooze, ADR-056). A driver that says it is
-- a doorbell (DIRECTORLINK_CAMERA_KIND "doorbell") makes the camera a doorbell too: listed with the
-- doorbells (device.doorbell, Registry.doorbellList), its picture this camera's; its event named Ring
-- (LAST_RING set just before) is a ring, kept as a DoorBird's are. The events are watched on the
-- camera's driver and routed to the camera by the manager. The DirectorLink · Hikvision Camera driver
-- is known by its file name too, until it sets the marker. Other camera drivers raise nothing.
local Camera = {}

-- The Hikvision camera driver's Alert and LAST_ALERT when Director names neither (ADR-056).
Camera.ALERT_EVENT = CameraDrivers.HIKVISION_ALERT_EVENT
Camera.LAST_ALERT_ID = CameraDrivers.HIKVISION_LAST_ALERT
-- What an alert saw, by the drivers' labels (case, spaces, "_" and "-" aside); anything else is
-- "other". The agreement's labels and the Hikvision driver's.
Camera.DETECTIONS = {
    ["motion"] = "motion",
    ["person"] = "person",
    ["vehicle"] = "vehicle",
    ["animal"] = "animal",
    ["package"] = "package",
    ["license plate"] = "license_plate",
    ["licence plate"] = "license_plate",
    ["line crossing"] = "line_crossing",
    ["intrusion"] = "intrusion",
    ["region entrance"] = "region_entrance",
    ["region exiting"] = "region_exiting",
    ["tamper"] = "tamper",
    ["scene change"] = "scene_change",
    ["face"] = "face",
    ["object left"] = "object_left",
    ["object removed"] = "object_removed",
    ["alarm input"] = "alarm_input",
    ["pir"] = "pir",
}
-- A doorbell camera's last rings, newest first (as a DoorBird's).
Camera.MAX_EVENTS = 20
-- LAST_RING is the ring's time when it is within this many seconds of the controller's clock; else
-- the ring is at the moment its event came.
Camera.RING_CLOCK_SECONDS = 120
-- Cameras whose marker is read again each minute (Camera.lookAgain).
Camera.LOOK_PER_TICK = 5

-- Camera id -> its driver's agreement (CameraDrivers.find) for cameras whose events are watched.
local tracked = {}
-- Camera id -> what its driver said when the camera was set up: { version, kind }, for lookAgain.
local seen = {}
local nextLook = 1

function Camera.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "camera.c4i" or driver == "camera.c4z"
end

local function watch(device, driverId, eventId, what)
    local watching, err = DeviceEvents.watch(driverId, eventId)
    if not watching then
        Log.warn("camera", "unable to watch a camera's " .. what, { device_id = device.id, driver_id = driverId, event_id = eventId, error = tostring(err) })
    end
    return watching == true
end

-- The driver's variable `name` (its id, kept in `info[field]`, else found by name now), or nil.
local function read(info, field, name)
    if not info[field] then
        info[field] = CameraDrivers.variableId(info.driver, name)
    end
    if not info[field] then
        return nil
    end
    local ok, value = pcall(function()
        return C4:GetVariable(info.driver, info[field])
    end)
    return ok and value or nil
end

-- The ring's time from LAST_RING (ISO 8601) when within RING_CLOCK_SECONDS of `now`, else `now`.
local function ringTime(info, now)
    local at = Clock.parseIso(read(info, "last_ring", CameraDrivers.LAST_RING))
    if at and math.abs(at - now) <= Camera.RING_CLOCK_SECONDS then
        return Clock.iso(at)
    end
    return Clock.iso(now)
end

-- before: this camera as it was before a project refresh or its driver's update (its rings).
function Camera.initialize(device, registry, before)
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { snapshot = true }
    device.actions = {}
    device.event_source_id = nil
    device.doorbell = nil
    tracked[device.id] = nil
    -- A doorbell camera's rings cannot be read back but the last one: a refresh keeps them.
    local kept = before and type(before.state) == "table" and before.state or {}
    device.state = { last = type(kept.last) == "table" and kept.last or {}, events = type(kept.events) == "table" and kept.events or {}, alert = kept.alert }

    local info = CameraDrivers.find(device, registry)
    seen[device.id] = { version = info and info.version or nil, kind = info and info.version and info.kind or "camera" }
    if not info then
        return true
    end
    if info.proxies > 1 then
        Log.warn("camera", "a camera driver of DirectorLink's camera agreement with several cameras: its alerts and rings are not watched (one camera a driver)", { device_id = device.id, driver_id = info.driver, cameras = info.proxies })
        return true
    end
    local watched = false
    if info.alert and watch(device, info.driver, info.alert, "alerts") then
        device.capabilities.alerts = true
        watched = true
    end
    if info.kind == "doorbell" then
        local rings = info.ring ~= nil and watch(device, info.driver, info.ring, "rings")
        watched = watched or rings
        -- The last ring its driver knows, when DirectorLink has none (it started since).
        if device.state.last.doorbell == nil then
            local last = Clock.parseIso(read(info, "last_ring", CameraDrivers.LAST_RING))
            if last and last <= os.time() + Camera.RING_CLOCK_SECONDS then
                device.state.last.doorbell = Clock.iso(last)
            end
        end
        -- This camera as a doorbell: what /v1/doorbells lists, what rings and who sees it (a
        -- doorbell, src/auth/access.lua), sharing the camera's state.
        device.doorbell = {
            id = device.id,
            name = device.name,
            room_id = device.room_id,
            room_name = device.room_name,
            kind = "doorbell",
            recognized = true,
            supported = true,
            camera_doorbell = true,
            linked = { camera = device.id },
            capabilities = { open = false, events = rings },
            actions = {},
            state = device.state,
        }
    end
    for _, missing in ipairs({ { info.alert, "Alert" }, { info.kind ~= "doorbell" or info.ring, "Ring" } }) do
        if not missing[1] then
            Log.warn("camera", "a camera driver of DirectorLink's camera agreement whose " .. missing[2] .. " event Director does not name: not watched", { device_id = device.id, driver_id = info.driver })
        end
    end
    if watched then
        tracked[device.id] = info
        -- Its alerts and rings come from its driver; the manager routes them here.
        device.event_source_id = info.driver
    end
    Log.debug("camera", "a camera of DirectorLink's camera agreement", {
        device_id = device.id,
        driver_id = info.driver,
        version = info.version,
        kind = info.kind,
        by = info.version and "marker" or "file name",
        alert_event = info.alert,
        ring_event = info.ring,
    })
    return true
end

-- What the alert saw, from LAST_ALERT ("Line Crossing", "License Plate" -> "line_crossing",
-- "license_plate"), or "other".
function Camera.detection(label)
    local text = string.lower(tostring(label or "")):gsub("[_%-]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return Camera.DETECTIONS[text] or "other"
end

-- What the camera's event `eventId` is: "ring", "alert", or nil (not one DirectorLink takes).
function Camera.eventOf(device, eventId)
    local info = type(device) == "table" and tracked[device.id] or nil
    eventId = tonumber(eventId)
    if not info or not eventId then
        return nil
    end
    if info.ring and eventId == info.ring and type(device.doorbell) == "table" then
        return "ring"
    end
    if info.alert and eventId == info.alert and device.capabilities and device.capabilities.alerts then
        return "alert"
    end
    return nil
end

-- The Alert event: the camera's state says what it saw and when (device.state.alert), for the alert
-- the listener sends (src/cloud/alerts.lua). The Ring event of a doorbell camera: its last ring and
-- its rings (device.state.last.doorbell, device.state.events), as a DoorBird's. Anything else is not
-- taken.
function Camera.onDeviceEvent(device, eventId)
    local event = Camera.eventOf(device, eventId)
    local info = tracked[device.id]
    if not event or type(device.state) ~= "table" then
        return false
    end
    if event == "ring" then
        local at = ringTime(info, os.time())
        device.state.last.doorbell = at
        table.insert(device.state.events, 1, { type = "doorbell", at = at })
        while #device.state.events > Camera.MAX_EVENTS do
            table.remove(device.state.events)
        end
        Log.info("doorbell", "the doorbell rang", { device_id = device.id })
        return true
    end
    local what = Camera.detection(read(info, "last_alert", CameraDrivers.LAST_ALERT))
    device.state.alert = { what = what, at = Clock.iso(os.time()) }
    Log.info("camera", "camera alert", { device_id = device.id, what = what })
    return true
end

function Camera.onVariableChanged()
    return false
end

function Camera.execute(device, action)
    if action == "open" and type(device) == "table" and device.doorbell then
        return false, { code = "ACTION_NOT_SUPPORTED", message = "This doorbell has nothing to open" }
    end
    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Cameras have no commands",
    }
end

-- Cameras whose driver now says something else of the agreement than when they were set up: its
-- marker came after the driver started (some drivers add it once they reach their camera), it went,
-- or its kind changed. LOOK_PER_TICK cameras looked at a minute, one after another (the
-- scheduler's tick, through Manager.lookAgain), one Director call each. Returns their ids, for the
-- manager to set them up again.
function Camera.lookAgain(registry)
    local ids = {}
    for id in pairs(seen) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local changed = {}
    for _ = 1, math.min(Camera.LOOK_PER_TICK, #ids) do
        if nextLook > #ids then
            nextLook = 1
        end
        local id = ids[nextLook]
        nextLook = nextLook + 1
        local device = registry and registry.getDevice(id)
        local was = seen[id]
        if device then
            local version, kind, known = CameraDrivers.state(device)
            if known and (version ~= was.version or kind ~= was.kind) then
                changed[#changed + 1] = id
                Log.info("camera", "a camera's driver says something else of DirectorLink's camera agreement; set up again", {
                    device_id = id,
                    version_from = was.version,
                    version_to = version,
                    kind_from = was.kind,
                    kind_to = kind,
                })
            end
        end
    end
    return changed
end

-- The adapters are initialized again on a project refresh: only the cached camera setups go (read
-- again for the next picture). Snapshots already asked for are still fetched and answered.
function Camera.reset()
    tracked = {}
    seen = {}
    nextLook = 1
    require("src.control4.camera").forgetAll()
end

return Camera
