-- The home's camera order (1.12.1, docs/PREFERENCES.md), one for everyone, set by an admin
-- (PUT /v1/cameras/order), as the room order is (room_layout.lua). GET /v1/cameras answers in it,
-- and GET /v1/doorbells too, each doorbell at its camera's place: a DoorBird's doorstation at its
-- camera's, a doorbell camera (ADR-065) at its own. Cameras not in the order (new ones) follow, by
-- name; one no longer in the project is passed over.

local SavedOrder = require("src.core.saved_order")

local CameraLayout = SavedOrder.new("directorlink_camera_order", "cameras", "camera order")
CameraLayout.MAX_CAMERAS = 1000

-- The id a doorbell has in the camera order: its camera's (a DoorBird's linked camera), or its own.
local function doorbellCamera(doorbell)
    return doorbell.linked and tonumber(doorbell.linked.camera) or doorbell.id
end

-- `doorbells` (as Registry.doorbellList gives them) in the camera order.
function CameraLayout.sortDoorbells(doorbells)
    return CameraLayout.sort(doorbells, doorbellCamera)
end

return CameraLayout
