-- Non-JSON handler results: raw bytes (camera images) and answers that come later.

local Response = {}

local RAW = {}
local LATER = {}

-- A body sent as is, e.g. a JPEG snapshot.
function Response.raw(body, contentType)
    return { [RAW] = true, body = body, content_type = contentType }
end

function Response.isRaw(value)
    return type(value) == "table" and value[RAW] == true
end

-- start(respond) runs now; respond(status, payload, headers) (or respond(problem)) answers later.
function Response.later(start)
    return { [LATER] = true, start = start }
end

function Response.isLater(value)
    return type(value) == "table" and value[LATER] == true
end

return Response
