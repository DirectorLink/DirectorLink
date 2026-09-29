-- Holy periods (src/core/holy_times.lua, ADR-037) against Hebcal's candle lighting (20 minutes
-- before sunset) and havdalah (42 after) from 2024 to 2035 in Tel Aviv (Israel), New York, Buenos
-- Aires, Reykjavik and Tromso (abroad) (tests/vectors/calendar/hebcal-times-*.json): every Hebcal
-- havdalah is a period's end, every period's start and every later candle lighting is Hebcal's,
-- and the other way round; plus the cases the design names and the API examples' periods.

local T = require("helpers")
local Vectors = require("calendar_vectors")
local HebrewDate = require("src.core.hebrew_date")
local HolyTimes = require("src.core.holy_times")

local tests = {}

local iso = Vectors.iso
local TEL_AVIV = { latitude = 32.08088, longitude = 34.78057, israel = true, candle_lighting_minutes = 20, havdalah_minutes = 42 }

-- Compared: the times between these, well inside the vectors' years.
local FROM, TO = Vectors.rd("2024-01-02"), Vectors.rd("2035-12-30")
local function inside(epoch)
    return epoch and epoch >= (FROM - HebrewDate.UNIX_EPOCH) * 86400 and epoch < (TO - HebrewDate.UNIX_EPOCH) * 86400
end

local function city(name)
    local vectors = Vectors.read("hebcal-times-" .. name .. ".json")
    local options = { latitude = vectors.location.latitude, longitude = vectors.location.longitude, israel = vectors.israel, candle_lighting_minutes = 20, havdalah_minutes = 42 }
    local hebcal = { candles = {}, havdalah = {}, events = {} }
    for _, event in ipairs(vectors.events) do
        local epoch = Vectors.epoch(event[1])
        if inside(epoch) then
            table.insert(hebcal[event[2]], epoch)
            hebcal.events[#hebcal.events + 1] = { epoch = epoch, kind = event[2] }
        end
    end
    return options, hebcal, HolyTimes.periods(FROM - 7, TO + 7, options)
end

-- Pairs two sorted lists of times within a minute of each other.
local function pair(theirs, ours)
    table.sort(theirs)
    table.sort(ours)
    local i, j, matched, exact, problems = 1, 1, 0, 0, {}
    while i <= #theirs or j <= #ours do
        local a, b = theirs[i], ours[j]
        if a and b and math.abs(a - b) <= 60 then
            matched = matched + 1
            exact = exact + (a == b and 1 or 0)
            i, j = i + 1, j + 1
        elseif not b or a and a < b then
            problems[#problems + 1] = "Hebcal's " .. iso(a) .. " is not ours"
            i = i + 1
        else
            problems[#problems + 1] = "our " .. iso(b) .. " is not Hebcal's"
            j = j + 1
        end
    end
    return matched, exact, problems
end

function tests.every_time_is_hebcals_and_every_hebcal_time_ours()
    for _, name in ipairs(Vectors.CITIES) do
        local _, hebcal, periods = city(name)
        local candles, ends = {}, {}
        for _, period in ipairs(periods) do
            for _, day in ipairs(period.days) do
                if inside(day.candle_lighting) then
                    candles[#candles + 1] = day.candle_lighting
                end
            end
            if inside(period.ends_at) then
                ends[#ends + 1] = period.ends_at
            end
        end
        for kind, ours in pairs({ candles = candles, havdalah = ends }) do
            local matched, exact, problems = pair(hebcal[kind], ours)
            T.eq(#problems, 0, name .. " " .. kind .. ": " .. table.concat(problems, "; ", 1, math.min(#problems, 5)))
            T.truthy(matched > (name == "tromso" and 400 or 600), name .. " " .. kind .. ": " .. matched)
            T.truthy(exact >= 0.99 * matched, string.format("%s %s: %d of %d to the minute", name, kind, exact, matched))
        end
    end
end

-- Each period, from the inside: its candle lightings are Hebcal's between its start and its end,
-- with no havdalah before the end; and Hebcal's periods have as many days as ours.
function tests.periods_have_hebcals_days()
    for _, name in ipairs(Vectors.CITIES) do
        local _, hebcal, periods = city(name)
        local lengths, checked = {}, 0
        for _, period in ipairs(periods) do
            if not period.approximate and inside(period.starts_at) and inside(period.ends_at) then
                local candles, havdalah = 0, 0
                for _, event in ipairs(hebcal.events) do
                    if event.epoch >= period.starts_at - 60 and event.epoch <= period.ends_at + 60 then
                        if event.kind == "candles" then
                            candles = candles + 1
                        else
                            havdalah = havdalah + 1
                            T.truthy(math.abs(event.epoch - period.ends_at) <= 60, name .. ": Hebcal ends " .. HebrewDate.dateKey(period.first) .. " at " .. iso(event.epoch))
                        end
                    end
                end
                T.eq(candles, #period.days, name .. " " .. HebrewDate.dateKey(period.first) .. ": candles for each day")
                T.eq(havdalah, 1, name .. " " .. HebrewDate.dateKey(period.first) .. ": one havdalah")
                T.eq(#period.days, period.last - period.first + 1)
                lengths[#period.days] = (lengths[#period.days] or 0) + 1
                checked = checked + 1
            end
        end
        T.truthy(checked > (name == "tromso" and 400 or 650), name .. ": " .. checked .. " periods")
        if name ~= "tromso" then
            -- Hebcal's periods by their events alone: the candle lightings before each havdalah.
            local theirs, count = {}, 0
            for _, event in ipairs(hebcal.events) do
                if event.kind == "candles" then
                    count = count + 1
                elseif count > 0 then
                    theirs[count] = (theirs[count] or 0) + 1
                    count = 0
                end
            end
            T.truthy(lengths[2] and lengths[3], name .. ": two- and three-day periods")
            for days = 1, 3 do
                -- Hebcal's first period may begin before the compared years.
                T.truthy(math.abs((theirs[days] or 0) - (lengths[days] or 0)) <= (days == 1 and 1 or 0), string.format("%s: %s periods of %d days, Hebcal %s", name, tostring(lengths[days]), days, tostring(theirs[days])))
            end
            T.eq(theirs[4], nil, "never four days")
        end
    end
end

local function only(fromDate, toDate, options)
    local periods = HolyTimes.periods(Vectors.rd(fromDate), Vectors.rd(toDate), options)
    T.eq(#periods, 1, fromDate .. " to " .. toDate)
    return periods[1]
end

-- A period as the API's HolyPeriod (dates and times as strings), to compare with api-examples.json.
local function asApi(period)
    local days = {}
    for index, day in ipairs(period.days) do
        local holidays = {}
        for position, entry in ipairs(day.holidays) do
            holidays[position] = { key = entry.key, day = entry.day, month = entry.month, yom_tov = entry.yom_tov, name = require("src.core.holidays").name(entry) }
        end
        days[index] = { date = HebrewDate.dateKey(day.rd), shabbat = day.shabbat, candle_lighting = day.candle_lighting and iso(day.candle_lighting), holidays = holidays }
    end
    return { starts_at = period.starts_at and iso(period.starts_at), ends_at = period.ends_at and iso(period.ends_at), approximate = period.approximate, days = days }
end

-- The example's value with JSON nulls dropped, as asApi leaves them out.
local function withoutNulls(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        if not Vectors.isNull(item) then
            result[key] = withoutNulls(item)
        end
    end
    return result
end

function tests.rosh_hashana_5785_in_tel_aviv_is_one_three_day_period()
    local period = only("2024-10-03", "2024-10-05", TEL_AVIV)
    T.eq(HebrewDate.dateKey(period.first), "2024-10-03")
    T.eq(HebrewDate.dateKey(period.last), "2024-10-05", "Thursday, Friday and Shabbat")
    T.eq(iso(period.starts_at), "2024-10-02T15:04:00Z", "18:04 on Wednesday")
    T.eq(iso(period.days[2].candle_lighting), "2024-10-03T16:05:00Z", "after nightfall on Thursday")
    T.eq(iso(period.days[3].candle_lighting), "2024-10-04T15:01:00Z", "before sunset on Friday")
    T.eq(iso(period.ends_at), "2024-10-05T16:02:00Z", "19:02 on Shabbat")
    local examples = Vectors.read("api-examples.json").Calendar
    T.same(asApi(period), withoutNulls(examples.three_day_period.value.current), "the API example")
    T.same(asApi(only("2024-10-12", "2024-10-12", TEL_AVIV)), withoutNulls(examples.three_day_period.value.next), "then Yom Kippur on Shabbat")
    -- Asked for a day in the middle, it is still the whole period.
    T.eq(HebrewDate.dateKey(only("2024-10-04", "2024-10-04", TEL_AVIV).first), "2024-10-03")
end

function tests.the_api_examples_times_are_the_engines()
    local examples = Vectors.read("api-examples.json").Calendar
    T.same(asApi(only("2026-10-03", "2026-10-03", TEL_AVIV)), withoutNulls(examples.ok.value.next), "Shabbat and Shmini Atzeret, 18:04 to 19:05")
    local tromso = { latitude = 69.65, longitude = 18.96, israel = false }
    T.same(asApi(only("2026-06-27", "2026-06-27", tromso)), withoutNulls(examples.approximate.value.next), "the midnight sun")
    -- Shavuot 5787 in Tel Aviv (the design's multi-day example).
    local shavuot = only("2027-06-11", "2027-06-12", TEL_AVIV)
    T.eq(iso(shavuot.starts_at), "2027-06-10T16:26:00Z")
    T.eq(iso(shavuot.days[2].candle_lighting), "2027-06-11T16:27:00Z", "Shabbat's candles, before sunset on Friday")
    T.eq(iso(shavuot.ends_at), "2027-06-12T17:29:00Z")
    T.eq(shavuot.days[2].shabbat, true)
end

-- Reykjavik, 19 June 2026: the sun sets at 00:03 on Saturday, so the candles are lit at 23:43 on
-- Friday (Hebcal's time; the design had 23:42), not at 23:43 on Saturday.
function tests.reykjavik_lights_candles_late_on_friday_for_a_sunset_after_midnight()
    local options = city("reykjavik")
    local period = only("2026-06-20", "2026-06-20", options)
    local hebcal = Vectors.read("hebcal-times-reykjavik.json")
    local found
    for _, event in ipairs(hebcal.events) do
        if event[1]:sub(1, 16) == "2026-06-19T23:43" then
            found = event
        end
    end
    T.eq(found and found[2], "candles", "Hebcal's Friday candle lighting")
    T.eq(period.starts_at, Vectors.epoch(found[1]), "on Friday, before a sunset after midnight")
    T.eq(os.date("!%A %H:%M", period.starts_at), "Friday 23:43", "Reykjavik keeps UTC")
    T.eq(HebrewDate.dateKey(period.first), "2026-06-20")
    T.eq(os.date("!%A %H:%M", period.ends_at), "Sunday 00:45", "and havdalah after midnight too")
    T.eq(period.approximate, false)
end

function tests.tromso_has_approximate_periods_without_times()
    local options, _, periods = city("tromso")
    local summer, winter, partial = 0, 0, 0
    for _, period in ipairs(periods) do
        local missing = period.starts_at == nil or period.ends_at == nil
        for _, day in ipairs(period.days) do
            missing = missing or day.candle_lighting == nil
        end
        T.eq(period.approximate, missing, HebrewDate.dateKey(period.first) .. ": approximate exactly when a time is missing")
        if period.approximate then
            local _, month = HebrewDate.gregorianFromFixed(period.first)
            if month >= 5 and month <= 8 then
                summer = summer + 1
            else
                winter = winter + 1
            end
            if period.starts_at or period.ends_at then
                partial = partial + 1
            end
        end
    end
    T.truthy(summer > 60 and winter > 60, "the midnight sun and the polar night, every year")
    local june = only("2026-06-27", "2026-06-27", options)
    T.eq(june.approximate, true)
    T.eq(june.starts_at, nil)
    T.eq(june.ends_at, nil)
    T.eq(june.days[1].candle_lighting, nil)
    local december = only("2026-12-19", "2026-12-19", options)
    T.eq(december.approximate, true)
    T.eq(december.starts_at, nil)
    T.truthy(partial > 0, "at the edges one time can be there without the other: still approximate")
end

function tests.the_minutes_come_from_the_options()
    local usual = only("2026-10-03", "2026-10-03", TEL_AVIV)
    local custom = only("2026-10-03", "2026-10-03", { latitude = TEL_AVIV.latitude, longitude = TEL_AVIV.longitude, israel = true, candle_lighting_minutes = 30, havdalah_minutes = 50 })
    T.eq(custom.starts_at, usual.starts_at - 600)
    T.eq(custom.ends_at, usual.ends_at + 480)
    local defaults = only("2026-10-03", "2026-10-03", { latitude = TEL_AVIV.latitude, longitude = TEL_AVIV.longitude, israel = true })
    T.eq(defaults.starts_at, usual.starts_at, "20 and 42 by default")
    T.eq(defaults.ends_at, usual.ends_at)
    -- Abroad the same Shabbat, Shmini Atzeret, runs into Simchat Torah on Sunday; its candles are
    -- lit after nightfall on Saturday.
    local abroad = only("2026-10-03", "2026-10-03", { latitude = TEL_AVIV.latitude, longitude = TEL_AVIV.longitude, israel = false })
    T.eq(HebrewDate.dateKey(abroad.first), "2026-10-03")
    T.eq(HebrewDate.dateKey(abroad.last), "2026-10-04")
    T.eq(#abroad.days, 2)
    T.eq(abroad.starts_at, usual.starts_at)
    T.eq(abroad.days[2].candle_lighting, usual.ends_at, "at Saturday's havdalah time")
    T.eq(abroad.days[2].holidays[1].key, "simchat_torah")
    local ok, message = pcall(HolyTimes.periods, 1, 2, { israel = true })
    T.eq(ok, false)
    T.contains(message, "latitude and longitude")
end

function tests.periods_are_in_order_and_cover_the_range()
    local from, to = Vectors.rd("2026-09-01"), Vectors.rd("2027-10-01")
    local periods = HolyTimes.periods(from, to, TEL_AVIV)
    local previous
    for _, period in ipairs(periods) do
        T.truthy(period.last >= from and period.first <= to, "overlaps the range")
        if previous then
            T.truthy(period.first > previous.last + 1, "maximal runs, in order")
        end
        for rd = period.first, period.last do
            T.truthy(HolyTimes.isHolyDay(rd, true))
        end
        T.eq(HolyTimes.isHolyDay(period.first - 1, true), false)
        T.eq(HolyTimes.isHolyDay(period.last + 1, true), false)
        previous = period
    end
    -- Every holy day in the range is in one of them.
    local covered = {}
    for _, period in ipairs(periods) do
        for rd = period.first, period.last do
            covered[rd] = true
        end
    end
    for rd = from, to do
        T.eq(covered[rd] == true, HolyTimes.isHolyDay(rd, true), HebrewDate.dateKey(rd))
    end
end

return tests
