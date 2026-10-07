-- The weather at home, for schedules (docs/SCHEDULES.md, ADR-071): Open-Meteo's hourly forecast
-- for the project's location (Composer: project properties, latitude and longitude), and each day's
-- high, low and chance of rain. The weather now is always the saved forecast's hour for now, with
-- or without the internet: the temperature and the wind between the two hours around now, rain when
-- the forecast has some in the hour now. The controller asks api.open-meteo.com itself, every 6
-- hours while a schedule needs the weather or the app showed it in the last hour; nothing goes
-- through DirectorLink's servers. The location is sent rounded to two decimals (about a
-- kilometre). The forecast is kept across restarts and used for 5 days after it was read.
-- Weather data by Open-Meteo.com (CC BY 4.0).

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Store = require("src.core.store")

local Weather = {}

-- A new forecast every 6 hours (4 requests a day), and 30 minutes after a try that failed.
Weather.REFRESH_SECONDS = 6 * 3600
Weather.RETRY_SECONDS = 30 * 60
-- A forecast is used for 5 days after it was read; after that the weather is unknown, and
-- schedules do what they say for no data.
Weather.KEEP_SECONDS = 5 * 86400
-- Open-Meteo's days start at the location's midnight: 6 of them hold the 5 days after any hour.
Weather.FORECAST_DAYS = 6
Weather.TIMEOUT_SECONDS = 15
Weather.HOST = "https://api.open-meteo.com"
-- A key of its own: 1.9.0 keeps its last reading (version 1, `fetched_at` and `data`) under
-- "directorlink_weather", which 1.10.0 leaves alone, so going back to 1.9.0 and forward again keeps
-- the forecast. 1.9.0 then finds its own old reading, too old to use after 45 minutes.
local STORE_KEY = "directorlink_forecast"
local STORE_VERSION = 2
local MAX_HOURS = 8 * 24
local MAX_DAYS = 16
-- What is kept of each hour, and Open-Meteo's name for it.
local SERIES = { "temperature", "wind_speed", "precipitation", "weather_code" }
local ASKED = { temperature = "temperature_2m", wind_speed = "wind_speed_10m", precipitation = "precipitation", weather_code = "weather_code" }

-- `forecast`: { saved_at, place ("32.08,34.78": where it is for), start (its first hour), count
-- (hours), temperature, wind_speed, precipitation, weather_code (hour 1 to count: a number or nil),
-- days = { { start, max_temperature, min_temperature, rain_chance }, ... } }.
local state = {
    location = nil, -- function returning latitude, longitude
    forecast = nil,
    fetching = false,
    failure = nil, -- why the last fetch failed
    attemptedAt = nil, -- when the last fetch started
    wantedUntil = 0, -- the app looked at the weather: keep it fresh a while
    ranOut = false, -- the log said that the saved forecast has run out
}

function Weather.reset()
    state.forecast, state.fetching, state.failure, state.attemptedAt, state.wantedUntil, state.ranOut = nil, false, nil, nil, 0, false
end

local function number(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end

local function placeOf(latitude, longitude)
    return string.format("%.2f,%.2f", latitude, longitude)
end

-- When a forecast runs out: 5 days after it was read, or at its last hour if that comes first.
local function untilOf(forecast)
    return math.min(forecast.saved_at + Weather.KEEP_SECONDS, forecast.start + (forecast.count - 1) * 3600)
end

-- What is stored: each hour's numbers in a list (null for none), each day as [start, max, min,
-- chance]; about 3 KB for 5 days.
local function list(values, count)
    local items = {}
    for index = 1, count do
        items[index] = values[index] == nil and Json.null or values[index]
    end
    return Json.array(items)
end

local function stored(forecast)
    local record = { version = STORE_VERSION, saved_at = forecast.saved_at, place = forecast.place, start = forecast.start, days = Json.array({}) }
    for _, name in ipairs(SERIES) do
        record[name] = list(forecast[name], forecast.count)
    end
    for index, day in ipairs(forecast.days) do
        record.days[index] = list({ day.start, day.max_temperature, day.min_temperature, day.rain_chance }, 4)
    end
    return record
end

local function restored(saved)
    if type(saved) ~= "table" or saved.version ~= STORE_VERSION or not number(saved.saved_at) or not number(saved.start)
        or type(saved.place) ~= "string" or type(saved.temperature) ~= "table" or type(saved.days) ~= "table" then
        return nil
    end
    local count = math.min(#saved.temperature, MAX_HOURS)
    local forecast = { saved_at = saved.saved_at, place = saved.place, start = saved.start, count = count, days = {} }
    for _, name in ipairs(SERIES) do
        local items = type(saved[name]) == "table" and saved[name] or {}
        forecast[name] = {}
        for index = 1, count do
            forecast[name][index] = number(items[index])
        end
    end
    for index = 1, math.min(#saved.days, MAX_DAYS) do
        local day = saved.days[index]
        if type(day) == "table" and number(day[1]) then
            forecast.days[#forecast.days + 1] = { start = day[1], max_temperature = number(day[2]), min_temperature = number(day[3]), rain_chance = number(day[4]) }
        end
    end
    if count < 2 then
        return nil
    end
    return forecast
end

-- The forecast kept across restarts, so schedules have the weather at once after one, and without
-- the internet for 5 days.
function Weather.load()
    Weather.reset()
    state.forecast = restored(Store.read(STORE_KEY, false))
end

-- `location()` returns the project's latitude and longitude (numbers) or nil.
function Weather.configure(location)
    state.location = location
end

-- The forecast in Open-Meteo's answer (times in seconds from 1970), read at `now` for `place`:
-- from the hour that holds now to the hour after 5 days later, with the days it touches. nil when
-- it is not what was asked for or does not hold now.
function Weather.parse(body, now, place)
    local answer = type(body) == "string" and Json.decode(body) or nil
    local hourly = type(answer) == "table" and answer.hourly or nil
    local times = type(hourly) == "table" and hourly.time or nil
    if type(times) ~= "table" then
        return nil
    end
    local forecast = { saved_at = now, place = place, count = 0, days = {} }
    for _, name in ipairs(SERIES) do
        forecast[name] = {}
    end
    local last = now + Weather.KEEP_SECONDS + 3600
    for index = 1, #times do
        local time = number(times[index])
        if time and time > now - 3600 and time < last then
            forecast.start = forecast.start or time
            local slot = (time - forecast.start) / 3600
            if slot >= 0 and slot == math.floor(slot) and slot < MAX_HOURS then
                slot = slot + 1
                for _, name in ipairs(SERIES) do
                    local values = hourly[ASKED[name]]
                    forecast[name][slot] = type(values) == "table" and number(values[index]) or nil
                end
                forecast.count = math.max(forecast.count, slot)
            end
        end
    end
    if not forecast.start or forecast.start > now or forecast.count < 2 or not forecast.temperature[1] or not forecast.temperature[2] then
        return nil
    end
    local daily = type(answer.daily) == "table" and answer.daily or {}
    local starts = type(daily.time) == "table" and daily.time or {}
    local function day(name, index)
        return type(daily[name]) == "table" and number(daily[name][index]) or nil
    end
    for index = 1, math.min(#starts, MAX_DAYS) do
        local start = number(starts[index])
        if start and start < last and start > now - 2 * 86400 then
            forecast.days[#forecast.days + 1] = {
                start = start,
                max_temperature = day("temperature_2m_max", index),
                min_temperature = day("temperature_2m_min", index),
                rain_chance = day("precipitation_probability_max", index),
            }
        end
    end
    return forecast
end

local function rounded(value)
    return value and math.floor(value * 10 + 0.5) / 10 or nil
end

-- The day of the forecast that holds `now` (the location's midnight to midnight).
local function today(forecast, now)
    local found
    for _, day in ipairs(forecast.days) do
        if day.start <= now and now < day.start + 26 * 3600 then
            found = day
        end
    end
    found = found or {}
    return { max_temperature = found.max_temperature, min_temperature = found.min_temperature, rain_chance = found.rain_chance }
end

-- The weather at `now` from a forecast for `place`, or nil when it does not hold now. The
-- temperature and the wind are between the hours before and after now; the precipitation is the
-- hour now's (Open-Meteo gives each hour's sum at its end), and it rains when there is any; the
-- weather code is the one at the hour's start (Open-Meteo's is the moment's).
local function readingAt(forecast, place, now)
    if not forecast or forecast.place ~= place or now < forecast.start or now >= untilOf(forecast) then
        return nil
    end
    local offset = (now - forecast.start) / 3600
    local slot = math.floor(offset) + 1
    local fraction = offset - (slot - 1)
    local function between(values)
        local before, after = values[slot], values[slot + 1]
        if before == nil or after == nil then
            return nil
        end
        return rounded(before + (after - before) * fraction)
    end
    local temperature = between(forecast.temperature)
    if not temperature then
        return nil
    end
    local precipitation = forecast.precipitation[slot + 1] or 0
    return {
        temperature = temperature,
        wind_speed = between(forecast.wind_speed),
        precipitation = precipitation,
        -- The code at the hour's start (an instant value, as the temperature).
        weather_code = forecast.weather_code[slot],
        raining = precipitation > 0,
        today = today(forecast, now),
        source = "forecast",
        saved_at = forecast.saved_at,
        forecast_until = untilOf(forecast),
    }
end

local function location()
    if not state.location then
        return nil
    end
    local ok, latitude, longitude = pcall(state.location)
    latitude, longitude = ok and tonumber(latitude), ok and tonumber(longitude)
    if not latitude or not longitude or latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180 or (latitude == 0 and longitude == 0) then
        return nil
    end
    return latitude, longitude
end

-- The saved forecast when it holds `now` for the project's location, or nil.
local function usable(now)
    local latitude, longitude = location()
    if not latitude or not readingAt(state.forecast, placeOf(latitude, longitude), now) then
        return nil
    end
    return state.forecast
end

function Weather.url(latitude, longitude)
    return string.format(
        "%s/v1/forecast?latitude=%.2f&longitude=%.2f&hourly=temperature_2m,precipitation,weather_code,wind_speed_10m"
            .. "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&timeformat=unixtime&forecast_days=%d",
        Weather.HOST,
        latitude,
        longitude,
        Weather.FORECAST_DAYS
    )
end

local function finish(forecast, failure)
    state.fetching = false
    if forecast then
        if state.failure then
            Log.info("weather", "the weather forecast can be read again")
        end
        state.forecast, state.failure, state.ranOut = forecast, nil, false
        Store.write(STORE_KEY, stored(forecast), false)
        Log.debug("weather", "weather forecast read", { hours = forecast.count, forecast_until = Clock.iso(untilOf(forecast)) })
    else
        -- Once per kind of failure, so an outage does not fill the log.
        if failure ~= state.failure then
            local kept = state.forecast and untilOf(state.forecast) > Clock.now() and Clock.iso(untilOf(state.forecast)) or Json.null
            Log.warn("weather", "could not read the weather forecast", { reason = failure, saved_forecast_until = kept })
        end
        state.failure = failure
    end
end

-- Asks Open-Meteo now (unless a request is on its way).
function Weather.refresh()
    if state.fetching then
        return
    end
    local latitude, longitude = location()
    if not latitude then
        state.failure = "NO_LOCATION"
        return
    end
    local place = placeOf(latitude, longitude)
    state.fetching = true
    state.attemptedAt = Clock.now()
    local done = false
    local guard
    local function complete(forecast, failure)
        if done then
            return
        end
        done = true
        if guard then
            pcall(function()
                guard:Cancel()
            end)
        end
        finish(forecast, failure)
    end
    pcall(function()
        guard = C4:SetTimer((Weather.TIMEOUT_SECONDS + 5) * 1000, function()
            complete(nil, "timeout")
        end)
    end)
    local ok, err = pcall(function()
        C4:url()
            :SetOptions({ timeout = Weather.TIMEOUT_SECONDS, connect_timeout = 5, fail_on_error = false })
            :OnDone(function(_transfer, responses, errCode, errMsg)
                local last = responses and responses[#responses]
                if not last then
                    complete(nil, tostring(errMsg or errCode or "no answer"))
                elseif tonumber(last.code) ~= 200 then
                    complete(nil, "HTTP " .. tostring(last.code))
                else
                    local forecast = Weather.parse(last.body, Clock.now(), place)
                    complete(forecast, forecast == nil and "unexpected answer" or nil)
                end
            end)
            :Get(Weather.url(latitude, longitude), { Accept = "application/json" })
    end)
    if not ok then
        complete(nil, tostring(err))
    end
end

-- Keeps the forecast fresh; `needed`: a schedule uses the weather. A new one every 6 hours, and at
-- once when the saved one does not hold now (none yet, run out, or for another location); after a
-- failure, 30 minutes after the last try, the saved one used meanwhile.
function Weather.tick(needed, now)
    now = now or Clock.now()
    if not needed and now >= state.wantedUntil then
        return
    end
    local forecast = usable(now)
    if not forecast and state.forecast and state.failure and not state.ranOut and now >= untilOf(state.forecast) then
        state.ranOut = true
        Log.warn("weather", "the saved weather forecast has run out: no weather until a new one is read", { saved_at = Clock.iso(state.forecast.saved_at) })
    end
    local due = not forecast or now - forecast.saved_at >= Weather.REFRESH_SECONDS
    local tooSoon = state.failure ~= nil and state.attemptedAt ~= nil and now - state.attemptedAt < Weather.RETRY_SECONDS
    if due and not tooSoon then
        Weather.refresh()
    end
end

-- True while a read is on its way, or none was tried since the start and none is saved.
function Weather.pending()
    return state.fetching or (not state.attemptedAt and not state.forecast and not state.failure)
end

-- The app shows the weather: read it now if it is due, and keep it fresh for the next hour.
function Weather.wanted(now)
    now = now or Clock.now()
    state.wantedUntil = now + 3600
    Weather.tick(false, now)
end

-- The weather now, from the saved forecast (`source` "forecast", `saved_at`, `forecast_until`),
-- when it was read, nil, and why the last read failed if it did; or nil and why there is none:
-- "NO_LOCATION", "UNREACHABLE" (and why), "WAITING".
function Weather.current(now)
    now = now or Clock.now()
    local latitude, longitude = location()
    if not latitude then
        return nil, nil, "NO_LOCATION"
    end
    local reading = readingAt(state.forecast, placeOf(latitude, longitude), now)
    if reading then
        return reading, reading.saved_at, nil, state.failure
    end
    if state.failure then
        return nil, nil, "UNREACHABLE", state.failure
    end
    return nil, nil, "WAITING"
end

function Weather.location()
    return location()
end

return Weather
