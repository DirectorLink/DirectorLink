-- Control4's Relay Door, Gate and Garage Door Controllers as doors and gates (1.10.0, ADR-069,
-- src/adapters/relay_controller.lua): each in its own room with its kind and, with a contact, its
-- state; opened with the controller's own Open, once, never a hold where Relay Hold is Not allowed,
-- never in a scene then; everything a door has (Door Control, who may open it, History, the opened
-- alert, ask-to-open links, scene steps, favorites, backups, Turn off all leaving it alone); a KNX
-- Contact/Relay a controller drives is one door under the relay's id, and the gate a DoorBird
-- doorbell also opens is noticed once.

local Mock = require("c4mock")
local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Harness = require("relay_harness")

local tests = {}

local GATE, GARAGE, BACK_DOOR, SIDE_GATE, BACK_RELAY = 71, 72, 73, 74, 75
local GATE_DRIVER, GARAGE_DRIVER, DOOR_DRIVER = 161, 162, 163
local DOORBIRD, DOORSTATION = 110, 93

local function project()
    return Mock.withRelayControllers(Mock.project())
end

local function byId(items)
    local found = {}
    for _, item in ipairs(items or {}) do
        found[item.id] = item
    end
    return found
end

-- The commands sent to Director since `since` (an index into mock.commands).
local function commandsSince(mock, since)
    local list = {}
    for index = (since or 0) + 1, #mock.commands do
        list[#list + 1] = mock.commands[index]
    end
    return list
end

local function start(prepare, theProject)
    local mock = Mock.startDriver(theProject or project(), nil, nil, function(m)
        Properties["Door Control"] = "Enabled"
        if prepare then
            prepare(m)
        end
    end)
    local key = T.pair(mock, "Dana's phone")
    return mock, key
end

local function relays(mock, key)
    local answer = T.http(mock, "GET", "/v1/relays", { key = key })
    T.eq(answer.status, 200, answer.body)
    return byId(answer.json.items), answer.json.items
end

-- ---- what is listed -----------------------------------------------------------------------------

function tests.each_controller_is_a_door_gate_or_garage_door_in_its_own_room()
    local mock, key = start()
    local list = relays(mock, key)
    T.eq(list[GATE].name, "Main Gate")
    T.eq(list[GATE].kind, "gate")
    T.eq(list[GATE].room.name, "Living Room", "the controller's room")
    T.eq(list[GATE].door_state, "closed", "its Closed Contact says so")
    T.eq(list[GATE].state, Json.null, "no relay of DirectorLink's own")
    T.eq(list[GATE].state_reported, false)
    T.eq(list[GARAGE].kind, "garage_door", "a second download of the driver too")
    T.eq(list[GARAGE].door_state, Json.null, "no contact: not known")
    T.eq(list[70].kind, "relay", "a KNX Contact/Relay of its own")
    T.eq(list[70].door_state, Json.null)
    T.eq(list[BACK_RELAY].kind, "door", "the KNX relay a door controller drives")
    T.eq(list[BACK_RELAY].name, "Back Door Relay", "under the relay's id and name, as before")
    T.eq(list[BACK_RELAY].door_state, "closed", "its controller's Opened Contact says so")
    T.eq(list[BACK_RELAY].state_reported, true, "its relay still watched")
    T.eq(list[BACK_DOOR], nil, "the controller's button is not a second door")
    T.eq(list[SIDE_GATE], nil, "nothing bound to its Open relay: nothing to open")

    -- A 1.9.0 app reads what it knew: id, name, room, state, state_reported.
    local one = T.http(mock, "GET", "/v1/relays/" .. GATE, { key = key })
    T.eq(one.status, 200)
    T.eq(one.json.kind, "gate")
    T.eq(T.http(mock, "GET", "/v1/relays/" .. BACK_DOOR, { key = key }).status, 404)
    T.eq(T.http(mock, "GET", "/v1/relays/" .. SIDE_GATE, { key = key }).status, 404)

    -- Every device of the project is still listed: the button shown as its relay as another device.
    local devices = byId(T.http(mock, "GET", "/v1/devices", { key = key }).json.items)
    T.eq(devices[GATE].type, "relay")
    T.eq(devices[GATE].href, "/v1/relays/" .. GATE)
    T.eq(devices[BACK_DOOR].type, "other")
    T.eq(devices[BACK_DOOR].supported, false)
    T.eq(devices[SIDE_GATE].type, "relay")
    T.eq(devices[SIDE_GATE].supported, false)
    -- In their rooms, and in the inventory.
    local inventory = T.http(mock, "GET", "/v1/system", { key = key }).json.inventory
    T.eq(inventory.relays, 4)

    -- The controllers' events are watched: Opened, Closed, Partial and Unknown.
    local watched = {}
    for _, event in ipairs(mock.deviceEvents) do
        if event[1] == GATE_DRIVER then
            watched[#watched + 1] = event[2]
        end
    end
    table.sort(watched)
    T.same(watched, { 1, 2, 3, 4 })
end

function tests.the_owners_home_shows_the_doorbirds_gate_controller_as_a_gate_and_the_knx_doors_as_they_were()
    local home = Mock.project()
    Mock.addRoom(home, 12, "חוץ")
    for id, name in pairs({ [543] = "Kitchen Door", [544] = "Main Door", [568] = "Parking Gate" }) do
        home.devices[id] = { deviceName = name, driverFileName = "knx_contact_relay.c4z", roomId = 10, roomName = "Kitchen" }
    end
    -- The official DoorBird (538) and its doorstation, whose button opens its gate today.
    home.devices[538] = {
        deviceName = "DoorBird", driverFileName = "doorbird_doorstation.c4z", roomId = 12, roomName = "חוץ",
        proxies = { [539] = { deviceName = "DoorBird", driverFileName = "doorstation.c4i" }, [540] = { deviceName = "DoorBird Button", driverFileName = "uibutton.c4i" } },
    }
    home.devices[539] = { deviceName = "DoorBird", driverFileName = "doorstation.c4i", roomId = 12, roomName = "חוץ", protocol = { [538] = { deviceName = "DoorBird", driverFileName = "doorbird_doorstation.c4z" } } }
    home.devices[540] = { deviceName = "DoorBird Button", driverFileName = "uibutton.c4i", roomId = 12, roomName = "חוץ", protocol = { [538] = { deviceName = "DoorBird", driverFileName = "doorbird_doorstation.c4z" } } }
    Mock.withRelayControllers(home, {
        { id = 531, controller = 530, name = "Relay Gate Controller (OS2.9+)", room = 12, roomName = "חוץ", kind = "gate", state = "Unknown", bindings = { [1] = 538 } },
    })
    local mock, key = start(nil, home)
    local list = relays(mock, key)
    T.eq(list[531].kind, "gate")
    T.eq(list[531].room.name, "חוץ")
    T.eq(list[531].door_state, Json.null, "no contact")
    for _, id in ipairs({ 543, 544, 568 }) do
        T.eq(list[id].kind, "relay", "the KNX doors as they are")
    end
    local doorbell = T.http(mock, "GET", "/v1/doorbells/539", { key = key }).json
    T.eq(doorbell.can_open, true, "the doorbell keeps its Open")

    local before = #mock.commands
    T.eq(T.http(mock, "POST", "/v1/relays/531/pulse", { key = key }).status, 202)
    local sent = commandsSince(mock, before)
    T.eq(#sent, 1)
    T.same(sent[1], { device = 530, command = "OPEN", params = {} })
end

-- ---- opening --------------------------------------------------------------------------------------

function tests.opening_is_the_controllers_own_open_once_and_nothing_else()
    local mock, key = start()
    for _, case in ipairs({ { GATE, GATE_DRIVER }, { GARAGE, GARAGE_DRIVER }, { BACK_RELAY, DOOR_DRIVER } }) do
        local before, timers = #mock.commands, #mock.timers
        local answer = T.http(mock, "POST", "/v1/relays/" .. case[1] .. "/pulse", { key = key })
        T.eq(answer.status, 202, answer.body)
        local sent = commandsSince(mock, before)
        T.eq(#sent, 1, "one command for " .. case[1])
        T.same(sent[1], { device = case[2], command = "OPEN", params = {} })
        T.eq(#mock.timers, timers, "nothing to release later: the controller pulses its relay itself")
    end

    -- Nothing is held or released on a controller: its relay is the controller's.
    local before = #mock.commands
    local released = T.http(mock, "PATCH", "/v1/relays/" .. GATE, { key = key, body = { state = "open" } })
    T.eq(released.status, 409)
    T.eq(released.json.code, "NOT_SUPPORTED")
    local held = T.http(mock, "PATCH", "/v1/relays/" .. GATE, { key = key, body = { state = "closed" } })
    T.eq(held.json.code, "HOLD_NOT_ALLOWED")
    Properties["Relay Hold"] = "Allowed"
    T.eq(T.http(mock, "PATCH", "/v1/relays/" .. GATE, { key = key, body = { state = "closed" } }).json.code, "NOT_SUPPORTED")
    T.eq(#commandsSince(mock, before), 0)
    -- The KNX relay a controller drives is released and held as before (Relay Hold allowed).
    T.eq(T.http(mock, "PATCH", "/v1/relays/" .. BACK_RELAY, { key = key, body = { state = "open" } }).status, 202)
    T.eq(T.http(mock, "PATCH", "/v1/relays/" .. BACK_RELAY, { key = key, body = { state = "closed" } }).status, 202)
    local sent = commandsSince(mock, before)
    T.eq(#sent, 2)
    T.same(sent[1], { device = BACK_RELAY, command = "Open Relay", params = { Relay = "1" } })
    T.same(sent[2], { device = BACK_RELAY, command = "Close Relay", params = { Relay = "1" } })
end

local function holdData(value, default)
    return {
        devicedata = "<devicedata><name>Relay Gate Controller (OS2.9+)</name><version>11</version><config><properties>"
            .. "<property><name>Number of Relays</name><type>LIST</type><default>1</default><value>1</value></property>"
            .. "<property><name>Relay Configuration</name><type>LIST</type><items><item>Hold</item><item>Pulse</item></items>"
            .. "<default>" .. (default or "Pulse") .. "</default>" .. (value and ("<value>" .. value .. "</value>") or "") .. "</property>"
            .. "</properties></config></devicedata>",
    }
end

function tests.a_controller_that_holds_its_relay_opens_only_where_holds_are_allowed_and_never_in_a_scene()
    local held = project()
    held.deviceData = { [GATE_DRIVER] = holdData("Hold"), [GARAGE_DRIVER] = holdData(nil, "Hold"), [DOOR_DRIVER] = holdData("Pulse", "Hold") }
    local mock, key = start(nil, held)
    local before = #mock.commands
    local refused = T.http(mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = key })
    T.eq(refused.status, 409)
    T.eq(refused.json.code, "HOLD_NOT_ALLOWED")
    T.eq(#commandsSince(mock, before), 0, "nothing sent")
    -- A default is not the controller's setting; Pulse set is a pulse.
    T.eq(T.http(mock, "POST", "/v1/relays/" .. GARAGE .. "/pulse", { key = key }).status, 202)
    T.eq(T.http(mock, "POST", "/v1/relays/" .. BACK_RELAY .. "/pulse", { key = key }).status, 202)
    T.eq(#commandsSince(mock, before), 2)

    -- The installer allows holds: then it opens, as Control4 would.
    Properties["Relay Hold"] = "Allowed"
    before = #mock.commands
    T.eq(T.http(mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = key }).status, 202)
    T.same(commandsSince(mock, before)[1], { device = GATE_DRIVER, command = "OPEN", params = {} })

    -- A scene is pulse-only whatever Relay Hold says.
    local scene = T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Gate", steps = { { type = "relays", device_ids = { GATE, GARAGE }, set = { action = "pulse" } } } } }).json
    before = #mock.commands
    local ran = T.http(mock, "POST", "/v1/scenes/" .. scene.id .. "/run", { key = key }).json
    T.eq(ran.ran, 1)
    T.eq(ran.failed, 1)
    T.eq(ran.problems[1].device_id, GATE)
    T.eq(ran.problems[1].code, "HOLD_NOT_ALLOWED")
    local sent = commandsSince(mock, before)
    T.eq(#sent, 1)
    T.eq(sent[1].device, GARAGE_DRIVER)
end

function tests.door_control_and_who_may_open_apply_unchanged()
    local mock, admin = start(function()
        Properties["Door Control"] = "Disabled"
    end)
    local before = #mock.commands
    local off = T.http(mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = admin })
    T.eq(off.status, 403)
    T.eq(off.json.code, "DOOR_CONTROL_DISABLED")
    Properties["Door Control"] = "Enabled"

    -- A member without doors sees the gate in their room and may not open it; one without the room
    -- does not see it.
    local function member(access, name)
        local created = T.http(mock, "POST", "/v1/api-keys", { key = admin, body = { name = name, role = "member", access = access } })
        T.eq(created.status, 201, created.body)
        return created.json.key
    end
    local noDoors = member({ all_rooms = false, rooms = { 11 } }, "Kid's phone")
    local kitchenOnly = member({ all_rooms = false, rooms = { 10 }, doors = true }, "Cook's phone")
    local living = member({ all_rooms = false, rooms = { 11 }, doors = true }, "Avi's phone")
    T.eq(relays(mock, noDoors)[GATE].kind, "gate")
    T.eq(T.http(mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = noDoors }).json.code, "FORBIDDEN")
    T.eq(relays(mock, kitchenOnly)[GATE], nil)
    T.eq(T.http(mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = kitchenOnly }).status, 404)
    T.eq(#commandsSince(mock, before), 0)
    T.eq(T.http(mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = living }).status, 202)
    T.eq(#commandsSince(mock, before), 1)
end

function tests.turn_off_all_never_reaches_a_door()
    local mock, key = start()
    local before = #mock.commands
    T.eq(T.http(mock, "POST", "/v1/off", { key = key, body = { type = "relays", device_ids = { GATE } } }).status, 400)
    T.eq(T.http(mock, "POST", "/v1/off", { key = key, body = { type = "lights", device_ids = { GATE } } }).status, 400)
    T.eq(T.http(mock, "POST", "/v1/off", { key = key, body = { type = "blinds", device_ids = { GARAGE } } }).status, 400)
    T.eq(#commandsSince(mock, before), 0)
end

-- ---- the state ---------------------------------------------------------------------------------------

function tests.the_state_is_the_controllers_with_a_contact_and_unknown_without()
    local mock, key = start()
    T.eq(Mock.controllerState(mock, GATE_DRIVER, "Partial"), 1)
    T.eq(relays(mock, key)[GATE].door_state, "partly_open")
    Mock.controllerState(mock, GATE_DRIVER, "Opened")
    T.eq(relays(mock, key)[GATE].door_state, "open")
    Mock.controllerState(mock, GATE_DRIVER, "Unknown")
    T.eq(relays(mock, key)[GATE].door_state, Json.null, "both contacts at once: not known")
    Mock.controllerState(mock, GATE_DRIVER, "Closed")
    T.eq(relays(mock, key)[GATE].door_state, "closed")
    -- Without a contact the controller's Opened is only what it was told last.
    Mock.controllerState(mock, GARAGE_DRIVER, "Opened")
    T.eq(relays(mock, key)[GARAGE].door_state, Json.null)

    -- A project refresh reads it again.
    mock.project.variables[GATE_DRIVER][1001] = "Opened"
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(relays(mock, key)[GATE].door_state, "open")
    -- A contact bound in Composer later: Director's OnPIP reads the project again, and the state shows.
    mock.project.bindings[GARAGE_DRIVER][4] = 177
    mock.project.variables[GARAGE_DRIVER][1001] = "Closed"
    ExecuteCommand("LUA_ACTION", { ACTION = "REFRESH_PROJECT" })
    T.eq(relays(mock, key)[GARAGE].door_state, "closed")
end

function tests.a_director_that_cannot_say_what_is_bound_still_shows_the_doors()
    local unreadable = project()
    unreadable.bindingsUnreadable = true
    local mock, key = start(nil, unreadable)
    local list = relays(mock, key)
    T.eq(list[GATE].kind, "gate")
    T.eq(list[GATE].door_state, Json.null, "no contact known")
    T.eq(list[SIDE_GATE].kind, "gate", "assumed bound")
    T.eq(list[BACK_DOOR].kind, "door", "no relay known: the controller is its own door")
    T.eq(list[BACK_RELAY].kind, "relay", "and the KNX relay its own")
end

-- ---- what a door has ---------------------------------------------------------------------------------

-- A connected home with the clock in the test's hands, Dana's admin phone paired with alerts on and
-- doors opened chosen: { mock, connection, clock, key, keyId, home, notified(), open(sealed) }.
local function home(prepare)
    local mock = Mock.startDriver(project(), nil, nil, function(m)
        Properties["Door Control"] = "Enabled"
        if prepare then
            prepare(m)
        end
    end)
    local _, connection = Harness.connected({ mock = mock })
    local Clock = require("src.core.clock")
    local clock = { now = os.time() }
    Clock.now = function()
        return clock.now
    end
    local key = T.pair(mock, "Dana's phone")
    local keyId = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json.id
    local s = { mock = mock, connection = connection, clock = clock, key = key, keyId = keyId }
    s.home = require("src.cloud.relay").identity().home_id
    T.eq(T.http(mock, "PUT", "/v1/alerts/choices", { key = key, body = { on = true, kinds = { door_opened = true } } }).status, 200)
    local function messages()
        local list = {}
        for _, frame in ipairs(Harness.clientFrames(connection.sent)) do
            list[#list + 1] = Json.decode(frame.payload)
        end
        connection.sent = ""
        return list
    end
    function s.messages(kind)
        local found = {}
        for _, message in ipairs(messages()) do
            if type(message) == "table" and message.type == kind then
                found[#found + 1] = message
            end
        end
        return found
    end
    function s.open(sealed)
        local Lock = require("src.cloud.lock")
        local alertKey = require("src.cloud.alerts").alertKey(Lock.deviceKey(key))
        local function hmacHex(k, data)
            return C4:HMAC("SHA256", k, data, { key_encoding = "HEX", data_encoding = "NONE", return_encoding = "HEX" }):lower()
        end
        local enc = hmacHex(alertKey, "enc")
        return Json.decode(C4:Decrypt("AES-256-CBC", enc, Base64.toHex(Base64.decode(sealed.iv)), Base64.toHex(Base64.decode(sealed.ct)), {
            key_encoding = "HEX", iv_encoding = "HEX", data_encoding = "HEX", return_encoding = "NONE", padding = true,
        }))
    end
    function s.doors()
        return T.http(mock, "GET", "/v1/activity?kind=door", { key = key }).json.items
    end
    messages()
    return s
end

function tests.history_and_the_opened_alert_say_who_and_see_an_opening_made_elsewhere_once()
    local s = home()
    T.eq(T.http(s.mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = s.key }).status, 202)
    local entries = s.doors()
    T.eq(#entries, 1)
    T.eq(entries[1].action, "pulse")
    T.eq(entries[1].what, "Main Gate")
    T.eq(entries[1].who.type, "key")
    local notices = s.messages("notify")
    T.eq(#notices, 1)
    local detail = s.open(notices[1]["for"][s.keyId])
    T.eq(detail.kind, "door_opened")
    T.eq(detail.id, GATE)
    T.eq(detail.name, "Main Gate")
    T.eq(detail.who.profile, "Dana's phone")

    -- The gate opens slowly: its contact says so a minute later, and the DoorBird its relay at once.
    s.clock.now = s.clock.now + 2
    Mock.fireDeviceEvent(s.mock, DOORBIRD, 104)
    s.clock.now = s.clock.now + 60
    Mock.controllerState(s.mock, GATE_DRIVER, "Opened")
    Mock.controllerState(s.mock, GATE_DRIVER, "Closed")
    T.eq(#s.doors(), 1, "DirectorLink's own opening, once")
    T.eq(#s.messages("notify"), 0)

    -- Opened in Control4 (its app, a keypad, a remote): once in History, once to the admins, though
    -- the controller and the DoorBird both say so.
    s.clock.now = s.clock.now + 300
    Mock.controllerState(s.mock, GATE_DRIVER, "Opened")
    Mock.fireDeviceEvent(s.mock, DOORBIRD, 104)
    entries = s.doors()
    T.eq(#entries, 2)
    T.eq(entries[1].who.type, "control4")
    T.eq(entries[1].what, "Main Gate")
    notices = s.messages("notify")
    T.eq(#notices, 1)
    T.same(s.open(notices[1]["for"][s.keyId]).who, { type = "control4" })

    -- Opened at the doorbell, by DirectorLink: the gate's contact that follows is that opening.
    s.clock.now = s.clock.now + 300
    Mock.controllerState(s.mock, GATE_DRIVER, "Closed")
    T.eq(T.http(s.mock, "POST", "/v1/doorbells/" .. DOORSTATION .. "/open", { key = s.key }).status, 202)
    s.clock.now = s.clock.now + 20
    Mock.controllerState(s.mock, GATE_DRIVER, "Opened")
    entries = s.doors()
    T.eq(#entries, 3)
    T.eq(entries[1].action, "doorbell")
    T.eq(entries[1].who.type, "key")

    -- A controller without a contact says Opened at once when Control4 opens it; a state it says
    -- again, or one it was not known in before, opened nothing.
    s.clock.now = s.clock.now + 300
    s.messages("notify")
    Mock.controllerState(s.mock, GARAGE_DRIVER, "Opened")
    T.eq(#s.doors(), 3, "from Unknown: not known to have been closed")
    Mock.controllerState(s.mock, GARAGE_DRIVER, "Closed")
    Mock.controllerState(s.mock, GARAGE_DRIVER, "Opened")
    entries = s.doors()
    T.eq(#entries, 4)
    T.eq(entries[1].what, "Garage Door")
    T.eq(entries[1].who.type, "control4")
    T.eq(#s.messages("notify"), 1)
end

function tests.a_knx_relay_a_controller_drives_is_noticed_by_either_once()
    local s = home()
    -- The relay reports its state; the controller's Unknown (its event 4, the KNX relay's "closed")
    -- is no opening.
    Mock.fireDeviceEvent(s.mock, BACK_RELAY, 3)
    Mock.controllerState(s.mock, DOOR_DRIVER, "Unknown")
    T.eq(#s.doors(), 0)
    Mock.controllerState(s.mock, DOOR_DRIVER, "Closed")
    -- Control4 opens the door: the relay closes, the contact opens.
    s.clock.now = s.clock.now + 1
    T.eq(Mock.fireDeviceEvent(s.mock, BACK_RELAY, 4), 1)
    Mock.fireDeviceEvent(s.mock, BACK_RELAY, 3)
    Mock.controllerState(s.mock, DOOR_DRIVER, "Opened")
    local entries = s.doors()
    T.eq(#entries, 1)
    T.eq(entries[1].who.type, "control4")
    T.eq(entries[1].what, "Back Door Relay")
    T.eq(entries[1].ids.device_id, BACK_RELAY)
    -- DirectorLink's own: the controller's Open, then the relay's pulse and the contact.
    s.clock.now = s.clock.now + 300
    Mock.controllerState(s.mock, DOOR_DRIVER, "Closed")
    T.eq(T.http(s.mock, "POST", "/v1/relays/" .. BACK_RELAY .. "/pulse", { key = s.key }).status, 202)
    s.clock.now = s.clock.now + 1
    Mock.fireDeviceEvent(s.mock, BACK_RELAY, 4)
    Mock.fireDeviceEvent(s.mock, BACK_RELAY, 3)
    Mock.controllerState(s.mock, DOOR_DRIVER, "Opened")
    entries = s.doors()
    T.eq(#entries, 2)
    T.eq(entries[1].who.type, "key")
end

function tests.ask_links_scene_steps_and_favorites_work_with_a_controllers_door()
    local s = home()
    -- A scene's door step: the controller's Open, named by the scene in History.
    local scene = T.http(s.mock, "POST", "/v1/scenes", { key = s.key, body = { name = "Arriving", steps = { { type = "relays", device_ids = { GATE }, set = { action = "pulse" } } } } })
    T.eq(scene.status, 201, scene.body)
    local before = #s.mock.commands
    T.eq(T.http(s.mock, "POST", "/v1/scenes/" .. scene.json.id .. "/run", { key = s.key }).json.ran, 1)
    T.same(commandsSince(s.mock, before), { { device = GATE_DRIVER, command = "OPEN", params = {} } })
    T.eq(s.doors()[1].via, "Arriving")

    -- A favorite.
    T.eq(T.http(s.mock, "PATCH", "/v1/profile", { key = s.key, body = { prefs = { favorites = { "relay:" .. GATE } } } }).status, 200)
    local profile = T.http(s.mock, "GET", "/v1/profile", { key = s.key }).json
    T.same(profile.prefs.favorites, { "relay:" .. GATE })
    T.eq(#profile.gone_favorites, 0)

    -- An ask-to-open link: it asks, and the answer opens with the controller's Open.
    local link = T.http(s.mock, "POST", "/v1/ask-links", { key = s.key, body = { relay_id = GATE, label = "Arriving home" } })
    T.eq(link.status, 201, link.body)
    T.eq(link.json.relay_name, "Main Gate")
    s.clock.now = s.clock.now + 120
    s.messages("notify")
    ReceivedFromNetwork(6001, 443, Harness.serverFrame(1, Json.encode({ type = "link", id = "ask-1", link = link.json.link_id, secret = link.json.secret })))
    local notices = s.messages("notify")
    T.eq(#notices, 1)
    local question = s.open(notices[1]["for"][s.keyId])
    T.eq(question.kind, "open_request")
    T.eq(question.id, GATE)
    before = #s.mock.commands
    local answer = T.http(s.mock, "POST", "/v1/relays/" .. GATE .. "/pulse", { key = s.key, body = { request = question.request } })
    T.eq(answer.status, 202, answer.body)
    T.same(commandsSince(s.mock, before), { { device = GATE_DRIVER, command = "OPEN", params = {} } })
    T.eq(s.doors()[1].ids.link_id, link.json.link_id)
end

-- ---- backups ---------------------------------------------------------------------------------------

local sealedCount = 0

local function sealed(mock, key, keyId, request)
    local Lock = require("src.cloud.lock")
    local info = T.http(mock, "GET", "/v1/sealed").json
    sealedCount = sealedCount + 1
    request.id = "doors-" .. sealedCount
    request.ts = info.time
    local lock = Lock.deviceKey(key)
    local envelope = Lock.seal(lock, info.home, keyId, "req", Json.encode(request))
    local response = T.http(mock, "POST", "/v1/sealed", { body = { envelope = envelope } })
    T.eq(response.status, 200, response.body)
    local answer = Json.decode(Lock.open(lock, response.json.envelope, "res"))
    answer.json = answer.body ~= "" and Json.decode(answer.body) or nil
    return answer
end

function tests.a_backup_brings_back_a_controllers_door_in_scene_steps_and_favorites()
    local mock, key = start()
    local keyId = T.http(mock, "GET", "/v1/api-keys/current", { key = key }).json.id
    T.eq(T.http(mock, "POST", "/v1/scenes", { key = key, body = { name = "Gate", steps = { { type = "relays", device_ids = { GATE, BACK_RELAY }, set = { action = "pulse" } } } } }).status, 201)
    T.eq(T.http(mock, "PATCH", "/v1/profile", { key = key, body = { prefs = { favorites = { "relay:" .. GATE, "relay:" .. BACK_RELAY } } } }).status, 200)
    local document = sealed(mock, key, keyId, { method = "GET", path = "/v1/backup" })
    T.eq(document.status, 200)

    local fresh, freshKey = start()
    local freshId = T.http(fresh, "GET", "/v1/api-keys/current", { key = freshKey }).json.id
    local text = Json.encode(document.json)
    local part = sealed(fresh, freshKey, freshId, { method = "POST", path = "/v1/restore/parts", body = { index = 0, count = 1, text = text } })
    T.eq(part.status, 200, part.body)
    local done = sealed(fresh, freshKey, freshId, { method = "POST", path = "/v1/restore", body = { upload = part.json.upload, dry_run = false } })
    T.eq(done.status, 200, done.body)
    T.eq(done.json.restore.references.unmatched_count, 0)
    local scenes = T.http(fresh, "GET", "/v1/scenes", { key = freshKey }).json.items
    local gate
    for _, scene in ipairs(scenes) do
        if scene.name == "Gate" then
            gate = scene
        end
    end
    T.same(gate.steps[1].device_ids, { GATE, BACK_RELAY })
    -- The backup's keys came back (only the restoring device was paired): Dana's phone's favorites.
    T.same(T.http(fresh, "GET", "/v1/profile", { key = key }).json.prefs.favorites, { "relay:" .. GATE, "relay:" .. BACK_RELAY })
end

return tests
