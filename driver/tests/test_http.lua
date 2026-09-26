local Http = require("src.api.http")
local T = require("helpers")

local tests = {}

local function feedAll(parser, chunks)
    local result, value
    for _, chunk in ipairs(chunks) do
        result, value = Http.feed(parser, chunk)
    end
    return result, value
end

function tests.parses_a_get_request()
    local result, request = Http.feed(Http.newParser(),
        "GET /v1/lights?room_id=10&name=Kitchen%20Island&q=a+b HTTP/1.1\r\nHost: x\r\nX-Test:  padded  \r\n\r\n")
    T.eq(result, "complete")
    T.eq(request.method, "GET")
    T.eq(request.path, "/v1/lights")
    T.eq(request.query.room_id, "10")
    T.eq(request.query.name, "Kitchen Island")
    T.eq(request.query.q, "a b")
    T.eq(request.headers["x-test"], "padded")
    T.eq(request.body, "")
end

function tests.waits_for_a_body_split_across_chunks()
    local parser = Http.newParser()
    local result, request = feedAll(parser, {
        "PATCH /v1/lights/20 HTT",
        "P/1.1\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"on\"",
        ": tr",
    })
    T.eq(result, "incomplete")
    result, request = Http.feed(parser, "ue, \"x\":1}")
    T.eq(result, "complete")
    T.eq(request.body, '{"on": true, "x"', "body is exactly Content-Length bytes")
end

function tests.rejects_malformed_requests()
    local result, failure = Http.feed(Http.newParser(), "HELLO\r\n\r\n")
    T.eq(result, "error")
    T.eq(failure.status, 400)

    result, failure = Http.feed(Http.newParser(), "GET http://x/ HTTP/1.1\r\n\r\n")
    T.eq(failure.status, 400, "absolute-form targets are rejected")

    result, failure = Http.feed(Http.newParser(), "POST /v1/x HTTP/1.1\r\nContent-Length: abc\r\n\r\n")
    T.eq(failure.status, 400, "invalid Content-Length")
end

function tests.enforces_size_limits()
    local result, failure = Http.feed(Http.newParser(), "GET / HTTP/1.1\r\nX: " .. string.rep("a", Http.MAX_HEADER_BYTES) .. "\r\n")
    T.eq(result, "error")
    T.eq(failure.status, 431)

    result, failure = Http.feed(Http.newParser(), "POST /v1/x HTTP/1.1\r\nContent-Length: " .. (Http.MAX_BODY_BYTES + 1) .. "\r\n\r\n")
    T.eq(failure.status, 413)
end

function tests.rejects_chunked_transfer_encoding()
    local _, failure = Http.feed(Http.newParser(), "POST /v1/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
    T.eq(failure.status, 501)
end

function tests.supports_expect_continue()
    local parser = Http.newParser()
    local result = Http.feed(parser, "POST /v1/x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n")
    T.eq(result, "continue")
    T.eq(Http.feed(parser, ""), "incomplete", "100 Continue is only requested once")
    local complete, request = Http.feed(parser, "{}")
    T.eq(complete, "complete")
    T.eq(request.body, "{}")
end

function tests.builds_responses_with_byte_lengths()
    local response = Http.buildResponse(200, { { "Content-Type", "application/json" } }, '"מ"')
    T.contains(response, "HTTP/1.1 200 OK\r\n")
    T.contains(response, "Content-Length: 4\r\n", "Hebrew letter is two bytes")
    T.contains(response, "Connection: close\r\n\r\n\"")
end

return tests
