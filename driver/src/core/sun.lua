-- Sunrise and sunset for the home's location, worked out on the controller (no internet needed):
-- NOAA's solar calculator, after Meeus, Astronomical Algorithms (chapters 25 and 28), at sea level,
-- with the official zenith (90°50′: refraction and the sun's radius). Hebcal's candle lighting
-- and havdalah come from the same sunsets, to the minute (docs/CALENDAR.md). Until 1.2.0 this
-- was the Almanac for Computers method, up to a minute off. Pure: no Director, no clock, no time
-- zone.

local Sun = {}

local RAD = math.pi / 180
local DEG = 180 / math.pi
local ZENITH = (90 + 50 / 60) * RAD

-- Days from 1970-01-01 to a Gregorian date.
local function daysFromCivil(year, month, day)
    if month <= 2 then
        year, month = year - 1, month + 12
    end
    return 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400) + math.floor((153 * (month - 3) + 2) / 5) + day - 719469
end

-- The sunrise or sunset around a civil date's local noon, in minutes after 0h UTC of that date,
-- with the sun where it is at Julian day `jd`; nil in polar day or night. Longitude east-positive.
local function eventMinutes(jd, latitude, longitude, rising)
    local t = (jd - 2451545) / 36525
    local meanLongitude = (280.46646 + t * (36000.76983 + 0.0003032 * t)) % 360
    local anomaly = (357.52911 + t * (35999.05029 - 0.0001537 * t)) * RAD
    local eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    local center = math.sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t)) + math.sin(2 * anomaly) * (0.019993 - 0.000101 * t) + math.sin(3 * anomaly) * 0.000289
    local omega = (125.04 - 1934.136 * t) * RAD
    local apparent = (meanLongitude + center - 0.00569 - 0.00478 * math.sin(omega)) * RAD
    local obliquity = (23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - 0.001813 * t))) / 60) / 60 + 0.00256 * math.cos(omega)) * RAD
    local declination = math.asin(math.sin(obliquity) * math.sin(apparent))
    local y = math.tan(obliquity / 2) ^ 2
    local l0 = meanLongitude * RAD
    local equationOfTime = 4 * DEG * (y * math.sin(2 * l0) - 2 * eccentricity * math.sin(anomaly) + 4 * eccentricity * y * math.sin(anomaly) * math.cos(2 * l0) - 0.5 * y * y * math.sin(4 * l0) - 1.25 * eccentricity * eccentricity * math.sin(2 * anomaly))
    local phi = latitude * RAD
    local cosHourAngle = math.cos(ZENITH) / (math.cos(phi) * math.cos(declination)) - math.tan(phi) * math.tan(declination)
    if cosHourAngle > 1 or cosHourAngle < -1 then
        return nil
    end
    local hourAngle = DEG * math.acos(cosHourAngle)
    if rising then
        return 720 - 4 * (longitude + hourAngle) - equationOfTime
    end
    return 720 - 4 * (longitude - hourAngle) - equationOfTime
end

-- Two passes: the sun at noon UTC gives an estimate, the sun at that estimate the time.
local function eventEpoch(year, month, day, latitude, longitude, rising)
    local days = daysFromCivil(year, month, day)
    local jd0 = days + 2440587.5
    local estimate = eventMinutes(jd0 + 0.5, latitude, longitude, rising)
    local minutes = estimate and eventMinutes(jd0 + estimate / 1440, latitude, longitude, rising)
    return minutes and days * 86400 + minutes * 60 or nil
end

-- The moment (seconds from 1970, with a fraction) of the sunrise on a date at a place, or nil
-- when the sun does not rise that day. It may fall on the day before in UTC.
function Sun.sunriseEpoch(year, month, day, latitude, longitude)
    return eventEpoch(year, month, day, latitude, longitude, true)
end

-- The moment of the sunset on a date, or nil when the sun does not set that day. It may be after
-- the local midnight (Reykjavik in June): it is only ever a later moment, never wrapped.
function Sun.sunsetEpoch(year, month, day, latitude, longitude)
    return eventEpoch(year, month, day, latitude, longitude, false)
end

-- Minutes after local midnight of sunrise and sunset on a date, given the local offset from UTC
-- in minutes that day, rounded to the nearest minute of the local day; either is nil in polar day
-- or night.
function Sun.times(year, month, day, latitude, longitude, offsetMinutes)
    local midnight = daysFromCivil(year, month, day) * 86400
    local function toLocal(epoch)
        return epoch and math.floor(((epoch - midnight) / 60 + offsetMinutes) % 1440 + 0.5) % 1440 or nil
    end
    return toLocal(Sun.sunriseEpoch(year, month, day, latitude, longitude)), toLocal(Sun.sunsetEpoch(year, month, day, latitude, longitude))
end

return Sun
