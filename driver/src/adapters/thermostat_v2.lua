local Log = require("src.core.log")
local Setpoints = require("src.adapters.thermostat_setpoints")
local Units = require("src.adapters.thermostat_units")

-- Thermostat V2 (thermostatV2.c4i), the proxy most thermostat drivers use. A zone works to one of:
--   single: its single setpoint (1149 °F / 1150 °C), as since 1.0.0;
--   heat:   floor heating that leaves the single setpoint at 0 and keeps its target in the heat
--           setpoint (1.1.0, #19);
--   dual:   separate heat and cool setpoints (1132-1135) and no single setpoint, as a Nest reports
--           them (1.10.2, ADR-076, #75): the heat setpoint in heat, the cool one in cool, both in
--           auto, with the plan of the Control4 thermostat proxy (thermostat_setpoints.lua).
-- A thermostat proxy that reports a room temperature and nothing to set (no heat, cool or auto
-- mode listed, no setpoint) is a temperature sensor (1.10.2): read, never set. One whose driver is
-- the outdoor weather (its name or its driver's says "weather") is left out: the weather card has
-- the weather.
--
-- Values are read in the project's scale (1100; else Composer's TemperatureScale; else °F when only
-- the °F room temperature is reported), and a value left at 0 is not reported (thermostat_units.lua).
-- A zone in °C that reports its room temperature (1131) and its single setpoint (1149) reads and
-- watches exactly what 1.0.0 did: the owner's 22 zones; everything more is read only when one of
-- those is missing or the project is in °F.
local Climate = {}

local VARIABLE_SCALE = 1100
local VARIABLE_HVAC_MODE = 1104
local VARIABLE_FAN_MODE = 1105
local VARIABLE_HVAC_STATE = 1107
local VARIABLE_IS_CONNECTED = 1112
local VARIABLE_HVAC_MODES_LIST = 1120
local VARIABLE_FAN_MODES_LIST = 1121
local VARIABLE_TEMPERATURE_F = 1130
local VARIABLE_TEMPERATURE_C = 1131
local VARIABLE_HEAT_SETPOINT_F = 1132
local VARIABLE_HEAT_SETPOINT_C = 1133
local VARIABLE_COOL_SETPOINT_F = 1134
local VARIABLE_COOL_SETPOINT_C = 1135
local VARIABLE_DEADBAND_F = 1146
local VARIABLE_DEADBAND_C = 1147
local VARIABLE_SINGLE_SETPOINT_F = 1149
local VARIABLE_SINGLE_SETPOINT_C = 1150

-- Read and watched only when the single setpoint is not reported: where a zone that does not use
-- it keeps its target; and the fan speeds such a zone lists (a Nest's Auto and On).
local OTHER_SETPOINTS = {
    VARIABLE_FAN_MODES_LIST,
    VARIABLE_SINGLE_SETPOINT_C,
    VARIABLE_HEAT_SETPOINT_F,
    VARIABLE_HEAT_SETPOINT_C,
    VARIABLE_COOL_SETPOINT_F,
    VARIABLE_COOL_SETPOINT_C,
    VARIABLE_DEADBAND_F,
    VARIABLE_DEADBAND_C,
}

-- Floor heating set through its heat setpoint may be parked well below comfort temperature.
local HEAT_SETPOINT_MIN_C = 5
local SINGLE_SETPOINT_MIN_C = 16
local SINGLE_SETPOINT_MAX_C = 32

-- The humidity (%): Snap One documents HUMIDITY_CHANGED but no variable for it; 1138 HUMIDITY is
-- what other Control4 clients read. A sensor's is looked up by name once (either name), else 1138,
-- and it has none when no such variable exists.
local HUMIDITY_NAMES = { HUMIDITY = true, CURRENT_HUMIDITY = true }
local VARIABLE_HUMIDITY = 1138

local tracked = {}

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function safeGetVariable(deviceId, variableId)
    local ok, value = pcall(function()
        return C4:GetVariable(deviceId, variableId)
    end)
    if ok then
        return value
    end
    return nil
end

local function registerListener(deviceId, variableId)
    return pcall(function()
        C4:RegisterVariableListener(deviceId, variableId)
    end)
end

local function parseList(value)
    local result = {}
    for item in tostring(value or ""):gmatch("[^,]+") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then
            table.insert(result, item)
        end
    end
    return result
end

local function boolValue(value)
    local v = lower(value)
    return v == "1" or v == "true" or v == "on" or v == "yes"
end

local function round(value)
    return math.floor(value + 0.5)
end

local function fahrenheitToCelsius(value)
    local f = tonumber(value)
    if not f then
        return nil
    end
    local c = (f - 32) * 5 / 9
    return math.floor(c + 0.5)
end

-- "Undefined" is how a sensor (or a zone not ready yet) reports its mode and state: none (1.10.2).
local function normalizeMode(value)
    local v = lower(value)
    if v == "off" then return "off" end
    if v == "heat" then return "heat" end
    if v == "cool" then return "cool" end
    if v == "auto" then return "auto" end
    return (v ~= "" and v ~= "undefined") and v or nil
end

-- "Undefined" (or nothing) is how a zone without a fan reports its fan mode: no fan speed.
local function fanValue(value)
    local v = lower(value)
    return (v ~= "" and v ~= "undefined") and v or nil
end

local function hasMode(modes, name)
    for _, mode in ipairs(modes or {}) do
        if lower(mode) == name then
            return true
        end
    end
    return false
end

-- Heat and neither cool nor auto. No AC zone is ever heat-only, so the heat setpoint path below
-- cannot reach one.
local function isHeatOnly(modes)
    return hasMode(modes, "heat") and not hasMode(modes, "cool") and not hasMode(modes, "auto")
end

-- "Weather" as a word of its own in a name ("Weather Driver", not "Weatherby").
local function namesWeather(text)
    return lower(text):find("%f[%a]weather%f[^%a]") ~= nil
end

-- An outdoor weather driver on the thermostat proxy (#75, "Weather Driver"): its name says so, or
-- its driver's (any driver file with "weather" in it, e.g. openweather.c4z: no HVAC driver has).
-- The weather card has the weather; such a thermostat is left out of Climate.
local function isWeather(device)
    if namesWeather(device.name) then
        return true
    end
    for _, protocol in ipairs(type(device.protocols) == "table" and device.protocols or {}) do
        if lower(protocol.driver):find("weather", 1, true) or namesWeather(protocol.name) then
            return true
        end
    end
    return false
end

local function singleNotReported(info)
    return Units.reported(info.raw[VARIABLE_SINGLE_SETPOINT_F]) == nil
end

-- Some heat-only zones (floor heating seen on a real °F project, #19) leave the single
-- setpoint at 0 in both scales, keep their real target in the heat setpoint (1133) and accept only
-- SET_SETPOINT_HEAT. Both 1149 and 1150 reading 0 is never a real target: a real 0 °C reads
-- 1149 = 32 and a real 0 °F reads 1150 = -17.8. A missing 1150 keeps the single setpoint, and so
-- does a heat setpoint of 0, which means it is not reported yet. The rule is checked again on
-- every change, so a zone that reads 0 while Director restarts goes back once its values arrive.
local function usesHeatSetpoint(info)
    local raw = info.raw
    local heatC = tonumber(raw[VARIABLE_HEAT_SETPOINT_C])
    return info.heatOnly == true
        and tonumber(raw[VARIABLE_SINGLE_SETPOINT_F]) == 0
        and tonumber(raw[VARIABLE_SINGLE_SETPOINT_C]) == 0
        and heatC ~= nil and heatC ~= 0
end

-- The Debug log of a zone that does not use its single setpoint lists the proxy's thermostat
-- variables (1100-1150) with their names and values, so a field log shows what the zone really
-- has. Nothing depends on these names; read only at Debug. Returns true when it logged them.
local function logVariableNames(deviceId)
    if Log.getLevel() ~= "debug" then
        return false
    end
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(deviceId)
    end)
    local names = {}
    if ok and type(variables) == "table" then
        for id, variable in pairs(variables) do
            local number = tonumber(id)
            if number and number >= 1100 and number <= 1150 and type(variable) == "table" then
                names[#names + 1] = tostring(id) .. "=" .. tostring(variable.name or "") .. ":" .. tostring(variable.value)
            end
        end
    end
    table.sort(names)
    Log.debug("climate", "heat-only thermostat variables", { device_id = deviceId, variables = table.concat(names, ", ") })
    return true
end

-- Reads and watches a variable not watched yet; true when it has a value.
local function watch(device, info, variableId)
    if info.watching[variableId] then
        return false
    end
    local value = safeGetVariable(device.id, variableId)
    if value == nil then
        return false
    end
    info.raw[variableId] = value
    info.watching[variableId] = registerListener(device.id, variableId)
    return true
end

-- A zone whose single setpoint is not reported reads and watches the other setpoints (and the
-- deadband): it may keep its target there. A zone in use on its single setpoint reads nothing
-- more, as in 1.0.0; if its single setpoint drops to 0, the change looks again. Returns true when
-- it read one it did not have.
local function lookAgain(device, info)
    if not singleNotReported(info) then
        return false
    end
    local found = false
    for _, variableId in ipairs(OTHER_SETPOINTS) do
        if watch(device, info, variableId) then
            found = true
        end
    end
    if not info.variablesLogged then
        info.variablesLogged = logVariableNames(device.id)
    end
    return found
end

-- A sensor's humidity variable, looked up once: by name (HUMIDITY_NAMES), else 1138.
local function watchHumidity(device, info)
    if info.humidityLooked then
        return
    end
    info.humidityLooked = true
    local ok, variables = pcall(function()
        return C4:GetDeviceVariables(device.id)
    end)
    for id, variable in pairs(ok and type(variables) == "table" and variables or {}) do
        local name = type(variable) == "table" and string.upper(tostring(variable.name or "")) or ""
        if HUMIDITY_NAMES[name] and tonumber(id) then
            info.humidityId = tonumber(id)
            watch(device, info, info.humidityId)
            return
        end
    end
    if watch(device, info, VARIABLE_HUMIDITY) then
        info.humidityId = VARIABLE_HUMIDITY
    end
end

-- A zone whose mode list loses Cool loses its fan control too, as a zone without Cool never gets
-- it at start-up. A zone that keeps Cool keeps its fan.
local function dropFanControl(info)
    info.hasFanMode = false
    info.fanModes = {}
end

-- The fan speeds a zone with heat and cool setpoints lists itself (1121, in the proxy's spelling),
-- or nil: every other zone has the Low, Medium and High of 1.0.0, or none (1.10.2).
local function listedFans(info)
    if info.source ~= "dual" then
        return nil
    end
    local listed = parseList(info.raw[VARIABLE_FAN_MODES_LIST])
    return #listed > 0 and listed or nil
end

-- The proxy's own spelling of a requested fan speed in `list`, matched case-insensitively.
local function findInList(list, requested)
    local wanted = lower(requested)
    for _, entry in ipairs(list or {}) do
        if lower(entry) == wanted then
            return entry
        end
    end
    return nil
end

-- The single setpoint, °C and whole °F (°F only in a °F project), or nil when it is not reported.
-- In °C as since 1.0.0: from 1149, to a whole °C. In a °F project from 1149 too, to 0.1 °C, and the
-- °F as the thermostat takes it. 1150 only when 1149 is not reported.
local function singleSetpoint(info)
    local raw, scale = info.raw, info.scale
    local f, c = Units.reported(raw[VARIABLE_SINGLE_SETPOINT_F]), Units.reported(raw[VARIABLE_SINGLE_SETPOINT_C])
    local celsius, fahrenheit
    if f then
        if scale == "F" then
            celsius, fahrenheit = round((f - 32) * 5 / 9 * 10) / 10, round(f)
        else
            celsius = fahrenheitToCelsius(f)
        end
    elseif c then
        celsius = round(c * 10) / 10
        fahrenheit = scale == "F" and Units.toNative(c, "F") or nil
    end
    -- A real 0 °C target reads 32 °F, which 1.1.0 showed as 0; one no thermostat works to is not.
    if celsius == nil or celsius < Units.SETPOINT_SHOWN_MIN_C or celsius > Units.SETPOINT_SHOWN_MAX_C then
        return nil, nil
    end
    return celsius, fahrenheit
end

-- Which setpoint the zone works to now: "single", "heat" or "dual"; a sensor has "single" and none.
local function sourceOf(info, heatNative, coolNative)
    if usesHeatSetpoint(info) then
        return "heat"
    end
    if not info.heatOnly and singleNotReported(info) and singleSetpoint(info) == nil and (heatNative or coolNative) then
        return "dual"
    end
    return "single"
end

-- Rebuilds capabilities, state and actions from what the zone reports.
local function refresh(device, info)
    local raw, scale = info.raw, info.scale
    local function setpoint(fahrenheitVariable, celsiusVariable)
        return Units.setpointNative(raw[fahrenheitVariable], raw[celsiusVariable], scale)
    end
    local heatNative = setpoint(VARIABLE_HEAT_SETPOINT_F, VARIABLE_HEAT_SETPOINT_C)
    local coolNative = setpoint(VARIABLE_COOL_SETPOINT_F, VARIABLE_COOL_SETPOINT_C)
    local singleC, singleF = singleSetpoint(info)
    local settable = hasMode(info.listed, "heat") or hasMode(info.listed, "cool") or hasMode(info.listed, "auto")
    local sensor = not settable and singleC == nil and heatNative == nil and coolNative == nil
    local source = sourceOf(info, heatNative, coolNative)
    info.useHeat = source == "heat"
    info.source = source
    info.sensor = sensor
    local fans = listedFans(info) or info.fanModes
    if sensor then
        watchHumidity(device, info)
    end
    if source == "dual" then
        Setpoints.reported(info.lastSent, heatNative, coolNative)
    end

    local capabilities = {
        hvac_modes = sensor and {} or info.hvacModes,
        fan_modes = sensor and {} or fans,
        single_setpoint = source ~= "dual",
        -- Internal: "heat" when the target is the heat setpoint (1133), "dual" with heat and cool
        -- setpoints; never shown by the API.
        setpoint_source = source,
        temperature_unit = "C",
        scale = scale,
        sensor = sensor or nil,
        -- The range Control4 itself allows these zones (an AC that is off is often left at 32 °C).
        -- Narrower here, DirectorLink would report a target it then refuses to set.
        target_temperature_min_c = source == "single" and SINGLE_SETPOINT_MIN_C or HEAT_SETPOINT_MIN_C,
        target_temperature_max_c = SINGLE_SETPOINT_MAX_C,
    }
    if source == "dual" then
        local anyHeat = hasMode(info.hvacModes, "heat") or hasMode(info.hvacModes, "auto")
        local anyCool = hasMode(info.hvacModes, "cool") or hasMode(info.hvacModes, "auto")
        local deadband = Units.deltaNative(raw[VARIABLE_DEADBAND_F], raw[VARIABLE_DEADBAND_C], scale)
        if deadband == 0 then
            deadband = nil
        end
        capabilities.setpoints = "dual"
        capabilities.has_heat = heatNative ~= nil and anyHeat
        capabilities.has_cool = coolNative ~= nil and anyCool
        capabilities.deadband_native = deadband
        capabilities.deadband_c = Units.deltaCelsius(deadband, scale)
        capabilities.target_temperature_min_c = Setpoints.MIN_C
        capabilities.target_temperature_max_c = Setpoints.MAX_C
    end
    device.capabilities = capabilities

    local actions = {}
    if not sensor then
        actions = { "set_hvac_mode", "set_temperature" }
        if source == "dual" then
            actions[#actions + 1] = "set_setpoints"
        end
        if #fans > 0 then
            actions[#actions + 1] = "set_fan_mode"
        end
    end
    device.actions = actions

    local state = device.state or {}
    device.state = state
    state.connected = raw[VARIABLE_IS_CONNECTED] == nil and true or boolValue(raw[VARIABLE_IS_CONNECTED])
    state.scale = tostring(raw[VARIABLE_SCALE] or "CELSIUS")
    -- As since 1.0.0, the °C variable, unless it is not reported or the project is in °F.
    local measuredC = Units.reported(raw[VARIABLE_TEMPERATURE_C])
    if measuredC and scale ~= "F" then
        state.current_temperature_c = measuredC
        state.current_temperature_f = nil
    else
        state.current_temperature_c, state.current_temperature_f = Units.roomTemperature(raw[VARIABLE_TEMPERATURE_F], raw[VARIABLE_TEMPERATURE_C], scale)
    end
    if scale ~= "F" then
        state.current_temperature_f = nil
    end
    state.hvac_mode = not sensor and normalizeMode(raw[VARIABLE_HVAC_MODE]) or nil
    state.hvac_state = not sensor and normalizeMode(raw[VARIABLE_HVAC_STATE]) or nil
    state.fan_mode = not sensor and fanValue(raw[VARIABLE_FAN_MODE]) or nil
    state.heat_native, state.cool_native, state.heat_setpoint_c, state.cool_setpoint_c = nil, nil, nil, nil
    state.target_temperature_f = nil
    if source == "dual" then
        state.heat_native = capabilities.has_heat and heatNative or nil
        state.cool_native = capabilities.has_cool and coolNative or nil
        state.heat_setpoint_c = Units.celsius(state.heat_native, scale)
        state.cool_setpoint_c = Units.celsius(state.cool_native, scale)
        if state.hvac_mode == "heat" then
            state.target_temperature_c = state.heat_setpoint_c
            state.target_temperature_f = scale == "F" and state.heat_native or nil
        elseif state.hvac_mode == "cool" then
            state.target_temperature_c = state.cool_setpoint_c
            state.target_temperature_f = scale == "F" and state.cool_native or nil
        else
            state.target_temperature_c = nil
        end
    elseif source == "heat" then
        state.target_temperature_c = tonumber(raw[VARIABLE_HEAT_SETPOINT_C])
        state.target_temperature_f = scale == "F" and heatNative or nil
    else
        state.target_temperature_c = singleC
        state.target_temperature_f = scale == "F" and singleF or nil
    end
    local humidity = info.humidityId and Units.reported(raw[info.humidityId]) or nil
    state.humidity = (sensor and humidity and humidity > 0 and humidity <= 100) and round(humidity) or nil
end

-- What the API shows of a zone, to tell whether a change changed anything.
local function snapshot(device)
    local state, capabilities = device.state or {}, device.capabilities or {}
    return table.concat({
        tostring(state.connected), tostring(state.current_temperature_c), tostring(state.current_temperature_f),
        tostring(state.target_temperature_c), tostring(state.target_temperature_f), tostring(state.heat_native),
        tostring(state.cool_native), tostring(state.hvac_mode), tostring(state.hvac_state), tostring(state.fan_mode),
        tostring(state.humidity), tostring(state.scale), tostring(capabilities.setpoint_source), tostring(capabilities.sensor),
        tostring(capabilities.has_heat), tostring(capabilities.has_cool), tostring(capabilities.deadband_native),
        table.concat(capabilities.hvac_modes or {}, ","), table.concat(capabilities.fan_modes or {}, ","),
    }, "|")
end

local function titleMode(value)
    local v = lower(value)
    if v == "off" then return "Off" end
    if v == "heat" then return "Heat" end
    if v == "cool" then return "Cool" end
    if v == "auto" then return "Auto" end
    return nil
end

local function titleFan(value)
    local v = lower(value)
    if v == "low" then return "Low" end
    if v == "medium" then return "Medium" end
    if v == "high" then return "High" end
    if v == "auto" then return "Auto" end
    if v == "top" then return "Top" end
    return nil
end

function Climate.matches(device)
    local driver = lower(device and device.proxy and device.proxy.driver)
    return driver == "thermostatv2.c4i" or driver == "thermostatv2.c4z"
end

function Climate.reset()
    tracked = {}
end

function Climate.initialize(device, registry)
    if isWeather(device) then
        return false, "An outdoor weather driver: the weather card shows the weather, not Climate"
    end

    local tempC = safeGetVariable(device.id, VARIABLE_TEMPERATURE_C)
    local hvacMode = safeGetVariable(device.id, VARIABLE_HVAC_MODE)
    local setpointF = safeGetVariable(device.id, VARIABLE_SINGLE_SETPOINT_F)

    local fanMode = safeGetVariable(device.id, VARIABLE_FAN_MODE)
    local hvacState = safeGetVariable(device.id, VARIABLE_HVAC_STATE)
    local connectedValue = safeGetVariable(device.id, VARIABLE_IS_CONNECTED)
    local hvacModesValue = safeGetVariable(device.id, VARIABLE_HVAC_MODES_LIST)
    local scaleValue = safeGetVariable(device.id, VARIABLE_SCALE)

    -- 1.0.0 required these three. Since 1.10.2 a zone that has no mode or single setpoint still
    -- starts (a sensor, #75); one without a room temperature in either scale does not (below).
    local required = {
        { VARIABLE_TEMPERATURE_C, tempC },
        { VARIABLE_HVAC_MODE, hvacMode },
        { VARIABLE_SINGLE_SETPOINT_F, setpointF },
    }
    local watching = {}
    for _, entry in ipairs(required) do
        if entry[2] ~= nil then
            local ok = registerListener(device.id, entry[1])
            if not ok then
                return false, "Unable to register Thermostat V2 state listener " .. tostring(entry[1])
            end
            watching[entry[1]] = true
        end
    end

    local optional = {
        VARIABLE_FAN_MODE,
        VARIABLE_HVAC_STATE,
        VARIABLE_IS_CONNECTED,
        VARIABLE_HVAC_MODES_LIST,
        VARIABLE_SCALE,
    }
    for _, variableId in ipairs(optional) do
        if safeGetVariable(device.id, variableId) ~= nil then
            watching[variableId] = registerListener(device.id, variableId)
        end
    end

    local raw = {
        [VARIABLE_TEMPERATURE_C] = tempC,
        [VARIABLE_HVAC_MODE] = hvacMode,
        [VARIABLE_SINGLE_SETPOINT_F] = setpointF,
        [VARIABLE_FAN_MODE] = fanMode,
        [VARIABLE_HVAC_STATE] = hvacState,
        [VARIABLE_IS_CONNECTED] = connectedValue,
        [VARIABLE_HVAC_MODES_LIST] = hvacModesValue,
        [VARIABLE_SCALE] = scaleValue,
    }
    local properties = registry and registry.metadata and registry.metadata.properties or {}
    local info = {
        raw = raw,
        watching = watching,
        projectScale = properties.TemperatureScale,
        listed = parseList(hvacModesValue),
        lastSent = {},
    }

    -- The °F room temperature: in a °F project, when the °C one is not reported, or when nothing
    -- says the scale (a sensor that sets none, #75).
    local said = Units.scale(scaleValue) or Units.scale(info.projectScale)
    if said == "F" or said == nil or Units.reported(tempC) == nil then
        watch(device, info, VARIABLE_TEMPERATURE_F)
    end
    info.scale = Units.scaleOr(scaleValue, info.projectScale, raw[VARIABLE_TEMPERATURE_F], tempC)
    if Units.reported(tempC) == nil and Units.reported(raw[VARIABLE_TEMPERATURE_F]) == nil and tempC == nil then
        return false, "Thermostat V2 room temperature (1130/1131) is unavailable"
    end

    local hvacModes = #info.listed > 0 and info.listed or { "Off", "Heat", "Cool" }
    info.hvacModes = hvacModes
    info.heatOnly = isHeatOnly(hvacModes)
    -- Only a zone whose single setpoint is not reported reads and watches the other setpoints; every
    -- other zone starts with the reads and listeners of 1.0.0.
    lookAgain(device, info)

    -- The AC zones in the real test system expose Low/Medium/High.
    -- Heat-only floor zones intentionally do not expose fan controls here.
    info.hasFanMode = fanMode ~= nil and hasMode(hvacModes, "cool")
    info.fanModes = info.hasFanMode and { "Low", "Medium", "High" } or {}
    tracked[device.id] = info

    device.supported = true
    device.adapter_error = nil
    device.state = {}
    refresh(device, info)
    info.loggedSource = info.source

    local logged = {
        device_id = device.id,
        hvac_modes = hvacModes,
        fan_mode = fanMode,
        current_temperature_c = device.state.current_temperature_c,
        target_temperature_c = device.state.target_temperature_c,
    }
    -- A zone that looked at its other setpoints also logs which setpoint it follows and the values
    -- that decided it, and a °F zone or a sensor says so; every other zone logs the line of 1.0.0.
    if singleNotReported(info) then
        logged.setpoint_source = info.source
        logged.single_f = setpointF
        logged.single_c = raw[VARIABLE_SINGLE_SETPOINT_C]
        logged.heat_c = raw[VARIABLE_HEAT_SETPOINT_C]
        logged.cool_c = raw[VARIABLE_COOL_SETPOINT_C]
    end
    if info.scale == "F" then
        logged.scale = "F"
        logged.target_temperature_f = device.state.target_temperature_f
    end
    if info.sensor then
        logged.sensor = true
    end
    Log.info("climate", "initialized thermostat", logged)

    return true
end

function Climate.onVariableChanged(device, variableId, value)
    local info = tracked[device.id]
    if not info or not device.state then
        return false
    end

    variableId = tonumber(variableId)
    if not variableId or not info.watching[variableId] then
        return false
    end
    local before = snapshot(device)
    info.raw[variableId] = value

    if variableId == VARIABLE_HVAC_MODES_LIST then
        local modes = parseList(value)
        info.listed = modes
        if #modes > 0 then
            info.hvacModes = modes
        end
        info.heatOnly = isHeatOnly(info.hvacModes)
        if info.hasFanMode and not hasMode(info.hvacModes, "cool") then
            dropFanControl(info)
        end
    elseif variableId == VARIABLE_SCALE then
        local scale = Units.scale(value)
        if scale and scale ~= info.scale then
            Log.info("climate", "thermostat scale changed", { device_id = device.id, scale = scale })
            info.scale = scale
        end
    end
    -- The room temperature changes often: a setpoint that appeared since is found then; a change of
    -- the single setpoint or of the mode list looks again too (a zone that just turned heat-only
    -- reads its heat setpoint before the path is chosen).
    if variableId == VARIABLE_TEMPERATURE_C or variableId == VARIABLE_TEMPERATURE_F
        or variableId == VARIABLE_SINGLE_SETPOINT_F or variableId == VARIABLE_HVAC_MODES_LIST then
        lookAgain(device, info)
    end
    refresh(device, info)

    if info.source ~= info.loggedSource then
        info.loggedSource = info.source
        local raw = info.raw
        Log.info("climate", "setpoint path changed", {
            device_id = device.id,
            setpoint_source = info.source,
            single_f = raw[VARIABLE_SINGLE_SETPOINT_F],
            single_c = raw[VARIABLE_SINGLE_SETPOINT_C],
            heat_c = raw[VARIABLE_HEAT_SETPOINT_C],
            cool_c = raw[VARIABLE_COOL_SETPOINT_C],
        })
    end
    if snapshot(device) == before then
        return false
    end

    Log.debug("climate_state", "thermostat variable changed", {
        device_id = device.id,
        variable_id = variableId,
        value = value,
    })
    return true
end

local function send(deviceId, command, params)
    Log.info("climate_command", "sending thermostat command", {
        device_id = deviceId,
        command = command,
        params = params,
    })

    local ok, err = pcall(function()
        C4:SendToDevice(deviceId, command, params)
    end)

    if not ok then
        return false, tostring(err)
    end
    return true
end

local function notInitialized()
    return false, {
        code = "DEVICE_NOT_SUPPORTED",
        message = "Thermostat adapter is not initialized",
    }
end

local function sensorRefusal()
    return false, { code = "ACTION_NOT_SUPPORTED", message = "This is a temperature sensor: it has nothing to set" }
end

-- Checks a command without sending anything (Manager.prepare): a sensor refuses everything, a zone
-- with heat and cool setpoints plans its setpoints; everything else is checked by execute, as in
-- 1.0.0.
function Climate.prepare(device, action, params)
    local info = device and tracked[device.id]
    if not info then
        return notInitialized()
    end
    if info.sensor then
        return sensorRefusal()
    end
    if info.source == "dual" and (action == "set_temperature" or action == "set_setpoints") then
        local _, failure = Setpoints.plan(device, info.lastSent, action, params or {})
        if failure then
            return false, failure
        end
    end
    return true
end

function Climate.execute(device, action, params)
    local info = tracked[device.id]
    if not info then
        return notInitialized()
    end
    if info.sensor then
        return sensorRefusal()
    end
    params = params or {}

    if action == "set_hvac_mode" then
        local requested = titleMode(params.value or params.mode)
        if not requested then
            return false, {
                code = "INVALID_HVAC_MODE",
                message = "HVAC mode must be off, heat, cool, or auto",
            }
        end

        local allowed = false
        for _, mode in ipairs(info.hvacModes or {}) do
            if lower(mode) == lower(requested) then allowed = true break end
        end
        if not allowed then
            return false, {
                code = "HVAC_MODE_NOT_SUPPORTED",
                message = "This thermostat does not support " .. requested,
            }
        end

        local ok, err = send(device.id, "SET_MODE_HVAC", { MODE = requested })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = requested }
    end

    -- A zone with heat and cool setpoints that lists its fan speeds takes one of them (1.10.2).
    local listed = listedFans(info)
    if action == "set_fan_mode" and listed then
        local requested = findInList(listed, params.value or params.mode)
        if not requested then
            return false, { code = "ACTION_NOT_SUPPORTED", message = "This thermostat does not support fan speed " .. tostring(params.value or params.mode) }
        end
        local ok, err = send(device.id, "SET_MODE_FAN", { MODE = requested })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = requested }
    end

    if action == "set_fan_mode" then
        if not info.hasFanMode then
            return false, {
                code = "ACTION_NOT_SUPPORTED",
                message = "Fan mode is unavailable on this thermostat",
            }
        end

        local requested = titleFan(params.value or params.mode)
        if not requested then
            return false, {
                code = "INVALID_FAN_MODE",
                message = "Fan mode is invalid",
            }
        end

        local ok, err = send(device.id, "SET_MODE_FAN", { MODE = requested })
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_mode = requested }
    end

    if info.source == "dual" and (action == "set_temperature" or action == "set_setpoints") then
        return Setpoints.execute(device, info.lastSent, action, params, send)
    end

    if action == "set_temperature" then
        local target = tonumber(params.value or params.celsius)
        local minTarget = device.capabilities and device.capabilities.target_temperature_min_c or SINGLE_SETPOINT_MIN_C
        local maxTarget = device.capabilities and device.capabilities.target_temperature_max_c or SINGLE_SETPOINT_MAX_C
        if not target or target < minTarget or target > maxTarget then
            return false, {
                code = "INVALID_TEMPERATURE",
                message = "Temperature is outside this thermostat's DirectorLink range",
            }
        end

        local scale = info.scale
        local ok, err, sentParams
        if info.useHeat then
            -- The heat setpoint goes in the project's scale. In °F it is whole degrees, with the
            -- parameter a real zone lists (#19).
            sentParams = Units.param(Units.toNative(target, scale), scale)
            ok, err = send(device.id, "SET_SETPOINT_HEAT", sentParams)
        elseif scale == "F" then
            -- In a °F project the thermostat works in whole °F (1.10.2, #75): the °F a client chose,
            -- exactly, in the one key that matches the project's scale, as other Control4 clients
            -- send it (the proxy hands its driver the value in every scale).
            sentParams = { FAHRENHEIT = Units.toNative(target, "F") }
            ok, err = send(device.id, "SET_SETPOINT_SINGLE", sentParams)
        else
            sentParams = { CELSIUS = math.floor(target * 10 + 0.5) / 10 }
            ok, err = send(device.id, "SET_SETPOINT_SINGLE", sentParams)
        end
        if not ok then
            return false, { code = "COMMAND_FAILED", message = err }
        end
        return true, { device_id = device.id, action = action, requested_celsius = math.floor(target * 10 + 0.5) / 10, sent = sentParams }
    end

    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Unsupported thermostat action: " .. tostring(action),
    }
end

return Climate
