-- The home's own holidays (1.14.0, docs/SCHEDULES.md "Your holidays"): days an admin chooses, such
-- as public holidays, school breaks or a trip, once or every year. A schedule may skip them or run
-- only on them (`on_holidays`, src/core/schedules.lua). A holiday is whole local days, from 00:00 on
-- its first day to 24:00 on its last, in the controller's time zone. Not the Jewish calendar's
-- holidays (src/core/holidays.lua), which are Shabbat automation's (`during_shabbat`).
-- Kept in the driver's persistent data as { version = 1, revision, items }, one list for the home,
-- replaced as a whole (PUT /v1/holidays) and in backups (ADR-042).

local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local HomeHolidays = {}

local STORE_KEY = "directorlink_holidays"
HomeHolidays.MAX_ITEMS = 100
HomeHolidays.MAX_NAME = 60
-- A holiday's days, from its first to its last: a one-off one up to a year and a day, one that comes
-- back every year less than a year (else it would meet itself).
HomeHolidays.MAX_DAYS = 366
HomeHolidays.MAX_YEARLY_DAYS = 365

-- `revision` counts the changes (the API's `version`); `complete` is false after the stored list
-- could not be read: saving would overwrite it.
local state = { items = {}, revision = 0, complete = true }

-- Days from 1970-01-01 to a Gregorian date.
local function daysFromCivil(year, month, day)
    if month <= 2 then
        year, month = year - 1, month + 12
    end
    return 365 * year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400) + math.floor((153 * (month - 3) + 2) / 5) + day - 719469
end

local function isLeap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- "2026-12-25" -> 2026, 12, 25 when it is a real date, or nil.
function HomeHolidays.date(text)
    if type(text) ~= "string" then
        return nil
    end
    local year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or year < 2000 or year > 2199 or month < 1 or month > 12 or day < 1 then
        return nil
    end
    local last = (month == 2 and isLeap(year)) and 29 or MONTH_DAYS[month]
    if day > last then
        return nil
    end
    return year, month, day
end

local function characters(text)
    local _, count = text:gsub("[^\128-\191]", "")
    return count
end

-- Checks one holiday as the API sends it or the store holds it: { name, from, to (optional, the
-- first day if left out), yearly (optional) }. Returns the clean record, or nil, the field (within
-- the item) and a message.
function HomeHolidays.check(input)
    if type(input) ~= "table" or input == Json.null or Json.isArray(input) then
        return nil, "", "A holiday is an object: name, from, to and yearly"
    end
    for key in pairs(input) do
        if key ~= "name" and key ~= "from" and key ~= "to" and key ~= "yearly" then
            return nil, tostring(key), "Unknown field: " .. tostring(key)
        end
    end
    local name = type(input.name) == "string" and input.name:gsub("^%s+", ""):gsub("%s+$", "") or nil
    if not name or characters(name) == 0 or characters(name) > HomeHolidays.MAX_NAME then
        return nil, "name", "name must be 1 to " .. HomeHolidays.MAX_NAME .. " characters"
    end
    local fromYear, fromMonth, fromDay = HomeHolidays.date(input.from)
    if not fromYear then
        return nil, "from", 'from is the first day, "YYYY-MM-DD"'
    end
    local to = (input.to == nil or input.to == Json.null) and input.from or input.to
    local toYear, toMonth, toDay = HomeHolidays.date(to)
    if not toYear then
        return nil, "to", 'to is the last day, "YYYY-MM-DD"'
    end
    if input.yearly ~= nil and input.yearly ~= Json.null and type(input.yearly) ~= "boolean" then
        return nil, "yearly", "yearly must be true or false"
    end
    local yearly = input.yearly == true
    local span = daysFromCivil(toYear, toMonth, toDay) - daysFromCivil(fromYear, fromMonth, fromDay) + 1
    if span < 1 then
        return nil, "to", "to must be the first day or later"
    end
    local most = yearly and HomeHolidays.MAX_YEARLY_DAYS or HomeHolidays.MAX_DAYS
    if span > most then
        return nil, "to", string.format("A holiday%s is at most %d days", yearly and " every year" or "", most)
    end
    return { name = name, from = input.from, to = to, yearly = yearly }
end

local function copy(item)
    return { name = item.name, from = item.from, to = item.to, yearly = item.yearly }
end

local function list()
    local items = Json.array()
    for _, item in ipairs(state.items) do
        items[#items + 1] = copy(item)
    end
    return items
end

local function record()
    return { version = 1, revision = state.revision, items = list() }
end

local function save()
    if not Store.write(STORE_KEY, record(), false) then
        Log.error("schedules", "could not save the holidays")
        return false
    end
    return true
end

-- The holidays of a stored record ({ version, revision, items }, as the store or a backup holds
-- them), each checked again. Returns them, the revision and how many were left out.
function HomeHolidays.read(data)
    local items, dropped = {}, 0
    for _, item in ipairs(Store.items(type(data) == "table" and data.items or nil)) do
        local checked = HomeHolidays.check(item)
        if checked and #items < HomeHolidays.MAX_ITEMS then
            items[#items + 1] = checked
        else
            dropped = dropped + 1
        end
    end
    local revision = type(data) == "table" and tonumber(data.revision) or nil
    if not revision or revision < 0 or revision ~= math.floor(revision) then
        revision = 0
    end
    return items, revision, dropped
end

function HomeHolidays.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    local dropped
    state.items, state.revision, dropped = HomeHolidays.read(data)
    if dropped > 0 then
        Log.warn("schedules", "stored holidays that are not valid were left out", { holidays = dropped })
    end
    return #state.items, form
end

function HomeHolidays.complete()
    return state.complete
end

-- { items, version } for the API.
function HomeHolidays.view()
    return { items = list(), version = state.revision }
end

function HomeHolidays.count()
    return #state.items
end

-- Replaces the list with `items` (each from HomeHolidays.check); `expected`: the version the caller
-- saw, or nil not to check. Returns the new view, or nil and a code.
function HomeHolidays.replace(items, expected)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    if expected ~= nil and expected ~= state.revision then
        return nil, "VERSION_CONFLICT"
    end
    local before, beforeRevision = state.items, state.revision
    state.items, state.revision = items, state.revision + 1
    if not save() then
        state.items, state.revision = before, beforeRevision
        return nil, "PERSIST_FAILED"
    end
    return HomeHolidays.view()
end

-- Backups (ADR-042, src/core/backup.lua): the list, without its revision (a restore counts one more
-- change here), so that the section is a store's version and one list, as every list section is.
function HomeHolidays.backup()
    return { version = 1, items = list() }
end

-- Replaces the list with the one of `data` (a backup's section). Returns true once saved.
function HomeHolidays.restore(data)
    local items = HomeHolidays.read(data)
    state.items, state.revision = items, state.revision + 1
    local ok = save()
    if ok then
        state.complete = true
    end
    return ok
end

-- What the store holds now, for a restore that has to put it back.
function HomeHolidays.snapshot()
    return { items = state.items, revision = state.revision }
end

function HomeHolidays.putBack(snapshot)
    state.items, state.revision = snapshot.items, snapshot.revision
    return save()
end

-- The holiday on a local date, or nil: the first of the list that holds it. A one-off holiday holds
-- its days; one every year holds the same days of the month every year, also across New Year
-- (24 December to 2 January).
function HomeHolidays.on(year, month, day)
    if #state.items == 0 then
        return nil
    end
    local key = string.format("%04d-%02d-%02d", year, month, day)
    local monthDay = month * 100 + day
    for _, item in ipairs(state.items) do
        if item.yearly then
            local first = tonumber(item.from:sub(6, 7)) * 100 + tonumber(item.from:sub(9, 10))
            local last = tonumber(item.to:sub(6, 7)) * 100 + tonumber(item.to:sub(9, 10))
            if first <= last and monthDay >= first and monthDay <= last or first > last and (monthDay >= first or monthDay <= last) then
                return item
            end
        elseif key >= item.from and key <= item.to then
            return item
        end
    end
    return nil
end

return HomeHolidays
