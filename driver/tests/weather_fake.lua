-- A fake Open-Meteo for the driver tests and the dev server: driver/tests/c4mock.lua answers
-- api.open-meteo.com with mock.weather, and these make that answer when the controller asks, at the
-- driver's clock (src/core/clock.lua), in Open-Meteo's shape for timeformat=unixtime: the hourly
-- forecast of 6 days from that day's local midnight, and the days (ADR-071).
--
--   mock.weather = WeatherFake.steady(24, { wind = 12 })      -- the same every hour
--   mock.weather = WeatherFake.forecast(function(hour) ... end)
--   mock.weather = WeatherFake.forecast(WeatherFake.steps({ { at, 23 }, { later, 18 } }))
--
-- `hour(time)` gives the weather of the hour that starts at `time`: a temperature, or
-- { temperature, wind, rain (mm in that hour), code }. Open-Meteo gives each hour's precipitation
-- at the hour's end (the sum of the preceding hour), and so does this.

local Json = require("src.core.json")

local WeatherFake = {}

WeatherFake.DAYS = 6

local function hourOf(fn, time)
    local value = fn(time)
    if type(value) ~= "table" then
        value = { temperature = value }
    end
    return value
end

local function orNull(value)
    if value == nil then
        return Json.null
    end
    return value
end

-- `days(start, hours)`, if given, gives a day's { max, min, chance }; otherwise the highest and
-- lowest of its hours, and a 10% chance of rain (or 80% with rain in it).
function WeatherFake.forecast(fn, days)
    return function()
        local now = require("src.core.clock").now()
        local today = os.date("*t", now)
        local midnight = os.time({ year = today.year, month = today.month, day = today.day, hour = 0, min = 0, sec = 0 })
        local hourly = { time = {}, temperature_2m = {}, precipitation = {}, weather_code = {}, wind_speed_10m = {} }
        for index = 0, WeatherFake.DAYS * 24 - 1 do
            local time = midnight + index * 3600
            local hour, before = hourOf(fn, time), hourOf(fn, time - 3600)
            local rain = before.rain or 0
            hourly.time[#hourly.time + 1] = time
            hourly.temperature_2m[#hourly.time] = orNull(hour.temperature)
            hourly.wind_speed_10m[#hourly.time] = orNull(hour.wind or 5)
            hourly.precipitation[#hourly.time] = rain
            hourly.weather_code[#hourly.time] = before.code or (rain > 0 and 61 or 1)
        end
        local daily = { time = {}, temperature_2m_max = {}, temperature_2m_min = {}, precipitation_probability_max = {} }
        for day = 0, WeatherFake.DAYS - 1 do
            local start = os.time({ year = today.year, month = today.month, day = today.day + day, hour = 0, min = 0, sec = 0 })
            local finish = os.time({ year = today.year, month = today.month, day = today.day + day + 1, hour = 0, min = 0, sec = 0 })
            local high, low, wet = nil, nil, false
            for time = start, finish - 3600, 3600 do
                local hour = hourOf(fn, time)
                if hour.temperature then
                    high = math.max(high or hour.temperature, hour.temperature)
                    low = math.min(low or hour.temperature, hour.temperature)
                end
                wet = wet or (hour.rain or 0) > 0
            end
            local values = days and days(start) or { max = high, min = low, chance = wet and 80 or 10 }
            local index = #daily.time + 1
            daily.time[index] = start
            daily.temperature_2m_max[index] = orNull(values.max)
            daily.temperature_2m_min[index] = orNull(values.min)
            daily.precipitation_probability_max[index] = orNull(values.chance)
        end
        for _, list in pairs(hourly) do
            Json.array(list)
        end
        for _, list in pairs(daily) do
            Json.array(list)
        end
        return { latitude = 32.08, longitude = 34.78, hourly = hourly, daily = daily }
    end
end

-- The same weather every hour: `options` wind, rain (mm an hour), code, and the days' max, min and
-- chance (by default 2° above and 8° below, and 10%).
function WeatherFake.steady(temperature, options)
    options = options or {}
    return WeatherFake.forecast(function()
        return { temperature = temperature, wind = options.wind, rain = options.rain, code = options.code }
    end, function()
        return { max = options.max or temperature + 2, min = options.min or temperature - 8, chance = options.chance or 10 }
    end)
end

-- Weather that changes at moments: `points` { { time, weather }, ... } in order; an hour has the
-- weather of the last point at or before it (the first point's before them).
function WeatherFake.steps(points)
    return function(time)
        local found = points[1][2]
        for _, point in ipairs(points) do
            if point[1] <= time then
                found = point[2]
            end
        end
        return found
    end
end

return WeatherFake
