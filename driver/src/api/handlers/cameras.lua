local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local CameraClient = require("src.control4.camera")
local CameraLayout = require("src.core.camera_layout")
local Access = require("src.auth.access")

local Cameras = {}

-- Snapshot widths the API offers; the height asked for is 16:9 (cameras keep their own ratio).
local WIDTHS = { [320] = true, [640] = true, [1280] = true, [1920] = true }
local DEFAULT_WIDTH = 640

local STATUS_BY_ERROR = {
    CAMERA_LOGIN_FAILED = 502,
    CAMERA_UNREACHABLE = 502,
    CAMERA_BUSY = 503,
}

-- Whether the caller may see a doorbell's picture whose camera this is (a member with cameras
-- sees the picture of a doorbell in their rooms, wherever its camera is placed).
local function atTheirDoorbell(ctx, camera)
    for _, doorbell in ipairs(ctx.services.registry.doorbellList()) do
        if doorbell.linked and tonumber(doorbell.linked.camera) == tonumber(camera.id) and Access.canSeePictures(ctx.apiKey, doorbell) then
            return true
        end
    end
    return false
end

-- A camera the caller may not see is, for them, one that does not exist (ADR-054).
local function findCamera(ctx)
    local id, problem = Validate.id(ctx.params.cameraId, "cameraId")
    if not id then
        return nil, problem
    end
    local device = ctx.services.registry.getDevice(id)
    if not device or device.kind ~= "camera" or device.supported ~= true
        or not (Access.canSeePictures(ctx.apiKey, device) or atTheirDoorbell(ctx, device)) then
        return nil, Problem.notFound("Camera", id)
    end
    return device
end

-- The cameras the caller sees, in the home's order (PUT /v1/cameras/order; 1.12.1), those of
-- `roomId` only when given.
local function listed(ctx, roomId)
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(CameraLayout.sort(Access.filter(ctx.apiKey, registry.cameraList()))) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = Views.camera(registry, device)
        end
    end
    return 200, { items = items }
end

function Cameras.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    return listed(ctx, roomId)
end

-- PUT {"camera_ids": [67, 60, 68]}: the home's camera order, for everyone (admins, 1.12.1), as the
-- room order (rooms.lua). Cameras left out follow, by name. Doorbells follow their cameras.
function Cameras.order(ctx)
    local body = ctx.body
    local problem = Validate.body(body, { camera_ids = true }, true)
    if problem then
        return problem
    end
    local ids = body.camera_ids
    if type(ids) ~= "table" or ids == Json.null or (not Json.isArray(ids) and next(ids) ~= nil) or #ids > CameraLayout.MAX_CAMERAS then
        return Problem.invalidField("camera_ids", "camera_ids must be a list of camera ids")
    end
    local registry = ctx.services.registry
    local seen, order = {}, {}
    for _, id in ipairs(ids) do
        local device = type(id) == "number" and id == math.floor(id) and registry.getDevice(id) or nil
        if not device or device.kind ~= "camera" or device.supported ~= true then
            return Problem.invalidField("camera_ids", "Unknown camera: " .. tostring(id))
        end
        if seen[id] then
            return Problem.invalidField("camera_ids", "Camera " .. id .. " is listed twice")
        end
        seen[id] = true
        order[#order + 1] = id
    end
    if not CameraLayout.setOrder(order) then
        return Problem.internal("The camera order could not be saved")
    end
    ctx.services.log.info("cameras", "camera order changed", { cameras = #order, by = ctx.apiKey.id })
    return listed(ctx, nil)
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
