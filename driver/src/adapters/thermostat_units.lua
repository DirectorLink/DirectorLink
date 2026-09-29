-- Temperature units shared by the thermostat adapters (Thermostat V2's heat setpoint path and the
-- Control4 thermostat proxy), so both convert and round the same way.
--
-- The API is always °C. Director takes setpoint commands in the project's scale (variable 1100),
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
-- scale: FAHRENHEIT (whole degrees, the form verified on a °F project) or CELSIUS.
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

return Units
