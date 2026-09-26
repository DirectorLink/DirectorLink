-- Access requests approved with the C4Bridge Access button (uibutton proxy, binding 5001).

local Mock = require("c4mock")
local T = require("helpers")

local tests = {}

local function lastIcon(mock)
    for index = #mock.proxy, 1, -1 do
        local sent = mock.proxy[index]
        if sent.binding == 5001 and sent.command == "ICON_CHANGED" then
            return sent.params.icon
        end
    end
end

local function press()
    ReceivedFromProxy(5001, "SELECT", {})
end

local function request(mock, name)
    return T.http(mock, "POST", "/v1/auth/requests", { body = { name = name or "Chrome" } })
end

-- Moves the approvals clock forward (os.time stays real for everything else).
local function advance(seconds)
    local Clock = package.loaded["src.core.clock"]
    local real = os.time
    local offset = (Clock.offset or 0) + seconds
    Clock.offset = offset
    Clock.now = function()
        return real() + offset
    end
end

function tests.the_access_button_is_not_listed_as_a_device()
    local mock = Mock.startDriver()
    local key = T.pair(mock)
    local devices = T.http(mock, "GET", "/v1/devices", { key = key }).json.items
    for _, device in ipairs(devices) do
        T.truthy(device.id ~= 574 and device.id ~= 572, "C4Bridge and its button are not homeowner devices")
    end
    T.eq(#devices, 5)
end

function tests.button_starts_idle()
    local mock = Mock.startDriver()
    T.eq(lastIcon(mock), "idle")
    T.eq(mock.properties["Access Request"], "None")
end

function tests.approval_issues_a_key_once()
    local mock = Mock.startDriver()
    local created = request(mock, "Chrome on laptop")
    T.eq(created.status, 201)
    T.eq(created.json.status, "pending")
    T.truthy(created.json.id:match("^%x+$") and #created.json.id == 32, "32-hex request id")
    T.eq(created.headers["location"], "/v1/auth/requests/" .. created.json.id)
    T.eq(lastIcon(mock), "waiting")
    T.contains(mock.properties["Access Request"], "Waiting: Chrome on laptop (192.168.1.50)")

    local pending = T.http(mock, "GET", "/v1/auth/requests/" .. created.json.id)
    T.eq(pending.json.status, "pending")
    T.eq(tostring(pending.json.api_key), "null")

    press()
    T.eq(lastIcon(mock), "approved")
    T.contains(mock.properties["Access Request"], "Approved: Chrome on laptop")

    local approved = T.http(mock, "GET", "/v1/auth/requests/" .. created.json.id)
    T.eq(approved.status, 200)
    T.eq(approved.json.status, "approved")
    T.eq(approved.json.api_key.name, "Chrome on laptop")
    T.eq(T.http(mock, "GET", "/v1/system", { key = approved.json.api_key.key }).status, 200)
    T.eq(mock.properties["API Keys"], "1")
    T.eq(lastIcon(mock), "idle", "button returns to idle once the key is collected")
    T.eq(mock.properties["Access Request"], "None")

    T.eq(T.http(mock, "GET", "/v1/auth/requests/" .. created.json.id).status, 404, "the key is handed out only once")
end

function tests.only_one_request_waits_at_a_time()
    local mock = Mock.startDriver()
    request(mock)
    local second = request(mock, "Someone else")
    T.eq(second.status, 409)
    T.eq(second.json.code, "REQUEST_PENDING")
    T.truthy(tonumber(second.headers["retry-after"]) > 0, "Retry-After tells when to try again")
end

function tests.requests_expire_and_the_button_resets()
    local mock = Mock.startDriver()
    local created = request(mock)
    advance(121)
    T.eq(T.http(mock, "GET", "/v1/auth/requests/" .. created.json.id).status, 404)
    T.eq(lastIcon(mock), "idle")
    press()
    T.eq(mock.properties["API Keys"], "0", "a late press approves nothing")
    T.eq(request(mock).status, 201, "a new request can start")
end

function tests.an_approved_key_must_be_collected_in_time()
    local mock = Mock.startDriver()
    local created = request(mock)
    press()
    advance(121)
    T.eq(T.http(mock, "GET", "/v1/auth/requests/" .. created.json.id).status, 404)
    T.eq(mock.properties["API Keys"], "0", "no orphan key is created")
end

function tests.a_press_with_nothing_waiting_does_nothing()
    local mock = Mock.startDriver()
    press()
    T.eq(mock.properties["API Keys"], "0")
    T.eq(lastIcon(mock), "idle")
end

function tests.requests_can_be_cancelled()
    local mock = Mock.startDriver()
    local created = request(mock)
    T.eq(T.http(mock, "DELETE", "/v1/auth/requests/" .. created.json.id).status, 204)
    T.eq(lastIcon(mock), "idle")
    T.eq(T.http(mock, "DELETE", "/v1/auth/requests/" .. created.json.id).status, 404)
    press()
    T.eq(mock.properties["API Keys"], "0")
end

function tests.wrong_ids_find_nothing()
    local mock = Mock.startDriver()
    request(mock)
    T.eq(T.http(mock, "GET", "/v1/auth/requests/" .. string.rep("0", 32)).status, 404)
    T.eq(T.http(mock, "GET", "/v1/auth/requests/short").status, 404)
end

function tests.requests_are_rate_limited()
    local mock = Mock.startDriver()
    for _ = 1, 5 do
        local created = request(mock)
        T.eq(created.status, 201)
        T.http(mock, "DELETE", "/v1/auth/requests/" .. created.json.id)
    end
    local limited = request(mock)
    T.eq(limited.status, 429)
    T.eq(limited.json.code, "RATE_LIMITED")
    advance(601)
    T.eq(request(mock).status, 201, "the window slides")
end

function tests.request_body_is_validated()
    local mock = Mock.startDriver()
    T.eq(T.http(mock, "POST", "/v1/auth/requests", { body = { name = string.rep("x", 65) } }).status, 400)
    T.eq(T.http(mock, "POST", "/v1/auth/requests", { body = { code = "1" } }).status, 400)
    T.eq(T.http(mock, "POST", "/v1/auth/requests").json.name, "Approved client", "the body is optional")
end

function tests.request_ids_and_keys_stay_out_of_the_log()
    local mock = Mock.startDriver()
    T.http(mock, "PATCH", "/v1/logs/settings", { key = T.pair(mock), body = { level = "debug" } })
    local created = request(mock)
    press()
    local approved = T.http(mock, "GET", "/v1/auth/requests/" .. created.json.id)
    local everything = table.concat(mock.debugLog, "\n")
    T.notContains(everything, created.json.id, "request id in the log")
    T.notContains(everything, approved.json.api_key.key, "API key in the log")
    T.contains(everything, "/v1/auth/requests/{requestId}", "access log uses the route template")
end

function tests.other_proxy_commands_are_ignored()
    local mock = Mock.startDriver()
    request(mock)
    ReceivedFromProxy(5001, "SOMETHING_ELSE", {})
    ReceivedFromProxy(1, "SELECT", {})
    T.eq(lastIcon(mock), "waiting", "only SELECT on binding 5001 approves")
end

return tests
