-- X25519 (RFC 7748): the elliptic-curve key exchange used when a device pairs, so someone listening
-- on the home network never sees the new API key (docs/ACCOUNTS.md). DriverWorks has no key
-- exchange of its own; this is TweetNaCl's field arithmetic in plain Lua 5.1: numbers are doubles,
-- so an element of GF(2^255 - 19) is 16 limbs of 16 bits, and every intermediate stays far below
-- 2^53. It is not constant time; it runs once per pairing, on the home network.
-- Checked against RFC 7748's test vectors (driver/tests/test_x25519.lua).

local X25519 = {}

local floor = math.floor
local LIMB = 65536

local function gf(values)
    local out = {}
    for i = 1, 16 do
        out[i] = values and values[i] or 0
    end
    return out
end

local function copy(to, from)
    for i = 1, 16 do
        to[i] = from[i]
    end
end

local function carry(o)
    for i = 1, 16 do
        o[i] = o[i] + LIMB
        local c = floor(o[i] / LIMB)
        if i < 16 then
            o[i + 1] = o[i + 1] + c - 1
        else
            o[1] = o[1] + 38 * (c - 1)
        end
        o[i] = o[i] - c * LIMB
    end
end

-- Swaps p and q when b is 1.
local function swap(p, q, b)
    for i = 1, 16 do
        local t = b * (q[i] - p[i])
        p[i] = p[i] + t
        q[i] = q[i] - t
    end
end

local function add(o, a, b)
    for i = 1, 16 do
        o[i] = a[i] + b[i]
    end
end

local function sub(o, a, b)
    for i = 1, 16 do
        o[i] = a[i] - b[i]
    end
end

local product = {}

local function mul(o, a, b)
    local t = product
    for i = 1, 31 do
        t[i] = 0
    end
    for i = 1, 16 do
        local ai = a[i]
        for j = 1, 16 do
            t[i + j - 1] = t[i + j - 1] + ai * b[j]
        end
    end
    for i = 1, 15 do
        t[i] = t[i] + 38 * t[i + 16]
    end
    for i = 1, 16 do
        o[i] = t[i]
    end
    carry(o)
    carry(o)
end

local function square(o, a)
    mul(o, a, a)
end

local function invert(o, input)
    local c = gf()
    copy(c, input)
    for a = 253, 0, -1 do
        square(c, c)
        if a ~= 2 and a ~= 4 then
            mul(c, c, input)
        end
    end
    copy(o, c)
end

-- (v >> 16) & 1 in two's complement.
local function bit16(v)
    return floor(v / LIMB) % 2
end

local function pack(n)
    local t, m = gf(), gf()
    copy(t, n)
    carry(t)
    carry(t)
    carry(t)
    for _ = 1, 2 do
        m[1] = t[1] - 0xffed
        for i = 2, 15 do
            m[i] = t[i] - 0xffff - bit16(m[i - 1])
            m[i - 1] = m[i - 1] % LIMB
        end
        m[16] = t[16] - 0x7fff - bit16(m[15])
        local b = bit16(m[16])
        m[15] = m[15] % LIMB
        swap(t, m, 1 - b)
    end
    local bytes = {}
    for i = 1, 16 do
        bytes[2 * i - 1] = string.char(t[i] % 256)
        bytes[2 * i] = string.char(floor(t[i] / 256))
    end
    return table.concat(bytes)
end

local function unpack(bytes)
    local o = gf()
    for i = 1, 16 do
        o[i] = bytes:byte(2 * i - 1) + bytes:byte(2 * i) * 256
    end
    o[16] = o[16] % 32768
    return o
end

local A24 = gf({ 0xDB41, 1 })

-- The 32-byte shared value for a 32-byte scalar and a 32-byte u-coordinate (little-endian strings).
function X25519.scalarmult(scalar, point)
    assert(type(scalar) == "string" and #scalar == 32, "X25519 needs a 32-byte scalar")
    assert(type(point) == "string" and #point == 32, "X25519 needs a 32-byte point")
    local z = { scalar:byte(1, 32) }
    -- Clear bit 255, set bit 254, clear the low three bits (RFC 7748 decodeScalar25519).
    z[32] = (z[32] % 64) + 64
    z[1] = z[1] - z[1] % 8
    local x = unpack(point)
    local a, b, c, d, e, f = gf(), gf(), gf(), gf(), gf(), gf()
    copy(b, x)
    a[1], d[1] = 1, 1
    for i = 254, 0, -1 do
        local r = floor(z[floor(i / 8) + 1] / 2 ^ (i % 8)) % 2
        swap(a, b, r)
        swap(c, d, r)
        add(e, a, c)
        sub(a, a, c)
        add(c, b, d)
        sub(b, b, d)
        square(d, e)
        square(f, a)
        mul(a, c, a)
        mul(c, b, e)
        add(e, a, c)
        sub(a, a, c)
        square(b, a)
        sub(c, d, f)
        mul(a, c, A24)
        add(a, a, d)
        mul(c, c, a)
        mul(a, d, f)
        mul(d, b, x)
        square(b, e)
        swap(a, b, r)
        swap(c, d, r)
    end
    invert(c, c)
    mul(a, a, c)
    return pack(a)
end

local BASE = string.char(9) .. string.rep(string.char(0), 31)

-- The public key (32 bytes) for a private key (32 random bytes).
function X25519.publicKey(privateKey)
    return X25519.scalarmult(privateKey, BASE)
end

-- The shared secret with another side's public key; nil when that key is one of the few points
-- that would make it all zeros (RFC 7748, section 6.1).
function X25519.shared(privateKey, publicKey)
    local value = X25519.scalarmult(privateKey, publicKey)
    if value == string.rep(string.char(0), 32) then
        return nil
    end
    return value
end

return X25519
