-- What a light's driver says it can do (1.10.2, ADR-077): <dimmer> and <set_level> in the
-- <capabilities> of its driver.xml. A light dims when its driver declares either one True, and is
-- a switch (on and off only) when it declares them and neither is True. When Director gives neither
-- (no protocol driver, nothing declared, an error), the light adapters keep their rule of 1.10.1: a
-- light with a level variable (1001) dims.
--
-- Why: the Light V2 proxy gives switches a level variable too. The owner's 107 KNX switches
-- (knx_switch.c4i, <dimmer>False</dimmer>, <set_level>False</set_level>) report 0 or 100 there, so
-- the variable alone made each of them a dimmer with a slider.
--
-- Read from the light's protocol driver (the KNX switch's driver, not its light_v2 proxy, which is
-- Control4's own and the same for every light): C4:GetDeviceData(<driver id>, "capabilities"),
-- documented from OS 2.10 (a tag at the first two levels of <devicedata>, as this one, comes with
-- what is in it), else the whole <devicedata> when that gives no text. Once per driver file name
-- and project read: the 107 lights on knx_switch.c4i cost one Director call, not 107. A driver
-- updated in Composer is read again (forget, from src/adapters/manager.lua setUpAgain).
--
-- What it does not see: a driver that changes these while it runs (Snap One's dynamic
-- capabilities, DYNAMIC_CAPABILITIES_CHANGED). Director gives the driver.xml, so such a light is
-- what its driver.xml says.

local Log = require("src.core.log")

local LightCapabilities = {}

-- The capabilities that say whether a light dims.
LightCapabilities.TAGS = { "dimmer", "set_level" }

-- driver file name (lower case) -> { dimmer, set_level (true, false, or nil: not declared), driver
-- (the file name), driver_id (the driver read) }, for the project read.
local cache = {}

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(text)
    return (text:gsub("&(%a+);", function(name)
        return ENTITIES[name]
    end))
end

-- "True" or "False" as Control4 writes them (any case, 1 or 0, yes or no); nil for anything else.
local function yesOrNo(text)
    local value = string.lower(trim(text))
    if value == "true" or value == "1" or value == "yes" then
        return true
    end
    if value == "false" or value == "0" or value == "no" then
        return false
    end
    return nil
end

local function tagValue(xml, name)
    local value = xml:match("<" .. name .. "%s*>([^<]*)</" .. name .. "%s*>")
        or xml:match("<" .. name .. "%s[^>]*>([^<]*)</" .. name .. "%s*>")
    if value == nil then
        return nil
    end
    return yesOrNo(unescape(value))
end

-- What a driver.xml's capabilities say, from the text Director gives (the "capabilities" tag's
-- content, or the whole <devicedata>; escaped once too): { dimmer, set_level }, each true, false or
-- nil (not declared, or neither yes nor no); nil when there is no text at all. Comments are left out.
function LightCapabilities.parse(xml)
    if type(xml) ~= "string" or trim(xml) == "" then
        return nil
    end
    if not xml:find("<", 1, true) and xml:find("&lt;", 1, true) then
        xml = unescape(xml)
    end
    xml = xml:gsub("<!%-%-.-%-%->", "")
    -- The whole <devicedata>: only what is in its <capabilities> counts.
    if xml:find("<devicedata", 1, true) then
        xml = xml:match("<capabilities%s*>(.-)</capabilities%s*>") or xml:match("<capabilities%s[^>]*>(.-)</capabilities%s*>") or ""
    end
    local found = {}
    for _, name in ipairs(LightCapabilities.TAGS) do
        found[name] = tagValue(xml, name)
    end
    return found
end

-- What a C4:GetDeviceData call gave, for the log: its shape, not its text.
local function shape(ok, value)
    if not ok then
        return "an error"
    end
    if type(value) ~= "string" then
        return value == nil and "nothing" or ("a " .. type(value))
    end
    if trim(value) == "" then
        return "an empty text"
    end
    return string.format("a text of %d characters", #value)
end

-- The capabilities of the driver `driverId` as Director gives them: parse's answer (nil: Director
-- gave no text), and for the log what Director gave: { capabilities_tag, devicedata (when asked) }.
function LightCapabilities.read(driverId)
    local ok, xml = pcall(function()
        return C4:GetDeviceData(driverId, "capabilities")
    end)
    local given = { capabilities_tag = shape(ok, xml) }
    local found = LightCapabilities.parse(ok and xml or nil)
    if found == nil then
        ok, xml = pcall(function()
            return C4:GetDeviceData(driverId)
        end)
        given.devicedata = shape(ok, xml)
        found = LightCapabilities.parse(ok and xml or nil)
    end
    return found, given
end

local function protocolsOf(device)
    return type(device) == "table" and type(device.protocols) == "table" and device.protocols or {}
end

local function shown(value)
    if value == nil then
        return "not declared"
    end
    return value
end

-- What the light `device`'s protocol drivers declare: the first entry (see `cache`) with dimmer or
-- set_level declared, or nil. Each driver file is read once a project read; a driver without a file
-- name is read each time.
function LightCapabilities.declared(device)
    for _, protocol in ipairs(protocolsOf(device)) do
        local driverId = tonumber(protocol.id)
        local name = string.lower(trim(protocol.driver))
        if driverId then
            local entry = name ~= "" and cache[name] or nil
            if not entry then
                local found, given = LightCapabilities.read(driverId)
                entry = { dimmer = found and found.dimmer, set_level = found and found.set_level, driver = name, driver_id = driverId }
                if name ~= "" then
                    cache[name] = entry
                end
                Log.info("light_state", "light driver capabilities", {
                    driver_id = driverId,
                    driver = name,
                    dimmer = shown(entry.dimmer),
                    set_level = shown(entry.set_level),
                    director = given,
                })
            end
            if entry.dimmer ~= nil or entry.set_level ~= nil then
                return entry
            end
        end
    end
    return nil
end

-- Whether the light `device` dims, and why: "declared" (by its driver: dimmer or set_level True),
-- else "level variable" (hasLevel: Director gives its level variable, the rule of 1.10.1).
function LightCapabilities.dimmable(device, hasLevel)
    local declared = LightCapabilities.declared(device)
    if declared then
        return declared.dimmer == true or declared.set_level == true, "declared"
    end
    return hasLevel == true, "level variable"
end

-- The device's drivers are read again at their next light (their driver was updated in Composer).
function LightCapabilities.forget(device)
    for _, protocol in ipairs(protocolsOf(device)) do
        local name = string.lower(trim(protocol.driver))
        if name ~= "" then
            cache[name] = nil
        end
    end
end

-- A project read: every driver is read again.
function LightCapabilities.reset()
    cache = {}
end

return LightCapabilities
