-- The Jewish calendar (ADR-037): Shabbat and holiday times, the Hebrew date and the week's reading,
-- worked out on the controller from the project's location, behind the Composer property Jewish
-- Calendar (Off by default). Everyone may read it; admins change how the times are worked out.
--
-- Until the calendar itself is built (1.2.0), both routes answer as while the property is Off,
-- whatever it says: GET says so, and a settings change is checked as it will be, then refused.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")

local Calendar = {}

-- What admins may set (PATCH /v1/calendar/settings).
Calendar.LIMITS = {
    candle_lighting_minutes = { 0, 90 }, -- before sunset
    havdalah_minutes = { 20, 90 }, -- after sunset
}
Calendar.HOLIDAYS = { auto = true, israel = true, abroad = true }

local FIELDS = { holidays = true, candle_lighting_minutes = true, havdalah_minutes = true, version = true }

local function isWhole(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

-- The answer to a request that needs the calendar while it is off (schedules use it too).
function Calendar.offProblem()
    return Problem.new(409, "JEWISH_CALENDAR_OFF", "The Jewish calendar is off: an installer turns it on with DirectorLink's Jewish Calendar property in Composer")
end

-- GET /v1/calendar: with the calendar off, nothing but that.
function Calendar.get(_ctx)
    return 200, {
        enabled = false,
        status = "off",
        settings = Json.null,
        today = Json.null,
        week = Json.null,
        current = Json.null,
        next = Json.null,
    }
end

-- A settings change: nil, or the Problem with it.
local function checkSettings(body)
    local problem = Validate.body(body, FIELDS, true)
    if problem then
        return problem
    end
    if body.holidays == nil and body.candle_lighting_minutes == nil and body.havdalah_minutes == nil then
        return Problem.invalidRequest("Send at least one setting to change")
    end
    if body.holidays ~= nil and not Calendar.HOLIDAYS[body.holidays] then
        return Problem.invalidField("holidays", 'holidays must be "auto", "israel" or "abroad"')
    end
    for _, field in ipairs({ "candle_lighting_minutes", "havdalah_minutes" }) do
        local limits = Calendar.LIMITS[field]
        if body[field] ~= nil and not isWhole(body[field], limits[1], limits[2]) then
            return Problem.invalidField(field, string.format("%s must be whole minutes from %d to %d", field, limits[1], limits[2]))
        end
    end
    if body.version ~= nil and not isWhole(body.version, 1, math.huge) then
        return Problem.invalidField("version", "version must be the settings' version, a whole number")
    end
    return nil
end

-- PATCH /v1/calendar/settings: the fields sent replace the settings; with the calendar off, refused.
function Calendar.update_settings(ctx)
    local problem = checkSettings(ctx.body)
    if problem then
        return problem
    end
    return Calendar.offProblem()
end

return Calendar
