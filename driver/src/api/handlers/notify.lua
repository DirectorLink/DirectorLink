-- The home's screens of DirectorLink's notification agreement (1.13.0, ADR-086,
-- docs/NOTIFY_DRIVERS.md, src/core/notify.lua): the list Settings → Alerts shows its admins, and a
-- notification's picture, which the screen's driver fetches without a key.

local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Response = require("src.api.response")
local CameraClient = require("src.control4.camera")
local Notify = require("src.core.notify")
local NotifyTargets = require("src.control4.notify_targets")

local Handlers = {}

local STATUS_BY_ERROR = {
    CAMERA_LOGIN_FAILED = 502,
    CAMERA_UNREACHABLE = 502,
    CAMERA_BUSY = 503,
}

-- GET /v1/alerts/screens (admins): the screens told of the home's alerts, by name, each with its
-- room and the kinds it shows, and the language they are told in. Admins only: a screen shows the
-- home's alerts to whoever is in its room, whatever a member may see (doors opened and schedules
-- are the admins' on a phone), and Composer sets it up, not the app.
function Handlers.screens(ctx)
    local list, language = Notify.screens()
    local items = Json.array()
    for _, screen in ipairs(list) do
        local roomId = tonumber(screen.room_id)
        local room = roomId and (ctx.services.registry.rooms or {})[roomId]
        items[#items + 1] = {
            id = screen.id,
            name = tostring(screen.name or ("Device " .. tostring(screen.id))),
            room_id = roomId or Json.null,
            room = (room and room.name) or screen.room_name or Json.null,
            kinds = Json.array(NotifyTargets.kindList(screen.kinds)),
        }
    end
    return 200, { items = items, language = language }
end

-- GET /v1/notify-pictures/{picture} (no key): a notification's picture, "<token>.jpg", for
-- Notify.PICTURE_SECONDS after the alert and at most Notify.PICTURE_USES times; then, and for any
-- other name, 404. The camera's picture now, fetched as GET /v1/cameras/{id}/snapshot fetches it.
function Handlers.picture(ctx)
    local cameraId = Notify.takePicture(ctx.params.picture)
    local device = cameraId and ctx.services.registry.getDevice(cameraId)
    if not device or device.kind ~= "camera" or device.supported ~= true then
        return Problem.new(404, "NOT_FOUND", "No such picture")
    end
    local width = Notify.PICTURE_WIDTH
    local source = CameraClient.source(device.id, width, math.floor(width * 9 / 16), os.time())
    if not source then
        return Problem.new(404, "NOT_FOUND", "No such picture")
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

return Handlers
