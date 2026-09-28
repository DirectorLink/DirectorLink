-- Standard base64 (RFC 4648, with padding) in plain Lua, for short values that must be exact: the
-- lock's IVs, MACs and the ciphertext of requests. Large bodies use C4:Base64Encode.

local Base64 = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local INDEX = {}
for position = 1, 64 do
    INDEX[CHARS:byte(position)] = position - 1
end
local PAD = 61 -- "="

function Base64.encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
        local c3, c4 = math.floor(n / 64) % 64, n % 64
        out[#out + 1] = CHARS:sub(c1 + 1, c1 + 1)
            .. CHARS:sub(c2 + 1, c2 + 1)
            .. (b and CHARS:sub(c3 + 1, c3 + 1) or "=")
            .. (c and CHARS:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

-- Returns the bytes, or nil when the text is not base64. Whitespace is ignored.
function Base64.decode(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("%s", "")
    if #text % 4 ~= 0 then
        return nil
    end
    local out = {}
    for i = 1, #text, 4 do
        local a, b, c, d = text:byte(i, i + 3)
        local n1, n2 = INDEX[a], INDEX[b]
        local n3 = c ~= PAD and INDEX[c] or nil
        local n4 = d ~= PAD and INDEX[d] or nil
        local last = i + 3 == #text
        if not n1 or not n2 or (c ~= PAD and not n3) or (d ~= PAD and not n4) then
            return nil
        end
        if (c == PAD and d ~= PAD) or ((c == PAD or d == PAD) and not last) then
            return nil
        end
        local n = n1 * 262144 + n2 * 4096 + (n3 or 0) * 64 + (n4 or 0)
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if n3 then
            out[#out + 1] = string.char(math.floor(n / 256) % 256)
        end
        if n4 then
            out[#out + 1] = string.char(n % 256)
        end
    end
    return table.concat(out)
end

function Base64.toHex(bytes)
    return (bytes:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

function Base64.fromHex(hex)
    if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^%x]") then
        return nil
    end
    return (hex:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

return Base64
