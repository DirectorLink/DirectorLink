-- The holidays (src/core/holidays.lua, ADR-037) against Hebcal's for the Hebrew years 5760-5820,
-- in Israel and abroad (tests/vectors/calendar/hebcal-years.json): the same days, the same keys,
-- day numbers and months, and the same holy days (Yom Tov).

local T = require("helpers")
local Vectors = require("calendar_vectors")
local HebrewDate = require("src.core.hebrew_date")
local Holidays = require("src.core.holidays")

local tests = {}

local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8 }

local MONTHS = {
    ["Cheshvan"] = "cheshvan", ["Kislev"] = "kislev", ["Tevet"] = "tevet", ["Sh'vat"] = "shvat",
    ["Adar"] = "adar", ["Adar I"] = "adar_1", ["Adar II"] = "adar_2", ["Nisan"] = "nisan",
    ["Iyyar"] = "iyar", ["Sivan"] = "sivan", ["Tamuz"] = "tamuz", ["Av"] = "av", ["Elul"] = "elul",
}

local SAME = {
    ["Tzom Gedaliah"] = "tzom_gedaliah",
    ["Yom Kippur"] = "yom_kippur",
    ["Sukkot VII (Hoshana Raba)"] = "hoshana_rabba",
    ["Simchat Torah"] = "simchat_torah",
    ["Asara B'Tevet"] = "asara_btevet",
    ["Tu BiShvat"] = "tu_bishvat",
    ["Ta'anit Esther"] = "taanit_esther",
    ["Purim"] = "purim",
    ["Shushan Purim"] = "shushan_purim",
    ["Pesach VII"] = "pesach_7",
    ["Pesach VIII"] = "pesach_8",
    ["Lag BaOmer"] = "lag_baomer",
    ["Tzom Tammuz"] = "shiva_asar_btamuz",
    ["Tish'a B'Av"] = "tisha_bav",
    ["Tish'a B'Av (observed)"] = "tisha_bav",
}

-- Kept by today's rules from 5764 on; Hebcal has them from earlier years.
local NATIONAL_FROM = 5764
local NATIONAL = {
    ["Yom HaShoah"] = "yom_hashoah",
    ["Yom HaZikaron"] = "yom_hazikaron",
    ["Yom HaAtzma'ut"] = "yom_haatzmaut",
    ["Yom Yerushalayim"] = "yom_yerushalayim",
}

-- Hebcal's other days, which the calendar does not keep.
local NOT_KEPT = {
    ["Erev Rosh Hashana"] = true, ["Erev Yom Kippur"] = true, ["Erev Sukkot"] = true, ["Erev Pesach"] = true,
    ["Erev Shavuot"] = true, ["Erev Purim"] = true, ["Erev Tish'a B'Av"] = true, ["Chanukah: 1 Candle"] = true,
    ["Leil Selichot"] = true, ["Rosh Hashana LaBehemot"] = true, ["Chag HaBanot"] = true, ["Ta'anit Bechorot"] = true,
    ["Purim Katan"] = true, ["Shushan Purim Katan"] = true, ["Purim Meshulash"] = true, ["Pesach Sheni"] = true,
    ["Tu B'Av"] = true, ["Birkat Hachamah"] = true, ["Sigd"] = true, ["Yom HaAliyah"] = true,
    ["Yom HaAliyah School Observance"] = true, ["Yitzhak Rabin Memorial Day"] = true, ["Ben-Gurion Day"] = true,
    ["Hebrew Language Day"] = true, ["Family Day"] = true, ["Herzl Day"] = true, ["Jabotinsky Day"] = true,
}

-- Hebcal's title as our entries: a list of { key, day, month }, or nil for a day we do not keep.
local function entriesFor(title, israel, year)
    if title:match("^Rosh Hashana %d+$") then
        return { { "rosh_hashana", 1 } }
    elseif title == "Rosh Hashana II" then
        return { { "rosh_hashana", 2 } }
    elseif title == "Shmini Atzeret" then
        -- In Israel one day is both.
        return israel and { { "shmini_atzeret" }, { "simchat_torah" } } or { { "shmini_atzeret" } }
    elseif SAME[title] then
        return { { SAME[title] } }
    elseif NATIONAL[title] then
        return year >= NATIONAL_FROM and { { NATIONAL[title] } } or {}
    end
    local festival, numeral, rest = title:match("^(%a+) (%u+)(.*)$")
    if (festival == "Sukkot" or festival == "Pesach") and ROMAN[numeral] then
        if rest == " (CH''M)" then
            return { { festival == "Sukkot" and "chol_hamoed_sukkot" or "chol_hamoed_pesach" } }
        elseif rest == "" and ROMAN[numeral] <= 2 then
            -- The first day, and abroad the second: numbered only where there are two.
            return { { string.lower(festival), not israel and ROMAN[numeral] or nil } }
        end
    end
    if title == "Shavuot" then
        return { { "shavuot" } }
    end
    local shavuot = title:match("^Shavuot (I+)$")
    if shavuot then
        return { { "shavuot", ROMAN[shavuot] } }
    end
    local candles = tonumber(title:match("^Chanukah: (%d) Candles$"))
    if candles then
        -- Hebcal dates each evening's candles; the day they begin is one less.
        return { { "chanukah", candles - 1 } }
    elseif title == "Chanukah: 8th Day" then
        return { { "chanukah", 8 } }
    end
    local month = title:match("^Rosh Chodesh (.+)$")
    if month then
        return { { "rosh_chodesh", nil, assert(MONTHS[month], "a month named " .. month) } }
    end
    if NOT_KEPT[title] then
        return nil
    end
    error("Hebcal has a day this test does not know: " .. title)
end

local function describe(date, key, day, month, yomTov)
    return date .. " " .. key .. (day and (" " .. day) or "") .. (month and (" " .. month) or "") .. (yomTov and " (yom tov)" or "")
end

-- Hebcal's events of a year in Israel or abroad, as our entries described.
local function expected(year, israel)
    local data = Vectors.read("hebcal-years.json").years[tostring(year)]
    local result = {}
    for _, list in ipairs({ data.both, israel and data.israel or data.abroad }) do
        for _, event in ipairs(list) do
            local date, title, yomTov = event[1], event[2], event[3] == true
            if not title:match("^Parashat ") then
                for _, entry in ipairs(entriesFor(title, israel, year) or {}) do
                    result[#result + 1] = describe(date, entry[1], entry[2], entry[3], yomTov)
                end
            end
        end
    end
    table.sort(result)
    return result
end

local function actual(year, israel)
    local result = {}
    for _, entry in ipairs(Holidays.forYear(year, israel)) do
        result[#result + 1] = describe(HebrewDate.dateKey(entry.rd), entry.key, entry.day, entry.month, entry.yom_tov)
    end
    table.sort(result)
    return result
end

local function differences(want, got)
    local count, seen, lines = 0, {}, {}
    for _, line in ipairs(want) do
        seen[line] = (seen[line] or 0) + 1
    end
    for _, line in ipairs(got) do
        seen[line] = (seen[line] or 0) - 1
    end
    for line, balance in pairs(seen) do
        if balance ~= 0 then
            count = count + 1
            lines[#lines + 1] = (balance > 0 and "missing " or "extra ") .. line
        end
    end
    table.sort(lines)
    return count, table.concat(lines, "; ", 1, math.min(#lines, 6))
end

function tests.every_holiday_is_hebcals_in_israel_and_abroad()
    local years, entries = 0, 0
    for year = 5760, 5820 do
        for _, israel in ipairs({ true, false }) do
            local want, got = expected(year, israel), actual(year, israel)
            local count, detail = differences(want, got)
            T.eq(count, 0, year .. (israel and " in Israel" or " abroad") .. ": " .. detail)
            entries = entries + #got
        end
        years = years + 1
    end
    T.eq(years, 61)
    T.truthy(entries > 61 * 2 * 55, "about 60 a year, " .. entries .. " in all")
end

function tests.the_entries_are_in_order_and_found_by_date()
    for _, israel in ipairs({ true, false }) do
        for year = 5785, 5788 do
            local entries = Holidays.forYear(year, israel)
            local previous
            for index, entry in ipairs(entries) do
                T.truthy(select(1, HebrewDate.fromFixed(entry.rd)) == year, "in the year")
                if previous then
                    T.truthy(previous.rd < entry.rd or previous.rd == entry.rd and index > 1, "in date order")
                end
                previous = entry
            end
            local first, last = HebrewDate.newYear(year), HebrewDate.newYear(year + 1) - 1
            local index = 1
            for rd = first, last do
                local onDate, yomTov = Holidays.onDate(rd, israel), false
                for _, entry in ipairs(onDate) do
                    T.eq(entry, entries[index], "onDate gives forYear's entries of the day, in order")
                    index = index + 1
                    yomTov = yomTov or entry.yom_tov
                end
                T.eq(Holidays.isYomTov(rd, israel), yomTov)
            end
            T.eq(index, #entries + 1)
        end
    end
end

function tests.a_day_can_have_several()
    local function keys(date, israel)
        local list = {}
        for _, entry in ipairs(Holidays.onDate(Vectors.rd(date), israel)) do
            list[#list + 1] = entry.key .. (entry.day and (":" .. entry.day) or "") .. (entry.month and (":" .. entry.month) or "")
        end
        return table.concat(list, ",")
    end
    -- The API examples (tests/vectors/calendar/api-examples.json) and their abroad days.
    T.eq(keys("2026-09-29", true), "chol_hamoed_sukkot")
    T.eq(keys("2026-10-03", true), "shmini_atzeret,simchat_torah")
    T.eq(keys("2026-10-03", false), "shmini_atzeret")
    T.eq(keys("2026-10-04", false), "simchat_torah")
    T.eq(keys("2024-10-04", true), "rosh_hashana:2")
    T.eq(keys("2024-10-05", true), "", "Tzom Gedaliah moves off Shabbat")
    T.eq(keys("2024-10-06", true), "tzom_gedaliah")
    -- Chanukah over Rosh Chodesh Tevet, 5786 (Kislev has 30 days).
    T.eq(keys("2025-12-20", true), "chanukah:6,rosh_chodesh:tevet")
    T.eq(keys("2025-12-21", true), "chanukah:7,rosh_chodesh:tevet")
    -- One day of Yom Tov in Israel, numbered days abroad.
    T.eq(keys("2027-06-11", true), "shavuot")
    T.eq(keys("2027-06-11", false), "shavuot:1")
    T.eq(keys("2027-06-12", false), "shavuot:2")
    T.eq(keys("2027-06-12", true), "")
    T.eq(Holidays.isYomTov(Vectors.rd("2027-06-12"), false), true)
    T.eq(Holidays.isYomTov(Vectors.rd("2027-06-12"), true), false)
    T.eq(Holidays.isYomTov(Vectors.rd("2026-10-10"), true), false, "Shabbat itself is not a holiday here")
end

function tests.keys_and_names_follow_the_contract()
    -- The same 27 keys, in the same order, as HolidayKey in api/openapi.yaml.
    local file = assert(io.open("api/openapi.yaml", "rb"))
    local spec = file:read("*a")
    file:close()
    local enum = assert(spec:match("\n    HolidayKey:.-\n      enum: %[([^%]]+)%]"), "HolidayKey in api/openapi.yaml")
    local keys = {}
    for key in enum:gmatch("[%w_]+") do
        keys[#keys + 1] = key
    end
    T.same(Holidays.KEYS, keys)
    T.eq(#Holidays.KEYS, 27)
    for _, key in ipairs(Holidays.KEYS) do
        T.truthy(Holidays.NAMES[key], "an English name for " .. key)
        T.notContains(Holidays.NAMES[key], "\226\128\153", "ASCII apostrophes, as in Hebcal's titles")
    end
    T.eq(Holidays.name({ key = "rosh_chodesh", month = "cheshvan" }), "Rosh Chodesh Cheshvan")
    T.eq(Holidays.name({ key = "rosh_chodesh", month = "adar_2" }), "Rosh Chodesh Adar II")
    T.eq(Holidays.name({ key = "shmini_atzeret" }), "Shmini Atzeret")
    -- The months as HebrewMonth in api/openapi.yaml.
    local months = assert(spec:match("\n    HebrewMonth:.-\n      enum: %[([^%]]+)%]"), "HebrewMonth in api/openapi.yaml")
    local count = 0
    for key in months:gmatch("[%w_]+") do
        count = count + 1
        T.truthy(HebrewDate.MONTH_NAMES[key], key)
    end
    T.eq(count, 14)
end

function tests.a_returned_list_is_the_callers()
    local list = Holidays.onDate(Vectors.rd("2026-10-03"), true)
    list[#list + 1] = "changed"
    T.eq(#Holidays.onDate(Vectors.rd("2026-10-03"), true), 2, "the cache is untouched")
    local year = Holidays.forYear(5787, true)
    local count = #year
    year[#year + 1] = "changed"
    T.eq(#Holidays.forYear(5787, true), count)
end

return tests
