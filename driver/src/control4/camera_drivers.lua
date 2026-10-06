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
-- with C4:GetDeviceVariables. The events: from the driver's own DIRECTORLINK_CAMERA_EVENTS
-- ("Alert=7,Ring=8", optional, recommended) when it sets it, with no other Director call; else by
-- name in the driver's <events> as Director gives its driver.xml (C4:GetDeviceData: the "events" tag,
-- else the whole <devicedata>). The marker may come after the driver starts (some drivers add
-- variables once they reach their camera): the camera adapter looks at each camera's marker again, a
-- few cameras a minute (src/adapters/camera.lua lookAgain), and a driver updated in Composer is read
-- again (ADR-059).
--
-- The DirectorLink · Hikvision Camera driver (1.8.0, ADR-056) is known by its file name too, until it
-- sets the marker: its Alert is its event 1, and LAST_ALERT found by name, else its variable 1013,
-- as in 1.8.0. A driver that sets the marker is read by the marker only, whatever its file name (a
-- Hikvision one whose events neither its DIRECTORLINK_CAMERA_EVENTS nor Director names: its event 1
-- still).

local Classifier = require("src.adapters.classifier")

local CameraDrivers = {}

CameraDrivers.MARKER = "DIRECTORLINK_CAMERA"
CameraDrivers.KIND = "DIRECTORLINK_CAMERA_KIND"
-- Optional: the ids of the driver's events Alert and Ring as its driver.xml numbers them,
-- "Alert=<id>,Ring=<id>" (a camera: "Alert=<id>").
CameraDrivers.EVENTS = "DIRECTORLINK_CAMERA_EVENTS"
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

-- The driver's DIRECTORLINK_CAMERA_EVENTS, for a driver of this kind: { alert, ring (a doorbell's),
-- key (the ids as one text, to compare) } when it names what the kind needs; nil when it is not set
-- (or empty); nil, why when it is set but not "Alert=<id>,Ring=<id>" (a camera: "Alert=<id>"): then
-- it is not used at all. Names without case or spaces around; a whole id from 1. A name the
-- agreement does not know is left for a later version of it.
function CameraDrivers.eventIds(variables, kind)
    local variable = variables and variables[CameraDrivers.EVENTS]
    local value = variable and trim(variable.value) or ""
    if value == "" then
        return nil
    end
    local ids = {}
    for part in (value .. ","):gmatch("([^,]*),") do
        part = trim(part)
        if part ~= "" then
            local name, idText = part:match("^([^=]*)=(.*)$")
            name = string.lower(trim(name))
            idText = trim(idText)
            local id = idText:match("^%d+$") and #idText <= 9 and tonumber(idText) or nil
            if name == "" or not id or id < 1 then
                return nil, "not Name=<id>: " .. part:sub(1, 40)
            end
            if ids[name] then
                return nil, "twice: " .. name
            end
            ids[name] = id
        end
    end
    local alert, ring = string.lower(CameraDrivers.ALERT_EVENT), string.lower(CameraDrivers.RING_EVENT)
    if not ids[alert] then
        return nil, "no " .. CameraDrivers.ALERT_EVENT
    end
    local found = { alert = ids[alert] }
    if kind == "doorbell" then
        if not ids[ring] then
            return nil, "no " .. CameraDrivers.RING_EVENT
        end
        found.ring = ids[ring]
    end
    found.key = "alert=" .. found.alert .. (found.ring and (",ring=" .. found.ring) or "")
    return found
end

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

local function unescape(text)
    return (text:gsub("&(%a+);", function(name)
        return ENTITIES[name]
    end))
end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Event names and ids in a driver.xml's events (text as Director gives it, escaped too): name (in
-- lower case, without spaces around) -> id, the first event of each name in the text; and the names
-- as written, in that order. Comments are left out, CDATA read as the text it is.
function CameraDrivers.parseEvents(xml)
    local found, names = {}, {}
    if type(xml) ~= "string" then
        return found, names
    end
    -- Given as escaped text, once.
    if not xml:find("<event", 1, true) and xml:find("&lt;event", 1, true) then
        xml = unescape(xml)
    end
    -- A CDATA section as the escaped text it stands for (a tag in it is none), then comments out.
    xml = xml:gsub("<!%[CDATA%[(.-)%]%]>", escape):gsub("<!%-%-.-%-%->", "")
    local function take(body)
        local id = tonumber(body:match("<id>%s*(%d+)%s*</id>"))
        local name = body:match("<name>(.-)</name>")
        if id and name then
            name = trim(unescape(name))
            local key = string.lower(name)
            if key ~= "" and found[key] == nil then
                found[key] = id
                names[#names + 1] = name
            end
        end
    end
    -- Each <event> (or <event ...>) in the order of the text; <events> and <event/> are not one.
    local position = 1
    while true do
        local start, finish = xml:find("<event", position, true)
        if not start then
            break
        end
        position = finish + 1
        local after = xml:sub(finish + 1, finish + 1)
        if after == ">" or after:match("^%s$") then
            local close = xml:find(">", finish + 1, true)
            if not close then
                break
            end
            position = close + 1
            if xml:sub(close - 1, close - 1) ~= "/" then
                local ending = xml:find("</event>", close + 1, true)
                if not ending then
                    break
                end
                take(xml:sub(close + 1, ending - 1))
                position = ending + #"</event>"
            end
        end
    end
    return found, names
end

-- What a C4:GetDeviceData call gave, for the log: its shape, not its text.
local function shape(ok, value)
    if not ok then
        return "an error"
    end
    if type(value) ~= "string" then
        return value == nil and "nothing" or ("a " .. type(value))
    end
    if value == "" then
        return "an empty text"
    end
    local tags = select(2, value:gsub("<event[%s>]", "")) + select(2, value:gsub("&lt;event[%s&]", ""))
    return string.format("a text of %d characters with %d <event> tags%s", #value, tags,
        value:find("&lt;event", 1, true) and " (escaped)" or "")
end

-- The driver's events by name, from what Director gives of its driver.xml: name (lower case) -> id
-- (empty when Director names none); and for the log what Director gave: { events_tag, devicedata
-- (when it was asked), named (how many names), names (the first 20 as written) }.
function CameraDrivers.events(driverId)
    local ok, xml = pcall(function()
        return C4:GetDeviceData(driverId, "events")
    end)
    local found, names = CameraDrivers.parseEvents(ok and xml or nil)
    local given = { events_tag = shape(ok, xml) }
    if next(found) == nil then
        -- Only the first two levels of a tag, says the documentation: the whole <devicedata> then.
        ok, xml = pcall(function()
            return C4:GetDeviceData(driverId)
        end)
        found, names = CameraDrivers.parseEvents(ok and xml or nil)
        given.devicedata = shape(ok, xml)
    end
    given.named = #names
    local shown = {}
    for index = 1, math.min(#names, 20) do
        shown[index] = names[index]
    end
    given.names = table.concat(shown, ", ") .. (#names > 20 and ", ..." or "")
    return found, given
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
-- first of its drivers with the marker: version, kind, true, and its DIRECTORLINK_CAMERA_EVENTS
-- (eventIds' key, nil when not set as the agreement says); else nil, "camera". The third value
-- (`read`): false when Director gave none of its drivers' variables (nothing can be said).
function CameraDrivers.state(device)
    local read = false
    for _, protocol in ipairs(type(device) == "table" and device.protocols or {}) do
        local variables = CameraDrivers.variables(tonumber(protocol.id))
        if variables then
            read = true
            local version, kind = CameraDrivers.marker(variables)
            if version then
                local ids = CameraDrivers.eventIds(variables, kind)
                return version, kind, true, ids and ids.key or nil
            end
        end
    end
    return nil, "camera", read, nil
end

-- The camera `device`'s driver, when it follows the agreement (or is the Hikvision camera driver):
-- { driver (its id), version (nil: known by its file name only), kind, hikvision, alert and ring
-- (event ids, nil when not found), events_by (how they were found: "by DIRECTORLINK_CAMERA_EVENTS",
-- "by name from Director", "Hikvision event 1" or "not found"), events_key (its
-- DIRECTORLINK_CAMERA_EVENTS when used), events_problem and events_value (one set otherwise: why it
-- was not used, what it said), director (what Director gave of its driver.xml, when asked: shape
-- only, CameraDrivers.events), last_alert and last_ring (variable ids, nil when not there yet),
-- proxies (how many camera proxies it has) }; nil for any other camera.
function CameraDrivers.find(device, registry)
    local hikvision = nil
    for _, protocol in ipairs(type(device) == "table" and device.protocols or {}) do
        local driverId = tonumber(protocol.id)
        local variables = driverId and CameraDrivers.variables(driverId) or nil
        local version, kind = CameraDrivers.marker(variables)
        local isHikvision = Classifier.isHikvisionCameraDriver(protocol.driver)
        if version then
            local info = {
                driver = driverId,
                version = version,
                kind = kind,
                hikvision = isHikvision,
                last_alert = variables[CameraDrivers.LAST_ALERT] and variables[CameraDrivers.LAST_ALERT].id or nil,
                last_ring = variables[CameraDrivers.LAST_RING] and variables[CameraDrivers.LAST_RING].id or nil,
                proxies = cameraProxies(registry, driverId),
            }
            local ids, problem = CameraDrivers.eventIds(variables, kind)
            if ids then
                -- The driver's own ids: nothing more to ask Director.
                info.alert, info.ring, info.events_key = ids.alert, ids.ring, ids.key
                info.events_by = "by DIRECTORLINK_CAMERA_EVENTS"
            else
                if problem then
                    info.events_problem = problem
                    info.events_value = tostring(variables[CameraDrivers.EVENTS].value):sub(1, 80)
                end
                local events, given = CameraDrivers.events(driverId)
                info.director = given
                info.alert = events[string.lower(CameraDrivers.ALERT_EVENT)]
                info.ring = kind == "doorbell" and events[string.lower(CameraDrivers.RING_EVENT)] or nil
                info.events_by = (info.alert or info.ring) and "by name from Director" or "not found"
                if isHikvision and not info.alert then
                    info.alert = CameraDrivers.HIKVISION_ALERT_EVENT
                    info.events_by = "Hikvision event 1"
                end
            end
            if isHikvision then
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
                events_by = "Hikvision event 1",
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
