local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Version = require("src.core.version")
local Problem = require("src.api.problem")

local System = {}

local function text(value)
    if value == nil or tostring(value) == "" then
        return Json.null
    end
    return tostring(value)
end

local function number(value)
    local parsed = tonumber(value)
    if parsed == nil then
        return Json.null
    end
    return parsed
end

function System.health(ctx)
    local status = ctx.services.status()
    return 200, {
        status = status.state,
        version = Version.BRIDGE_VERSION,
        api_version = Version.API_VERSION,
        detail = text(status.detail),
    }
end

-- The document is generated from api/openapi.yaml by scripts/build.py.
function System.openapi(_ctx)
    local ok, document = pcall(require, "src.api.openapi_spec")
    if not ok or type(document) ~= "string" then
        return Problem.new(503, "UNAVAILABLE", "This driver build does not include the API description")
    end
    return 200, document
end

function System.info(ctx)
    local services = ctx.services
    local registry = services.registry
    local metadata = registry.metadata or {}
    local properties = metadata.properties or {}
    local counts = registry.counts()
    local status = services.status()
    local lifecycle = services.lifecycle()

    return 200, {
        bridge = {
            version = Version.BRIDGE_VERSION,
            api_version = Version.API_VERSION,
            status = status.state,
            detail = text(status.detail),
            started_at = Clock.iso(services.startedAt),
        },
        controller = {
            platform = "control4",
            os_version = text(services.controllerVersion),
            model = text(metadata.systemType),
        },
        location = {
            city = text(properties.CityName),
            country_code = text(properties.CountryCode),
            country = text(properties.CountryName),
            latitude = number(properties.Latitude),
            longitude = number(properties.Longitude),
            timezone = text(metadata.timezone),
        },
        inventory = {
            rooms = counts.rooms,
            devices = counts.devices,
            supported_devices = counts.supported,
            lights = counts.supported_lights,
            thermostats = counts.supported_climate,
            blinds = counts.supported_blinds,
            cameras = counts.supported_cameras,
        },
        lifecycle = {
            reload_count = tonumber(lifecycle.reload_count) or 0,
            last_init_type = text(lifecycle.last_init_type),
            last_init_time = text(lifecycle.last_init_time),
            last_destroy_type = text(lifecycle.last_destroy_type),
            last_destroy_time = text(lifecycle.last_destroy_time),
        },
    }
end

return System
