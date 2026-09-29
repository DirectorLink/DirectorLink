-- The weekly Torah reading (parashat ha-shavua) of every Shabbat, in Israel or abroad (ADR-037,
-- docs/CALENDAR.md). Pure: no Director, no clock, no time zone.
-- The rules are Shulchan Aruch, Orach Chaim 428:4, as the MIT-licensed pyluach library formulates
-- them (written here from those rules, not from its code). A year's readings depend only on its
-- type (the weekdays of Rosh Hashana and Pesach, and its length) and on Israel or abroad, so the
-- tests' check of every year type in both proves them for every year.
-- Readings are numbered 1 (Bereshit) to 54 (Vezot Haberakhah, read on Simchat Torah, never on a
-- Shabbat); a Shabbat reads one, two combined, or none when a holiday reading replaces it.

local HebrewDate = require("src.core.hebrew_date")

local Parasha = {}

-- English, in Hebcal's spelling (apps show their own names by id).
Parasha.NAMES = {
    "Bereshit", "Noach", "Lech-Lecha", "Vayera", "Chayei Sara", "Toldot", "Vayetzei", "Vayishlach",
    "Vayeshev", "Miketz", "Vayigash", "Vayechi", "Shemot", "Vaera", "Bo", "Beshalach", "Yitro",
    "Mishpatim", "Terumah", "Tetzaveh", "Ki Tisa", "Vayakhel", "Pekudei", "Vayikra", "Tzav", "Shmini",
    "Tazria", "Metzora", "Achrei Mot", "Kedoshim", "Emor", "Behar", "Bechukotai", "Bamidbar", "Nasso",
    "Beha'alotcha", "Sh'lach", "Korach", "Chukat", "Balak", "Pinchas", "Matot", "Masei", "Devarim",
    "Vaetchanan", "Eikev", "Re'eh", "Shoftim", "Ki Teitzei", "Ki Tavo", "Nitzavim", "Vayeilech",
    "Ha'azinu", "Vezot Haberakhah",
}

local NISAN, SIVAN, AV, TISHREI = HebrewDate.NISAN, HebrewDate.SIVAN, HebrewDate.AV, HebrewDate.TISHREI
local THURSDAY, SATURDAY = 4, 6

local VAYAKHEL, TAZRIA, ACHREI_MOT, BEHAR, CHUKAT, MATOT, NITZAVIM, VAYEILECH, HAAZINU = 22, 27, 29, 32, 39, 42, 51, 52, 53

-- Shabbatot that read for the holiday instead: 1, 2, 10 and 15-22 Tishrei, 15-21 Nisan and
-- 6 Sivan, and abroad also 23 Tishrei, 22 Nisan and 7 Sivan (the second days).
local function holidayReading(rd, israel)
    local _, month, day = HebrewDate.fromFixed(rd)
    local extra = israel and 0 or 1
    if month == TISHREI then
        return day == 1 or day == 2 or day == 10 or (day >= 15 and day <= 22 + extra)
    elseif month == NISAN then
        return day >= 15 and day <= 21 + extra
    elseif month == SIVAN then
        return day >= 6 and day <= 6 + extra
    end
    return false
end

local function weekdayIs(rd, ...)
    local weekday = HebrewDate.weekday(rd)
    for _, wanted in ipairs({ ... }) do
        if weekday == wanted then
            return true
        end
    end
    return false
end

local function build(year, israel)
    local newYear, nextYear = HebrewDate.newYear(year), HebrewDate.newYear(year + 1)
    local leap = HebrewDate.isLeapYear(year)
    local nisan14 = HebrewDate.toFixed(year, NISAN, 14)
    local pesachOnShabbat = HebrewDate.weekday(nisan14 + 1) == SATURDAY
    local pesachOnThursday = HebrewDate.weekday(nisan14 + 1) == THURSDAY
    local av9 = HebrewDate.toFixed(year, AV, 9)
    local nextOnThursdayOrShabbat = weekdayIs(nextYear, THURSDAY, SATURDAY)

    -- Vayeilech and Ha'azinu finish last year's cycle; Vayeilech was read with Nitzavim when this
    -- Rosh Hashana is on a Thursday or Shabbat.
    local list = { VAYEILECH, HAAZINU }
    for id = 1, VAYEILECH do
        list[#list + 1] = id
    end
    local position = weekdayIs(newYear, THURSDAY, SATURDAY) and 2 or 1
    local function take()
        local id = list[position]
        position = position + 1
        return id
    end
    local function combined(id, shabbat)
        if id == VAYAKHEL then
            return math.floor((nisan14 - shabbat) / 7) < 3
        elseif id == TAZRIA or id == ACHREI_MOT then
            return not leap
        elseif id == BEHAR then
            return not leap and not (israel and pesachOnShabbat)
        elseif id == CHUKAT then
            return not israel and pesachOnThursday
        elseif id == MATOT then
            return math.floor((av9 - shabbat) / 7) < 2
        elseif id == NITZAVIM then
            return nextOnThursdayOrShabbat
        end
        return false
    end

    local shabbatot, byRd = {}, {}
    local shabbat = newYear + (SATURDAY - HebrewDate.weekday(newYear)) % 7
    while shabbat < nextYear do
        local entry = { rd = shabbat }
        if not holidayReading(shabbat, israel) then
            local id = take()
            entry.ids = { id }
            if combined(id, shabbat) then
                entry.ids[2] = take()
            end
        end
        shabbatot[#shabbatot + 1] = entry
        byRd[shabbat] = entry
        shabbat = shabbat + 7
    end
    return { year = year, israel = israel, shabbatot = shabbatot, byRd = byRd }
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

-- Every Shabbat of the Hebrew year, in order: { { rd = rd, ids = { id, id? } | nil }, ... } (ids
-- nil for a holiday reading). Shared: read it, do not change it.
function Parasha.yearTable(year, israel)
    return yearData(year, israel).shabbatot
end

-- The reading of the Shabbat `rd`: { id } or { id, id } (a new table), or nil for a holiday reading.
function Parasha.forShabbat(rd, israel)
    if HebrewDate.weekday(rd) ~= SATURDAY then
        error("Parasha.forShabbat: " .. HebrewDate.dateKey(rd) .. " is not a Saturday", 2)
    end
    local year = HebrewDate.fromFixed(rd)
    local ids = yearData(year, israel).byRd[rd].ids
    return ids and { ids[1], ids[2] } or nil
end

-- "Bereshit", "Vayakhel-Pekudei"; nil for nil.
function Parasha.name(ids)
    if not ids then
        return nil
    end
    local names = {}
    for index, id in ipairs(ids) do
        names[index] = Parasha.NAMES[id]
    end
    return table.concat(names, "-")
end

return Parasha
