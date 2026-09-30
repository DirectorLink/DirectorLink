-- The weekly readings (src/core/parasha.lua, ADR-037) against Hebcal's for every Shabbat of the
-- Hebrew years 5760-5820, in Israel and abroad (tests/vectors/calendar/hebcal-years.json). The
-- readings depend only on the year's type and the place, and these years have all 14 types.

local T = require("helpers")
local Vectors = require("calendar_vectors")
local HebrewDate = require("src.core.hebrew_date")
local Parasha = require("src.core.parasha")

local tests = {}

local FIRST, LAST = 5760, 5820
local COMBINED = { ["22-23"] = true, ["27-28"] = true, ["29-30"] = true, ["32-33"] = true, ["39-40"] = true, ["42-43"] = true, ["51-52"] = true }

-- Hebcal's readings of a year: date -> name ("Vayakhel-Pekudei").
local function hebcal(year, israel)
    local data = Vectors.read("hebcal-years.json").years[tostring(year)]
    local result = {}
    for _, list in ipairs({ data.both, israel and data.israel or data.abroad }) do
        for _, event in ipairs(list) do
            local name = event[2]:match("^Parashat (.+)$")
            if name then
                result[event[1]] = name
            end
        end
    end
    return result
end

-- Every Shabbat of the years, in order: { rd, ids|nil }.
local function shabbatot(israel)
    local list = {}
    for year = FIRST, LAST do
        for _, entry in ipairs(Parasha.yearTable(year, israel)) do
            list[#list + 1] = entry
        end
    end
    return list
end

function tests.every_shabbat_reads_as_hebcal_says()
    local count = 0
    for year = FIRST, LAST do
        for _, israel in ipairs({ true, false }) do
            local want = hebcal(year, israel)
            local seen = 0
            for _, entry in ipairs(Parasha.yearTable(year, israel)) do
                local date = HebrewDate.dateKey(entry.rd)
                T.eq(Parasha.name(entry.ids), want[date], date .. (israel and " in Israel" or " abroad"))
                T.same(Parasha.forShabbat(entry.rd, israel), entry.ids)
                if want[date] then
                    seen = seen + 1
                end
                count = count + 1
            end
            local total = 0
            for _ in pairs(want) do
                total = total + 1
            end
            T.eq(seen, total, year .. ": every reading Hebcal has is on one of the year's Shabbatot")
        end
    end
    T.truthy(count > 6000, count .. " Shabbatot")
end

function tests.each_cycle_reads_every_parasha_once_in_order()
    for _, israel in ipairs({ true, false }) do
        local cycles, cycle = 0, nil
        for _, entry in ipairs(shabbatot(israel)) do
            for _, id in ipairs(entry.ids or {}) do
                if id == 1 then
                    if cycle then
                        T.eq(#cycle, 53, "a whole cycle")
                        cycles = cycles + 1
                    end
                    cycle = {}
                end
                if cycle then
                    T.eq(id, #cycle + 1, "the readings follow each other")
                    cycle[#cycle + 1] = id
                end
            end
        end
        T.eq(cycles, LAST - FIRST, "one cycle a year")
    end
end

function tests.only_the_seven_combined_readings_occur()
    local found = {}
    for _, israel in ipairs({ true, false }) do
        for _, entry in ipairs(shabbatot(israel)) do
            if entry.ids and #entry.ids == 2 then
                local pair = entry.ids[1] .. "-" .. entry.ids[2]
                T.truthy(COMBINED[pair], "a combined reading " .. pair)
                found[pair] = true
            end
            T.truthy(not entry.ids or #entry.ids <= 2)
        end
    end
    for pair in pairs(COMBINED) do
        T.truthy(found[pair], pair .. " occurs")
    end
end

-- Israel reads ahead of abroad only after a Shabbat that is a holy day abroad alone (the eighth
-- day of Pesach, the second of Shavuot), until a reading combined abroad is read apart in Israel.
function tests.israel_differs_only_after_a_holy_day_kept_only_abroad()
    local differing, apart = 0, 0
    for year = FIRST, LAST do
        local israel, abroad = Parasha.yearTable(year, true), Parasha.yearTable(year, false)
        T.eq(#israel, #abroad)
        local ahead = false
        for index, entry in ipairs(israel) do
            local here, there = Parasha.name(entry.ids), Parasha.name(abroad[index].ids)
            if here ~= there then
                if not ahead then
                    local _, month, day = HebrewDate.fromFixed(entry.rd)
                    T.truthy(month == HebrewDate.NISAN and day == 22 or month == HebrewDate.SIVAN and day == 7, HebrewDate.dateKey(entry.rd) .. " is where they part")
                    T.eq(there, nil, "abroad reads for the holiday")
                    ahead = true
                    apart = apart + 1
                end
                differing = differing + 1
            elseif ahead then
                ahead = false
            end
        end
        T.eq(ahead, false, year .. ": they meet again before the year ends")
    end
    T.truthy(apart > 5 and differing > apart, "it happens")
    -- Shabbat 12 June 2027: Nasso in Israel, the second day of Shavuot abroad.
    local rd = Vectors.rd("2027-06-12")
    T.eq(Parasha.name(Parasha.forShabbat(rd, true)), "Nasso")
    T.eq(Parasha.forShabbat(rd, false), nil)
end

function tests.all_fourteen_year_types_are_checked_in_both_places()
    local types, count = {}, 0
    for year = FIRST, LAST do
        local key = HebrewDate.weekday(HebrewDate.newYear(year)) .. "/" .. HebrewDate.yearLength(year)
        if not types[key] then
            types[key] = true
            count = count + 1
        end
    end
    T.eq(count, 14)
end

function tests.names_are_hebcals()
    T.eq(#Parasha.NAMES, 54)
    T.eq(Parasha.NAMES[1], "Bereshit")
    T.eq(Parasha.NAMES[53], "Ha'azinu")
    T.eq(Parasha.NAMES[54], "Vezot Haberakhah")
    T.eq(Parasha.name({ 22, 23 }), "Vayakhel-Pekudei")
    T.eq(Parasha.name({ 1 }), "Bereshit")
    T.eq(Parasha.name(nil), nil)
    -- Every name Hebcal gives (names.json) is ours, and each of ours but Vezot Haberakhah is Hebcal's.
    local names = Vectors.read("names.json").parashot
    local byName = {}
    for id, name in ipairs(Parasha.NAMES) do
        byName[name] = id
    end
    for name in pairs(names) do
        local first, second = name:match("^(.-)%-(%u.*)$")
        if first and byName[first] and byName[second] then
            T.truthy(COMBINED[byName[first] .. "-" .. byName[second]], name)
        else
            T.truthy(byName[name], name .. " is one of Parasha.NAMES")
        end
    end
    for id = 1, 53 do
        T.truthy(names[Parasha.NAMES[id]], Parasha.NAMES[id] .. " is Hebcal's spelling")
    end
end

function tests.only_a_saturday_has_a_reading()
    local friday = Vectors.rd("2026-10-09")
    local ok, message = pcall(Parasha.forShabbat, friday, true)
    T.eq(ok, false)
    T.contains(message, "2026-10-09 is not a Saturday")
    T.same(Parasha.forShabbat(friday + 1, true), { 1 }, "Bereshit on 10 October 2026")
    T.eq(Parasha.forShabbat(friday - 6, true), nil, "Shabbat 3 October 2026 is Shmini Atzeret")
    local ids = Parasha.forShabbat(friday + 1, true)
    ids[1] = 99
    T.same(Parasha.forShabbat(friday + 1, true), { 1 }, "the caller's own table")
end

return tests
