-- The home's room order (docs/PREFERENCES.md), one for everyone, set by an admin
-- (PUT /v1/rooms/order). Control4 has its own order; this is DirectorLink's. Rooms not in the order
-- keep Control4's order, after the ordered ones. Hiding a room is personal: each profile's
-- `hidden_rooms` (profiles.lua). The cameras have an order of their own (camera_layout.lua).

local SavedOrder = require("src.core.saved_order")

local RoomLayout = SavedOrder.new("directorlink_room_layout", "rooms", "room order")
RoomLayout.MAX_ROOMS = 1000

return RoomLayout
