-- Plain Lua 5.1 SHA-1 (FIPS 180-4) for the fake Director's C4:Hash, so the WebSocket handshake
-- (Sec-WebSocket-Accept) is checked against real hashes. Returns the 20-byte binary digest.

local MOD = 4294967296

local function band(a, b)
    local result, bit = 0, 1
    for _ = 1, 32 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bit
        end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end

local function bxor(a, b)
    local result, bit = 0, 1
    for _ = 1, 32 do
        if a % 2 ~= b % 2 then
            result = result + bit
        end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end

local function bnot(a)
    return MOD - 1 - a
end

local function bor(a, b)
    return MOD - 1 - band(bnot(a), bnot(b))
end

local function rotl(x, n)
    return (x * 2 ^ n) % MOD + math.floor(x / 2 ^ (32 - n))
end

local function bytes32(x)
    local out = {}
    for index = 4, 1, -1 do
        out[index] = string.char(x % 256)
        x = math.floor(x / 256)
    end
    return table.concat(out)
end

return function(message)
    local length = #message
    local bitLength = length * 8
    message = message .. "\128" .. string.rep("\0", (55 - length) % 64)
    local lengthBytes = {}
    for index = 8, 1, -1 do
        lengthBytes[index] = string.char(bitLength % 256)
        bitLength = math.floor(bitLength / 256)
    end
    message = message .. table.concat(lengthBytes)

    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    for chunk = 1, #message, 64 do
        local w = {}
        for i = 0, 15 do
            local a, b, c, d = message:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for i = 16, 79 do
            w[i] = rotl(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then
                f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
            elseif i < 40 then
                f, k = bxor(bxor(b, c), d), 0x6ED9EBA1
            elseif i < 60 then
                f, k = bor(bor(band(b, c), band(b, d)), band(c, d)), 0x8F1BBCDC
            else
                f, k = bxor(bxor(b, c), d), 0xCA62C1D6
            end
            local temp = (rotl(a, 5) + f + e + k + w[i]) % MOD
            e, d, c, b, a = d, c, rotl(b, 30), a, temp
        end
        h0, h1, h2, h3, h4 = (h0 + a) % MOD, (h1 + b) % MOD, (h2 + c) % MOD, (h3 + d) % MOD, (h4 + e) % MOD
    end
    return bytes32(h0) .. bytes32(h1) .. bytes32(h2) .. bytes32(h3) .. bytes32(h4)
end
