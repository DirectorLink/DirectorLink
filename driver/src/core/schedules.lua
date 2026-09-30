-- DirectorLink schedules (docs/SCHEDULES.md): run a scene at a time of day, at sunrise or sunset,
-- when the weather turns (heat, wind, rain), or when Shabbat and holidays begin or end (the Jewish
-- calendar, ADR-037), on chosen days. Time and sun schedules may also say "only if" about the
-- weather, and time, sun and weather schedules what to do on Shabbat and holidays
-- ("during_shabbat"). They are the home's, kept in the driver's persistent data, and run by the
-- controller (src/core/scheduler.lua) whether or not an app is open.
-- The same rules check what the API receives and what is loaded from the store.

local Clock = require("src.core.clock")
local Random = require("src.core.random")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local Schedules = {}

local STORE_KEY = "directorlink_schedules"
local STATE_KEY = "directorlink_schedule_state"
Schedules.MAX_SCHEDULES = 50
Schedules.LIMITS = {
    heat = { 15, 45 }, -- °C outside
    wind = { 10, 150 }, -- km/h
    offset = { -180, 180 }, -- minutes before or after sunrise and sunset
    shabbat_offset = { -360, 360 }, -- minutes before or after candle lighting and havdalah
}
Schedules.DURING_SHABBAT = { run = true, skip = true, only = true }

-- `complete` is false after the stored schedules could not be read: saving would overwrite them.
-- `catchUpAfter`: after a restart, nothing due before this moment is caught up (src/core/scheduler.lua).
local state = { schedules = {}, runtime = {}, complete = true, catchUpAfter = nil }

local function randomHex(length)
    return Random.hex(length)
end

local function isNumber(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= minimum and value <= maximum
end

local function isWhole(value, minimum, maximum)
    return isNumber(value, minimum, maximum) and value == math.floor(value)
end

-- "06:45" -> 405 (minutes after midnight), or nil.
function Schedules.minutes(text)
    if type(text) ~= "string" then
        return nil
    end
    local hours, minutes = text:match("^(%d%d):(%d%d)$")
    hours, minutes = tonumber(hours), tonumber(minutes)
    if not hours or hours > 23 or minutes > 59 then
        return nil
    end
    return hours * 60 + minutes
end

local function present(value)
    return value ~= nil and value ~= Json.null
end

-- Checks a whole schedule (API input merged with the stored one, or a stored record). Returns the
-- clean record, or nil, the field and a message.
function Schedules.check(input)
    if type(input) ~= "table" or input == Json.null then
        return nil, "schedule", "A schedule is an object"
    end
    local record = {}
    if type(input.scene_id) ~= "string" or #input.scene_id ~= 8 or not input.scene_id:match("^[%da-f]+$") then
        return nil, "scene_id", "scene_id is the scene to run (8 hex characters)"
    end
    record.scene_id = input.scene_id
    if input.enabled ~= nil and type(input.enabled) ~= "boolean" then
        return nil, "enabled", "enabled must be true or false"
    end
    record.enabled = input.enabled ~= false

    local trigger = input.trigger
    if type(trigger) ~= "table" or trigger == Json.null or Json.isArray(trigger) then
        return nil, "trigger", "trigger says when the schedule runs"
    end
    local kind = trigger.type
    local known = ({
        time = { type = true, at = true },
        sun = { type = true, event = true, offset = true },
        weather = { type = true, kind = true, above = true, from = true, to = true, once_a_day = true },
        shabbat = { type = true, event = true, offset = true },
    })[kind]
    if known then
        for key in pairs(trigger) do
            if not known[key] then
                return nil, "trigger." .. tostring(key), "Unknown field for a " .. kind .. " trigger: " .. tostring(key)
            end
        end
    end
    if kind == "time" then
        if not Schedules.minutes(trigger.at) then
            return nil, "trigger.at", 'at is a time of day, "HH:MM"'
        end
        record.trigger = { type = "time", at = trigger.at }
    elseif kind == "sun" then
        if trigger.event ~= "sunrise" and trigger.event ~= "sunset" then
            return nil, "trigger.event", "event must be sunrise or sunset"
        end
        local offset = present(trigger.offset) and trigger.offset or 0
        if not isWhole(offset, Schedules.LIMITS.offset[1], Schedules.LIMITS.offset[2]) then
            return nil, "trigger.offset", "offset is minutes from -180 (before) to 180 (after)"
        end
        record.trigger = { type = "sun", event = trigger.event, offset = offset }
    elseif kind == "weather" then
        local weather = trigger.kind
        if weather ~= "heat" and weather ~= "wind" and weather ~= "rain" then
            return nil, "trigger.kind", "kind must be heat, wind or rain"
        end
        record.trigger = { type = "weather", kind = weather, once_a_day = trigger.once_a_day ~= false }
        if present(trigger.once_a_day) and type(trigger.once_a_day) ~= "boolean" then
            return nil, "trigger.once_a_day", "once_a_day must be true or false"
        end
        if weather ~= "rain" then
            local limits = Schedules.LIMITS[weather]
            if not isNumber(trigger.above, limits[1], limits[2]) then
                return nil, "trigger.above", string.format("above must be a number from %d to %d", limits[1], limits[2])
            end
            record.trigger.above = trigger.above
        elseif present(trigger.above) then
            return nil, "trigger.above", "rain has no threshold"
        end
        if present(trigger.from) or present(trigger.to) then
            local from, to = Schedules.minutes(trigger.from), Schedules.minutes(trigger.to)
            if not from or not to or from == to then
                return nil, "trigger.from", 'from and to are two different times of day, "HH:MM"'
            end
            record.trigger.from, record.trigger.to = trigger.from, trigger.to
        end
    elseif kind == "shabbat" then
        -- When Shabbat or a holiday begins (candle lighting) or ends (havdalah); days that follow
        -- each other are one period, which begins and ends once.
        if trigger.event ~= "candle_lighting" and trigger.event ~= "havdalah" then
            return nil, "trigger.event", "event must be candle_lighting or havdalah"
        end
        local offset = present(trigger.offset) and trigger.offset or 0
        if not isWhole(offset, Schedules.LIMITS.shabbat_offset[1], Schedules.LIMITS.shabbat_offset[2]) then
            return nil, "trigger.offset", "offset is minutes from -360 (before) to 360 (after)"
        end
        record.trigger = { type = "shabbat", event = trigger.event, offset = offset }
    else
        return nil, "trigger.type", "type must be time, sun, weather or shabbat"
    end

    local days = input.days
    if type(days) ~= "table" or days == Json.null or (not Json.isArray(days) and next(days) ~= nil) then
        return nil, "days", "days is a list of weekdays, 0 (Sunday) to 6 (Saturday)"
    end
    local seen = {}
    for _, day in ipairs(days) do
        if not isWhole(day, 0, 6) then
            return nil, "days", "days is a list of weekdays, 0 (Sunday) to 6 (Saturday)"
        end
        seen[day] = true
    end
    record.days = Json.array()
    for day = 0, 6 do
        if seen[day] then
            record.days[#record.days + 1] = day
        end
    end
    if #record.days == 0 then
        return nil, "days", "Pick at least one day"
    end

    record.only_if = {}
    local onlyIf = input.only_if
    if present(onlyIf) then
        if type(onlyIf) ~= "table" or Json.isArray(onlyIf) and next(onlyIf) ~= nil then
            return nil, "only_if", "only_if is an object"
        end
        for key, value in pairs(onlyIf) do
            if value == Json.null then
                -- Left out.
            elseif key == "not_raining" or key == "rain_expected" then
                if type(value) ~= "boolean" then
                    return nil, "only_if." .. key, key .. " must be true or false"
                end
                record.only_if[key] = value or nil
            elseif key == "hotter_than" then
                if not isNumber(value, Schedules.LIMITS.heat[1], Schedules.LIMITS.heat[2]) then
                    return nil, "only_if.hotter_than", "hotter_than is °C from 15 to 45"
                end
                record.only_if.hotter_than = value
            elseif key == "wind_below" then
                if not isNumber(value, Schedules.LIMITS.wind[1], Schedules.LIMITS.wind[2]) then
                    return nil, "only_if.wind_below", "wind_below is km/h from 10 to 150"
                end
                record.only_if.wind_below = value
            else
                return nil, "only_if." .. tostring(key), "Unknown condition: " .. tostring(key)
            end
        end
        if next(record.only_if) and kind == "weather" then
            return nil, "only_if", "A weather schedule has no other conditions"
        end
    end
    local noWeather = present(input.if_no_weather) and input.if_no_weather or "run"
    if noWeather ~= "run" and noWeather ~= "skip" then
        return nil, "if_no_weather", 'if_no_weather must be "run" or "skip"'
    end
    record.if_no_weather = noWeather
    -- On Shabbat and holidays, from candle lighting to havdalah: run as usual, skip, or run only
    -- then. Stored in full; records from before 1.2.0 have none and run as usual.
    local during = present(input.during_shabbat) and input.during_shabbat or "run"
    if type(during) ~= "string" or not Schedules.DURING_SHABBAT[during] then
        return nil, "during_shabbat", 'during_shabbat must be "run", "skip" or "only"'
    end
    if kind == "shabbat" and during ~= "run" then
        return nil, "during_shabbat", "A Shabbat schedule runs at Shabbat times; during_shabbat does not apply"
    end
    record.during_shabbat = during
    return record
end

-- True when the schedule needs Open-Meteo: a weather trigger or an "only if".
function Schedules.usesWeather(schedule)
    return schedule.trigger.type == "weather" or next(schedule.only_if or {}) ~= nil
end

-- True when the schedule needs the Jewish calendar: a Shabbat trigger, or "during_shabbat" other
-- than "run".
function Schedules.usesCalendar(schedule)
    return schedule.trigger.type == "shabbat" or (schedule.during_shabbat or "run") ~= "run"
end

local function copy(schedule)
    local record = Json.decode(Json.encode(schedule))
    record.days = Json.array(record.days)
    return record
end

local function save()
    local records = Json.array()
    for _, schedule in ipairs(state.schedules) do
        records[#records + 1] = schedule
    end
    local ok = Store.write(STORE_KEY, { version = 1, schedules = records }, false)
    if not ok then
        Log.error("schedules", "could not save the schedules")
    end
    return ok
end

local function saveRuntime()
    local ok = Store.write(STATE_KEY, { version = 1, schedules = state.runtime, catch_up_after = state.catchUpAfter }, false)
    if not ok then
        -- A restart could then run a Shabbat schedule again (the catch-up), or miss one.
        Log.error("schedules", "could not save what the schedules ran")
    end
    return ok
end

function Schedules.load()
    state.schedules, state.runtime = {}, {}
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    local dropped = 0
    for _, item in ipairs(Store.items(type(data) == "table" and data.schedules or nil)) do
        local record = type(item) == "table" and Schedules.check(item) or nil
        local id = type(item) == "table" and item.id or nil
        if record and type(id) == "string" and #id == 8 and id:match("^[%da-f]+$") and #state.schedules < Schedules.MAX_SCHEDULES then
            record.id = id
            record.version = isWhole(item.version, 1, math.huge) and item.version or 1
            record.created_at = type(item.created_at) == "string" and item.created_at or Clock.iso()
            record.updated_at = type(item.updated_at) == "string" and item.updated_at or Clock.iso()
            record.updated_epoch = isWhole(item.updated_epoch, 0, math.huge) and item.updated_epoch or 0
            state.schedules[#state.schedules + 1] = record
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        Log.warn("schedules", "stored schedules that are not valid were left out", { schedules = dropped })
    end
    local runtime, runtimeForm = Store.read(STATE_KEY, false)
    state.catchUpAfter = nil
    if type(runtime) == "table" and type(runtime.schedules) == "table" then
        for _, schedule in ipairs(state.schedules) do
            local item = runtime.schedules[schedule.id]
            if type(item) == "table" then
                state.runtime[schedule.id] = item
            end
        end
        if isWhole(runtime.catch_up_after, 0, math.huge) then
            state.catchUpAfter = runtime.catch_up_after
        end
    elseif runtimeForm ~= "missing" then
        -- What ran before is not known, so nothing is caught up now: that could run a Shabbat
        -- schedule a second time.
        state.catchUpAfter = Clock.now()
        Log.warn("schedules", "what the schedules ran could not be read; nothing is caught up after this start", { stored_as = runtimeForm })
    end
    return #state.schedules, form
end

function Schedules.complete()
    return state.complete
end

local function findRecord(id)
    for index, schedule in ipairs(state.schedules) do
        if schedule.id == id then
            return schedule, index
        end
    end
    return nil
end

function Schedules.list()
    local items = {}
    for _, schedule in ipairs(state.schedules) do
        items[#items + 1] = copy(schedule)
    end
    return items
end

function Schedules.find(id)
    local schedule = type(id) == "string" and findRecord(id) or nil
    return schedule and copy(schedule) or nil
end

-- Schedules that run this scene (a scene in use is not deleted).
function Schedules.usingScene(sceneId)
    local count = 0
    for _, schedule in ipairs(state.schedules) do
        if schedule.scene_id == sceneId then
            count = count + 1
        end
    end
    return count
end

-- `record`: from Schedules.check.
function Schedules.create(record)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    if #state.schedules >= Schedules.MAX_SCHEDULES then
        return nil, "SCHEDULE_LIMIT_REACHED"
    end
    local id = randomHex(8)
    while findRecord(id) do
        id = randomHex(8)
    end
    local now = Clock.now()
    record.id = id
    record.version = 1
    record.created_at = Clock.iso(now)
    record.updated_at = Clock.iso(now)
    record.updated_epoch = now
    state.schedules[#state.schedules + 1] = record
    if not save() then
        table.remove(state.schedules)
        return nil, "PERSIST_FAILED"
    end
    return copy(record)
end

-- Replaces the schedule with `record` (from Schedules.check); `expected`: the version the caller
-- saw, or nil not to check.
function Schedules.replace(id, record, expected)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    local current, index = findRecord(id)
    if not current then
        return nil, "NOT_FOUND"
    end
    if expected ~= nil and expected ~= current.version then
        return nil, "VERSION_CONFLICT"
    end
    local now = Clock.now()
    record.id = id
    record.version = current.version + 1
    record.created_at = current.created_at
    record.updated_at = Clock.iso(now)
    record.updated_epoch = now
    state.schedules[index] = record
    if not save() then
        state.schedules[index] = current
        return nil, "PERSIST_FAILED"
    end
    -- What it ran today stays (switching it off and on does not run it again); a weather rule with
    -- a new kind or threshold waits for the weather anew.
    local runtime = state.runtime[id] or {}
    local before, after = current.trigger, record.trigger
    if before.type ~= after.type or before.kind ~= after.kind or before.above ~= after.above then
        runtime.armed, runtime.dry_since = nil, nil
    end
    state.runtime[id] = runtime
    saveRuntime()
    return copy(record)
end

function Schedules.delete(id)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    local current, index = findRecord(id)
    if not current then
        return nil, "NOT_FOUND"
    end
    table.remove(state.schedules, index)
    if not save() then
        table.insert(state.schedules, index, current)
        return nil, "PERSIST_FAILED"
    end
    state.runtime[id] = nil
    saveRuntime()
    return true
end

-- What the scheduler remembers per schedule (when it last ran, whether a weather rule is armed).
-- `runtime(id)` is the live table; call `saveRuntime()` after changing it.
function Schedules.runtime(id)
    state.runtime[id] = state.runtime[id] or {}
    return state.runtime[id]
end

Schedules.saveRuntime = saveRuntime

-- After a restart nothing due before this moment (seconds from 1970) is caught up, or nil
-- (src/core/scheduler.lua); kept with the runtime.
function Schedules.catchUpAfter()
    return state.catchUpAfter
end

function Schedules.setCatchUpAfter(epoch)
    state.catchUpAfter = epoch
    saveRuntime()
end

-- The live records, for the scheduler (not copied: it only reads them).
function Schedules.records()
    return state.schedules
end

return Schedules
