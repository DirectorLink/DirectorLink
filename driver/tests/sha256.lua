-- Plain Lua 5.1 SHA-256 (FIPS 180-4) for the fake Director's C4:Hash. Returns the 32-byte digest.

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

local function rotr(x, n)
    return math.floor(x / 2 ^ n) + (x * 2 ^ (32 - n)) % MOD
end

local function shr(x, n)
    return math.floor(x / 2 ^ n)
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

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

    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for chunk = 1, #message, 64 do
        local w = {}
        for i = 0, 15 do
            local a, b, c, d = message:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for i = 16, 63 do
            local s0 = bxor(bxor(rotr(w[i - 15], 7), rotr(w[i - 15], 18)), shr(w[i - 15], 3))
            local s1 = bxor(bxor(rotr(w[i - 2], 17), rotr(w[i - 2], 19)), shr(w[i - 2], 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local S1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (hh + S1 + ch + K[i + 1] + w[i]) % MOD
            local S0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temp2 = (S0 + maj) % MOD
            hh, g, f, e, d, c, b, a = g, f, e, (d + temp1) % MOD, c, b, a, (temp1 + temp2) % MOD
        end
        h[1], h[2], h[3], h[4] = (h[1] + a) % MOD, (h[2] + b) % MOD, (h[3] + c) % MOD, (h[4] + d) % MOD
        h[5], h[6], h[7], h[8] = (h[5] + e) % MOD, (h[6] + f) % MOD, (h[7] + g) % MOD, (h[8] + hh) % MOD
    end
    local out = {}
    for index = 1, 8 do
        out[index] = bytes32(h[index])
    end
    return table.concat(out)
end
