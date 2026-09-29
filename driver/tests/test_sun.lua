-- Sunrise and sunset (src/core/sun.lua, NOAA since 1.2.0) against Hebcal's zmanim, every day of
-- 2026 in Tel Aviv, New York, Buenos Aires, Reykjavik and Tromso
-- (tests/vectors/calendar/hebcal-sun-*.json); and Sun.times as the scheduler, the weather card
-- and Composer use it.

local T = require("helpers")
local Vectors = require("calendar_vectors")
local HebrewDate = require("src.core.hebrew_date")
local Sun = require("src.core.sun")

local tests = {}

-- Hebcal's zmanim take the sun's apparent radius at its distance (16′ ± 0.27′), its candle lighting
-- and havdalah the fixed 90°50′ that the calendar uses too (test_holy_times matches those to the
-- minute). The two differ by up to about 2.5 seconds at these latitudes, more further north, so
-- here a time is to the minute on most days and always within these seconds of Hebcal's.
local SECONDS = { ["tel-aviv"] = 3, ["new-york"] = 3, ["buenos-aires"] = 3, ["reykjavik"] = 10, tromso = 60 }
local SAME_MINUTE = { ["tel-aviv"] = 0.96, ["new-york"] = 0.96, ["buenos-aires"] = 0.96, ["reykjavik"] = 0.92, tromso = 0.92 }

local function ymd(date)
    local year, month, day = date:match("^(%d+)%-(%d+)%-(%d+)$")
    return tonumber(year), tonumber(month), tonumber(day)
end

function tests.sunrise_and_sunset_are_hebcals_within_seconds()
    for _, city in ipairs(Vectors.CITIES) do
        local vectors = Vectors.read("hebcal-sun-" .. city .. ".json")
        local latitude, longitude = vectors.location.latitude, vectors.location.longitude
        local count, sameMinute, worst = 0, 0, 0
        T.eq(#vectors.days, 365, city)
        for _, row in ipairs(vectors.days) do
            local year, month, day = ymd(row[1])
            for index, event in ipairs({ Sun.sunriseEpoch, Sun.sunsetEpoch }) do
                local label = city .. " " .. row[1] .. (index == 1 and " sunrise" or " sunset")
                local theirs, ours = row[index + 1], event(year, month, day, latitude, longitude)
                if Vectors.isNull(theirs) then
                    T.eq(ours, nil, label .. ": none")
                else
                    T.truthy(ours, label .. ": Hebcal has " .. theirs)
                    -- Hebcal cuts the seconds: its moment is within the second after its time.
                    local epoch = Vectors.epoch(theirs)
                    local off = math.abs(ours - (epoch + 0.5))
                    T.truthy(off <= SECONDS[city], label .. string.format(": %.1f s from %s", off, theirs))
                    worst = math.max(worst, off)
                    count = count + 1
                    -- Hebcal's own times are to the nearest minute (30 s and more up).
                    if math.floor(ours / 60 + 0.5) == math.floor((epoch + 30) / 60) then
                        sameMinute = sameMinute + 1
                    end
                end
            end
        end
        T.truthy(count >= 480, city .. ": " .. count .. " times")
        T.truthy(sameMinute >= SAME_MINUTE[city] * count, string.format("%s: %d of %d to the same minute", city, sameMinute, count))
    end
end

function tests.tromso_has_no_sunset_in_june_nor_sunrise_in_december()
    local vectors = Vectors.read("hebcal-sun-tromso.json")
    local latitude, longitude = vectors.location.latitude, vectors.location.longitude
    for _, date in ipairs({ { 2026, 6, 1 }, { 2026, 6, 21 }, { 2026, 7, 15 }, { 2026, 12, 1 }, { 2026, 12, 21 }, { 2027, 1, 10 } }) do
        local year, month, day = date[1], date[2], date[3]
        T.eq(Sun.sunriseEpoch(year, month, day, latitude, longitude), nil)
        T.eq(Sun.sunsetEpoch(year, month, day, latitude, longitude), nil)
        local sunrise, sunset = Sun.times(year, month, day, latitude, longitude, 60)
        T.eq(sunrise, nil)
        T.eq(sunset, nil)
    end
    T.truthy(Sun.sunsetEpoch(2026, 3, 20, latitude, longitude), "and a sunset at the equinox")
end

function tests.times_keeps_its_signature_and_rounding()
    -- Tel Aviv, 21 June 2026: Hebcal has 05:35:05 and 19:50:15 (UTC+3).
    local sunrise, sunset = Sun.times(2026, 6, 21, 32.08088, 34.78057, 180)
    T.eq(sunrise, 5 * 60 + 35)
    T.eq(sunset, 19 * 60 + 50)
    -- New York, 3 January 2026, UTC-5; and the same moment read in another offset.
    local rise, set = Sun.times(2026, 1, 3, 40.71427, -74.00597, -300)
    T.truthy(rise == math.floor(rise) and rise >= 0 and rise < 1440 and set == math.floor(set) and set > rise, "whole minutes of the local day")
    local riseUtc, setUtc = Sun.times(2026, 1, 3, 40.71427, -74.00597, 0)
    T.eq(riseUtc, rise + 300)
    T.eq((setUtc - set) % 1440, 300, "the local day wraps")
    -- Reykjavik, 21 June 2026: sunrise at 02:55, and the sunset just after 00:03 the next morning
    -- is a minute early in the day, as before (the calendar takes the moment, Sun.sunsetEpoch).
    local early, late = Sun.times(2026, 6, 21, 64.13548, -21.89541, 0)
    T.eq(early, 2 * 60 + 55)
    local midnight = (HebrewDate.fixedFromGregorian(2026, 6, 22) - HebrewDate.UNIX_EPOCH) * 86400
    T.eq(late, math.floor((Sun.sunsetEpoch(2026, 6, 21, 64.13548, -21.89541) - midnight) / 60 + 0.5))
    T.truthy(late >= 3 and late <= 4, "minute " .. late)
    -- To the nearest minute: each is the moment rounded, on the local clock.
    for _, date in ipairs({ { 2026, 3, 27 }, { 2026, 10, 25 }, { 2027, 6, 11 } }) do
        local year, month, day = date[1], date[2], date[3]
        local midnight = (HebrewDate.fixedFromGregorian(year, month, day) - HebrewDate.UNIX_EPOCH) * 86400
        local a, b = Sun.times(year, month, day, 32.08088, 34.78057, 120)
        T.eq(a, math.floor((Sun.sunriseEpoch(year, month, day, 32.08088, 34.78057) - midnight) / 60 + 120 + 0.5))
        T.eq(b, math.floor((Sun.sunsetEpoch(year, month, day, 32.08088, 34.78057) - midnight) / 60 + 120 + 0.5))
    end
end

function tests.a_sunset_after_midnight_is_a_later_moment()
    -- Reykjavik, Friday 19 June 2026: the sun sets after midnight, on Saturday.
    local sunset = Sun.sunsetEpoch(2026, 6, 19, 64.13548, -21.89541)
    local saturday = (HebrewDate.fixedFromGregorian(2026, 6, 20) - HebrewDate.UNIX_EPOCH) * 86400
    T.truthy(sunset > saturday and sunset < saturday + 600, "a few minutes after midnight")
    -- And a sunrise far east can be on the day before in UTC (Auckland, 2 January 2026, ~06:04 local, UTC+13).
    local sunrise = Sun.sunriseEpoch(2026, 1, 2, -36.85, 174.76)
    local day = (HebrewDate.fixedFromGregorian(2026, 1, 2) - HebrewDate.UNIX_EPOCH) * 86400
    T.truthy(sunrise < day and sunrise > day - 86400, "the evening before in UTC")
end

return tests
