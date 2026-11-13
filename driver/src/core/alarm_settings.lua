-- The home's alarm settings (1.16.0, ADR-092), set by admins: how far DirectorLink arms and disarms
-- without a typed code. "none" (as it ships: a code each time), "arm" (arming without one) or
-- "arm_disarm". It never goes further than the alarm's driver allows (its Composer property, which
-- it says in DIRECTORLINK_ALARM_WITHOUT_CODE: src/control4/alarm_control.lua), and the code used
-- then is the driver's own: DirectorLink keeps none. Not in backups: a restore must not loosen it.

local Store = require("src.core.store")

local AlarmSettings = {}

local STORE_KEY = "directorlink_alarm_settings"
AlarmSettings.STORE_VERSION = 1
AlarmSettings.LEVELS = { none = true, arm = true, arm_disarm = true }

local state = { loaded = false, without_code = "none" }

local function load()
    if state.loaded then
        return
    end
    state.loaded = true
    local stored = Store.read(STORE_KEY)
    if type(stored) == "table" and AlarmSettings.LEVELS[stored.without_code] then
        state.without_code = stored.without_code
    end
end

-- "none", "arm" or "arm_disarm".
function AlarmSettings.withoutCode()
    load()
    return state.without_code
end

-- Sets it; returns true, or false when it is no level or could not be saved (nothing changes).
function AlarmSettings.setWithoutCode(level)
    load()
    if not AlarmSettings.LEVELS[level] then
        return false
    end
    if not Store.write(STORE_KEY, { version = AlarmSettings.STORE_VERSION, without_code = level }) then
        return false
    end
    state.without_code = level
    return true
end

-- Forgets what was read (tests).
function AlarmSettings.reset()
    state = { loaded = false, without_code = "none" }
end

return AlarmSettings
