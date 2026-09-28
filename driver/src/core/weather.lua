-- The weather at home, for schedules (docs/SCHEDULES.md): Open-Meteo's current conditions and
-- today's forecast for the project's location (Composer: project properties, latitude and
-- longitude). The controller asks api.open-meteo.com itself, every 15 minutes while a schedule
-- needs the weather or the app shows it; nothing goes through DirectorLink's servers. The location
-- is sent rounded to two decimals (about a kilometre). Weather data by Open-Meteo.com (CC BY 4.0).

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")

local Weather = {}

Weather.REFRESH_SECONDS = 15 * 60
-- Older than this, the weather is unknown: schedules then do what they say for no data.
Weather.STALE_SECONDS = 45 * 60
Weather.TIMEOUT_SECONDS = 15
Weather.HOST = "https://api.open-meteo.com"

-- WMO weather codes with rain: drizzle, rain, freezing rain, showers, thunderstorms.
local RAIN_CODES = {}
for _, range in ipairs({ { 51, 67 }, { 80, 82 }, { 95, 99 } }) do
    for code = range[1], range[2] do
        RAIN_CODES[code] = true
    end
end

local state = {
    location = nil, -- function returning latitude, longitude
    data = nil,
    fetchedAt = nil,
    fetching = false,
    failure = nil, -- why the last fetch failed
    wantedUntil = 0, -- the app looked at the weather: keep it fresh a while
}

function Weather.reset()
    state.data, state.fetchedAt, state.fetching, state.failure, state.wantedUntil = nil, nil, false, nil, 0
end

-- `location()` returns the project's latitude and longitude (numbers) or nil.
function Weather.configure(location)
    state.location = location
end

local function number(value)
    return type(value) == "number" and value == value and value or nil
end

local function first(list)
    return type(list) == "table" and number(list[1]) or nil
end

-- The parts of Open-Meteo's answer DirectorLink uses, or nil when it is not what was asked for.
function Weather.parse(body)
    local answer = type(body) == "string" and Json.decode(body) or nil
    local current = type(answer) == "table" and answer.current or nil
    if type(current) ~= "table" or not number(current.temperature_2m) then
        return nil
    end
    local daily = type(answer.daily) == "table" and answer.daily or {}
    local code = number(current.weather_code)
    local precipitation = number(current.precipitation) or 0
    return {
        temperature = current.temperature_2m,
        wind_speed = number(current.wind_speed_10m),
        wind_gusts = number(current.wind_gusts_10m),
        precipitation = precipitation,
        weather_code = code,
        raining = precipitation > 0 or (code ~= nil and RAIN_CODES[code] == true),
        today = {
            max_temperature = first(daily.temperature_2m_max),
            min_temperature = first(daily.temperature_2m_min),
            rain_chance = first(daily.precipitation_probability_max),
        },
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

function Weather.url(latitude, longitude)
    return string.format(
        "%s/v1/forecast?latitude=%.2f&longitude=%.2f&current=temperature_2m,precipitation,weather_code,wind_speed_10m,wind_gusts_10m"
            .. "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=1",
        Weather.HOST,
        latitude,
        longitude
    )
end

local function finish(data, failure)
    state.fetching = false
    if data then
        state.data, state.fetchedAt, state.failure = data, Clock.now(), nil
        Log.debug("weather", "weather read", { temperature = data.temperature, wind_speed = data.wind_speed or Json.null, raining = data.raining })
    else
        state.failure = failure
        Log.warn("weather", "could not read the weather", { reason = failure })
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
    state.fetching = true
    local done = false
    local guard
    local function complete(data, failure)
        if done then
            return
        end
        done = true
        if guard then
            pcall(function()
                guard:Cancel()
            end)
        end
        finish(data, failure)
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
                    local data = Weather.parse(last.body)
                    complete(data, data == nil and "unexpected answer" or nil)
                end
            end)
            :Get(Weather.url(latitude, longitude), { Accept = "application/json" })
    end)
    if not ok then
        complete(nil, tostring(err))
    end
end

-- Keeps the reading fresh; `needed`: a schedule uses the weather.
function Weather.tick(needed, now)
    now = now or Clock.now()
    if not needed and now >= state.wantedUntil then
        return
    end
    if not state.fetchedAt or now - state.fetchedAt >= Weather.REFRESH_SECONDS then
        Weather.refresh()
    end
end

-- The app shows the weather: read it now if it is old, and keep it fresh for the next hour.
function Weather.wanted(now)
    now = now or Clock.now()
    state.wantedUntil = now + 3600
    Weather.tick(false, now)
end

-- The current reading, or nil and why there is none: "NO_LOCATION", "UNREACHABLE", "WAITING".
function Weather.current(now)
    now = now or Clock.now()
    if state.data and state.fetchedAt and now - state.fetchedAt <= Weather.STALE_SECONDS then
        return state.data, state.fetchedAt
    end
    if not location() then
        return nil, nil, "NO_LOCATION"
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
