-- The home's camera order (1.12.1, src/core/camera_layout.lua, PUT /v1/cameras/order), as the room
-- order: one for everyone, set by admins; GET /v1/cameras (a room's cameras too) answers in it, and
-- GET /v1/doorbells puts each doorbell at its camera's place; cameras not in it (new ones) follow,
-- by name, and one no longer in the project is passed over; kept across an update and a restart,
-- and in backups, matched to the project as favorites are.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")

local tests = {}

-- Mock.project()'s cameras 60 "Driveway" (Kitchen), 61 "Gate" (Living Room) and 92 "Gate Camera"
-- (Kitchen: the camera of the DoorBird 93 "Front Gate"), and with Mock.withAgreementCameras 67
-- "Porch" (Living Room) and the doorbell camera 68 "Entrance" (Kitchen).
local DRIVEWAY, GATE, GATE_CAMERA, PORCH, ENTRANCE = 60, 61, 92, 67, 68
local FRONT_GATE = 93
local KITCHEN, LIVING_ROOM = 10, 11

local function project()
    return Mock.withAgreementCameras(Mock.project())
end

local function start(theProject)
    local mock = Mock.startDriver(theProject or project())
    return mock, T.pair(mock, "Owner's iPhone")
end

-- The ids GET `path` lists, in its order.
local function ids(mock, key, path)
    local answer = T.http(mock, "GET", path or "/v1/cameras", { key = key })
    T.eq(answer.status, 200, answer.body)
    local list = {}
    for _, item in ipairs(answer.json.items) do
        list[#list + 1] = item.id
    end
    return list
end

local function order(mock, key, list)
    return T.http(mock, "PUT", "/v1/cameras/order", { key = key, body = { camera_ids = list } })
end

local function member(mock, admin, name, access)
    local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name, role = "member", access = access } })
    T.eq(created.status, 201, created.body)
    return created.json.key
end

local function stored(mock)
    local value = mock.persist.directorlink_camera_order
    return type(value) == "string" and Json.decode(value:gsub("^json:", "")) or nil
end

function tests.cameras_are_listed_by_name_until_an_admin_orders_them_for_everyone()
    local mock, admin = start()
    T.same(ids(mock, admin), { DRIVEWAY, ENTRANCE, GATE, GATE_CAMERA, PORCH }, "by name")
    T.same(ids(mock, admin, "/v1/doorbells"), { ENTRANCE, FRONT_GATE }, "by name")
    T.eq(T.http(mock, "GET", "/v1/system", { key = admin }).json.features.camera_order, true)

    local put = order(mock, admin, { PORCH, GATE_CAMERA, DRIVEWAY })
    T.eq(put.status, 200, put.body)
    local answered = {}
    for _, item in ipairs(put.json.items) do
        answered[#answered + 1] = item.id
    end
    T.same(answered, { PORCH, GATE_CAMERA, DRIVEWAY, ENTRANCE, GATE }, "the cameras in the new order: the ordered ones, then the rest by name")
    T.eq(put.json.items[1].name, "Porch", "as GET /v1/cameras lists them")
    T.same(ids(mock, admin), { PORCH, GATE_CAMERA, DRIVEWAY, ENTRANCE, GATE })
    T.same(ids(mock, admin, "/v1/cameras?room_id=" .. KITCHEN), { GATE_CAMERA, DRIVEWAY, ENTRANCE }, "a room's cameras in the same order")
    T.same(ids(mock, admin, "/v1/cameras?room_id=" .. LIVING_ROOM), { PORCH, GATE })
    T.same(ids(mock, admin, "/v1/doorbells"), { FRONT_GATE, ENTRANCE }, "the DoorBird at its camera's place, the doorbell camera at its own")
    T.same(ids(mock, admin, "/v1/doorbells?room_id=" .. KITCHEN), { FRONT_GATE, ENTRANCE })
    T.same(stored(mock), { version = 1, order = { PORCH, GATE_CAMERA, DRIVEWAY } })

    -- A member sees the cameras they may see in the home's order, and cannot change it.
    local dana = member(mock, admin, "Dana's phone", { all_rooms = true, cameras = true })
    T.same(ids(mock, dana), { PORCH, GATE_CAMERA, DRIVEWAY, ENTRANCE, GATE })
    local kitchenOnly = member(mock, admin, "Kitchen tablet", { all_rooms = false, rooms = { KITCHEN }, cameras = true })
    T.same(ids(mock, kitchenOnly), { GATE_CAMERA, DRIVEWAY, ENTRANCE })
    local refused = order(mock, dana, { GATE, PORCH })
    T.eq(refused.status, 403)
    T.eq(refused.json.code, "FORBIDDEN")
    T.same(ids(mock, admin), { PORCH, GATE_CAMERA, DRIVEWAY, ENTRANCE, GATE }, "unchanged")

    -- An empty order: by name again.
    T.eq(order(mock, admin, {}).status, 200)
    T.same(ids(mock, admin), { DRIVEWAY, ENTRANCE, GATE, GATE_CAMERA, PORCH })
end

function tests.the_order_is_checked_as_the_room_order_is()
    local mock, admin = start()
    T.eq(order(mock, admin, { PORCH, GATE }).status, 200)
    local function refused(body, what)
        local answer = T.http(mock, "PUT", "/v1/cameras/order", { key = admin, body = body })
        T.eq(answer.status, 400, what .. ": " .. answer.body)
        return answer.json
    end
    T.eq(refused({ camera_ids = { 999 } }, "no such device").code, "INVALID_FIELD")
    T.eq(refused({ camera_ids = { 20 } }, "a light").detail, "Unknown camera: 20")
    refused({ camera_ids = { FRONT_GATE } }, "a DoorBird is ordered by its camera")
    T.eq(refused({ camera_ids = { DRIVEWAY, GATE, DRIVEWAY } }, "twice").detail, "Camera 60 is listed twice")
    refused({ camera_ids = { 60.5 } }, "not a whole number")
    refused({ camera_ids = { "60" } }, "not a number")
    refused({ camera_ids = "60" }, "not a list")
    refused({ camera_ids = { first = 60 } }, "an object")
    refused({ cameras = { 60 } }, "another field")
    refused({}, "nothing")
    local long = {}
    for index = 1, 1001 do
        long[index] = index
    end
    refused({ camera_ids = long }, "more than 1000")
    T.same(ids(mock, admin), { PORCH, GATE, DRIVEWAY, ENTRANCE, GATE_CAMERA }, "nothing refused changed it")
end

function tests.the_order_is_kept_across_an_update_and_a_restart()
    local mock, admin = start()
    T.eq(order(mock, admin, { PORCH, GATE }).status, 200)
    local updated = Mock.updateDriver(mock, project())
    T.same(ids(updated, admin), { PORCH, GATE, DRIVEWAY, ENTRANCE, GATE_CAMERA }, "after an update")
    -- The controller restarts: the driver starts again with what Director kept.
    local restarted = Mock.startDriver(project(), nil, "DIT_STARTUP", function(m)
        for name, value in pairs(updated.persist) do
            m.persist[name] = value
        end
    end)
    T.same(ids(restarted, admin), { PORCH, GATE, DRIVEWAY, ENTRANCE, GATE_CAMERA }, "after a restart")
    T.same(ids(restarted, admin, "/v1/doorbells"), { ENTRANCE, FRONT_GATE })
end

function tests.new_cameras_come_last_and_a_camera_gone_is_passed_over()
    -- The home before the agreement cameras were added: three cameras, ordered.
    local mock, admin = start(Mock.project())
    T.eq(order(mock, admin, { GATE_CAMERA, GATE, DRIVEWAY }).status, 200)
    T.same(ids(mock, admin), { GATE_CAMERA, GATE, DRIVEWAY })
    -- Porch and Entrance added in Composer, Gate removed.
    local changed = project()
    Mock.removeDevice(changed, GATE)
    local updated = Mock.updateDriver(mock, changed)
    T.same(ids(updated, admin), { GATE_CAMERA, DRIVEWAY, ENTRANCE, PORCH }, "the new ones after the ordered ones, by name; Gate gone")
    T.same(ids(updated, admin, "/v1/doorbells"), { FRONT_GATE, ENTRANCE })
    local gone = order(updated, admin, { GATE, DRIVEWAY })
    T.eq(gone.status, 400, "a camera no longer in the project cannot be ordered")
    T.eq(gone.json.detail, "Unknown camera: 61")
    -- Gate comes back with its id: at its place again, as a room does.
    local back = Mock.updateDriver(updated, project())
    T.same(ids(back, admin), { GATE_CAMERA, GATE, DRIVEWAY, ENTRANCE, PORCH })
end

-- ---- backups --------------------------------------------------------------------------------------

-- A request as it runs once opened from a sealed one (as tests/test_backup.lua's `opened`).
local function sealedAs(mock, key, method, path, body)
    local keyId = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json.id
    local status, _, text = require("src.api.server").handleRequest({
        method = method,
        path = path,
        query = {},
        headers = body and { ["content-type"] = "application/json" } or {},
        body = body and Json.encode(body) or "",
        principal = { id = keyId, name = "Owner's iPhone", role = "admin", sealed = true },
    }, { ip = "192.168.1.50", port = "0" })
    return { status = status, json = Json.decode(text), body = text }
end

-- Checks the backup `document`, then restores it; returns the check's preview.
local function restoreInto(mock, key, document)
    local part = sealedAs(mock, key, "POST", "/v1/restore/parts", { index = 0, count = 1, text = Json.encode(document) })
    T.eq(part.status, 200, part.body)
    local check = sealedAs(mock, key, "POST", "/v1/restore", { upload = part.json.upload })
    T.eq(check.status, 200, check.body)
    local done = sealedAs(mock, key, "POST", "/v1/restore", { upload = part.json.upload, dry_run = false })
    T.eq(done.status, 200, done.body)
    return check.json.restore
end

function tests.a_backup_brings_the_order_back_matched_to_the_project()
    local mock, admin = start()
    T.eq(order(mock, admin, { PORCH, GATE_CAMERA, DRIVEWAY }).status, 200)
    local document = sealedAs(mock, admin, "GET", "/v1/backup").json
    T.same(document.sections.camera_order, { version = 1, order = { PORCH, GATE_CAMERA, DRIVEWAY } })
    T.eq(document.references.devices[tostring(PORCH)].name, "Porch", "with the cameras' names, to match them")
    T.eq(document.references.devices[tostring(PORCH)].kind, "camera")

    -- Another controller, its project rebuilt: Driveway removed, Porch and Gate Camera swapped ids.
    local rebuilt = project()
    Mock.removeDevice(rebuilt, DRIVEWAY)
    Mock.renameDevice(rebuilt, PORCH, "Gate Camera")
    Mock.renameDevice(rebuilt, GATE_CAMERA, "Porch")
    Mock.moveDevice(rebuilt, PORCH, KITCHEN)
    Mock.moveDevice(rebuilt, GATE_CAMERA, LIVING_ROOM)
    local fresh, freshKey = start(rebuilt)
    T.same(ids(fresh, freshKey), { ENTRANCE, GATE, PORCH, GATE_CAMERA }, "by name before the restore")
    local preview = restoreInto(fresh, freshKey, document)
    T.eq(preview.counts.camera_order, 2, "Porch and Gate Camera; Driveway is not in this project")
    local gone
    for _, entry in ipairs(preview.references.unmatched) do
        if entry.id == DRIVEWAY then
            gone = entry
        end
    end
    T.eq(gone.kind, "camera")
    T.eq(gone.name, "Driveway")
    T.same(gone.used_in, { { section = "camera_order", name = Json.null } })
    -- Porch is 92 now and Gate Camera 67: each found by its name in its room.
    T.same(ids(fresh, freshKey), { GATE_CAMERA, PORCH, ENTRANCE, GATE }, "Porch (92), Gate Camera (67), then the rest by name")
    T.same(stored(fresh), { version = 1, order = { GATE_CAMERA, PORCH } })

    -- A backup made before 1.12.1 has no camera order: the order here stays.
    T.eq(order(fresh, freshKey, { GATE }).status, 200)
    document.sections.camera_order = nil
    document.driver_version = "1.12.0"
    preview = restoreInto(fresh, freshKey, document)
    T.eq(preview.counts.camera_order, Json.null)
    T.eq(ids(fresh, freshKey)[1], GATE, "not written")
    T.same(stored(fresh), { version = 1, order = { GATE } })
end

function tests.a_failed_write_of_the_camera_order_puts_every_store_back()
    local mock, admin = start()
    T.eq(order(mock, admin, { PORCH }).status, 200)
    local document = sealedAs(mock, admin, "GET", "/v1/backup").json
    local fresh, freshKey = start()
    T.eq(order(fresh, freshKey, { GATE }).status, 200)
    T.eq(T.http(fresh, "PUT", "/v1/rooms/order", { key = freshKey, body = { room_ids = { LIVING_ROOM, KITCHEN } } }).status, 200)
    local write = C4.PersistSetValue
    C4.PersistSetValue = function(self, name, value, encrypted)
        if name == "directorlink_camera_order" then
            error("storage full")
        end
        return write(self, name, value, encrypted)
    end
    local failed = sealedAs(fresh, freshKey, "POST", "/v1/restore", { document = document, dry_run = false })
    C4.PersistSetValue = write
    T.eq(failed.status, 500)
    T.eq(failed.json.store, "camera_order")
    T.eq(ids(fresh, freshKey)[1], GATE, "the camera order from before")
    T.eq(ids(fresh, freshKey, "/v1/rooms")[1], LIVING_ROOM, "and the room order")
end

return tests
