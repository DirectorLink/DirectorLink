-- Camera pictures at the same time (1.8.0, ADR-055, src/control4/camera.lua): how many are fetched
-- at once (in all, per camera address, per NVR), in what order, a digest login's challenge kept and
-- answered again with the count going up (and answered anew once when the camera refuses it), and
-- tiles showing one camera sharing a fetch for 2 s. The fake cameras answer when the test says
-- (mock.httpDeferred), and check digest logins as a Hikvision camera does (driver/tests/c4mock.lua).

local T = require("helpers")
local Mock = require("c4mock")

local tests = {}

-- A project whose cameras are `count` Hikvision cameras (ids 200 on, drivers 300 on), each at its
-- own address; the first `nvr` of them are channels of one NVR (one address). The cameras of
-- Mock.project() are left out.
local function project(count, nvr)
    local p = Mock.project()
    for _, id in ipairs({ 60, 61, 107, 108 }) do
        p.devices[id] = nil
    end
    p.cameras[60], p.cameras[61] = nil, nil
    local list = {}
    for index = 1, count do
        local onNvr = nvr and index <= nvr
        list[#list + 1] = {
            id = 199 + index,
            protocol = 299 + index,
            name = "Camera " .. index,
            room = index % 2 == 0 and 10 or 11,
            address = onNvr and "192.0.2.10" or ("192.0.2." .. tostring(100 + index)),
            channel = onNvr and index or 1,
        }
    end
    return Mock.withHikvisionCameras(p, list)
end

local function start(count, nvr)
    local mock = Mock.startDriver(project(count, nvr))
    local key = T.pair(mock)
    mock.urlRequests = {}
    return mock, key, require("src.control4.camera")
end

local function ask(mock, key, id, width)
    return T.http(mock, "GET", "/v1/cameras/" .. id .. "/snapshot?width=" .. (width or 320), { key = key })
end

-- The camera requests sent to `address` since `from` (an index into mock.urlRequests).
local function requestsTo(mock, address, from)
    local found = {}
    for index = from or 1, #mock.urlRequests do
        local request = mock.urlRequests[index]
        if request.url:find("//" .. address .. "/", 1, true) then
            found[#found + 1] = request
        end
    end
    return found
end

local function field(request, name)
    local authorization = request.headers and request.headers.Authorization or ""
    return authorization:match(name .. '="([^"]*)"') or authorization:match(name .. "=([^,%s]+)")
end

-- Moves DirectorLink's millisecond clock on (pictures are kept 2 s).
local function later(mock, ms)
    mock.clock = mock.clock + ms
end

-- Answers the camera requests waiting, each `latency` ms after it was sent, in that order, until
-- none is left: a request sent meanwhile waits its own `latency`. Returns how long it all took.
local function answerWithLatency(mock, latency)
    local now = 0
    local function stamp()
        for _, item in ipairs(mock.httpQueue) do
            item.due = item.due or now + latency
        end
    end
    stamp()
    while #mock.httpQueue > 0 do
        local first = 1
        for index, item in ipairs(mock.httpQueue) do
            if item.due < mock.httpQueue[first].due then
                first = index
            end
        end
        local item = table.remove(mock.httpQueue, first)
        now = item.due
        item.deliver()
        stamp()
    end
    return now
end

-- ---- several at once ----------------------------------------------------------------------------

function tests.eight_pictures_are_fetched_at_once_and_the_others_wait_their_turn()
    local mock, key, Camera = start(11)
    mock.httpDeferred = true
    local waiting = {}
    for index = 1, 11 do
        waiting[index] = ask(mock, key, 199 + index)
        T.eq(waiting[index].status, nil, "answered later")
    end
    T.eq(#mock.httpQueue, 8, "eight on their way")
    T.eq(Camera.stats().waiting, 3)
    -- One comes back (its login's challenge): its answer goes out at once, and nothing else starts.
    Mock.deliverHttp(mock, 1)
    T.eq(#mock.httpQueue, 8)
    Mock.deliverHttp(mock)
    for index = 1, 11 do
        T.eq(T.response(mock, waiting[index].handle).status, 200, "camera " .. index)
    end
    T.eq(Camera.stats().in_flight, 0)
    T.eq(Camera.stats().waiting, 0)
end

function tests.a_camera_address_takes_two_at_once_and_an_nvr_three()
    -- Cameras 1 to 5 are channels of one NVR; camera 6 is on its own.
    local mock, key, Camera = start(6, 5)
    mock.httpDeferred = true
    for index = 1, 5 do
        ask(mock, key, 199 + index)
    end
    T.eq(#requestsTo(mock, "192.0.2.10"), 3, "three at once from the NVR")
    T.eq(Camera.stats().waiting, 2)
    for _, width in ipairs({ 320, 640, 1280, 1920 }) do
        ask(mock, key, 205, width)
    end
    T.eq(#requestsTo(mock, "192.0.2.106"), 2, "two at once from one camera")
    T.eq(Camera.stats().in_flight, 5)
    T.eq(Camera.stats().waiting, 4)
    Mock.deliverHttp(mock)
    T.eq(Camera.stats().waiting, 0)
end

function tests.a_picture_waiting_for_a_busy_address_does_not_hold_back_another_camera()
    local mock, key, Camera = start(6, 5)
    mock.httpDeferred = true
    for index = 1, 5 do
        ask(mock, key, 199 + index)
    end
    T.eq(Camera.stats().waiting, 2, "two of the NVR's wait")
    local other = ask(mock, key, 205)
    T.eq(#requestsTo(mock, "192.0.2.106"), 1, "asked last, on its way first")
    T.eq(Camera.stats().waiting, 2)
    -- When the NVR has room again, its own wait no longer: oldest first.
    Mock.deliverHttp(mock)
    T.eq(T.response(mock, other.handle).status, 200)
end

function tests.too_many_waiting_are_refused_as_busy()
    local mock, key, Camera = start(9)
    mock.httpDeferred = true
    local asked = 0
    for index = 1, 9 do
        for _, width in ipairs({ 320, 640, 1280, 1920 }) do
            if asked < Camera.MAX_IN_FLIGHT + Camera.MAX_QUEUED then
                T.eq(ask(mock, key, 199 + index, width).status, nil)
                asked = asked + 1
            end
        end
    end
    T.eq(Camera.stats().in_flight, 8)
    T.eq(Camera.stats().waiting, 24)
    local refused = ask(mock, key, 208, 320)
    T.eq(refused.status, 503)
    T.eq(refused.json.code, "CAMERA_BUSY")
    T.eq(refused.headers["retry-after"], "1")
    -- One more asking for a picture already waiting joins it.
    T.eq(ask(mock, key, 200, 320).status, nil)
    Mock.deliverHttp(mock)
    T.eq(Camera.stats().waiting, 0)
end

-- ---- the digest login -----------------------------------------------------------------------------

function tests.a_cameras_challenge_is_kept_so_a_picture_is_one_request()
    local mock, key = start(1)
    local camera = mock.project.cameras[200]
    T.eq(ask(mock, key, 200).status, 200)
    local first = requestsTo(mock, "192.0.2.101")
    T.eq(#first, 2, "the first picture: the challenge, then the answer")
    T.eq(first[1].headers.Authorization, nil)
    T.eq(field(first[2], "nonce"), "n1")
    T.eq(field(first[2], "nc"), "00000001")

    for picture = 2, 4 do
        later(mock, 2500)
        local from = #mock.urlRequests + 1
        T.eq(ask(mock, key, 200).status, 200, "picture " .. picture)
        local requests = requestsTo(mock, "192.0.2.101", from)
        T.eq(#requests, 1, "picture " .. picture .. ": one request")
        T.eq(field(requests[1], "nonce"), "n1", "the same nonce")
        T.eq(field(requests[1], "nc"), string.format("%08x", picture), "its count going up")
        T.eq(field(requests[1], "opaque"), "op1")
    end
    T.eq(camera.digest.issued, 1, "one challenge for four pictures")
    T.eq(camera.digest.accepted, 4)
end

function tests.pictures_at_once_from_one_address_have_a_login_each()
    local mock, key = start(3, 3)
    local nvr = mock.project.cameras[200]
    mock.httpDeferred = true
    local function round()
        for index = 1, 3 do
            ask(mock, key, 199 + index)
        end
        -- Never two requests with one nonce on their way at once (Hikvision refuses their counts out
        -- of order).
        local seen = {}
        for _, item in ipairs(mock.httpQueue) do
            local nonce = field(item, "nonce")
            if nonce then
                T.eq(seen[nonce], nil, "nonce " .. nonce .. " once")
                seen[nonce] = true
            end
        end
        Mock.deliverHttp(mock)
        later(mock, 2500)
    end
    round()
    T.eq(nvr.digest.issued, 3, "three logins, one per picture at once")
    local before = #mock.urlRequests
    round()
    round()
    T.eq(#mock.urlRequests - before, 6, "then one request a picture")
    T.eq(nvr.digest.issued, 3, "no new challenge")
    T.eq(nvr.digest.accepted, 9, "nothing refused")
end

function tests.a_stale_or_forgotten_nonce_is_answered_once_with_the_new_challenge()
    local mock, key = start(1)
    local camera = mock.project.cameras[200]
    camera.staleAfter = 2
    T.eq(ask(mock, key, 200).status, 200)
    later(mock, 2500)
    T.eq(ask(mock, key, 200).status, 200)
    later(mock, 2500)
    -- Used twice: the camera says it is stale.
    local from = #mock.urlRequests + 1
    T.eq(ask(mock, key, 200).status, 200)
    local requests = requestsTo(mock, "192.0.2.101", from)
    T.eq(#requests, 2, "refused as stale, then answered with the new challenge")
    T.eq(field(requests[1], "nonce"), "n1")
    T.eq(field(requests[2], "nonce"), "n2")
    T.eq(field(requests[2], "nc"), "00000001")

    -- The camera restarted and knows no nonce (a 401 without stale): the same.
    camera.staleAfter = nil
    camera.digest.nonces = {}
    later(mock, 2500)
    from = #mock.urlRequests + 1
    T.eq(ask(mock, key, 200).status, 200)
    requests = requestsTo(mock, "192.0.2.101", from)
    T.eq(#requests, 2)
    T.eq(field(requests[2], "nonce"), "n3")
end

function tests.a_wrong_password_is_tried_once_a_picture()
    local mock, key = start(1)
    local camera = mock.project.cameras[200]
    T.eq(ask(mock, key, 200).status, 200)
    -- The password changed on the camera: the kept challenge is refused, and so is the new one.
    camera.camera_password = "changed on the camera"
    later(mock, 2500)
    local from = #mock.urlRequests + 1
    local refused = ask(mock, key, 200)
    T.eq(refused.status, 502)
    T.eq(refused.json.code, "CAMERA_LOGIN_FAILED")
    T.eq(#requestsTo(mock, "192.0.2.101", from), 2)
    -- From then on each picture starts without a challenge: one wrong answer a picture, as in 1.7.0.
    for _ = 1, 3 do
        later(mock, 2500)
        from = #mock.urlRequests + 1
        T.eq(ask(mock, key, 200).json.code, "CAMERA_LOGIN_FAILED")
        local requests = requestsTo(mock, "192.0.2.101", from)
        T.eq(#requests, 2)
        T.eq(requests[1].headers.Authorization, nil, "the first without a login")
    end
    -- Fixed in Composer: pictures again.
    camera.camera_password = nil
    later(mock, 2500)
    T.eq(ask(mock, key, 200).status, 200)
end

-- A camera set to Basic login in Composer that asks for digest gets digest (as in 1.7.0), and keeps
-- it; so does one that offers Basic too, in a header before digest's.
function tests.a_camera_set_to_basic_that_asks_for_digest_gets_it_kept()
    local mock, key = start(2)
    local first, second = mock.project.cameras[200], mock.project.cameras[201]
    first.composer_auth_type = "BASIC"
    second.offersBasic = true
    for _, camera in ipairs({ { 200, "192.0.2.101" }, { 201, "192.0.2.102" } }) do
        T.eq(ask(mock, key, camera[1]).status, 200, "camera " .. camera[1])
        T.eq(#requestsTo(mock, camera[2]), 2)
        later(mock, 2500)
        local from = #mock.urlRequests + 1
        T.eq(ask(mock, key, camera[1]).status, 200)
        local requests = requestsTo(mock, camera[2], from)
        T.eq(#requests, 1, "then one request")
        T.eq(field(requests[1], "nc"), "00000002")
    end
    T.truthy(requestsTo(mock, "192.0.2.101")[1].headers.Authorization:find("^Basic "), "Basic first, as set in Composer")
end

-- ---- sharing ----------------------------------------------------------------------------------------

function tests.tiles_showing_one_camera_share_a_fetch_and_its_picture_for_two_seconds()
    local mock, key = start(2)
    mock.httpDeferred = true
    local tiles = {}
    for index = 1, 3 do
        tiles[index] = ask(mock, key, 200, 320)
    end
    T.eq(#mock.httpQueue, 1, "one fetch for three tiles")
    local large = ask(mock, key, 200, 640)
    T.eq(#mock.httpQueue, 2, "another size is another picture")
    Mock.deliverHttp(mock)
    local body = T.response(mock, tiles[1].handle).body
    for index = 1, 3 do
        local answer = T.response(mock, tiles[index].handle)
        T.eq(answer.status, 200)
        T.eq(answer.body, body, "the same picture")
    end
    T.eq(T.response(mock, large.handle).status, 200)
    T.truthy(T.response(mock, large.handle).body ~= body)

    -- Asked again within 2 s: that picture, at once.
    local count = #mock.urlRequests
    local again = ask(mock, key, 200, 320)
    T.eq(again.status, 200)
    T.eq(again.body, body)
    T.eq(#mock.urlRequests, count, "nothing asked of the camera")
    -- After 2 s, a new one.
    later(mock, 2100)
    T.eq(ask(mock, key, 200, 320).status, nil)
    T.eq(#mock.urlRequests, count + 1)
    Mock.deliverHttp(mock)
end

-- ---- how long a grid takes ----------------------------------------------------------------------

-- The controller's part of filling a grid of 11 cameras when each request to a camera takes 150 ms
-- (ADR-055 has the numbers; 1.7.0, 3 at once with two requests a picture, took 1,200 ms each time).
function tests.a_grid_of_eleven_fills_in_two_rounds_of_requests()
    local mock, key = start(11)
    mock.httpDeferred = true
    local function fill()
        local waiting = {}
        for index = 1, 11 do
            waiting[index] = ask(mock, key, 199 + index)
        end
        local took = answerWithLatency(mock, 150)
        for index = 1, 11 do
            T.eq(T.response(mock, waiting[index].handle).status, 200)
        end
        return took
    end
    local first = fill()
    T.eq(first, 600, "the first time: a challenge and an answer each, eight at once")
    later(mock, 2500)
    T.eq(fill(), 300, "then one request each, eight at once")
end

return tests
