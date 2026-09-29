-- Holy periods (ADR-037, docs/CALENDAR.md): Shabbat and the holy days of Yom Tov that follow each
-- other count as one period, from the candle lighting before its first day to the havdalah after
-- its last. Pure: no Director, no clock, no time zone; days are R.D. numbers (HebrewDate) and
-- times are seconds from 1970 (UTC).
--
-- HolyTimes.periods(fromRd, toRd, options) --> { period, ... } overlapping [fromRd, toRd], in order
-- options = { latitude, longitude, israel, candle_lighting_minutes = b (20), havdalah_minutes = m (42) }
-- period = {
--   first = rd, last = rd,       -- a maximal run of consecutive holy civil days
--   starts_at = epoch|nil,       -- candle lighting: the sunset before `first`, cut to the minute, less b
--   ends_at = epoch|nil,         -- havdalah: the sunset of `last`, to the nearest minute, plus m
--   days = { { rd, shabbat = bool, holidays = { Holidays entry, ... }, candle_lighting = epoch|nil }, ... },
--   approximate = bool,          -- a sunset it needs does not happen here (polar day or night)
-- }
-- Candles for a later day are lit from an existing flame: before the sunset of the day before when
-- the day is Shabbat (as on any Friday), otherwise after nightfall, at that day's havdalah time.
-- These are Hebcal's roundings; without a sunset a time is nil, never guessed.

local HebrewDate = require("src.core.hebrew_date")
local Holidays = require("src.core.holidays")
local Sun = require("src.core.sun")

local HolyTimes = {}

local SATURDAY = 6

-- Shabbat, or a holy day of Yom Tov.
function HolyTimes.isHolyDay(rd, israel)
    return HebrewDate.weekday(rd) == SATURDAY or Holidays.isYomTov(rd, israel)
end

local function build(first, last, options, israel, sunset)
    local before = (options.candle_lighting_minutes or 20) * 60
    local after = (options.havdalah_minutes or 42) * 60
    local function candles(rd)
        local time = sunset(rd)
        return time and math.floor(time / 60) * 60 - before or nil
    end
    local function havdalah(rd)
        local time = sunset(rd)
        return time and math.floor(time / 60 + 0.5) * 60 + after or nil
    end
    local period = { first = first, last = last, starts_at = candles(first - 1), ends_at = havdalah(last), days = {} }
    for rd = first, last do
        local shabbat = HebrewDate.weekday(rd) == SATURDAY
        local lit
        if rd == first then
            lit = period.starts_at
        elseif shabbat then
            lit = candles(rd - 1)
        else
            lit = havdalah(rd - 1)
        end
        period.days[#period.days + 1] = { rd = rd, shabbat = shabbat, holidays = Holidays.onDate(rd, israel), candle_lighting = lit }
    end
    -- Every time it needs is a sunset from the day before `first` to `last`.
    period.approximate = false
    for rd = first - 1, last do
        if not sunset(rd) then
            period.approximate = true
        end
    end
    return period
end

function HolyTimes.periods(fromRd, toRd, options)
    local latitude, longitude = options.latitude, options.longitude
    if type(latitude) ~= "number" or type(longitude) ~= "number" then
        error("HolyTimes.periods needs the latitude and longitude", 2)
    end
    local israel = options.israel == true
    local sunsets = {}
    local function sunset(rd)
        local time = sunsets[rd]
        if time == nil then
            local year, month, day = HebrewDate.gregorianFromFixed(rd)
            time = Sun.sunsetEpoch(year, month, day, latitude, longitude) or false
            sunsets[rd] = time
        end
        return time or nil
    end
    -- The Yom Tov days of the years around the range (a period runs at most 3 days past it).
    local yomTov = {}
    local year = HebrewDate.fromFixed(fromRd - 7)
    while HebrewDate.newYear(year) <= toRd + 7 do
        for _, entry in ipairs(Holidays.forYear(year, israel)) do
            if entry.yom_tov then
                yomTov[entry.rd] = true
            end
        end
        year = year + 1
    end
    local function holy(rd)
        return yomTov[rd] == true or HebrewDate.weekday(rd) == SATURDAY
    end
    local periods = {}
    local rd = fromRd
    -- A period that began before fromRd and is still on at fromRd counts, from its first day.
    if holy(rd) then
        while holy(rd - 1) do
            rd = rd - 1
        end
    end
    while rd <= toRd do
        if holy(rd) then
            local first = rd
            while holy(rd + 1) do
                rd = rd + 1
            end
            periods[#periods + 1] = build(first, rd, options, israel, sunset)
        end
        rd = rd + 1
    end
    return periods
end

return HolyTimes
