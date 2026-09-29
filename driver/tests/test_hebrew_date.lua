-- The Hebrew calendar (src/core/hebrew_date.lua, ADR-037): known dates, a round trip of every day
-- for three centuries, the calendar's own rules for seven, and Hebcal's first day of every month
-- from 5660 to 5960 (tests/vectors/calendar/hebcal-months.json).

local T = require("helpers")
local Vectors = require("calendar_vectors")
local HebrewDate = require("src.core.hebrew_date")

local tests = {}

local SUNDAY, MONDAY, WEDNESDAY, THURSDAY, FRIDAY, SATURDAY = 0, 1, 3, 4, 5, 6
local H = HebrewDate

-- Hebcal's month names in Rosh Chodesh titles, as month numbers.
local HEBCAL_MONTHS = {
    ["Cheshvan"] = H.CHESHVAN, ["Kislev"] = H.KISLEV, ["Tevet"] = H.TEVET, ["Sh'vat"] = H.SHVAT,
    ["Adar"] = H.ADAR, ["Adar I"] = H.ADAR, ["Adar II"] = H.ADAR_2, ["Nisan"] = H.NISAN,
    ["Iyyar"] = H.IYAR, ["Sivan"] = H.SIVAN, ["Tamuz"] = H.TAMUZ, ["Av"] = H.AV, ["Elul"] = H.ELUL,
}

local function hebrew(date)
    local year, month, day = H.fromFixed(Vectors.rd(date))
    return year .. " " .. H.monthKey(year, month) .. " " .. day
end

function tests.known_dates()
    T.eq(H.dateKey(H.newYear(5787)), "2026-09-12", "1 Tishrei 5787")
    T.eq(H.weekday(H.newYear(5787)), SATURDAY)
    T.eq(H.dateKey(H.toFixed(5786, H.NISAN, 15)), "2026-04-02", "15 Nisan 5786")
    T.eq(H.weekday(H.toFixed(5786, H.NISAN, 15)), THURSDAY)
    T.eq(H.dateKey(H.newYear(5785)), "2024-10-03", "1 Tishrei 5785")
    T.eq(H.weekday(H.newYear(5785)), THURSDAY)
    T.eq(H.fixedFromGregorian(1, 1, 1), 1, "R.D. 1")
    T.eq(H.weekday(1), MONDAY, "R.D. 1 is a Monday")
    T.eq(H.fixedFromGregorian(1970, 1, 1), H.UNIX_EPOCH)
    T.eq(H.weekday(H.UNIX_EPOCH), THURSDAY)
    T.eq(H.newYear(1), H.EPOCH)
    -- The API examples' dates (tests/vectors/calendar/api-examples.json).
    T.eq(hebrew("2026-09-29"), "5787 tishrei 18")
    T.eq(hebrew("2024-10-04"), "5785 tishrei 2")
    T.eq(hebrew("2026-10-05"), "5787 tishrei 24")
    T.eq(hebrew("2026-06-25"), "5786 tamuz 10")
    T.eq(H.isLeapYear(5787), true)
    T.eq(H.isLeapYear(5786), false)
    T.eq(H.isLeapYear(5785), false)
end

function tests.every_day_from_1900_to_2199_goes_there_and_back()
    local first, last = H.fixedFromGregorian(1900, 1, 1), H.fixedFromGregorian(2199, 12, 31)
    local year, month, day = H.gregorianFromFixed(first - 1)
    local hebrewYear, hebrewMonth, hebrewDay = H.fromFixed(first - 1)
    for rd = first, last do
        local y, m, d = H.gregorianFromFixed(rd)
        if not (y == year and m == month and d == day + 1 or y == year and m == month + 1 and d == 1 or y == year + 1 and m == 1 and d == 1) then
            error("the day after " .. year .. "-" .. month .. "-" .. day .. " is " .. y .. "-" .. m .. "-" .. d)
        end
        year, month, day = y, m, d
        T.eq(H.fixedFromGregorian(y, m, d), rd)
        T.eq(H.parseDateKey(H.dateKey(rd)), rd)
        T.eq(H.weekday(rd), (H.weekday(rd - 1) + 1) % 7)

        local hy, hm, hd = H.fromFixed(rd)
        T.eq(H.toFixed(hy, hm, hd), rd, "Hebrew round trip of " .. H.dateKey(rd))
        if hd ~= hebrewDay + 1 or hm ~= hebrewMonth or hy ~= hebrewYear then
            -- A new month: day 1, after the last day of the month before.
            T.eq(hd, 1, "the day after " .. hebrewYear .. "/" .. hebrewMonth .. "/" .. hebrewDay)
            T.eq(hebrewDay, H.monthLength(hebrewYear, hebrewMonth), "a month ends on its last day")
            local lastBeforeNisan = H.isLeapYear(hebrewYear) and H.ADAR_2 or H.ADAR
            local nextMonth = hebrewMonth == H.ELUL and H.TISHREI or hebrewMonth == lastBeforeNisan and H.NISAN or hebrewMonth + 1
            T.eq(hm, nextMonth, "the month after " .. hebrewYear .. "/" .. hebrewMonth)
            if hm == H.TISHREI then
                T.eq(hy, hebrewYear + 1, "the year changes at Tishrei")
            else
                T.eq(hy, hebrewYear, "the year changes only at Tishrei")
            end
        end
        hebrewYear, hebrewMonth, hebrewDay = hy, hm, hd
    end
end

function tests.years_5600_to_6300_keep_the_calendar_rules()
    local LEAP_IN_CYCLE = { [0] = true, [3] = true, [6] = true, [8] = true, [11] = true, [14] = true, [17] = true }
    local LENGTHS = { [353] = true, [354] = true, [355] = true, [383] = true, [384] = true, [385] = true }
    for year = 5600, 6300 do
        local length = H.yearLength(year)
        T.truthy(LENGTHS[length], year .. " has " .. length .. " days")
        T.eq(length, H.newYear(year + 1) - H.newYear(year))
        T.eq(H.isLeapYear(year), length > 380, year .. ": the leap years are exactly the long ones")
        T.eq(H.isLeapYear(year), LEAP_IN_CYCLE[year % 19] == true, year .. ": years 3, 6, 8, 11, 14, 17 and 19 of the cycle")
        local newYear = H.weekday(H.newYear(year))
        T.truthy(newYear ~= SUNDAY and newYear ~= WEDNESDAY and newYear ~= FRIDAY, year .. ": Rosh Hashana is never on Sunday, Wednesday or Friday")
        local pesach = H.weekday(H.toFixed(year, H.NISAN, 15))
        T.truthy(pesach ~= MONDAY and pesach ~= WEDNESDAY and pesach ~= FRIDAY, year .. ": Pesach is never on Monday, Wednesday or Friday")
        local total = 0
        for month = 1, H.isLeapYear(year) and 13 or 12 do
            local days = H.monthLength(year, month)
            T.truthy(days == 29 or days == 30)
            total = total + days
        end
        T.eq(total, length, year .. ": the months add up to the year")
        T.eq(H.monthLength(year, H.CHESHVAN) == 30, length % 10 == 5, year .. ": a long Cheshvan in a full year")
        T.eq(H.monthLength(year, H.KISLEV) == 29, length % 10 == 3, year .. ": a short Kislev in a deficient year")
        T.eq(H.toFixed(year, H.ELUL, 29) + 1, H.newYear(year + 1))
    end
    -- Far out too: the parts arithmetic stays exact.
    for year = 3762, 9000 do
        local length = H.newYear(year + 1) - H.newYear(year)
        T.truthy(LENGTHS[length] and (length > 380) == H.isLeapYear(year), year .. " has " .. length .. " days")
    end
end

function tests.every_month_begins_on_the_day_hebcal_says()
    local vectors = Vectors.read("hebcal-months.json")
    local years = 0
    for key, months in pairs(vectors.years) do
        local year = tonumber(key)
        years = years + 1
        local count = 0
        for name, date in pairs(months) do
            local month = assert(HEBCAL_MONTHS[name], "a month Hebcal names " .. name)
            T.eq(H.dateKey(H.toFixed(year, month, 1)), date, "1 " .. name .. " " .. year)
            count = count + 1
        end
        T.eq(count, H.isLeapYear(year) and 12 or 11, year .. ": every month but Tishrei")
        T.eq(months["Adar I"] ~= nil, H.isLeapYear(year), year .. ": Adar I and II in leap years only")
        T.eq(H.newYear(year + 1), Vectors.rd(months["Elul"]) + 29, year .. ": Elul has 29 days")
    end
    T.eq(years, 301, "5660 to 5960")
end

function tests.adar_is_adar_i_and_adar_ii_in_a_leap_year()
    T.eq(H.monthKey(5786, H.ADAR), "adar")
    T.eq(H.monthKey(5786, H.ADAR_2), nil, "no Adar II in a common year")
    T.eq(H.monthKey(5787, H.ADAR), "adar_1")
    T.eq(H.monthKey(5787, H.ADAR_2), "adar_2")
    T.eq(hebrew("2026-02-18"), "5786 adar 1")
    T.eq(hebrew("2027-02-08"), "5787 adar_1 1")
    T.eq(hebrew("2027-03-10"), "5787 adar_2 1")
    T.eq(hebrew("2027-03-23"), "5787 adar_2 14", "Purim is in Adar II")
    T.eq(H.monthLength(5787, H.ADAR), 30)
    T.eq(H.monthLength(5787, H.ADAR_2), 29)
    T.eq(H.monthLength(5786, H.ADAR), 29)
    T.truthy(not pcall(H.toFixed, 5786, H.ADAR_2, 1), "a common year has no Adar II")
    T.truthy(not pcall(H.monthLength, 5786, H.ADAR_2), "nor its length")
    -- All 14 keys, in a common and a leap year, each with its English name.
    local keys = {}
    for _, year in ipairs({ 5786, 5787 }) do
        for month = 1, H.isLeapYear(year) and 13 or 12 do
            keys[H.monthKey(year, month)] = true
        end
    end
    local count = 0
    for key in pairs(keys) do
        count = count + 1
        T.truthy(H.MONTH_NAMES[key], "an English name for " .. key)
    end
    T.eq(count, 14)
end

function tests.dates_are_written_and_read_as_iso()
    T.eq(H.dateKey(H.fixedFromGregorian(2026, 10, 3)), "2026-10-03")
    T.eq(H.parseDateKey("2024-02-29"), H.fixedFromGregorian(2024, 2, 29))
    for _, text in ipairs({ "2023-02-29", "2026-13-01", "2026-04-31", "2026-00-10", "2026-1-01", "tomorrow", "" }) do
        T.eq(H.parseDateKey(text), nil, text)
    end
end

function tests.the_year_cache_gives_the_same_answers_in_any_order()
    local expected = {}
    for year = 5700, 5730 do
        expected[year] = { H.toFixed(year, H.NISAN, 15), H.yearLength(year), H.monthLength(year, H.KISLEV) }
    end
    -- Many more years than the cache keeps, interleaved and backwards.
    for pass = 1, 3 do
        for index = 0, 30 do
            local year = pass == 2 and 5730 - index or 5700 + (index * 7) % 31
            T.same({ H.toFixed(year, H.NISAN, 15), H.yearLength(year), H.monthLength(year, H.KISLEV) }, expected[year], tostring(year))
            T.eq(select(1, H.fromFixed(expected[year][1])), year)
        end
    end
end

return tests
