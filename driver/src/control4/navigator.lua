-- Makes C4Bridge's own "C4Bridge Access" button visible in the Control4 app.
--
-- New buttons are added hidden. Composer shows them by sending the room SET_SECURITY_DEVICE_ORDER
-- with the room's whole Security list: the visible entries (hidden 0) followed by the hidden ones
-- (hidden 1). This module does the same for C4Bridge's button only — it reads the room's visible
-- and hidden lists, moves the button to the end of the visible part and keeps every other entry
-- exactly where it was.

local Navigator = {}

local UINT32 = 4294967296

-- Special entries such as the security-cameras shortcut are listed as unsigned 32-bit ids
-- (4294966301) but written as signed ones (-995).
local function signed(id)
    if id >= UINT32 / 2 then
        return id - UINT32
    end
    return id
end

local function parseIds(xml)
    local ids = {}
    for id in tostring(xml or ""):gmatch("<id>(%-?%d+)</id>") do
        ids[#ids + 1] = tonumber(id)
    end
    return ids
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function request(roomId, params)
    local ok, result = pcall(function()
        return C4:SendUIRequest(roomId, "GET_SECURITY_DEVICES", params)
    end)
    if ok and type(result) == "string" then
        return result
    end
    return nil
end

-- Returns the room's visible and hidden Security lists (in order), or nil plus a reason.
function Navigator.securityLists(roomId)
    local visible = request(roomId, {})
    local hidden = request(roomId, { hidden = 1 })
    if not visible or not hidden then
        return nil, nil, "the room's Security list could not be read"
    end
    return parseIds(visible), parseIds(hidden)
end

-- Builds the DEVICE_DATA_XML Composer sends, with buttonId moved to the end of the visible part.
function Navigator.orderXml(visible, hidden, buttonId)
    local entries = {}
    local order = 0
    local function add(id, isHidden)
        order = order + 1
        entries[#entries + 1] = "<device><deviceid>" .. string.format("%.0f", signed(id)) .. "</deviceid><order>"
            .. order .. "</order><hidden>" .. (isHidden and "1" or "0") .. "</hidden></device>"
    end
    for _, id in ipairs(visible) do
        if id ~= buttonId then
            add(id, false)
        end
    end
    add(buttonId, false)
    for _, id in ipairs(hidden) do
        if id ~= buttonId then
            add(id, true)
        end
    end
    return "<devicedata>" .. table.concat(entries) .. "</devicedata>"
end

-- Returns "already_visible", "made_visible", or nil plus a reason ("not_listed" means the room
-- does not list the button yet — the Director may still be adding it, so try again shortly).
function Navigator.showInSecurity(roomId, buttonId)
    local visible, hidden, reason = Navigator.securityLists(roomId)
    if not visible then
        return nil, reason
    end
    if contains(visible, buttonId) then
        return "already_visible"
    end
    if not contains(hidden, buttonId) then
        return nil, "not_listed"
    end

    local ok, err = pcall(function()
        C4:SendToDevice(roomId, "SET_SECURITY_DEVICE_ORDER", {
            DEVICE_DATA_XML = Navigator.orderXml(visible, hidden, buttonId),
        })
    end)
    if not ok then
        return nil, "the room rejected the new order: " .. tostring(err)
    end

    local after = Navigator.securityLists(roomId)
    if after and contains(after, buttonId) then
        return "made_visible"
    end
    return nil, "the room did not apply the change"
end

-- Finds C4Bridge's own button proxy and its room from the project device list.
function Navigator.findAccessButton(bridgeId, devices)
    for rawId, device in pairs(devices or {}) do
        local id = tonumber(rawId)
        if id and type(device) == "table" and string.lower(tostring(device.driverFileName or "")) == "uibutton.c4i"
            and type(device.protocol) == "table"
            and (device.protocol[bridgeId] ~= nil or device.protocol[tostring(bridgeId)] ~= nil) then
            return id, tonumber(device.roomId or device.roomID)
        end
    end
    return nil
end

return Navigator
