-- Plain Lua 5.1 AES-256 (FIPS-197) with CBC and PKCS#7 padding, for the fake Director's
-- C4:Encrypt/C4:Decrypt. Tables are computed from GF(2^8) arithmetic rather than typed in.

local AES = {}

-- XOR of two bytes, from a table (Lua 5.1 has no bit operators).
local XOR = {}
for a = 0, 255 do
    local row = {}
    for b = 0, 255 do
        local result, bit, x, y = 0, 1, a, b
        for _ = 1, 8 do
            if x % 2 ~= y % 2 then
                result = result + bit
            end
            x, y, bit = math.floor(x / 2), math.floor(y / 2), bit * 2
        end
        row[b] = result
    end
    XOR[a] = row
end
local function xor(a, b)
    return XOR[a][b]
end

-- GF(2^8) with the AES polynomial x^8 + x^4 + x^3 + x + 1, through exp/log tables (generator 3).
local EXP, LOG = {}, {}
do
    local x = 1
    for i = 0, 254 do
        EXP[i] = x
        LOG[x] = i
        local doubled = x * 2
        if doubled >= 256 then
            doubled = xor(doubled - 256, 0x1b)
        end
        x = xor(doubled, x) -- x * 3
    end
end
local function mul(a, b)
    if a == 0 or b == 0 then
        return 0
    end
    return EXP[(LOG[a] + LOG[b]) % 255]
end

local SBOX, INV_SBOX = {}, {}
do
    local function rotl(byte, n)
        return ((byte * 2 ^ n) % 256) + math.floor(byte / 2 ^ (8 - n))
    end
    for x = 0, 255 do
        local inverse = x == 0 and 0 or EXP[(255 - LOG[x]) % 255]
        local s = xor(xor(xor(xor(xor(inverse, rotl(inverse, 1)), rotl(inverse, 2)), rotl(inverse, 3)), rotl(inverse, 4)), 0x63)
        SBOX[x] = s
        INV_SBOX[s] = x
    end
end

local function expandKey(key)
    assert(#key == 32, "AES-256 needs a 32-byte key")
    local words = {}
    for i = 0, 7 do
        words[i] = { key:byte(i * 4 + 1, i * 4 + 4) }
    end
    local rcon = 1
    for i = 8, 59 do
        local temp = { words[i - 1][1], words[i - 1][2], words[i - 1][3], words[i - 1][4] }
        if i % 8 == 0 then
            temp = { xor(SBOX[temp[2]], rcon), SBOX[temp[3]], SBOX[temp[4]], SBOX[temp[1]] }
            rcon = mul(rcon, 2)
        elseif i % 8 == 4 then
            temp = { SBOX[temp[1]], SBOX[temp[2]], SBOX[temp[3]], SBOX[temp[4]] }
        end
        words[i] = {}
        for j = 1, 4 do
            words[i][j] = xor(words[i - 8][j], temp[j])
        end
    end
    return words
end

-- state[c * 4 + r + 1]: column-major, as in the standard.
local function addRoundKey(state, words, round)
    for c = 0, 3 do
        local word = words[round * 4 + c]
        for r = 0, 3 do
            state[c * 4 + r + 1] = xor(state[c * 4 + r + 1], word[r + 1])
        end
    end
end

local function encryptBlock(words, block)
    local state = { block:byte(1, 16) }
    addRoundKey(state, words, 0)
    for round = 1, 14 do
        for i = 1, 16 do
            state[i] = SBOX[state[i]]
        end
        local shifted = {}
        for c = 0, 3 do
            for r = 0, 3 do
                shifted[c * 4 + r + 1] = state[((c + r) % 4) * 4 + r + 1]
            end
        end
        state = shifted
        if round < 14 then
            for c = 0, 3 do
                local a0, a1, a2, a3 = state[c * 4 + 1], state[c * 4 + 2], state[c * 4 + 3], state[c * 4 + 4]
                state[c * 4 + 1] = xor(xor(xor(mul(a0, 2), mul(a1, 3)), a2), a3)
                state[c * 4 + 2] = xor(xor(xor(a0, mul(a1, 2)), mul(a2, 3)), a3)
                state[c * 4 + 3] = xor(xor(xor(a0, a1), mul(a2, 2)), mul(a3, 3))
                state[c * 4 + 4] = xor(xor(xor(mul(a0, 3), a1), a2), mul(a3, 2))
            end
        end
        addRoundKey(state, words, round)
    end
    return string.char(unpack(state))
end

local function decryptBlock(words, block)
    local state = { block:byte(1, 16) }
    addRoundKey(state, words, 14)
    for round = 13, 0, -1 do
        local shifted = {}
        for c = 0, 3 do
            for r = 0, 3 do
                shifted[((c + r) % 4) * 4 + r + 1] = state[c * 4 + r + 1]
            end
        end
        state = shifted
        for i = 1, 16 do
            state[i] = INV_SBOX[state[i]]
        end
        addRoundKey(state, words, round)
        if round > 0 then
            for c = 0, 3 do
                local a0, a1, a2, a3 = state[c * 4 + 1], state[c * 4 + 2], state[c * 4 + 3], state[c * 4 + 4]
                state[c * 4 + 1] = xor(xor(xor(mul(a0, 14), mul(a1, 11)), mul(a2, 13)), mul(a3, 9))
                state[c * 4 + 2] = xor(xor(xor(mul(a0, 9), mul(a1, 14)), mul(a2, 11)), mul(a3, 13))
                state[c * 4 + 3] = xor(xor(xor(mul(a0, 13), mul(a1, 9)), mul(a2, 14)), mul(a3, 11))
                state[c * 4 + 4] = xor(xor(xor(mul(a0, 11), mul(a1, 13)), mul(a2, 9)), mul(a3, 14))
            end
        end
    end
    return string.char(unpack(state))
end

local function xorBlocks(a, b)
    local out = {}
    for i = 1, 16 do
        out[i] = string.char(xor(a:byte(i), b:byte(i)))
    end
    return table.concat(out)
end

AES.encryptBlock = function(key, block)
    return encryptBlock(expandKey(key), block)
end

-- AES-256-CBC. Returns the ciphertext, or nil plus an error.
function AES.encryptCBC(key, iv, data, padding)
    if #iv ~= 16 then
        return nil, "IV must be 16 bytes"
    end
    if padding ~= false then
        local pad = 16 - #data % 16
        data = data .. string.rep(string.char(pad), pad)
    elseif #data % 16 ~= 0 then
        return nil, "data is not a multiple of the block size"
    end
    local words = expandKey(key)
    local out, previous = {}, iv
    for i = 1, #data, 16 do
        previous = encryptBlock(words, xorBlocks(data:sub(i, i + 15), previous))
        out[#out + 1] = previous
    end
    return table.concat(out)
end

function AES.decryptCBC(key, iv, data, padding)
    if #iv ~= 16 or #data == 0 or #data % 16 ~= 0 then
        return nil, "bad IV or ciphertext length"
    end
    local words = expandKey(key)
    local out, previous = {}, iv
    for i = 1, #data, 16 do
        local block = data:sub(i, i + 15)
        out[#out + 1] = xorBlocks(decryptBlock(words, block), previous)
        previous = block
    end
    local plain = table.concat(out)
    if padding ~= false then
        local pad = plain:byte(#plain)
        if not pad or pad < 1 or pad > 16 or plain:sub(-pad) ~= string.rep(string.char(pad), pad) then
            return nil, "bad decrypt"
        end
        plain = plain:sub(1, #plain - pad)
    end
    return plain
end

return AES
