local Version = {}

Version.BRIDGE_VERSION = "0.1.0-alpha.7"
Version.PROTOCOL_VERSION = 1
Version.MIN_OS = { major = 3, minor = 3, patch = 0 }

local function numbers(value)
    local major, minor, patch = tostring(value or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not major then
        return nil
    end
    return tonumber(major), tonumber(minor), tonumber(patch ~= "" and patch or "0")
end

function Version.isSupported(osVersion)
    local major, minor, patch = numbers(osVersion)
    if not major then
        return false
    end

    local min = Version.MIN_OS
    if major ~= min.major then
        return major > min.major
    end
    if minor ~= min.minor then
        return minor > min.minor
    end
    return patch >= min.patch
end

return Version
