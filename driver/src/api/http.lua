-- Minimal HTTP/1.1 request parser and response builder for the DriverWorks TCP server.
-- Data can arrive in any chunking, so each connection gets its own incremental parser.
-- Request bodies are read by Content-Length; chunked transfer encoding is not supported.

local Http = {}

Http.MAX_HEADER_BYTES = 16 * 1024
Http.MAX_BODY_BYTES = 64 * 1024

local STATUS_TEXT = {
    [100] = "Continue",
    [200] = "OK",
    [201] = "Created",
    [202] = "Accepted",
    [204] = "No Content",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [409] = "Conflict",
    [413] = "Content Too Large",
    [415] = "Unsupported Media Type",
    [429] = "Too Many Requests",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
    [502] = "Bad Gateway",
    [503] = "Service Unavailable",
}

function Http.statusText(status)
    return STATUS_TEXT[status] or "Unknown"
end

local function percentDecode(value)
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function Http.decodePathSegment(value)
    return percentDecode(tostring(value or ""))
end

function Http.decodeQueryComponent(value)
    return percentDecode((tostring(value or ""):gsub("%+", " ")))
end

function Http.parseQuery(query)
    local result = {}
    for pair in tostring(query or ""):gmatch("[^&]+") do
        local name, value = pair:match("^([^=]*)=?(.*)$")
        if name and name ~= "" then
            result[Http.decodeQueryComponent(name)] = Http.decodeQueryComponent(value)
        end
    end
    return result
end

local function badRequest(detail)
    return { status = 400, code = "INVALID_REQUEST", detail = detail }
end

local function parseHead(head)
    local lines = {}
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
        lines[#lines + 1] = line
    end

    local method, target = (lines[1] or ""):match("^(%u+) (%S+) HTTP/%d%.%d$")
    if not method then
        return nil, badRequest("Malformed request line")
    end

    local headers = {}
    for index = 2, #lines do
        local line = lines[index]
        if line ~= "" then
            local name, value = line:match("^([^:%s]+):%s*(.-)%s*$")
            if not name then
                return nil, badRequest("Malformed header line")
            end
            name = string.lower(name)
            if headers[name] then
                headers[name] = headers[name] .. ", " .. value
            else
                headers[name] = value
            end
        end
    end

    local path, query = target:match("^([^?#]*)%??([^#]*)")
    if not path or path:sub(1, 1) ~= "/" then
        return nil, badRequest("The request target must be an absolute path")
    end

    return {
        method = method,
        target = target,
        path = path,
        rawQuery = query or "",
        query = Http.parseQuery(query),
        headers = headers,
    }
end

function Http.newParser()
    return {
        buffer = "",
        request = nil,
        continueSent = false,
    }
end

-- Feeds received bytes. Returns one of:
--   "incomplete"             wait for more data
--   "continue"               client asked for 100-continue; send it, then wait
--   "complete", request      request.body holds exactly Content-Length bytes
--   "error", failure         failure = { status, code, detail }
function Http.feed(parser, data)
    parser.buffer = parser.buffer .. (data or "")

    if not parser.request then
        local headEnd = parser.buffer:find("\r\n\r\n", 1, true)
        if not headEnd then
            if #parser.buffer > Http.MAX_HEADER_BYTES then
                return "error", { status = 431, code = "HEADERS_TOO_LARGE", detail = "Request headers are too large" }
            end
            return "incomplete"
        end
        if headEnd > Http.MAX_HEADER_BYTES then
            return "error", { status = 431, code = "HEADERS_TOO_LARGE", detail = "Request headers are too large" }
        end

        local request, failure = parseHead(parser.buffer:sub(1, headEnd - 1))
        if not request then
            return "error", failure
        end
        parser.buffer = parser.buffer:sub(headEnd + 4)

        if request.headers["transfer-encoding"] then
            return "error", {
                status = 501,
                code = "TRANSFER_ENCODING_NOT_SUPPORTED",
                detail = "Send the request body with a Content-Length header",
            }
        end

        local length = request.headers["content-length"]
        if length == nil then
            request.contentLength = 0
        elseif length:match("^%d+$") then
            request.contentLength = tonumber(length)
        else
            return "error", badRequest("Invalid Content-Length header")
        end

        if request.contentLength > Http.MAX_BODY_BYTES then
            return "error", {
                status = 413,
                code = "BODY_TOO_LARGE",
                detail = "The request body is larger than " .. Http.MAX_BODY_BYTES .. " bytes",
            }
        end

        parser.request = request
    end

    local request = parser.request
    if #parser.buffer < request.contentLength then
        local expect = string.lower(request.headers["expect"] or "")
        if expect == "100-continue" and not parser.continueSent then
            parser.continueSent = true
            return "continue"
        end
        return "incomplete"
    end

    request.body = parser.buffer:sub(1, request.contentLength)
    parser.buffer = ""
    return "complete", request
end

-- headers: list of { name, value } pairs. Content-Length and Connection are added here.
function Http.buildResponse(status, headers, body)
    body = body or ""
    local lines = { "HTTP/1.1 " .. tostring(status) .. " " .. Http.statusText(status) }
    for _, header in ipairs(headers or {}) do
        lines[#lines + 1] = header[1] .. ": " .. header[2]
    end
    lines[#lines + 1] = "Content-Length: " .. tostring(#body)
    lines[#lines + 1] = "Connection: close"
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

return Http
