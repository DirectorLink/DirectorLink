-- Access requests approved with the "C4Bridge Access" button in the Control4 app.
-- One request can wait at a time; pressing the button approves it, and the requester then
-- collects its API key once with the request id (which only the requester knows).

local Clock = require("src.core.clock")

local Approvals = {}

Approvals.BUTTON_BINDING = 5001
Approvals.REQUEST_TTL_SECONDS = 120
Approvals.PICKUP_SECONDS = 120

local RATE_WINDOW_SECONDS = 600
local MAX_REQUESTS_PER_WINDOW = 5

local state = {
    request = nil,
    recent = {},
    timer = nil,
    log = nil,
    onChange = nil,
}

local function log(level, message, data)
    if state.log then
        state.log.write(level, "auth", message, data)
    end
end

local function setIcon(icon, description)
    pcall(function()
        C4:SendToProxy(Approvals.BUTTON_BINDING, "ICON_CHANGED", {
            icon = icon,
            icon_description = description,
        })
    end)
end

local function publish()
    local request = state.request
    local text = "None"
    if request and request.status == "pending" then
        text = "Waiting: " .. request.name .. " as " .. tostring(request.role) .. " (" .. tostring(request.client or "?")
            .. ") until " .. os.date("%H:%M", request.expires_at)
    elseif request and request.status == "approved" then
        text = "Approved: " .. request.name .. " (collecting its key)"
    end
    if state.onChange then
        state.onChange(text)
    end
end

local function clear()
    state.request = nil
    pcall(function()
        if state.timer then
            state.timer:Cancel()
        end
    end)
    state.timer = nil
    setIcon("idle", "C4Bridge Access")
    publish()
end

local function expireIfNeeded()
    local request = state.request
    if request and request.expires_at <= Clock.now() then
        log("info", "access request expired", { name = request.name, status = request.status })
        clear()
    end
end

-- A timer returns the button to idle even if nobody polls again.
local function scheduleExpiry(seconds)
    pcall(function()
        if state.timer then
            state.timer:Cancel()
        end
        state.timer = C4:SetTimer(seconds * 1000, function()
            state.timer = nil
            expireIfNeeded()
        end, false)
    end)
end

local function constantTimeEqual(left, right)
    left, right = tostring(left or ""), tostring(right or "")
    if #left ~= #right then
        return false
    end
    local same = true
    for index = 1, #left do
        if left:byte(index) ~= right:byte(index) then
            same = false
        end
    end
    return same
end

function Approvals.initialize(options)
    options = options or {}
    state.log = options.log
    state.onChange = options.onChange
    state.request = nil
    state.recent = {}
    setIcon("idle", "C4Bridge Access")
    publish()
end

-- Returns the new request, or nil plus { code, message, retry_after }.
function Approvals.create(name, client, role)
    expireIfNeeded()
    local now = Clock.now()

    if state.request then
        return nil, {
            code = "REQUEST_PENDING",
            message = "Another device is waiting for approval; try again when it finishes",
            retry_after = math.max(1, state.request.expires_at - now),
        }
    end

    local recent = {}
    for _, time in ipairs(state.recent) do
        if now - time < RATE_WINDOW_SECONDS then
            recent[#recent + 1] = time
        end
    end
    state.recent = recent
    if #recent >= MAX_REQUESTS_PER_WINDOW then
        return nil, {
            code = "RATE_LIMITED",
            message = "Too many access requests; try again later",
            retry_after = math.max(1, RATE_WINDOW_SECONDS - (now - recent[1])),
        }
    end

    local uuid = C4:UUID("RANDOM")
    if not uuid then
        return nil, { code = "UNAVAILABLE", message = "Could not create a request id" }
    end

    state.request = {
        id = (tostring(uuid):gsub("[^%x]", "")):lower(),
        name = name,
        client = client,
        role = role or "member",
        status = "pending",
        created_at = now,
        expires_at = now + Approvals.REQUEST_TTL_SECONDS,
    }
    table.insert(state.recent, now)
    setIcon("waiting", "Approve access for " .. name)
    scheduleExpiry(Approvals.REQUEST_TTL_SECONDS)
    publish()
    log("info", "access requested; waiting for the C4Bridge Access button", { name = name, role = state.request.role, client = client })
    return state.request
end

function Approvals.get(id)
    expireIfNeeded()
    local request = state.request
    if request and constantTimeEqual(id, request.id) then
        return request
    end
    return nil
end

function Approvals.cancel(id)
    if Approvals.get(id) then
        log("info", "access request cancelled", { name = state.request.name })
        clear()
        return true
    end
    return false
end

-- Called when the key has been handed to the requester.
function Approvals.complete(id)
    if Approvals.get(id) then
        clear()
    end
end

function Approvals.onButtonPressed()
    expireIfNeeded()
    local request = state.request
    if not request or request.status ~= "pending" then
        log("info", "C4Bridge Access pressed with no request waiting")
        return false
    end
    request.status = "approved"
    request.expires_at = Clock.now() + Approvals.PICKUP_SECONDS
    scheduleExpiry(Approvals.PICKUP_SECONDS)
    setIcon("approved", "Access approved for " .. request.name)
    publish()
    log("info", "access approved from the Control4 app", { name = request.name, client = request.client })
    return true
end

return Approvals
