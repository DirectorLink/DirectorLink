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
--
-- Version 2 of the agreement (1.16.0, ADR-092): a driver that also publishes an X25519 public key
-- (DIRECTORLINK_ALARM = "2", DIRECTORLINK_ALARM_KEY: 64 hex digits) gets every command sealed to
-- it: UserCode is "dl2:" and the base64 of the command's key exchange, IV, AES-256-CBC ciphertext and
-- HMAC-SHA256 (AlarmControl.token), so Director's debug log, which records every command one driver
-- sends another (ADR-091's correction), sees no code. The sealed command names the action, the mode,
-- the code a person typed or none, a nonce and the time; the driver checks all of them. Without a
-- code it is carried out with the driver's own code, and only as far as the driver allows it
-- (DIRECTORLINK_ALARM_WITHOUT_CODE: "none", "arm" or "arm_disarm", from its Composer property) and
-- DirectorLink's admins do (src/core/alarm_settings.lua). A driver of version 1, or none, gets the
-- typed code as 1.15.0 sent it, and never a command without one.

local Base64 = require("src.core.base64")
local Json = require("src.core.json")
local Random = require("src.core.random")
local X25519 = require("src.core.x25519")

local AlarmControl = {}

AlarmControl.INTERFACE_ID = "DirectorLink"
AlarmControl.MARKER = "DIRECTORLINK_ALARM"
AlarmControl.CONTROL_VARIABLE = "DIRECTORLINK_ALARM_CONTROL"
AlarmControl.KEY_VARIABLE = "DIRECTORLINK_ALARM_KEY"
AlarmControl.WITHOUT_CODE_VARIABLE = "DIRECTORLINK_ALARM_WITHOUT_CODE"
AlarmControl.TOKEN_PREFIX = "dl2:"
AlarmControl.TOKEN_LABEL = "DirectorLink alarm v2"
-- How far a level of "without a code" goes: none, arming only, arming and disarming.
AlarmControl.LEVELS = { none = 0, arm = 1, arm_disarm = 2 }
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
-- driver id -> { at = os.time(), agreement = { version, control, key, without_code } | false }
local agreementCache = {}

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

local function isHexKey(value)
    return type(value) == "string" and #value == 64 and value:match("^%x+$") ~= nil
end

-- What a driver says of the agreement: { version, control (DIRECTORLINK_ALARM_CONTROL is "1"),
-- key (version 2's public key, lower-case hex, or nil), without_code ("none", "arm" or
-- "arm_disarm"; "none" for version 1 or without a key) }, or false when it does not keep it (no
-- DIRECTORLINK_ALARM from "1", or its variables could not be read).
local function readAgreement(driverId)
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(driverId)
    end)
    if not ok or type(variables) ~= "table" then
        return false
    end
    local found = {}
    for _, variable in pairs(variables) do
        if type(variable) == "table" then
            found[string.upper(trim(variable.name))] = variable.value
        end
    end
    local version = tonumber(trim(found[AlarmControl.MARKER]))
    if not version or version < 1 or version % 1 ~= 0 then
        return false
    end
    local agreement = { version = version, control = trim(found[AlarmControl.CONTROL_VARIABLE]) == "1", without_code = "none" }
    local key = string.lower(trim(found[AlarmControl.KEY_VARIABLE]))
    if version >= 2 and isHexKey(key) then
        agreement.key = key
        local level = trim(found[AlarmControl.WITHOUT_CODE_VARIABLE])
        if AlarmControl.LEVELS[level] then
            agreement.without_code = level
        end
    end
    return agreement
end

-- The agreement of the first driver of the partition `device` that keeps it, or nil.
function AlarmControl.agreement(device)
    local now = os.time()
    for _, protocol in ipairs(protocolsOf(device)) do
        local driverId = tonumber(protocol.id)
        if driverId then
            local entry = agreementCache[driverId]
            if not entry or now - entry.at >= AlarmControl.AVAILABLE_SECONDS or now < entry.at then
                entry = { at = now, agreement = readAgreement(driverId) }
                agreementCache[driverId] = entry
            end
            if entry.agreement then
                return entry.agreement
            end
        end
    end
    return nil
end

-- Whether arming and disarming the partition `device` can work now: false only when a driver of
-- it keeps DirectorLink's alarm agreement and says so (DIRECTORLINK_ALARM_CONTROL not "1").
function AlarmControl.available(device)
    local agreement = AlarmControl.agreement(device)
    return agreement == nil or agreement.control == true
end

-- How far the partition's driver lets DirectorLink go without a code: "none", "arm" or
-- "arm_disarm" (only a driver of version 2 with a key; any other: "none").
function AlarmControl.driverWithoutCode(device)
    local agreement = AlarmControl.agreement(device)
    return agreement and agreement.key and agreement.without_code or "none"
end

-- Whether `action` ("arm" or "disarm") may go without a code at `level`.
function AlarmControl.allows(level, action)
    local rank = AlarmControl.LEVELS[level] or 0
    return rank >= (action == "disarm" and 2 or 1)
end

-- The lower of two levels (an unknown one counts as "none").
function AlarmControl.lower(left, right)
    left = AlarmControl.LEVELS[left] and left or "none"
    right = AlarmControl.LEVELS[right] and right or "none"
    if AlarmControl.LEVELS[left] <= AlarmControl.LEVELS[right] then
        return left
    end
    return right
end

local function hmac(keyHex, data)
    local mac = C4:HMAC("SHA256", keyHex, data, { key_encoding = "HEX", data_encoding = "NONE", return_encoding = "HEX" })
    if type(mac) ~= "string" or #mac ~= 64 then
        return nil
    end
    return mac:lower()
end

-- A command sealed to the driver's public key `keyHex`: "dl2:" .. base64(ephemeral public key (32)
-- .. IV (16) .. ciphertext .. HMAC (32)). `fields`: { a = "arm" | "disarm", m = mode or nil, c =
-- the typed code or nil }. The shared secret of a fresh X25519 key and the driver's gives, through
-- HMAC-SHA256 with the label and both public keys, an encryption key and a MAC key; the plaintext is
-- JSON { v = 2, a, m, c, n (a nonce of 16 hex digits), t (the controller's time) }. `ephemeral` and
-- `iv` (bytes) and `nonce` and `now` are for the tests' vectors. nil when anything fails: nothing
-- that could name the code is said.
function AlarmControl.token(keyHex, fields, ephemeral, iv, nonce, now)
    local ok, token = pcall(function()
        local peer = Base64.fromHex(keyHex)
        local secret = ephemeral or Random.bytes(32)
        local public = X25519.publicKey(secret)
        local shared = X25519.shared(secret, peer)
        if not shared then
            return nil
        end
        local prk = hmac(Base64.toHex(shared), AlarmControl.TOKEN_LABEL .. public .. peer)
        local encKey, macKey = prk and hmac(prk, "enc"), prk and hmac(prk, "mac")
        if not encKey or not macKey then
            return nil
        end
        local plaintext = Json.encode({
            v = 2,
            a = fields.a,
            m = fields.m or Json.null,
            c = fields.c or Json.null,
            n = nonce or Random.hex(16),
            t = now or os.time(),
        })
        iv = iv or Random.bytes(16)
        local ct = C4:Encrypt("AES-256-CBC", encKey, Base64.toHex(iv), plaintext, {
            key_encoding = "HEX",
            iv_encoding = "HEX",
            data_encoding = "NONE",
            return_encoding = "HEX",
            padding = true,
        })
        if type(ct) ~= "string" or ct == "" then
            return nil
        end
        local body = public .. iv .. Base64.fromHex(ct)
        local mac = hmac(macKey, body)
        if not mac then
            return nil
        end
        return AlarmControl.TOKEN_PREFIX .. Base64.encode(body .. Base64.fromHex(mac))
    end)
    return ok and token or nil
end

-- What goes in UserCode for the partition `device`: the sealed command for a driver of version 2,
-- else the typed code (nil without one: such a driver gets no command without a code).
local function userCode(device, action, mode, code)
    local agreement = AlarmControl.agreement(device)
    if agreement and agreement.key then
        return AlarmControl.token(agreement.key, { a = action, m = mode, c = code })
    end
    return code
end

-- Sends the partition `device` an arm in `mode` (one AlarmControl.mode gave) or a disarm, with the
-- code a person typed, or none (only to a driver of version 2, which then uses its own code if it
-- allows it). Returns true, or false when there is nothing to send or Director refused the command
-- (nothing said why: an error could name what was sent).
function AlarmControl.arm(device, mode, code)
    local sent = userCode(device, "arm", mode, code)
    if not sent then
        return false
    end
    local params = { ArmType = mode, UserCode = sent, InterfaceID = AlarmControl.INTERFACE_ID }
    local ok = pcall(function()
        C4:SendToDevice(device.id, "PARTITION_ARM", params, false, false)
    end)
    return ok
end

function AlarmControl.disarm(device, code)
    local sent = userCode(device, "disarm", nil, code)
    if not sent then
        return false
    end
    local params = { UserCode = sent, InterfaceID = AlarmControl.INTERFACE_ID }
    local ok = pcall(function()
        C4:SendToDevice(device.id, "PARTITION_DISARM", params, false, false)
    end)
    return ok
end

-- Forgets what was read (the tests' new project).
function AlarmControl.reset()
    modesCache = {}
    agreementCache = {}
end

return AlarmControl
