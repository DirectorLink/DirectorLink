-- The Hebrew calendar (ADR-037, docs/CALENDAR.md), worked out from the arithmetic rules in
-- Dershowitz and Reingold, Calendrical Calculations, chapter 8. Pure: no Director, no clock, no
-- time zone.
-- - Days are fixed day numbers (R.D.): R.D. 1 is Monday 1 January of year 1 (Gregorian), R.D.
--   719163 is 1970-01-01, and the weekday is rd % 7 (0 Sunday .. 6 Saturday).
-- - Months are numbered as in the book: 1 Nisan .. 6 Elul, 7 Tishrei .. 12 Adar (Adar I in a leap
--   year), 13 Adar II. A year runs from 1 Tishrei to the end of Elul.
-- - The molad is counted in whole days and parts (1 day = 25,920 parts), never as a fraction of a
--   day. Every number stays far below 2^53 (the parts reach about 1.5e9 in the year 9000), so
--   Lua's doubles are exact, and math.floor of a quotient of two of them is too.

local HebrewDate = {}

HebrewDate.EPOCH = -1373427 -- R.D. of 1 Tishrei of year 1
HebrewDate.UNIX_EPOCH = 719163 -- R.D. of 1970-01-01

HebrewDate.NISAN, HebrewDate.IYAR, HebrewDate.SIVAN, HebrewDate.TAMUZ, HebrewDate.AV, HebrewDate.ELUL = 1, 2, 3, 4, 5, 6
HebrewDate.TISHREI, HebrewDate.CHESHVAN, HebrewDate.KISLEV, HebrewDate.TEVET, HebrewDate.SHVAT = 7, 8, 9, 10, 11
HebrewDate.ADAR, HebrewDate.ADAR_2 = 12, 13

local NISAN, IYAR, TAMUZ, ELUL = HebrewDate.NISAN, HebrewDate.IYAR, HebrewDate.TAMUZ, HebrewDate.ELUL
local TISHREI, CHESHVAN, KISLEV, TEVET = HebrewDate.TISHREI, HebrewDate.CHESHVAN, HebrewDate.KISLEV, HebrewDate.TEVET
local ADAR, ADAR_2 = HebrewDate.ADAR, HebrewDate.ADAR_2

local DAY_PARTS = 25920 -- 24 hours of 1,080 parts
local MONTH_PARTS = 13753 -- a month is 29 days, 12 hours and 793 parts
local FIRST_MOLAD = 12084 -- the first molad (BaHaRaD: 5 hours 204 parts), plus 6 hours (molad zaken)

local MONTH_KEYS = { "nisan", "iyar", "sivan", "tamuz", "av", "elul", "tishrei", "cheshvan", "kislev", "tevet", "shvat" }

-- English month names in Hebcal's spelling, by key (for Composer and logs; apps have their own).
HebrewDate.MONTH_NAMES = {
    tishrei = "Tishrei",
    cheshvan = "Cheshvan",
    kislev = "Kislev",
    tevet = "Tevet",
    shvat = "Sh'vat",
    adar = "Adar",
    adar_1 = "Adar I",
    adar_2 = "Adar II",
    nisan = "Nisan",
    iyar = "Iyyar",
    sivan = "Sivan",
    tamuz = "Tamuz",
    av = "Av",
    elul = "Elul",
}

local function isGregorianLeap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

function HebrewDate.fixedFromGregorian(year, month, day)
    local prior = year - 1
    local rd = 365 * prior + math.floor(prior / 4) - math.floor(prior / 100) + math.floor(prior / 400) + math.floor((367 * month - 362) / 12) + day
    if month > 2 then
        rd = rd - (isGregorianLeap(year) and 1 or 2)
    end
    return rd
end

-- Counts from 1 March of year 0 (R.D. -305) in 400-year eras of 146,097 days, so that the leap
-- day comes last in each counted year.
function HebrewDate.gregorianFromFixed(rd)
    local days = rd + 305
    local era = math.floor(days / 146097)
    local dayOfEra = days - era * 146097
    local yearOfEra = math.floor((dayOfEra - math.floor(dayOfEra / 1460) + math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365)
    local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100))
    local fromMarch = math.floor((5 * dayOfYear + 2) / 153)
    local day = dayOfYear - math.floor((153 * fromMarch + 2) / 5) + 1
    local month = fromMarch < 10 and fromMarch + 3 or fromMarch - 9
    return era * 400 + yearOfEra + (month <= 2 and 1 or 0), month, day
end

-- "2026-10-03"
function HebrewDate.dateKey(rd)
    local year, month, day = HebrewDate.gregorianFromFixed(rd)
    return string.format("%04d-%02d-%02d", year, month, day)
end

-- "2026-10-03" -> rd, or nil when it is not a real date.
function HebrewDate.parseDateKey(text)
    local year, month, day = tostring(text):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or month < 1 or month > 12 or day < 1 then
        return nil
    end
    local rd = HebrewDate.fixedFromGregorian(year, month, day)
    local _, sameMonth = HebrewDate.gregorianFromFixed(rd)
    return sameMonth == month and rd or nil
end

function HebrewDate.weekday(rd)
    return rd % 7
end

function HebrewDate.isLeapYear(year)
    return (7 * year + 1) % 19 < 7
end

-- Days from the epoch to 1 Tishrei of `year`, before the two postponements that depend on the
-- years around it: the molad of Tishrei in whole days (the 6 hours in FIRST_MOLAD make a molad at
-- or after noon count as the next day), and a day more when that is a Sunday, Wednesday or Friday.
local function elapsedDays(year)
    local months = math.floor((235 * year - 234) / 19)
    local parts = FIRST_MOLAD + MONTH_PARTS * months
    local days = 29 * months + math.floor(parts / DAY_PARTS)
    if (3 * (days + 1)) % 7 < 3 then
        days = days + 1
    end
    return days
end

-- Two days when the year would otherwise have 356 days (GaTaRaD), one when the year before
-- would have 382 (BeTUTaKPaT).
local function correction(year)
    local days = elapsedDays(year)
    if elapsedDays(year + 1) - days == 356 then
        return 2
    end
    if days - elapsedDays(year - 1) == 382 then
        return 1
    end
    return 0
end

-- R.D. of 1 Tishrei (Rosh Hashana).
function HebrewDate.newYear(year)
    return HebrewDate.EPOCH + elapsedDays(year) + correction(year)
end

local function monthDays(month, yearLength, leap)
    if month == IYAR or month == TAMUZ or month == ELUL or month == TEVET or month == ADAR_2 then
        return 29
    elseif month == ADAR then
        return leap and 30 or 29
    elseif month == CHESHVAN then
        return (yearLength == 355 or yearLength == 385) and 30 or 29
    elseif month == KISLEV then
        return (yearLength == 353 or yearLength == 383) and 29 or 30
    end
    return 30
end

-- One record per year, { new_year, length, leap, starts = { [month] = rd } } (and each month's
-- length and the months in order), for the few years in use: most recently used first.
local CACHED_YEARS = 6
local cache = {}

local function buildYear(year)
    local newYear = HebrewDate.newYear(year)
    local length = HebrewDate.newYear(year + 1) - newYear
    local leap = HebrewDate.isLeapYear(year)
    local record = { year = year, new_year = newYear, length = length, leap = leap, starts = {}, lengths = {}, months = {} }
    local rd = newYear
    local function add(month)
        record.starts[month] = rd
        record.lengths[month] = monthDays(month, length, leap)
        record.months[#record.months + 1] = month
        rd = rd + record.lengths[month]
    end
    for month = TISHREI, leap and ADAR_2 or ADAR do
        add(month)
    end
    for month = NISAN, ELUL do
        add(month)
    end
    return record
end

local function yearRecord(year)
    for index, record in ipairs(cache) do
        if record.year == year then
            if index > 1 then
                table.remove(cache, index)
                table.insert(cache, 1, record)
            end
            return record
        end
    end
    local record = buildYear(year)
    table.insert(cache, 1, record)
    cache[CACHED_YEARS + 1] = nil
    return record
end

-- 353, 354 or 355 days, or 383, 384 or 385 in a leap year.
function HebrewDate.yearLength(year)
    return yearRecord(year).length
end

function HebrewDate.monthLength(year, month)
    local days = yearRecord(year).lengths[month]
    if not days then
        error("the Hebrew year " .. tostring(year) .. " has no month " .. tostring(month), 2)
    end
    return days
end

function HebrewDate.toFixed(year, month, day)
    local start = yearRecord(year).starts[month]
    if not start then
        error("the Hebrew year " .. tostring(year) .. " has no month " .. tostring(month), 2)
    end
    return start + day - 1
end

-- The Hebrew year, month and day of a fixed day (its daytime: the Hebrew day began at the sunset
-- before).
function HebrewDate.fromFixed(rd)
    local year
    for _, cached in ipairs(cache) do
        if rd >= cached.new_year and rd < cached.new_year + cached.length then
            year = cached.year
            break
        end
    end
    if not year then
        -- 35,975,351 / 98,496 days is the mean year; step to the right year from the estimate.
        year = math.floor((rd - HebrewDate.EPOCH) * 98496 / 35975351)
        while HebrewDate.newYear(year + 1) <= rd do
            year = year + 1
        end
        while HebrewDate.newYear(year) > rd do
            year = year - 1
        end
    end
    local record = yearRecord(year)
    for _, month in ipairs(record.months) do
        local start = record.starts[month]
        if rd < start + record.lengths[month] then
            return year, month, rd - start + 1
        end
    end
end

-- The API's month key: Adar is "adar" in a common year, "adar_1" and "adar_2" in a leap year.
function HebrewDate.monthKey(year, month)
    if month == ADAR then
        return HebrewDate.isLeapYear(year) and "adar_1" or "adar"
    elseif month == ADAR_2 then
        return HebrewDate.isLeapYear(year) and "adar_2" or nil
    end
    return MONTH_KEYS[month]
end

return HebrewDate
