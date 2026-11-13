-- Arming and disarming the home's alarm (1.15.0, ADR-091): the one place in DirectorLink that sends
-- a security partition anything. Only POST /v1/alarm/{partitionId}/arm and /disarm use it
-- (src/api/handlers/alarm.lua), after checking Alarm Status and Alarm Control in Composer, the
-- person's permission, the seal, the partition and the code; scripts/check_package.py fails the
-- build when another module names a partition command or loads this one.
--
-- What it sends is what a Control4 screen sends a partition's proxy (security.c4i), and what
-- Home Assistant's Control4 library sends it through Director: PARTITION_ARM with ArmType (one of
-- the modes its driver declares, <arm_states> in its capabilities) and UserCode, PARTITION_DISARM
-- with UserCode, both with InterfaceID "DirectorLink". The proxy hands them to the alarm's driver,
-- which sends the code to the panel, and the panel checks it. Never ARM_CANCEL (a driver may cancel
-- an exit delay with a code of its own), emergencies, key presses or a default code, and never the
-- InterfaceID of Composer's programming ("DirectorProgramming"), with which a driver may arm or
-- disarm with a code of its own: every command here carries the code a person typed for it.
--
-- The code is never kept, logged or put in an error: it goes into the command's parameters and
-- nowhere else, and the command is sent with LogCommand false (SendToDevice's fifth argument, as
-- DirectorLink · DoorBird sends a camera's login), which drops Director's INFO line for it. Director
-- logging at its debug level still writes the command with its parameters into director.log, the
-- code with it (seen on the owner's controller, 2026-11-13: root-only, in memory, rotated away
-- within 2 to 3 hours, never on flash): ADR-091's correction. Nothing here logs at all.
--
-- What it reads, for GET /v1/alarm: the modes a partition arms in (its driver's <arm_states>, read
-- again after MODES_SECONDS, so that a driver updated in Composer is followed), and whether arming and disarming can work now, as a driver
-- of DirectorLink's alarm agreement says it (docs/ALARM_DRIVERS.md): DIRECTORLINK_ALARM = "1" and
-- DIRECTORLINK_ALARM_CONTROL = "1" (the DirectorLink · PIMA FORCE driver says "0" while its panel
-- only reports). A driver that does not keep the agreement, any other Control4 alarm, is not asked:
-- what a command did shows in the partition's state.

local AlarmControl = {}

AlarmControl.INTERFACE_ID = "DirectorLink"
AlarmControl.MARKER = "DIRECTORLINK_ALARM"
AlarmControl.CONTROL_VARIABLE = "DIRECTORLINK_ALARM_CONTROL"
-- At most this many modes a partition, each at most this many bytes (whole characters), so that
-- GET /v1/alarm, which is padded to its longest form, stays small.
AlarmControl.MAX_MODES = 8
AlarmControl.MODE_BYTES = 32
-- How long a driver's DIRECTORLINK_ALARM_CONTROL is taken as read: GET /v1/alarm is asked every
-- 10 s while the app is open, by every device that has it open.
AlarmControl.AVAILABLE_SECONDS = 5
-- How long a driver's modes are taken as read.
AlarmControl.MODES_SECONDS = 600

-- driver file name (lower case), or "#<driver id>" without one -> { at = os.time(), modes = list }
local modesCache = {}
-- driver id -> { at = os.time(), value = true | false | nil (no agreement) }
local availableCache = {}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(text)
    return (text:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- Cut to `bytes` bytes, never inside a character.
local function cut(text, bytes)
    if #text <= bytes then
        return text
    end
    local stop = bytes
    while stop > 0 and text:byte(stop + 1) >= 128 and text:byte(stop + 1) < 192 do
        stop = stop - 1
    end
    return text:sub(1, stop)
end

-- The modes in a driver's capabilities, as Director gives them (the "capabilities" tag's content,
-- or the whole <devicedata>; escaped once too): "Away,Home,Night" -> { "Away", "Home", "Night" },
-- in the driver's order, without empty or repeated ones, control characters left out. An empty
-- list when the driver declares none.
function AlarmControl.parseModes(xml)
    local modes = {}
    if type(xml) ~= "string" or trim(xml) == "" then
        return modes
    end
    if not xml:find("<", 1, true) and xml:find("&lt;", 1, true) then
        xml = unescape(xml)
    end
    xml = xml:gsub("<!%-%-.-%-%->", "")
    if xml:find("<devicedata", 1, true) then
        xml = xml:match("<capabilities%s*>(.-)</capabilities%s*>") or xml:match("<capabilities%s[^>]*>(.-)</capabilities%s*>") or ""
    end
    local list = xml:match("<arm_states%s*>(.-)</arm_states%s*>")
    if not list then
        return modes
    end
    local seen = {}
    for item in unescape(list):gmatch("[^,]+") do
        local mode = cut(trim(item:gsub("%c", "")), AlarmControl.MODE_BYTES)
        if mode ~= "" and not seen[mode] and #modes < AlarmControl.MAX_MODES then
            seen[mode] = true
            modes[#modes + 1] = mode
        end
    end
    return modes
end

local function protocolsOf(device)
    return type(device) == "table" and type(device.protocols) == "table" and device.protocols or {}
end

local function readCapabilities(driverId)
    local ok, xml = pcall(function()
        return C4:GetDeviceData(driverId, "capabilities")
    end)
    local modes = AlarmControl.parseModes(ok and xml or nil)
    if #modes == 0 then
        ok, xml = pcall(function()
            return C4:GetDeviceData(driverId)
        end)
        modes = AlarmControl.parseModes(ok and xml or nil)
    end
    return modes
end

-- The modes the partition `device` arms in, as its driver declares them: a new list each call
-- (empty: none declared, and it is not armed from DirectorLink).
function AlarmControl.modes(device)
    for _, protocol in ipairs(protocolsOf(device)) do
        local driverId = tonumber(protocol.id)
        if driverId then
            local name = string.lower(trim(protocol.driver))
            local key = name ~= "" and name or ("#" .. driverId)
            local now = os.time()
            local entry = modesCache[key]
            if not entry or now - entry.at >= AlarmControl.MODES_SECONDS or now < entry.at then
                entry = { at = now, modes = readCapabilities(driverId) }
                modesCache[key] = entry
            end
            local modes = entry.modes
            if #modes > 0 then
                local copy = {}
                for i, mode in ipairs(modes) do
                    copy[i] = mode
                end
                return copy
            end
        end
    end
    return {}
end

-- The mode as the driver declares it, for one a request names (case aside), or nil.
function AlarmControl.mode(device, name)
    if type(name) ~= "string" then
        return nil
    end
    local wanted = string.lower(trim(name))
    for _, mode in ipairs(AlarmControl.modes(device)) do
        if string.lower(mode) == wanted then
            return mode
        end
    end
    return nil
end

-- What a driver says of the agreement: true or false (DIRECTORLINK_ALARM_CONTROL is "1" or not), or
-- nil when it does not keep it (no DIRECTORLINK_ALARM from "1", or its variables could not be read).
local function readAvailable(driverId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(driverId)
    end)
    if not ok or type(variables) ~= "table" then
        return nil
    end
    local marker, control
    for _, variable in pairs(variables) do
        if type(variable) == "table" then
            local name = string.upper(trim(variable.name))
            if name == AlarmControl.MARKER then
                marker = variable.value
            elseif name == AlarmControl.CONTROL_VARIABLE then
                control = variable.value
            end
        end
    end
    local version = tonumber(trim(marker))
    if not version or version < 1 or version % 1 ~= 0 then
        return nil
    end
    return trim(control) == "1"
end

-- Whether arming and disarming the partition `device` can work now: false only when a driver of
-- it keeps DirectorLink's alarm agreement and says so (DIRECTORLINK_ALARM_CONTROL not "1").
function AlarmControl.available(device)
    local now = os.time()
    for _, protocol in ipairs(protocolsOf(device)) do
        local driverId = tonumber(protocol.id)
        if driverId then
            local entry = availableCache[driverId]
            if not entry or now - entry.at >= AlarmControl.AVAILABLE_SECONDS or now < entry.at then
                entry = { at = now, value = readAvailable(driverId) }
                availableCache[driverId] = entry
            end
            if entry.value ~= nil then
                return entry.value
            end
        end
    end
    return true
end

-- Sends the partition `device` an arm in `mode` (one AlarmControl.mode gave) or a disarm, with the
-- code a person typed. Returns true, or false when Director refused the command (nothing said why:
-- an error could name what was sent).
function AlarmControl.arm(device, mode, code)
    local params = { ArmType = mode, UserCode = code, InterfaceID = AlarmControl.INTERFACE_ID }
    local ok = pcall(function()
        C4:SendToDevice(device.id, "PARTITION_ARM", params, false, false)
    end)
    return ok
end

function AlarmControl.disarm(device, code)
    local params = { UserCode = code, InterfaceID = AlarmControl.INTERFACE_ID }
    local ok = pcall(function()
        C4:SendToDevice(device.id, "PARTITION_DISARM", params, false, false)
    end)
    return ok
end

-- Forgets what was read (the tests' new project).
function AlarmControl.reset()
    modesCache = {}
    availableCache = {}
end

return AlarmControl
