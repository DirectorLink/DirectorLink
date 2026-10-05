-- DirectorLink's camera agreement (1.10.0, ADR-065, docs/CAMERA_DRIVERS.md, src/control4/camera_drivers.lua):
-- a camera driver of DirectorLink Drivers says so with DIRECTORLINK_CAMERA ("1") and
-- DIRECTORLINK_CAMERA_KIND ("camera" or "doorbell"); a detection is LAST_ALERT and its event named
-- Alert, a doorbell press LAST_RING and its event named Ring. DirectorLink finds them by name, sets a
-- camera up again when its marker comes later or its driver is updated, makes a doorbell camera a
-- doorbell (listed, ringing, its ring alert), and keeps knowing the DirectorLink · Hikvision drivers
-- by their file name until they set the marker, never handling one twice.
-- The fake agreement drivers are Mock.withAgreementCameras: 67 "Porch" (a camera, Living Room, driver
-- 157) and 68 "Entrance" (a doorbell, Kitchen, driver 158); their Alert is event 7, Ring 8.

local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Mock = require("c4mock")
local Harness = require("relay_harness")

local tests = {}

local function count(map)
    local total = 0
    for _ in pairs(map or {}) do
        total = total + 1
    end
    return total
end

local function hmacHex(key, data)
    return C4:HMAC("SHA256", key, data, { key_encoding = "HEX", data_encoding = "NONE", return_encoding = "HEX" }):lower()
end

-- Opens `sealed` as the device of `apiKey` does (its service worker).
local function open(apiKey, keyId, sealed)
    local alertKey = require("src.cloud.alerts").alertKey(require("src.cloud.lock").deviceKey(apiKey))
    local enc = hmacHex(alertKey, "enc")
    local plaintext = C4:Decrypt("AES-256-CBC", enc, Base64.toHex(Base64.decode(sealed.iv)), Base64.toHex(Base64.decode(sealed.ct)), {
        key_encoding = "HEX",
        iv_encoding = "HEX",
        data_encoding = "HEX",
        return_encoding = "NONE",
        padding = true,
    })
    T.truthy(keyId, "a key id")
    return Json.decode(plaintext)
end

-- A connected driver with the clock in the test's hands (as test_alerts.lua): { mock, connection,
-- clock, admin, adminId, keys = { name -> { key, id } }, add(name, role, access), on(name, kinds),
-- notified() }.
local function home(project, setup)
    local mock = Mock.startDriver(project, nil, nil, setup)
    local _, connection = Harness.connected({ mock = mock })
    local Clock = require("src.core.clock")
    local clock = { now = os.time() }
    Clock.now = function()
        return clock.now
    end
    local admin = T.pair(mock, "Chrome on Windows")
    local adminId = T.http(mock, "GET", "/v1/api-keys/current", { key = admin }).json.id
    local state = { mock = mock, connection = connection, clock = clock, admin = admin, adminId = adminId, keys = {} }
    state.keys.admin = { key = admin, id = adminId }
    function state.add(name, role, access)
        local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name, role = role, access = access } })
        T.eq(created.status, 201, created.body)
        state.keys[name] = { key = created.json.key, id = created.json.id }
        return created.json.key, created.json.id
    end
    function state.on(name, kinds)
        local answer = T.http(mock, "PUT", "/v1/alerts/choices", { key = state.keys[name].key, body = { on = true, kinds = kinds } })
        T.eq(answer.status, 200, answer.body)
        return answer.json
    end
    function state.notified()
        local found = {}
        for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
            local message = Json.decode(frame.payload)
            if type(message) == "table" and message.type == "notify" then
                found[#found + 1] = { text = frame.payload, message = message }
            end
        end
        connection.sent = ""
        return found
    end
    -- The detail sealed for `name` in the only notify sent since the last look.
    function state.detail(name)
        local notified = state.notified()
        T.eq(#notified, 1, "one message")
        local key = state.keys[name]
        local sealed = notified[1].message["for"][key.id]
        return sealed and open(key.key, key.id, sealed) or nil, notified[1].message
    end
    state.notified()
    return state
end

local function get(mock, key, path)
    local answer = T.http(mock, "GET", path, { key = key })
    T.eq(answer.status, 200, answer.body)
    return answer.json
end

local function ids(items)
    local list = {}
    for _, item in ipairs(items or {}) do
        list[#list + 1] = item.id
    end
    table.sort(list)
    return list
end

-- How many times DirectorLink registered for `driver`'s event `event`.
local function registrations(mock, driver, event)
    local total = 0
    for _, watched in ipairs(mock.deviceEvents) do
        if watched[1] == driver and (event == nil or watched[2] == event) then
            total = total + 1
        end
    end
    return total
end

local function logged(mock, text)
    local total = 0
    for _, line in ipairs(mock.debugLog) do
        if line:find(text, 1, true) then
            total = total + 1
        end
    end
    return total
end

local function minutes(n)
    local Scheduler = require("src.core.scheduler")
    for _ = 1, n or 1 do
        Scheduler.tick()
    end
end

-- ---- reading the agreement ------------------------------------------------------------------------

function tests.labels_times_and_events_are_read_as_drivers_write_them()
    Mock.startDriver()
    local Camera = require("src.adapters.camera")
    for label, what in pairs({
        ["Person"] = "person", ["Vehicle"] = "vehicle", ["Animal"] = "animal", ["Package"] = "package",
        ["Face"] = "face", ["License Plate"] = "license_plate", ["license_plate"] = "license_plate",
        ["LICENCE-PLATE"] = "license_plate", ["Line Crossing"] = "line_crossing", ["Intrusion"] = "intrusion",
        ["Motion"] = "motion", [" package "] = "package", ["Object Left"] = "object_left", ["PIR"] = "pir",
        ["Region  Entrance"] = "region_entrance", ["Smoke"] = "other", [""] = "other",
    }) do
        T.eq(Camera.detection(label), what, label)
    end
    T.eq(Camera.detection(nil), "other")

    local Clock = require("src.core.clock")
    T.eq(Clock.parseIso("1970-01-01T00:00:00Z"), 0)
    T.eq(Clock.parseIso("2026-10-05T18:14:03Z"), 1791224043)
    T.eq(Clock.parseIso("2026-10-05T18:14:03.250Z"), 1791224043, "a fraction of a second")
    T.eq(Clock.parseIso("2026-10-05T21:14:03+03:00"), 1791224043, "an offset")
    T.eq(Clock.parseIso("2026-10-05T13:14:03-0500"), 1791224043)
    T.eq(Clock.parseIso("2024-02-29T12:00:00Z"), 1709208000, "a leap day")
    T.eq(Clock.iso(Clock.parseIso("2026-10-05T18:14:03Z")), "2026-10-05T18:14:03Z")
    for _, bad in ipairs({ "2026-10-05T18:14:03", "2026-10-05", "2026-13-05T18:14:03Z", "yesterday", "", 1791224043 }) do
        T.eq(Clock.parseIso(bad), nil, tostring(bad))
    end

    local CameraDrivers = require("src.control4.camera_drivers")
    local xml = Mock.eventsXml({ { 7, "Alert" }, { 8, "Ring" }, { 9, "Alert Ended" } })
    T.same(CameraDrivers.parseEvents(xml), { Alert = 7, ["Alert Ended"] = 9, Ring = 8 })
    T.same(CameraDrivers.parseEvents("<events>" .. xml .. "</events>"), { Alert = 7, ["Alert Ended"] = 9, Ring = 8 }, "the tag whole")
    T.same(CameraDrivers.parseEvents((xml:gsub("<", "&lt;"):gsub(">", "&gt;"))), { Alert = 7, ["Alert Ended"] = 9, Ring = 8 }, "as escaped text")
    T.same(CameraDrivers.parseEvents("<event><id> 3 </id><name> Ring </name></event>"), { Ring = 3 })
    T.same(CameraDrivers.parseEvents("<event/><event/>"), {}, "no ids: nothing")
    T.same(CameraDrivers.parseEvents(nil), {})
    -- The marker: a whole number from 1 (a later version read as this one); the kind, else a camera.
    local function marker(version, kind)
        return CameraDrivers.marker({ DIRECTORLINK_CAMERA = version and { value = version } or nil, DIRECTORLINK_CAMERA_KIND = kind and { value = kind } or nil })
    end
    T.same({ marker("1", "doorbell") }, { 1, "doorbell" })
    T.same({ marker(" 1 ", " Doorbell ") }, { 1, "doorbell" })
    T.same({ marker("2", nil) }, { 2, "camera" })
    T.same({ marker("1", "nvr") }, { 1, "camera" })
    for _, bad in ipairs({ "0", "", "yes", "1.5", "-1" }) do
        T.eq(marker(bad, "doorbell"), nil, bad)
    end
    T.eq(marker(nil, "doorbell"), nil)
end

-- ---- cameras ------------------------------------------------------------------------------------

-- An agreement camera's Alert, found by its name (event 7 here), goes sealed as the Hikvision
-- drivers' does, with the new labels; its other events are not alerts.
function tests.an_agreement_camera_alerts_by_its_event_named_alert()
    local home = home(Mock.withAgreementCameras(Mock.project()))
    local mock = home.mock
    T.eq(get(mock, home.admin, "/v1/system").features.camera_alerts, true)
    T.eq(get(mock, home.admin, "/v1/alerts/choices").kinds.camera, false, "offered, off until chosen")
    T.eq(registrations(mock, 157, 7), 1, "its Alert, by name")
    T.eq(registrations(mock, 157), 1, "nothing else of it")
    T.eq(registrations(mock, 157, 1), 0, "not event 1: that is its Camera Online")
    home.on("admin", { camera = true })
    home.notified()

    for _, case in ipairs({ { "Animal", "animal" }, { "Package", "package" }, { "License Plate", "license_plate" }, { "Person", "person" } }) do
        home.clock.now = home.clock.now + 61
        T.eq(Mock.cameraAlert(mock, 157, case[1]), 1, case[1])
        local detail, message = home.detail("admin")
        T.same(detail, { at = message.at, id = 67, kind = "camera", name = "Porch", room = "Living Room", room_id = 11, what = case[2], v = 1 }, case[1])
        T.eq(message.brief, nil)
    end
    home.clock.now = home.clock.now + 61
    T.eq(Mock.fireDeviceEvent(mock, 157, 1), 0, "Camera Online is not watched")
    T.eq(#home.notified(), 0)
    -- Pictures as for any camera.
    T.same(ids(get(mock, home.admin, "/v1/cameras").items), { 60, 61, 67, 68, 92 })
    local picture = T.http(mock, "GET", "/v1/cameras/67/snapshot?width=320", { key = home.admin })
    T.eq(picture.status, 200, picture.body)
    T.eq(picture.headers["content-type"], "image/jpeg")
end

-- ---- doorbells -----------------------------------------------------------------------------------

-- A doorbell camera is a doorbell: listed with the doorbells, its picture its own; its Ring is a ring
-- (last_ring_at from LAST_RING, its rings kept as a DoorBird's), the sealed ring alert to those who
-- see it, at most one in 30 s; its Alert is still a camera alert; it opens nothing.
function tests.a_doorbell_camera_is_a_doorbell_that_rings()
    local home = home(Mock.withAgreementCameras(Mock.project()), function()
        Properties["Door Control"] = "Enabled"
    end)
    local mock = home.mock
    local doorbells = get(mock, home.admin, "/v1/doorbells").items
    T.same(ids(doorbells), { 68, 93 }, "the DoorBird and the doorbell camera; not the camera Porch")
    local entrance = get(mock, home.admin, "/v1/doorbells/68")
    T.eq(entrance.name, "Entrance")
    T.eq(entrance.room.id, 10)
    T.same(entrance.camera, { id = 68, snapshot_href = "/v1/cameras/68/snapshot" }, "its picture its own")
    T.eq(entrance.can_open, false)
    for _, field in ipairs({ "connected", "last_ring_at", "last_motion_at", "last_opened_at", "last_access_at" }) do
        T.eq(entrance[field], Json.null, field)
    end
    T.eq(#entrance.events, 0)
    T.truthy(get(mock, home.admin, "/v1/cameras/68").id == 68, "a camera too")
    local inventory = get(mock, home.admin, "/v1/system").inventory
    T.eq(inventory.doorbells, 2)
    T.eq(inventory.cameras, 5)
    T.eq(registrations(mock, 158, 8), 1, "its Ring, by name")
    T.eq(registrations(mock, 158, 7), 1, "and its Alert")
    local refused = T.http(mock, "POST", "/v1/doorbells/68/open", { key = home.admin })
    T.eq(refused.status, 409, refused.body)
    T.eq(refused.json.code, "NOT_SUPPORTED")
    T.contains(refused.body, "nothing to open")

    home.add("Hall tablet", "member")
    home.on("admin", { camera = true })
    home.on("Hall tablet")
    home.notified()

    -- The driver's own time of the ring (a second ago).
    home.clock.now = home.clock.now + 3600
    local rang = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 1)
    T.eq(Mock.cameraRing(mock, 158, rang), 1)
    local detail, message = home.detail("admin")
    T.eq(message.brief, true, "a ring is brief")
    T.eq(count(message["for"]), 2, "the admin and the member")
    T.same(detail, { at = rang, id = 68, kind = "doorbell", name = "Entrance", room = "Kitchen", room_id = 10, v = 1 })
    entrance = get(mock, home.admin, "/v1/doorbells/68")
    T.eq(entrance.last_ring_at, rang)
    T.same(entrance.events, { { type = "doorbell", at = rang } })
    T.eq(logged(mock, "the doorbell rang"), 1)

    -- Again within 30 s: one alert is enough, the ring is kept. A LAST_RING the driver did not set
    -- (an old one) is not the ring's time: now is.
    home.clock.now = home.clock.now + 20
    T.eq(Mock.cameraRing(mock, 158, "2026-01-01T00:00:00Z"), 1)
    T.eq(#home.notified(), 0, "at most one in 30 s")
    entrance = get(mock, home.admin, "/v1/doorbells/68")
    T.eq(#entrance.events, 2)
    T.truthy(entrance.last_ring_at ~= "2026-01-01T00:00:00Z", "not a time long gone")
    T.truthy(math.abs(require("src.core.clock").parseIso(entrance.last_ring_at) - os.time()) <= 2, "the moment it came")
    home.clock.now = home.clock.now + 11
    Mock.cameraRing(mock, 158)
    T.eq(#home.notified(), 1)

    -- Its detections are camera alerts, to those who chose them.
    home.clock.now = home.clock.now + 61
    T.eq(Mock.cameraAlert(mock, 158, "Package"), 1)
    detail = home.detail("admin")
    T.eq(detail.kind, "camera")
    T.eq(detail.what, "package")
    T.eq(detail.id, 68)

    -- The kept rings go through a Refresh Project.
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(#get(mock, home.admin, "/v1/doorbells/68").events, 3, "kept")
end

-- A doorbell camera opens nothing: in a home without doors, gates or a DoorBird, "doors opened" is
-- not offered for it.
function tests.a_doorbell_camera_offers_no_door_alerts()
    local project = Mock.withAgreementCameras(Mock.project())
    for _, id in ipairs({ 70, 90, 91, 92, 93, 110 }) do
        Mock.removeDevice(project, id)
    end
    local home = home(project)
    T.same(ids(get(home.mock, home.admin, "/v1/doorbells").items), { 68 })
    local kinds = get(home.mock, home.admin, "/v1/alerts/choices").kinds
    T.eq(kinds.doorbell, true)
    T.eq(kinds.door_opened, nil, "nothing here opens")
end

-- Who sees a doorbell camera (ADR-054): a member in its room sees the doorbell and gets its ring,
-- its picture only with cameras; a member without its room sees nothing of it.
function tests.a_doorbell_camera_follows_access_as_a_doorbell_does()
    local home = home(Mock.withAgreementCameras(Mock.project()))
    local mock = home.mock
    local kinds = { light = true, climate = true, fan = true, blind = true, music = true, refrigerator = true }
    local noCameras = home.add("Kids phone", "member", { all_rooms = true, rooms = {}, kinds = kinds, cameras = false, doors = false, alarm = false, scenes = {} })
    local elsewhere = home.add("Guest phone", "member", { all_rooms = false, rooms = { 11 }, kinds = kinds, cameras = true, doors = false, alarm = false, scenes = {} })

    local listed = get(mock, noCameras, "/v1/doorbells").items
    T.same(ids(listed), { 68, 93 })
    for _, doorbell in ipairs(listed) do
        T.eq(doorbell.camera, Json.null, "no picture without cameras")
    end
    T.eq(T.http(mock, "GET", "/v1/cameras/68", { key = noCameras }).status, 404)
    T.eq(T.http(mock, "GET", "/v1/cameras/68/snapshot", { key = noCameras }).status, 404)
    T.eq(get(mock, noCameras, "/v1/system").inventory.doorbells, 2)
    T.eq(get(mock, noCameras, "/v1/system").inventory.cameras, 0)
    T.same(get(mock, noCameras, "/v1/alerts/choices").kinds, { doorbell = true }, "its ring, no camera alerts")

    T.same(ids(get(mock, elsewhere, "/v1/doorbells").items), {}, "the Kitchen is not theirs")
    T.eq(T.http(mock, "GET", "/v1/doorbells/68", { key = elsewhere }).status, 404)
    T.eq(get(mock, elsewhere, "/v1/system").inventory.doorbells, 0)

    home.on("Kids phone")
    home.on("Guest phone", { camera = true, doorbell = true })
    home.on("admin", { camera = true })
    home.notified()
    home.clock.now = home.clock.now + 3600
    Mock.cameraRing(mock, 158)
    local message = home.notified()[1].message
    T.truthy(message["for"][home.keys["Kids phone"].id], "the ring: they see the doorbell")
    T.eq(message["for"][home.keys["Guest phone"].id], nil, "not theirs")
    home.clock.now = home.clock.now + 61
    Mock.cameraAlert(mock, 158, "Person")
    message = home.notified()[1].message
    T.eq(count(message["for"]), 1, "a camera alert: only who may see its pictures and chose it")
    T.truthy(message["for"][home.adminId])
end

-- ---- the marker later, a driver update ------------------------------------------------------------

-- A driver that adds the marker once it runs (after DirectorLink set its camera up), or changes its
-- kind: DirectorLink looks again, a few cameras a minute, and sets that camera up again.
function tests.a_marker_that_comes_later_is_seen_within_minutes()
    local project = Mock.withAgreementCameras(Mock.project(), {
        { id = 68, protocol = 158, name = "Entrance", room = 10, address = "192.0.2.52", kind = "doorbell", marker = false },
    })
    local home = home(project)
    local mock = home.mock
    T.same(ids(get(mock, home.admin, "/v1/doorbells").items), { 93 }, "a plain camera until it says otherwise")
    T.eq(registrations(mock, 158), 0)
    T.eq(get(mock, home.admin, "/v1/system").features.camera_alerts, false)

    Mock.addVariables(mock, 158, { DIRECTORLINK_CAMERA = "1", DIRECTORLINK_CAMERA_KIND = "doorbell" })
    -- Five cameras a minute (60, 61, 68, 92 here): within a minute or two.
    minutes(2)
    T.same(ids(get(mock, home.admin, "/v1/doorbells").items), { 68, 93 }, "a doorbell now")
    T.eq(registrations(mock, 158, 8), 1)
    T.eq(get(mock, home.admin, "/v1/system").features.camera_alerts, true)
    T.eq(logged(mock, "says something else of DirectorLink's camera agreement; set up again"), 1)
    home.on("admin")
    home.notified()
    home.clock.now = home.clock.now + 3600
    T.eq(Mock.cameraRing(mock, 158), 1)
    T.eq(home.detail("admin").kind, "doorbell")

    -- Nothing changes: nothing is set up again.
    minutes(3)
    T.eq(logged(mock, "set up again"), 1)

    -- Its kind changes (the driver learned its model): a camera again, its rings gone with it.
    Mock.addVariables(mock, 158, { DIRECTORLINK_CAMERA_KIND = "camera" })
    minutes(2)
    T.same(ids(get(mock, home.admin, "/v1/doorbells").items), { 93 })
    T.eq(T.http(mock, "GET", "/v1/doorbells/68", { key = home.admin }).status, 404)
    T.eq(Mock.cameraRing(mock, 158), 1, "still registered with Director")
    T.eq(#home.notified(), 0, "but no ring")
    T.eq(logged(mock, "set up again"), 2)
end

-- A driver updated in Composer is read again (ADR-059): its new events, its marker.
function tests.a_driver_update_reads_the_agreement_again()
    local home = home(Mock.withAgreementCameras(Mock.project()))
    local mock = home.mock
    home.on("admin", { camera = true })
    home.notified()
    -- Version 2 of the driver numbers its events otherwise, and the doorbell is now a camera.
    mock.project.deviceData[158].events = Mock.eventsXml({ { 1, "Camera Online" }, { 11, "Alert" }, { 12, "Ring" } })
    Mock.addVariables(mock, 158, { DIRECTORLINK_CAMERA_KIND = "camera" })
    Mock.updateDeviceDriver(mock, 158, "2")
    minutes(2)
    T.eq(registrations(mock, 158, 11), 1, "its new Alert")
    T.same(ids(get(mock, home.admin, "/v1/doorbells").items), { 93 }, "a camera now")
    home.clock.now = home.clock.now + 3600
    T.eq(Mock.cameraAlert(mock, 158, "Person"), 1)
    T.eq(home.detail("admin").what, "person")
    T.eq(Mock.fireDeviceEvent(mock, 158, 7), 1, "the old Alert's id is still registered with Director")
    T.eq(#home.notified(), 0, "but nothing")
end

-- After a restart DirectorLink knows the last ring from LAST_RING; a time ahead of the controller's
-- clock is not believed.
function tests.the_last_ring_survives_a_restart_through_last_ring()
    local home = home(Mock.withAgreementCameras(Mock.project()))
    local rang = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 30)
    Mock.cameraRing(home.mock, 158, rang)
    local updated = Mock.updateDriver(home.mock, home.mock.project)
    T.eq(get(updated, home.admin, "/v1/doorbells/68").last_ring_at, rang, "from LAST_RING")
    T.eq(#get(updated, home.admin, "/v1/doorbells/68").events, 0, "its rings are since DirectorLink started")
    Mock.cameraRing(updated, 158, os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 3600))
    local again = Mock.updateDriver(updated, updated.project)
    T.eq(get(again, home.admin, "/v1/doorbells/68").last_ring_at, Json.null, "an hour ahead: not believed")
end

-- ---- what Director may not say ------------------------------------------------------------------

-- Director may give a tag's first levels only: the whole <devicedata> then. A driver whose events
-- Director names nowhere is not watched (said in the log); one with several cameras neither.
function tests.events_are_found_in_the_whole_driver_xml_or_not_watched()
    local project = Mock.withAgreementCameras(Mock.project())
    local events = Mock.eventsXml(Mock.AGREEMENT_EVENTS)
    project.deviceData[157].devicedata = "<devicedata><version>1</version><events>" .. events .. "</events></devicedata>"
    project.deviceData[157].events = "<event/><event/><event/><event/><event/>"
    project.deviceData[158] = { version = "1" }
    local first = home(project)
    T.eq(registrations(first.mock, 157, 7), 1, "from the whole <devicedata>")
    T.eq(registrations(first.mock, 158), 0, "nothing named")
    T.eq(logged(first.mock, "whose Alert event Director does not name"), 1)
    T.eq(logged(first.mock, "whose Ring event Director does not name"), 1)
    T.same(ids(get(first.mock, first.admin, "/v1/doorbells").items), { 68, 93 }, "still a doorbell, as its driver says")
    T.eq(get(first.mock, first.admin, "/v1/doorbells/68").camera.id, 68, "with its picture")

    -- One driver, two cameras: neither is watched (one camera a driver).
    local two = Mock.withAgreementCameras(Mock.project(), { { id = 67, protocol = 157, name = "Porch", room = 11, address = "192.0.2.51" } })
    two.devices[157].proxies[69] = { deviceName = "Porch 2", driverFileName = "camera.c4i" }
    two.devices[69] = { deviceName = "Porch 2", driverFileName = "camera.c4i", roomId = 11, roomName = "Living Room", protocol = { [157] = { deviceName = "Porch", driverFileName = Mock.AGREEMENT_FILE } } }
    local other = home(two)
    T.eq(registrations(other.mock, 157), 0)
    T.eq(logged(other.mock, "with several cameras"), 2)
end

-- ---- the Hikvision drivers ------------------------------------------------------------------------

-- Without the marker, by its file name (ADR-056); with it, by the marker; once either way: one
-- registration, one alert.
function tests.a_hikvision_driver_is_one_camera_with_or_without_the_marker()
    local project = Mock.withHikvisionCameras(Mock.project(), {
        { id = 65, protocol = 150, name = "Garden", room = 11, address = "192.0.2.31" },
        { id = 66, protocol = 151, name = "Back Gate", room = 10, address = "192.0.2.32", marker = true },
        { id = 67, protocol = 152, name = "Pool", room = 11, address = "192.0.2.33", events = true },
    })
    local home = home(project)
    local mock = home.mock
    for _, driver in ipairs({ 150, 151, 152 }) do
        T.eq(registrations(mock, driver, 1), 1, "Alert, once: " .. driver)
        T.eq(registrations(mock, driver), 1, "nothing else: " .. driver)
    end
    home.on("admin", { camera = true })
    home.notified()
    for _, case in ipairs({ { 150, 65 }, { 151, 66 }, { 152, 67 } }) do
        home.clock.now = home.clock.now + 61
        T.eq(Mock.hikvisionAlert(mock, case[1], "Vehicle"), 1)
        local detail = home.detail("admin")
        T.eq(detail.id, case[2])
        T.eq(detail.what, "vehicle")
    end

    -- Garden's driver is updated to a version that sets the marker: by the marker now, still once.
    Mock.updateDeviceDriver(mock, 150, "107", { DIRECTORLINK_CAMERA = "1", DIRECTORLINK_CAMERA_KIND = "camera" })
    mock.project.deviceData[150].events = Mock.eventsXml(Mock.HIKVISION_EVENTS)
    minutes(2)
    T.eq(registrations(mock, 150), 1, "the same event, registered once")
    home.clock.now = home.clock.now + 61
    T.eq(Mock.hikvisionAlert(mock, 150, "Person"), 1)
    T.eq(#home.notified(), 1, "one alert")
    -- And when Director names no events, a marked Hikvision driver's Alert is still its event 1.
    mock.project.deviceData[151] = { version = "100" }
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    home.clock.now = home.clock.now + 61
    T.eq(Mock.hikvisionAlert(mock, 151, "Person"), 1)
    T.eq(home.detail("admin").id, 66)
end

return tests
