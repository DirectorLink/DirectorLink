-- Plain Lua 5.1 MD5 (RFC 1321) for the fake Director's C4:Hash, so digest logins are checked
-- against real hashes. Bit operations are done with arithmetic; speed does not matter here.

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
    local high = math.floor(x / 2 ^ (32 - n))
    return (x * 2 ^ n) % MOD + high
end

local S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local K = {}
for i = 0, 63 do
    K[i + 1] = math.floor(math.abs(math.sin(i + 1)) * MOD) % MOD
end

local function word(bytes, offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function hexWord(x)
    local parts = {}
    for _ = 1, 4 do
        parts[#parts + 1] = string.format("%02x", x % 256)
        x = math.floor(x / 256)
    end
    return table.concat(parts)
end

return function(message)
    local length = #message
    local bitLength = length * 8
    message = message .. "\128" .. string.rep("\0", (55 - length) % 64)
    local lengthBytes = {}
    for _ = 1, 8 do
        lengthBytes[#lengthBytes + 1] = string.char(bitLength % 256)
        bitLength = math.floor(bitLength / 256)
    end
    message = message .. table.concat(lengthBytes)

    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for chunk = 1, #message, 64 do
        local M = {}
        for i = 0, 15 do
            M[i] = word(message, chunk + i * 4)
        end
        local A, B, C, D = a0, b0, c0, d0
        for i = 0, 63 do
            local F, g
            if i < 16 then
                F, g = bor(band(B, C), band(bnot(B), D)), i
            elseif i < 32 then
                F, g = bor(band(D, B), band(bnot(D), C)), (5 * i + 1) % 16
            elseif i < 48 then
                F, g = bxor(bxor(B, C), D), (3 * i + 5) % 16
            else
                F, g = bxor(C, bor(B, bnot(D))), (7 * i) % 16
            end
            F = (F + A + K[i + 1] + M[g]) % MOD
            A, D, C = D, C, B
            B = (B + rotl(F, S[i + 1])) % MOD
        end
        a0, b0, c0, d0 = (a0 + A) % MOD, (b0 + B) % MOD, (c0 + C) % MOD, (d0 + D) % MOD
    end
    return hexWord(a0) .. hexWord(b0) .. hexWord(c0) .. hexWord(d0)
end
