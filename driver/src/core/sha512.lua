-- SHA-512 (FIPS 180-4) and HMAC-SHA512 (RFC 2104) in plain Lua 5.1, for pairing with CPace
-- (src/core/cpace.lua). Lua 5.1 has no bit operators and Director's hashes take text, not the
-- bytes CPace hashes (zero bytes included), so this is done here: a 64-bit word is two 32-bit
-- halves held in doubles, and the bitwise functions of three words are looked up four bits at a
-- time. It runs a few times per pairing, on the home network; it is not constant time.
-- Checked against FIPS 180-4's and RFC 4231's vectors (driver/tests/test_cpace.lua).

local Sha512 = {}

local floor = math.floor
local char = string.char
local W32 = 4294967296

local function words(list)
    local hi, lo = {}, {}
    for index, hex in ipairs(list) do
        hi[index] = tonumber(hex:sub(1, 8), 16)
        lo[index] = tonumber(hex:sub(9, 16), 16)
    end
    return hi, lo
end

local KH, KL = words({
    "428a2f98d728ae22", "7137449123ef65cd", "b5c0fbcfec4d3b2f", "e9b5dba58189dbbc",
    "3956c25bf348b538", "59f111f1b605d019", "923f82a4af194f9b", "ab1c5ed5da6d8118",
    "d807aa98a3030242", "12835b0145706fbe", "243185be4ee4b28c", "550c7dc3d5ffb4e2",
    "72be5d74f27b896f", "80deb1fe3b1696b1", "9bdc06a725c71235", "c19bf174cf692694",
    "e49b69c19ef14ad2", "efbe4786384f25e3", "0fc19dc68b8cd5b5", "240ca1cc77ac9c65",
    "2de92c6f592b0275", "4a7484aa6ea6e483", "5cb0a9dcbd41fbd4", "76f988da831153b5",
    "983e5152ee66dfab", "a831c66d2db43210", "b00327c898fb213f", "bf597fc7beef0ee4",
    "c6e00bf33da88fc2", "d5a79147930aa725", "06ca6351e003826f", "142929670a0e6e70",
    "27b70a8546d22ffc", "2e1b21385c26c926", "4d2c6dfc5ac42aed", "53380d139d95b3df",
    "650a73548baf63de", "766a0abb3c77b2a8", "81c2c92e47edaee6", "92722c851482353b",
    "a2bfe8a14cf10364", "a81a664bbc423001", "c24b8b70d0f89791", "c76c51a30654be30",
    "d192e819d6ef5218", "d69906245565a910", "f40e35855771202a", "106aa07032bbd1b8",
    "19a4c116b8d2d0c8", "1e376c085141ab53", "2748774cdf8eeb99", "34b0bcb5e19b48a8",
    "391c0cb3c5c95a63", "4ed8aa4ae3418acb", "5b9cca4f7763e373", "682e6ff3d6b2b8a3",
    "748f82ee5defb2fc", "78a5636f43172f60", "84c87814a1f0ab72", "8cc702081a6439ec",
    "90befffa23631e28", "a4506cebde82bde9", "bef9a3f7b2c67915", "c67178f2e372532b",
    "ca273eceea26619c", "d186b8c721c0c207", "eada7dd6cde0eb1e", "f57d4f7fee6ed178",
    "06f067aa72176fba", "0a637dc5a2c898a6", "113f9804bef90dae", "1b710b35131c471b",
    "28db77f523047d84", "32caab7b40c72493", "3c9ebe0a15c9bebc", "431d67c49c100d4c",
    "4cc5d4becb3e42b6", "597f299cfc657e2a", "5fcb6fab3ad6faec", "6c44198c4a475817",
})

local IH, IL = words({
    "6a09e667f3bcc908", "bb67ae8584caa73b", "3c6ef372fe94f82b", "a54ff53a5f1d36f1",
    "510e527fade682d1", "9b05688c2b3e6c1f", "1f83d9abfb41bd6b", "5be0cd19137e2179",
})

-- For three nibbles a, b, c (index a * 256 + b * 16 + c + 1): their xor, their majority, and
-- "a chooses b or c". Made the first time something is hashed.
local XOR3, MAJ, CH

local function makeTables()
    XOR3, MAJ, CH = {}, {}, {}
    for a = 0, 15 do
        for b = 0, 15 do
            for c = 0, 15 do
                local x, m, ch, bit = 0, 0, 0, 1
                local p, q, r = a, b, c
                for _ = 1, 4 do
                    local pa, qb, rc = p % 2, q % 2, r % 2
                    if (pa + qb + rc) % 2 == 1 then
                        x = x + bit
                    end
                    if pa + qb + rc >= 2 then
                        m = m + bit
                    end
                    if (pa == 1 and qb == 1) or (pa == 0 and rc == 1) then
                        ch = ch + bit
                    end
                    p, q, r, bit = (p - pa) / 2, (q - qb) / 2, (r - rc) / 2, bit * 2
                end
                local index = a * 256 + b * 16 + c + 1
                XOR3[index], MAJ[index], CH[index] = x, m, ch
            end
        end
    end
end

-- A table's function of three 32-bit words, four bits at a time.
local function op3(t, a, b, c)
    local na, nb, nc = a % 16, b % 16, c % 16
    local result = t[na * 256 + nb * 16 + nc + 1]
    a, b, c = (a - na) / 16, (b - nb) / 16, (c - nc) / 16
    local place = 16
    for _ = 2, 8 do
        na, nb, nc = a % 16, b % 16, c % 16
        result = result + t[na * 256 + nb * 16 + nc + 1] * place
        a, b, c = (a - na) / 16, (b - nb) / 16, (c - nc) / 16
        place = place * 16
    end
    return result
end

-- (hi, lo) rotated right by n bits, 0 < n < 32 (swap the halves first for 32 and more).
local function rotr(hi, lo, n)
    local p = 2 ^ n
    local q = W32 / p
    local hiLow, loLow = hi % p, lo % p
    return (hi - hiLow) / p + loLow * q, (lo - loLow) / p + hiLow * q
end

-- (hi, lo) shifted right by n bits, 0 < n < 32.
local function shr(hi, lo, n)
    local p = 2 ^ n
    local hiLow, loLow = hi % p, lo % p
    return (hi - hiLow) / p, (lo - loLow) / p + hiLow * (W32 / p)
end

local WH, WL = {}, {}

local function compress(H, L, block, offset)
    local wh, wl = WH, WL
    for t = 1, 16 do
        local at = offset + (t - 1) * 8
        local b1, b2, b3, b4, b5, b6, b7, b8 = block:byte(at + 1, at + 8)
        wh[t] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        wl[t] = ((b5 * 256 + b6) * 256 + b7) * 256 + b8
    end
    for t = 17, 80 do
        -- sigma0(w[t-15]) = rotr 1 ^ rotr 8 ^ shr 7; sigma1(w[t-2]) = rotr 19 ^ rotr 61 ^ shr 6
        local xh, xl = wh[t - 15], wl[t - 15]
        local h1, l1 = rotr(xh, xl, 1)
        local h2, l2 = rotr(xh, xl, 8)
        local h3, l3 = shr(xh, xl, 7)
        local s0h, s0l = op3(XOR3, h1, h2, h3), op3(XOR3, l1, l2, l3)
        xh, xl = wh[t - 2], wl[t - 2]
        h1, l1 = rotr(xh, xl, 19)
        h2, l2 = rotr(xl, xh, 29)
        h3, l3 = shr(xh, xl, 6)
        local s1h, s1l = op3(XOR3, h1, h2, h3), op3(XOR3, l1, l2, l3)
        local lo = s1l + wl[t - 7] + s0l + wl[t - 16]
        local carry = floor(lo / W32)
        wl[t] = lo - carry * W32
        wh[t] = (s1h + wh[t - 7] + s0h + wh[t - 16] + carry) % W32
    end

    local ah, bh, ch, dh, eh, fh, gh, hh = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    local al, bl, cl, dl, el, fl, gl, hl = L[1], L[2], L[3], L[4], L[5], L[6], L[7], L[8]
    for t = 1, 80 do
        -- Sigma1(e) = rotr 14 ^ rotr 18 ^ rotr 41
        local h1, l1 = rotr(eh, el, 14)
        local h2, l2 = rotr(eh, el, 18)
        local h3, l3 = rotr(el, eh, 9)
        local lo = hl + op3(XOR3, l1, l2, l3) + op3(CH, el, fl, gl) + KL[t] + wl[t]
        local carry = floor(lo / W32)
        local t1l = lo - carry * W32
        local t1h = hh + op3(XOR3, h1, h2, h3) + op3(CH, eh, fh, gh) + KH[t] + wh[t] + carry
        -- Sigma0(a) = rotr 28 ^ rotr 34 ^ rotr 39
        h1, l1 = rotr(ah, al, 28)
        h2, l2 = rotr(al, ah, 2)
        h3, l3 = rotr(al, ah, 7)
        local t2l = op3(XOR3, l1, l2, l3) + op3(MAJ, al, bl, cl)
        local t2h = op3(XOR3, h1, h2, h3) + op3(MAJ, ah, bh, ch)

        hh, hl = gh, gl
        gh, gl = fh, fl
        fh, fl = eh, el
        lo = dl + t1l
        carry = floor(lo / W32)
        el = lo - carry * W32
        eh = (dh + t1h + carry) % W32
        dh, dl = ch, cl
        ch, cl = bh, bl
        bh, bl = ah, al
        lo = t1l + t2l
        carry = floor(lo / W32)
        al = lo - carry * W32
        ah = (t1h + t2h + carry) % W32
    end

    local finals = { { ah, al }, { bh, bl }, { ch, cl }, { dh, dl }, { eh, el }, { fh, fl }, { gh, gl }, { hh, hl } }
    for index = 1, 8 do
        local lo = L[index] + finals[index][2]
        local carry = floor(lo / W32)
        L[index] = lo - carry * W32
        H[index] = (H[index] + finals[index][1] + carry) % W32
    end
end

local function bigEndian(value)
    local b4 = value % 256
    value = (value - b4) / 256
    local b3 = value % 256
    value = (value - b3) / 256
    local b2 = value % 256
    return char((value - b2) / 256, b2, b3, b4)
end

-- The 64-byte SHA-512 digest of a byte string.
function Sha512.digest(message)
    if not XOR3 then
        makeTables()
    end
    local H, L = {}, {}
    for index = 1, 8 do
        H[index], L[index] = IH[index], IL[index]
    end
    local length = #message
    -- 0x80, zeros, then the length in bits as 128 bits big-endian (only the low 64 can be set).
    local zeros = (111 - length) % 128
    local bits = length * 8
    local padded = message .. "\128" .. string.rep("\0", zeros) .. string.rep("\0", 8)
        .. bigEndian(floor(bits / W32)) .. bigEndian(bits % W32)
    for offset = 0, #padded - 1, 128 do
        compress(H, L, padded, offset)
    end
    local out = {}
    for index = 1, 8 do
        out[#out + 1] = bigEndian(H[index])
        out[#out + 1] = bigEndian(L[index])
    end
    return table.concat(out)
end

local function xorBytes(text, byte)
    return (text:gsub(".", function(c)
        local a, b, result, bit = c:byte(), byte, 0, 1
        for _ = 1, 8 do
            if a % 2 ~= b % 2 then
                result = result + bit
            end
            a, b, bit = floor(a / 2), floor(b / 2), bit * 2
        end
        return char(result)
    end))
end

-- HMAC-SHA512 (64 bytes) of a message under a key (byte strings).
function Sha512.hmac(key, message)
    if #key > 128 then
        key = Sha512.digest(key)
    end
    key = key .. string.rep("\0", 128 - #key)
    return Sha512.digest(xorBytes(key, 0x5c) .. Sha512.digest(xorBytes(key, 0x36) .. message))
end

return Sha512
