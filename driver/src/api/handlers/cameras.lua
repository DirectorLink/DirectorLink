local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local CameraClient = require("src.control4.camera")

local Cameras = {}

-- Snapshot widths the API offers; the height asked for is 16:9 (cameras keep their own ratio).
local WIDTHS = { [320] = true, [640] = true, [1280] = true, [1920] = true }
local DEFAULT_WIDTH = 640

local STATUS_BY_ERROR = {
    CAMERA_LOGIN_FAILED = 502,
    CAMERA_UNREACHABLE = 502,
    CAMERA_BUSY = 503,
}

local function findCamera(ctx)
    local id, problem = Validate.id(ctx.params.cameraId, "cameraId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "camera" or device.supported ~= true then
        return nil, Problem.notFound("Camera", id)
    end
    return device
end

function Cameras.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(registry.cameraList()) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.camera(registry, device)
        end
    end
    return 200, { items = items }
end

function Cameras.get(ctx)
    local device, problem = findCamera(ctx)
    if not device then
        return problem
    end
    return 200, Views.camera(ctx.services.registry, device)
end

function Cameras.snapshot(ctx)
    local device, problem = findCamera(ctx)
    if not device then
        return problem
    end
    local width, widthProblem = Validate.optionalInteger(ctx.query.width, "width", 1)
    if widthProblem then
        return widthProblem
    end
    width = width or DEFAULT_WIDTH
    if not WIDTHS[width] then
        return Problem.invalidParameter("width", "width must be one of 320, 640, 1280, 1920")
    end

    local source, reason = CameraClient.source(device.id, width, math.floor(width * 9 / 16), os.time())
    if not source then
        return Problem.new(409, "SNAPSHOT_NOT_AVAILABLE", "No snapshot for this camera: " .. tostring(reason))
    end

    return Response.later(function(respond)
        CameraClient.snapshot(device.id, source, function(result)
            if result.image then
                respond(200, Response.raw(result.image, result.content_type))
                return
            end
            local status = STATUS_BY_ERROR[result.error] or 502
            respond(Problem.new(status, result.error, result.message), status == 503 and { { "Retry-After", "1" } } or nil)
        end)
    end)
end

return Cameras
