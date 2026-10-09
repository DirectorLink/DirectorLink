-- Temperature units shared by the thermostat adapters (Thermostat V2's heat setpoint path and the
-- Control4 thermostat proxy), so both convert and round the same way.
--
-- The API's main fields are °C; since 1.10.2 (ADR-076) a °F thermostat's are also given in °F, as
-- it reports them, and °F clients may send °F. Director takes setpoint commands in the project's
-- scale (variable 1100),
-- and a proxy reports every value in both scales. Comparisons are done in "native" units: whole
-- degrees in a °F project, integer tenths of a degree in a °C project. With plain floats,
-- 24.0 - 22.3 = 1.6999... and a 1.7 deadband would wrongly fail.
local Units = {}

local function round(value)
    return math.floor(value + 0.5)
end

-- "F", "C", or nil when the value names neither (the first letter of FAHRENHEIT / CELSIUS).
function Units.scale(value)
    local first = string.lower(tostring(value or "")):sub(1, 1)
    if first == "f" then
        return "F"
    elseif first == "c" then
        return "C"
    end
    return nil
end

-- °C to native units: whole °F, or tenths of a °C.
function Units.toNative(celsius, scale)
    if scale == "F" then
        return round(celsius * 9 / 5 + 32)
    end
    return round(celsius * 10)
end

-- Command parameters for a native value, with the only key the proxy is known to take in each
-- scale: FAHRENHEIT (whole degrees, as listed on a °F project) or CELSIUS.
function Units.param(native, scale)
    if scale == "F" then
        return { FAHRENHEIT = native }
    end
    return { CELSIUS = native / 10 }
end

-- A value read from the proxy's °F and °C variables, in native units. The project-scale variable
-- comes first; the other one, converted, is only a fallback.
function Units.readNative(fahrenheit, celsius, scale)
    local f, c = tonumber(fahrenheit), tonumber(celsius)
    if scale == "F" then
        if f then
            return round(f)
        end
        return c and Units.toNative(c, "F") or nil
    end
    if c then
        return round(c * 10)
    end
    return f and Units.toNative((f - 32) * 5 / 9, "C") or nil
end

-- Native units back to °C, rounded to 0.1.
function Units.celsius(native, scale)
    if native == nil then
        return nil
    end
    if scale == "F" then
        return round((native - 32) * 5 / 9 * 10) / 10
    end
    return native / 10
end

-- A measured temperature (not a setpoint) in °C to 0.1, project-scale variable first. Setpoints
-- are whole °F in a °F project because that is what the thermostat takes; a room at 71.6 °F is
-- 22.0 °C, not 72 °F (22.2 °C).
function Units.measuredCelsius(fahrenheit, celsius, scale)
    local f, c = tonumber(fahrenheit), tonumber(celsius)
    if f and (scale == "F" or not c) then
        return Units.celsius(f, "F")
    end
    return c and round(c * 10) / 10 or nil
end

-- A deadband is a difference, not a temperature: °C = ΔF × 5/9, never (ΔF - 32) × 5/9.
function Units.deltaNative(deltaF, deltaC, scale)
    local f, c = tonumber(deltaF), tonumber(deltaC)
    if scale == "F" then
        if f then
            return round(f)
        end
        return c and round(c * 9 / 5) or nil
    end
    if c then
        return round(c * 10)
    end
    return f and round(f * 5 / 9 * 10) or nil
end

function Units.deltaCelsius(delta, scale)
    if delta == nil then
        return nil
    end
    if scale == "F" then
        return round(delta * 5 / 9 * 10) / 10
    end
    return delta / 10
end

-- 1.10.2 (ADR-076): values a driver has not reported, and what °F clients send.

-- A proxy variable reads 0 until its driver reports a value, so 0 in the variable read is "not
-- reported", never a real setpoint or room temperature: a real 0 °C reads 32 in the °F variable,
-- a real 0 °F reads -17.8 in the °C one.
local function reported(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == 0 then
        return nil
    end
    return number
end

-- The lowest and highest setpoint shown, in °C. Below and above are values no thermostat works to:
-- -17.8 °C is a 0 °F setpoint converted, which a driver that reports none leaves (#75).
Units.SETPOINT_SHOWN_MIN_C = 0
Units.SETPOINT_SHOWN_MAX_C = 50

-- A setpoint from its °F and °C variables in native units (Units.readNative), or nil when it is
-- not reported (missing, or 0 in both) or not one a thermostat works to.
function Units.setpointNative(fahrenheit, celsius, scale)
    local native = Units.readNative(reported(fahrenheit), reported(celsius), scale)
    if native == nil then
        return nil
    end
    local value = Units.celsius(native, scale)
    if value < Units.SETPOINT_SHOWN_MIN_C or value > Units.SETPOINT_SHOWN_MAX_C then
        return nil
    end
    return native
end

-- The room temperature from the °F and °C variables: °C and °F, each to 0.1, or nil when the
-- thermostat reports none. The project-scale variable comes first when both are reported; a
-- variable left at 0 is not reported, so a driver that fills only one scale (or sets no scale) is
-- read from the one it fills. A reading of exactly 0 °C is not reported either: it is what the
-- °F variable shows (32) for a °C variable left at 0, and no room is at exactly 0.0 °C; nor is
-- -17.8 °C next to a °F variable left at 0 (the °C variable converted from it).
function Units.roomTemperature(fahrenheit, celsius, scale)
    local f, c = reported(fahrenheit), reported(celsius)
    if tonumber(fahrenheit) == 0 and c and math.abs(c + 17.8) < 0.05 then
        return nil
    end
    if f and c then
        if scale == "F" then
            c = nil
        else
            f = nil
        end
    end
    local celsiusValue
    if f then
        celsiusValue = (f - 32) * 5 / 9
    elseif c then
        celsiusValue = c
        f = c * 9 / 5 + 32
    else
        return nil
    end
    celsiusValue = round(celsiusValue * 10) / 10
    if celsiusValue == 0 or celsiusValue < -50 or celsiusValue > 80 then
        return nil
    end
    return celsiusValue, round(f * 10) / 10
end

-- °F to °C, unrounded: a whole °F a client sends comes back exact through Units.toNative.
function Units.fromFahrenheit(fahrenheit)
    return (fahrenheit - 32) * 5 / 9
end

-- A °C value in whole °F (a setpoint, as a °F thermostat takes it), or nil.
function Units.wholeFahrenheit(celsius)
    if type(celsius) ~= "number" then
        return nil
    end
    return round(celsius * 9 / 5 + 32)
end

-- A °C range in whole °F, inside it (16 to 32 °C is 61 to 89 °F), so a °F value sent back is
-- always within the °C range.
function Units.fahrenheitRange(minimum, maximum)
    local low = minimum * 9 / 5 + 32
    local high = maximum * 9 / 5 + 32
    return math.ceil(low - 1e-9), math.floor(high + 1e-9)
end

-- The scale a value names (Units.scale), else the project's, else the one the thermostat fills:
-- °F when only its °F room temperature is reported. Never nil.
function Units.scaleOr(value, projectScale, fahrenheit, celsius)
    local scale = Units.scale(value) or Units.scale(projectScale)
    if scale then
        return scale
    end
    if reported(fahrenheit) and not reported(celsius) then
        return "F"
    end
    return "C"
end

Units.reported = reported

-- The project's temperature scale, "F" or "C" (1.10.2, ADR-076), for what no one thermostat says
-- (the weather, weather schedules, "only if", the Composer printout): Composer's TemperatureScale
-- as Director reports it, else the one most thermostats work in, else °C (a °C project without
-- thermostats stays °C). `registry`: src/core/registry.lua.
function Units.projectScale(registry)
    local properties = registry and registry.metadata and registry.metadata.properties or {}
    local scale = Units.scale(properties.TemperatureScale)
    if scale then
        return scale
    end
    local count = { F = 0, C = 0 }
    for _, device in ipairs(registry and registry.climateList and registry.climateList() or {}) do
        local thermostatScale = (device.capabilities or {}).scale
        if count[thermostatScale] then
            count[thermostatScale] = count[thermostatScale] + 1
        end
    end
    return count.F > count.C and "F" or "C"
end

-- A °C temperature as Composer's printout says it in `scale`: "23C", "22.5C" or "73F" (whole °F).
function Units.text(celsius, scale)
    if scale == "F" then
        return string.format("%dF", round(celsius * 9 / 5 + 32))
    end
    if celsius == math.floor(celsius) then
        return string.format("%dC", celsius)
    end
    return string.format("%.1fC", celsius)
end

return Units
