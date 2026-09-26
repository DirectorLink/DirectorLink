local Classifier = {}

local function normalizedDriverName(value)
    return string.lower(tostring(value or ""))
end

function Classifier.classify(driverFileName)
    local name = normalizedDriverName(driverFileName)

    if name == "light_v2.c4i" or name == "light_v2.c4z" then
        return { kind = "light", recognized = true }
    end

    if name == "thermostatv2.c4i" or name == "thermostatv2.c4z" then
        return { kind = "climate", recognized = true }
    end

    if name == "blind.c4i" or name == "blind.c4z" then
        return { kind = "blind", recognized = true }
    end

    if name == "camera.c4i" or name == "camera.c4z" then
        return { kind = "camera", recognized = true }
    end

    if name == "knx_contact_relay.c4z" then
        return { kind = "relay", recognized = true }
    end

    return { kind = "unsupported", recognized = false }
end

return Classifier
