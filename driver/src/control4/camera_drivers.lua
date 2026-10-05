-- DirectorLink's camera agreement, version 1 (1.10.0, ADR-065, docs/CAMERA_DRIVERS.md): how
-- DirectorLink knows a camera driver of DirectorLink Drivers, and what it reads from it.
--
-- The driver behind a camera proxy (camera.c4i) says it follows the agreement with its variable
-- DIRECTORLINK_CAMERA ("1", the agreement's version) and what it is with DIRECTORLINK_CAMERA_KIND
-- ("camera" or "doorbell"). A detection worth alerting: it sets LAST_ALERT (the label: "Person",
-- "Vehicle", ...), then fires its event named Alert. A doorbell press: it sets LAST_RING (ISO 8601,
-- UTC), then fires its event named Ring. Pictures and live video go through Control4's camera
-- proxy, as for every camera (src/control4/camera.lua).
--
-- Every driver numbers its own variables and events, so DirectorLink finds them by name: variables
-- with C4:GetDeviceVariables, events in the driver's <events> as Director gives its driver.xml
-- (C4:GetDeviceData: the "events" tag, else the whole <devicedata>). The marker may come after the
-- driver starts (some drivers add variables once they reach their camera): the camera adapter looks
-- at each camera's marker again, a few cameras a minute (src/adapters/camera.lua lookAgain), and a
-- driver updated in Composer is read again (ADR-059).
--
-- The DirectorLink · Hikvision Camera driver (1.8.0, ADR-056) is known by its file name too, until it
-- sets the marker: its Alert is its event 1, and LAST_ALERT found by name, else its variable 1013,
-- as in 1.8.0. A driver that sets the marker is read by the marker only, whatever its file name (a
-- Hikvision one whose events Director does not name: its event 1 still).

local Classifier = require("src.adapters.classifier")

local CameraDrivers = {}

CameraDrivers.MARKER = "DIRECTORLINK_CAMERA"
CameraDrivers.KIND = "DIRECTORLINK_CAMERA_KIND"
CameraDrivers.LAST_ALERT = "LAST_ALERT"
CameraDrivers.LAST_RING = "LAST_RING"
CameraDrivers.ALERT_EVENT = "Alert"
CameraDrivers.RING_EVENT = "Ring"
-- The agreement's version DirectorLink knows. A driver that says a higher one is read as this one
-- (a later version of the agreement only adds to it).
CameraDrivers.VERSION = 1
-- The Hikvision camera driver's own numbers, when Director names neither (its driver.xml's event 1,
-- the 13th variable it adds).
CameraDrivers.HIKVISION_ALERT_EVENT = 1
CameraDrivers.HIKVISION_LAST_ALERT = 1013

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isCameraProxy(driver)
    local name = string.lower(tostring(driver or ""))
    return name == "camera.c4i" or name == "camera.c4z"
end

-- The driver's variables by name (upper case): name -> { id, value }; nil when Director could not
-- give them.
function CameraDrivers.variables(driverId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(driverId)
    end)
    if not ok or type(variables) ~= "table" then
        return nil
    end
    local byName = {}
    for id, variable in pairs(variables) do
        if type(variable) == "table" and tonumber(id) then
            local name = string.upper(trim(variable.name))
            if name ~= "" and not byName[name] then
                byName[name] = { id = tonumber(id), value = variable.value }
            end
        end
    end
    return byName
end

-- What the variables say of the agreement: its version (a whole number from 1, or nil: no marker)
-- and the kind ("doorbell", else "camera").
function CameraDrivers.marker(variables)
    local marker = variables and variables[CameraDrivers.MARKER]
    local version = marker and tonumber(trim(marker.value)) or nil
    if not version or version < 1 or version ~= math.floor(version) then
        return nil, "camera"
    end
    local kind = variables[CameraDrivers.KIND]
    if kind and string.lower(trim(kind.value)) == "doorbell" then
        return version, "doorbell"
    end
    return version, "camera"
end

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

local function unescape(text)
    return (text:gsub("&(%a+);", function(name)
        return ENTITIES[name]
    end))
end

-- Event names and ids in a driver.xml's events (text as Director gives it): name -> id.
function CameraDrivers.parseEvents(xml)
    local found = {}
    if type(xml) ~= "string" then
        return found
    end
    -- Given as escaped text, once.
    if not xml:find("<event", 1, true) and xml:find("&lt;event", 1, true) then
        xml = unescape(xml)
    end
    local function take(body)
        local id = tonumber(body:match("<id>%s*(%d+)%s*</id>"))
        local name = body:match("<name>(.-)</name>")
        if id and name then
            name = trim(unescape(name))
            if found[name] == nil then
                found[name] = id
            end
        end
    end
    for body in xml:gmatch("<event>(.-)</event>") do
        take(body)
    end
    for body in xml:gmatch("<event%s[^>]*>(.-)</event>") do
        take(body)
    end
    return found
end

-- The driver's events by name: name -> id (empty when Director lists none).
function CameraDrivers.events(driverId)
    local ok, xml = pcall(function()
        return C4:GetDeviceData(driverId, "events")
    end)
    local found = CameraDrivers.parseEvents(ok and xml or nil)
    if next(found) == nil then
        -- Only the first two levels of a tag, says the documentation: the whole <devicedata> then.
        ok, xml = pcall(function()
            return C4:GetDeviceData(driverId)
        end)
        found = CameraDrivers.parseEvents(ok and xml or nil)
    end
    return found
end

-- How many camera proxies the driver has (the agreement: one camera a driver).
local function cameraProxies(registry, driverId)
    local protocol = registry and registry.protocols and registry.protocols[driverId]
    local count = 0
    for _, proxy in ipairs(protocol and protocol.proxies or {}) do
        if isCameraProxy(proxy.driver) then
            count = count + 1
        end
    end
    return count
end

-- What the camera `device`'s driver says of the agreement, as a camera's look again needs it: the
-- first of its drivers with the marker: version, kind; else nil, "camera". `read`: false when
-- Director gave none of its drivers' variables (nothing can be said).
function CameraDrivers.state(device)
    local read = false
    for _, protocol in ipairs(type(device) == "table" and device.protocols or {}) do
        local variables = CameraDrivers.variables(tonumber(protocol.id))
        if variables then
            read = true
            local version, kind = CameraDrivers.marker(variables)
            if version then
                return version, kind, true
            end
        end
    end
    return nil, "camera", read
end

-- The camera `device`'s driver, when it follows the agreement (or is the Hikvision camera driver):
-- { driver (its id), version (nil: known by its file name only), kind, hikvision, alert and ring
-- (event ids, nil when not found), last_alert and last_ring (variable ids, nil when not there yet),
-- proxies (how many camera proxies it has) }; nil for any other camera.
function CameraDrivers.find(device, registry)
    local hikvision = nil
    for _, protocol in ipairs(type(device) == "table" and device.protocols or {}) do
        local driverId = tonumber(protocol.id)
        local variables = driverId and CameraDrivers.variables(driverId) or nil
        local version, kind = CameraDrivers.marker(variables)
        local isHikvision = Classifier.isHikvisionCameraDriver(protocol.driver)
        if version then
            local events = CameraDrivers.events(driverId)
            local info = {
                driver = driverId,
                version = version,
                kind = kind,
                hikvision = isHikvision,
                alert = events[CameraDrivers.ALERT_EVENT],
                ring = kind == "doorbell" and events[CameraDrivers.RING_EVENT] or nil,
                last_alert = variables[CameraDrivers.LAST_ALERT] and variables[CameraDrivers.LAST_ALERT].id or nil,
                last_ring = variables[CameraDrivers.LAST_RING] and variables[CameraDrivers.LAST_RING].id or nil,
                proxies = cameraProxies(registry, driverId),
            }
            if isHikvision then
                info.alert = info.alert or CameraDrivers.HIKVISION_ALERT_EVENT
                info.last_alert = info.last_alert or CameraDrivers.HIKVISION_LAST_ALERT
            end
            return info
        end
        if isHikvision and driverId and not hikvision then
            -- As in 1.8.0 (ADR-056): its event 1, without reading its driver.xml.
            hikvision = {
                driver = driverId,
                kind = "camera",
                hikvision = true,
                alert = CameraDrivers.HIKVISION_ALERT_EVENT,
                last_alert = variables and variables[CameraDrivers.LAST_ALERT] and variables[CameraDrivers.LAST_ALERT].id
                    or CameraDrivers.HIKVISION_LAST_ALERT,
                proxies = cameraProxies(registry, driverId),
            }
        end
    end
    return hikvision
end

-- The id of the driver's variable `name` now (one it added after DirectorLink set the camera up),
-- or nil.
function CameraDrivers.variableId(driverId, name)
    local variables = CameraDrivers.variables(driverId)
    local variable = variables and variables[name]
    return variable and variable.id or nil
end

return CameraDrivers
