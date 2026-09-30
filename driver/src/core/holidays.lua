-- The holidays of the Hebrew calendar (ADR-037, docs/CALENDAR.md): the holy days (Yom Tov), kept
-- like Shabbat, and the days that are only shown (fasts, Chanukah, Rosh Chodesh, the national
-- days), in Israel (one day of Yom Tov) or abroad (two). Pure: no Director, no clock, no time zone.
-- An entry is { rd, key, day = n|nil, yom_tov = bool, month = monthKey|nil }:
-- - rd: the civil date whose daytime it is (a holiday begins at the sunset before);
-- - day: which day, for one kept on several days (Rosh Hashana 1-2, Chanukah 1-8, and abroad the
--   first two days of Sukkot, Pesach and Shavuot); nil otherwise;
-- - month: for rosh_chodesh only, the month that begins (HebrewDate.monthKey).
-- The entries are shared: read them, do not change them.

local HebrewDate = require("src.core.hebrew_date")

local Holidays = {}

Holidays.KEYS = {
    "rosh_hashana", "tzom_gedaliah", "yom_kippur", "sukkot", "chol_hamoed_sukkot", "hoshana_rabba",
    "shmini_atzeret", "simchat_torah", "chanukah", "asara_btevet", "tu_bishvat", "taanit_esther",
    "purim", "shushan_purim", "pesach", "chol_hamoed_pesach", "pesach_7", "pesach_8", "yom_hashoah",
    "yom_haatzmaut", "yom_hazikaron", "lag_baomer", "yom_yerushalayim", "shavuot", "shiva_asar_btamuz",
    "tisha_bav", "rosh_chodesh",
}

-- English, for Composer, the log and the API's `name` (apps show their own names by key).
Holidays.NAMES = {
    rosh_hashana = "Rosh Hashana",
    tzom_gedaliah = "Tzom Gedaliah",
    yom_kippur = "Yom Kippur",
    sukkot = "Sukkot",
    chol_hamoed_sukkot = "Chol HaMoed Sukkot",
    hoshana_rabba = "Hoshana Rabba",
    shmini_atzeret = "Shmini Atzeret",
    simchat_torah = "Simchat Torah",
    chanukah = "Chanukah",
    asara_btevet = "Asara B'Tevet",
    tu_bishvat = "Tu BiShvat",
    taanit_esther = "Ta'anit Esther",
    purim = "Purim",
    shushan_purim = "Shushan Purim",
    pesach = "Pesach",
    chol_hamoed_pesach = "Chol HaMoed Pesach",
    pesach_7 = "Seventh day of Pesach",
    pesach_8 = "Eighth day of Pesach",
    yom_hashoah = "Yom HaShoah",
    yom_haatzmaut = "Yom HaAtzma'ut",
    yom_hazikaron = "Yom HaZikaron",
    lag_baomer = "Lag BaOmer",
    yom_yerushalayim = "Yom Yerushalayim",
    shavuot = "Shavuot",
    shiva_asar_btamuz = "Tzom Tammuz",
    tisha_bav = "Tish'a B'Av",
    rosh_chodesh = "Rosh Chodesh",
}

-- The four national days are kept by today's rules, from 5764 (2004) on.
Holidays.NATIONAL_FROM = 5764

local ORDER = {}
for index, key in ipairs(Holidays.KEYS) do
    ORDER[key] = index
end

local NISAN, IYAR, SIVAN, TAMUZ, AV = HebrewDate.NISAN, HebrewDate.IYAR, HebrewDate.SIVAN, HebrewDate.TAMUZ, HebrewDate.AV
local TISHREI, KISLEV, TEVET, SHVAT, ADAR, ADAR_2 = HebrewDate.TISHREI, HebrewDate.KISLEV, HebrewDate.TEVET, HebrewDate.SHVAT, HebrewDate.ADAR, HebrewDate.ADAR_2
local SUNDAY, MONDAY, FRIDAY, SATURDAY = 0, 1, 5, 6

local function weekday(rd)
    return HebrewDate.weekday(rd)
end

local function build(year, israel)
    local entries = {}
    local function add(rd, key, day, yomTov, month)
        entries[#entries + 1] = { rd = rd, key = key, day = day, yom_tov = yomTov == true, month = month }
    end
    local function date(month, day)
        return HebrewDate.toFixed(year, month, day)
    end
    -- A fast that would fall on Shabbat moves to the day after (or, Ta'anit Esther, to Thursday).
    local function fast(month, day, key, earlier)
        local rd = date(month, day)
        if weekday(rd) == SATURDAY then
            rd = earlier and rd - 2 or rd + 1
        end
        add(rd, key)
    end
    -- The first days of Sukkot, Pesach and Shavuot: one day in Israel, two abroad.
    local function yomTov(month, day, key)
        if israel then
            add(date(month, day), key, nil, true)
        else
            add(date(month, day), key, 1, true)
            add(date(month, day + 1), key, 2, true)
        end
    end
    local adar = HebrewDate.isLeapYear(year) and ADAR_2 or ADAR
    local holidayStart = israel and 16 or 17

    add(date(TISHREI, 1), "rosh_hashana", 1, true)
    add(date(TISHREI, 2), "rosh_hashana", 2, true)
    fast(TISHREI, 3, "tzom_gedaliah")
    add(date(TISHREI, 10), "yom_kippur", nil, true)
    yomTov(TISHREI, 15, "sukkot")
    for day = holidayStart, 20 do
        add(date(TISHREI, day), "chol_hamoed_sukkot")
    end
    add(date(TISHREI, 21), "hoshana_rabba")
    add(date(TISHREI, 22), "shmini_atzeret", nil, true)
    add(date(TISHREI, israel and 22 or 23), "simchat_torah", nil, true)
    for day = 1, 8 do
        add(date(KISLEV, 25) + day - 1, "chanukah", day)
    end
    add(date(TEVET, 10), "asara_btevet")
    add(date(SHVAT, 15), "tu_bishvat")
    fast(adar, 13, "taanit_esther", true)
    add(date(adar, 14), "purim")
    add(date(adar, 15), "shushan_purim")
    yomTov(NISAN, 15, "pesach")
    for day = holidayStart, 20 do
        add(date(NISAN, day), "chol_hamoed_pesach")
    end
    add(date(NISAN, 21), "pesach_7", nil, true)
    if not israel then
        add(date(NISAN, 22), "pesach_8", nil, true)
    end
    if year >= Holidays.NATIONAL_FROM then
        -- Moved off Friday and Sunday, so that none of them touches Shabbat.
        local shoah = date(NISAN, 27)
        if weekday(shoah) == FRIDAY then
            shoah = shoah - 1
        elseif weekday(shoah) == SUNDAY then
            shoah = shoah + 1
        end
        add(shoah, "yom_hashoah")
        local independence = date(IYAR, 5)
        if weekday(independence) == FRIDAY then
            independence = independence - 1
        elseif weekday(independence) == SATURDAY then
            independence = independence - 2
        elseif weekday(independence) == MONDAY then
            independence = independence + 1
        end
        add(independence - 1, "yom_hazikaron")
        add(independence, "yom_haatzmaut")
        add(date(IYAR, 28), "yom_yerushalayim")
    end
    add(date(IYAR, 18), "lag_baomer")
    yomTov(SIVAN, 6, "shavuot")
    fast(TAMUZ, 17, "shiva_asar_btamuz")
    fast(AV, 9, "tisha_bav")
    -- Rosh Chodesh: the 1st of every month but Tishrei, and the 30th of the month before, when it
    -- has 30 days.
    local previous = TISHREI
    for _, month in ipairs({ HebrewDate.CHESHVAN, KISLEV, TEVET, SHVAT, ADAR, ADAR_2, NISAN, IYAR, SIVAN, TAMUZ, AV, HebrewDate.ELUL }) do
        if month ~= ADAR_2 or HebrewDate.isLeapYear(year) then
            local key = HebrewDate.monthKey(year, month)
            if HebrewDate.monthLength(year, previous) == 30 then
                add(date(previous, 30), "rosh_chodesh", nil, false, key)
            end
            add(date(month, 1), "rosh_chodesh", nil, false, key)
            previous = month
        end
    end

    table.sort(entries, function(a, b)
        if a.rd ~= b.rd then
            return a.rd < b.rd
        end
        return ORDER[a.key] < ORDER[b.key]
    end)
    local byRd, holy = {}, {}
    for _, entry in ipairs(entries) do
        byRd[entry.rd] = byRd[entry.rd] or {}
        table.insert(byRd[entry.rd], entry)
        if entry.yom_tov then
            holy[entry.rd] = true
        end
    end
    return { year = year, israel = israel, entries = entries, byRd = byRd, holy = holy }
end

-- The years in use, in Israel or abroad: most recently used first.
local CACHED_YEARS = 6
local cache = {}

local function yearData(year, israel)
    israel = israel == true
    for index, data in ipairs(cache) do
        if data.year == year and data.israel == israel then
            if index > 1 then
                table.remove(cache, index)
                table.insert(cache, 1, data)
            end
            return data
        end
    end
    local data = build(year, israel)
    table.insert(cache, 1, data)
    cache[CACHED_YEARS + 1] = nil
    return data
end

local function copy(list)
    local result = {}
    for index, value in ipairs(list or {}) do
        result[index] = value
    end
    return result
end

-- The Hebrew year's entries (Tishrei to Elul), in date order and, on a day, in KEYS order.
function Holidays.forYear(year, israel)
    return copy(yearData(year, israel).entries)
end

-- The entries of a civil date (its daytime), possibly none.
function Holidays.onDate(rd, israel)
    local year = HebrewDate.fromFixed(rd)
    return copy(yearData(year, israel).byRd[rd])
end

-- A holy day (Yom Tov), kept like Shabbat. Shabbat itself is not a holiday here.
function Holidays.isYomTov(rd, israel)
    local year = HebrewDate.fromFixed(rd)
    return yearData(year, israel).holy[rd] == true
end

-- An entry's English name: "Rosh Chodesh Cheshvan" names the month.
function Holidays.name(entry)
    if entry.key == "rosh_chodesh" and entry.month then
        return Holidays.NAMES.rosh_chodesh .. " " .. HebrewDate.MONTH_NAMES[entry.month]
    end
    return Holidays.NAMES[entry.key]
end

return Holidays
