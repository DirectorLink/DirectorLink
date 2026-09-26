-- The C4Bridge Access button is made visible in the Control4 app (room Security list),
-- the same change Composer makes in Navigators.

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function setOrderCommands(mock)
    local found = {}
    for _, command in ipairs(mock.commands) do
        if command.command == "SET_SECURITY_DEVICE_ORDER" then
            found[#found + 1] = command
        end
    end
    return found
end

local function joined(list)
    return table.concat(list, ",")
end

function tests.order_xml_matches_what_composer_sends()
    local Navigator = require("src.control4.navigator")
    local xml = Navigator.orderXml({ 4294966301, 531, 567 }, { 541, 575, 483 }, 575)
    T.eq(xml, "<devicedata>"
        .. "<device><deviceid>-995</deviceid><order>1</order><hidden>0</hidden></device>"
        .. "<device><deviceid>531</deviceid><order>2</order><hidden>0</hidden></device>"
        .. "<device><deviceid>567</deviceid><order>3</order><hidden>0</hidden></device>"
        .. "<device><deviceid>575</deviceid><order>4</order><hidden>0</hidden></device>"
        .. "<device><deviceid>541</deviceid><order>5</order><hidden>1</hidden></device>"
        .. "<device><deviceid>483</deviceid><order>6</order><hidden>1</hidden></device>"
        .. "</devicedata>")
end

function tests.adding_the_driver_makes_the_button_visible()
    local mock = Mock.startDriver(nil, nil, "DIT_ADDING")
    T.eq(#setOrderCommands(mock), 0, "waits for the Director to finish adding the button")
    Mock.fireTimers(mock)
    local room = mock.security[10]
    T.eq(joined(room.visible), "4294966301,531,574", "button appended to the visible entries")
    T.eq(joined(room.hidden), "541,483", "every other entry keeps its place and flag")
    T.eq(#setOrderCommands(mock), 1)
    T.contains(table.concat(mock.debugLog, "\n"), "C4Bridge Access is now visible")
end

function tests.a_normal_startup_never_touches_the_app_configuration()
    local mock = Mock.startDriver()
    Mock.fireTimers(mock)
    T.eq(#setOrderCommands(mock), 0)
end

function tests.an_already_visible_button_is_left_alone()
    local mock = Mock.install()
    mock.security[10] = { visible = { 531, 574 }, hidden = { 541 } }
    local restarted = Mock.startDriver(nil, nil, "DIT_ADDING")
    restarted.security[10] = { visible = { 531, 574 }, hidden = { 541 } }
    Mock.fireTimers(restarted)
    T.eq(#setOrderCommands(restarted), 0)
    T.contains(table.concat(restarted.debugLog, "\n"), "already visible")
end

function tests.it_waits_until_the_room_lists_the_button()
    local mock = Mock.startDriver(nil, nil, "DIT_ADDING")
    mock.security[10] = { visible = { 531 }, hidden = { 541 } }
    Mock.fireTimers(mock, 2)
    T.eq(#setOrderCommands(mock), 0, "not listed yet: nothing is written")
    mock.security[10].hidden = { 541, 574 }
    Mock.fireTimers(mock)
    T.eq(joined(mock.security[10].visible), "531,574")
end

function tests.failures_change_nothing_and_are_logged()
    local mock = Mock.startDriver(nil, nil, "DIT_ADDING")
    mock.uiRequestsFail = true
    Mock.fireTimers(mock)
    T.eq(#setOrderCommands(mock), 0)
    T.contains(table.concat(mock.debugLog, "\n"), "could not show C4Bridge Access")
end

function tests.composer_action_shows_the_button_on_demand()
    local mock = Mock.startDriver()
    ExecuteCommand("LUA_ACTION", { ACTION = "SHOW_ACCESS_BUTTON" })
    T.eq(joined(mock.security[10].visible), "4294966301,531,574")
end

return tests
