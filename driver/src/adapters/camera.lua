local Classifier = require("src.adapters.classifier")
local Clock = require("src.core.clock")
local DeviceEvents = require("src.control4.device_events")
local Log = require("src.core.log")

-- Camera proxy (camera.c4i). Cameras have no state to watch; snapshots are fetched on demand by
-- src/control4/camera.lua.
--
-- A camera on the DirectorLink · Hikvision Camera driver (DirectorLink-Hikvision-Camera.c4z, 1.8.0,
-- ADR-056) also raises alerts: its driver fires its event 1, Alert, when a detection gets through
-- the camera's Alert On filter, the hub's alerts switch and its snooze, once per alert (not again
-- while that alert lasts), with LAST_ALERT (what it saw, by its label: "Person", "Vehicle", "Line
-- Crossing", ...) set just before. The event is watched on that driver and routed to the camera by
-- the manager; LAST_ALERT is read then. Other camera drivers raise none.
local Camera = {}

Camera.ALERT_EVENT = 1
-- The driver's variables are numbered from 1001 in the order it adds them; LAST_ALERT is the 13th.
-- Found by name, else by this id.
Camera.LAST_ALERT_ID = 1013
-- What an alert saw, by the driver's labels; anything else is "other".
Camera.DETECTIONS = {
    ["motion"] = "motion",
    ["person"] = "person",
    ["vehicle"] = "vehicle",
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

-- Camera id -> { driver, lastAlert (its LAST_ALERT's id) } for cameras that raise alerts.
local tracked = {}

function Camera.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "camera.c4i" or driver == "camera.c4z"
end

-- The camera's DirectorLink · Hikvision Camera driver, or nil.
local function alertDriver(device)
    for _, protocol in ipairs(device.protocols or {}) do
        if Classifier.isHikvisionCameraDriver(protocol.driver) then
            return tonumber(protocol.id)
        end
    end
    return nil
end

local function lastAlertId(driverId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(driverId)
    end)
    for id, variable in pairs(ok and type(variables) == "table" and variables or {}) do
        if type(variable) == "table" and string.upper(tostring(variable.name or "")) == "LAST_ALERT" and tonumber(id) then
            return tonumber(id)
        end
    end
    return Camera.LAST_ALERT_ID
end

function Camera.initialize(device)
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { snapshot = true }
    device.state = {}
    device.actions = {}
    local driverId = alertDriver(device)
    if driverId then
        local watching, err = DeviceEvents.watch(driverId, Camera.ALERT_EVENT)
        if watching then
            tracked[device.id] = { driver = driverId, lastAlert = lastAlertId(driverId) }
            -- Its alerts come from its driver; the manager routes them here.
            device.event_source_id = driverId
            device.capabilities.alerts = true
        else
            Log.warn("camera", "unable to watch a camera's alerts", { device_id = device.id, driver_id = driverId, error = tostring(err) })
        end
    end
    return true
end

-- What the alert saw, from LAST_ALERT ("Line Crossing" -> "line_crossing"), or "other".
function Camera.detection(label)
    local text = string.lower(tostring(label or "")):gsub("^%s+", ""):gsub("%s+$", "")
    return Camera.DETECTIONS[text] or "other"
end

-- The Alert event: the camera's state says what it saw and when (device.state.alert), for the alert
-- the listener sends (src/cloud/alerts.lua). Anything else is not taken.
function Camera.onDeviceEvent(device, eventId)
    local info = tracked[device.id]
    if not info or tonumber(eventId) ~= Camera.ALERT_EVENT then
        return false
    end
    local ok, label = pcall(function()
        return C4:GetVariable(info.driver, info.lastAlert)
    end)
    local what = Camera.detection(ok and label or nil)
    device.state = { alert = { what = what, at = Clock.iso(os.time()) } }
    Log.info("camera", "camera alert", { device_id = device.id, what = what })
    return true
end

function Camera.onVariableChanged()
    return false
end

function Camera.execute()
    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Cameras have no commands",
    }
end

-- The adapters are initialized again on a project refresh: only the cached camera setups go (read
-- again for the next picture). Snapshots already asked for are still fetched and answered.
function Camera.reset()
    tracked = {}
    require("src.control4.camera").forgetAll()
end

return Camera
