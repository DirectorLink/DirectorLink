-- Sunrise and sunset for the home's location, worked out on the controller (no internet needed).
-- The Almanac for Computers method (US Naval Observatory), good to about a minute, with the
-- official zenith (90°50′: refraction and the sun's radius).

local Sun = {}

local RAD = math.pi / 180
local DEG = 180 / math.pi
local ZENITH = 90.833

local function wrap(value, range)
    value = value % range
    if value < 0 then
        value = value + range
    end
    return value
end

local function dayOfYear(year, month, day)
    local n1 = math.floor(275 * month / 9)
    local n2 = math.floor((month + 9) / 12)
    local n3 = 1 + math.floor((year - 4 * math.floor(year / 4) + 2) / 3)
    return n1 - n2 * n3 + day - 30
end

-- Hours after midnight UTC, or nil when the sun does not rise (or set) that day.
local function utcHours(year, month, day, latitude, longitude, rising)
    local lngHour = longitude / 15
    local t = dayOfYear(year, month, day) + ((rising and 6 or 18) - lngHour) / 24
    local meanAnomaly = 0.9856 * t - 3.289
    local trueLongitude = wrap(meanAnomaly + 1.916 * math.sin(meanAnomaly * RAD) + 0.020 * math.sin(2 * meanAnomaly * RAD) + 282.634, 360)
    local rightAscension = wrap(DEG * math.atan(0.91764 * math.tan(trueLongitude * RAD)), 360)
    rightAscension = (rightAscension + math.floor(trueLongitude / 90) * 90 - math.floor(rightAscension / 90) * 90) / 15
    local sinDec = 0.39782 * math.sin(trueLongitude * RAD)
    local cosDec = math.cos(math.asin(sinDec))
    local cosH = (math.cos(ZENITH * RAD) - sinDec * math.sin(latitude * RAD)) / (cosDec * math.cos(latitude * RAD))
    if cosH > 1 or cosH < -1 then
        return nil
    end
    local hourAngle = (rising and (360 - DEG * math.acos(cosH)) or (DEG * math.acos(cosH))) / 15
    local localMean = hourAngle + rightAscension - 0.06571 * t - 6.622
    return wrap(localMean - lngHour, 24)
end

-- Minutes after local midnight of sunrise and sunset on a date, given the local offset from UTC
-- in minutes that day; either is nil in polar day or night.
function Sun.times(year, month, day, latitude, longitude, offsetMinutes)
    local function toLocal(hours)
        return hours and math.floor(wrap(hours * 60 + offsetMinutes, 1440) + 0.5) % 1440 or nil
    end
    return toLocal(utcHours(year, month, day, latitude, longitude, true)), toLocal(utcHours(year, month, day, latitude, longitude, false))
end

return Sun
