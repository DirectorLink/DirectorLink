local Json = require("src.core.json")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local Views = require("src.api.views")
local Activity = require("src.core.activity")
local Access = require("src.auth.access")

local Doorbells = {}

local function findDoorbell(ctx)
    local id, problem = Validate.id(ctx.params.doorbellId, "doorbellId")
    if not id then
        return nil, problem
    end
    -- A DoorBird's doorstation, or a camera that is a doorbell (ADR-065), as a doorbell.
    local device = ctx.services.registry.getDoorbell(id)
    -- A doorbell the caller may not see is, for them, one that does not exist (ADR-054).
    if not device or device.kind ~= "doorbell" or device.supported ~= true or not Access.canSee(ctx.apiKey, device) then
        return nil, Problem.notFound("Doorbell", id)
    end
    return device
end

-- Its picture only for those who may see it (ADR-054: a member with cameras).
local function view(ctx, device)
    local result = Views.doorbell(ctx.services.registry, device)
    if not Access.canSeePictures(ctx.apiKey, device) then
        result.camera = Json.null
    end
    return result
end

function Doorbells.list(ctx)
    local roomId, problem = Validate.optionalInteger(ctx.query.room_id, "room_id", 1)
    if problem then
        return problem
    end
    local registry = ctx.services.registry
    local items = Json.array()
    for _, device in ipairs(Access.filter(ctx.apiKey, registry.doorbellList())) do
        if roomId == nil or tonumber(device.room_id) == roomId then
            items[#items + 1] = view(ctx, device)
        end
    end
    return 200, { items = items }
end

function Doorbells.get(ctx)
    local device, problem = findDoorbell(ctx)
    if not device then
        return problem
    end
    return 200, view(ctx, device)
end

-- Opens the gate or door wired to the DoorBird, like its button in the Control4 app.
function Doorbells.open(ctx)
    local device, problem = findDoorbell(ctx)
    if not device then
        return problem
    end
    -- One that opens nothing (a doorbell camera, a DoorBird without its button) says so first,
    -- whatever Door Control and the caller's doors: no setting would let it open.
    if not (device.capabilities and device.capabilities.open == true) then
        return Problem.fromAdapter({
            code = "ACTION_NOT_SUPPORTED",
            message = device.camera_doorbell and "This doorbell has nothing to open" or "This DoorBird has no button to open with",
        })
    end
    if not Access.canOpen(ctx.apiKey, device) then
        return Problem.new(403, "FORBIDDEN", "Opening doors and gates is not among this person's permissions")
    end
    if not ctx.services.doorControlEnabled() then
        return Problem.new(403, "DOOR_CONTROL_DISABLED",
            "Door control is off; turn on the Door Control property of DirectorLink in Composer")
    end
    local ok, failure = ctx.services.adapters.execute(device.id, "open")
    if not ok then
        return Problem.fromAdapter(failure)
    end
    ctx.services.log.info("doorbell_command", "open requested", {
        device_id = device.id,
        key_id = ctx.apiKey and ctx.apiKey.id or Json.null,
        client = ctx.client and ctx.client.ip or Json.null,
    })
    Activity.record("door", "doorbell", { by = ctx.apiKey, what = device.name, room = device.room_name, ids = { device_id = device.id, room_id = device.room_id } })
    return 202, view(ctx, device)
end

return Doorbells
