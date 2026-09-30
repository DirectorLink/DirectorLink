-- CPace (draft-irtf-cfrg-cpace, cipher suite CPACE-X25519-SHA512): a key exchange that works only
-- for the two sides that know the same password, here the pairing code. The code never crosses
-- the network, and someone listening, or in the middle, learns nothing to test codes with: each
-- guess needs a whole exchange with the controller, which counts it (docs/ACCOUNTS.md, ADR-039).
-- These are the draft's functions; how DirectorLink pairs with them is src/auth/cpace_pairing.lua.
-- Checked against the draft's X25519 vectors (driver/tests/test_cpace.lua, tests/vectors/cpace.json).

local Sha512 = require("src.core.sha512")
local X25519 = require("src.core.x25519")

local Cpace = {}

Cpace.DSI = "CPace255"
local S_IN_BYTES = 128 -- SHA-512's input block
local IDENTITY = string.rep(string.char(0), 32) -- G.I, the neutral element

-- The data with its length before it (LEB128).
function Cpace.prependLen(data)
    local length = #data
    local encoded = {}
    repeat
        local low = length % 128
        length = (length - low) / 128
        encoded[#encoded + 1] = string.char(length > 0 and low + 128 or low)
    until length == 0
    return table.concat(encoded) .. data
end

function Cpace.lvCat(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = Cpace.prependLen((select(index, ...)))
    end
    return table.concat(parts)
end

-- DSI, the password and zeros fill the hash's first block, so its length does not depend on the
-- password's.
function Cpace.generatorString(prs, ci, sid)
    local zeros = math.max(0, S_IN_BYTES - 1 - #Cpace.prependLen(prs) - #Cpace.prependLen(Cpace.DSI))
    return Cpace.lvCat(Cpace.DSI, prs, string.rep(string.char(0), zeros), ci, sid)
end

-- G_X25519.calculate_generator: the generator (a u-coordinate) for this password, channel and
-- session.
function Cpace.generator(prs, ci, sid)
    return X25519.elligator2(Sha512.digest(Cpace.generatorString(prs, ci, sid)):sub(1, 32))
end

-- The public share y * g of a scalar (32 random bytes).
function Cpace.share(scalar, generator)
    return X25519.scalarmult(scalar, generator)
end

-- G_X25519.scalar_mult_vfy: the secret point from our scalar and the other side's share, or nil
-- for a share of low order (the neutral element): then the exchange stops.
function Cpace.secret(scalar, share)
    if type(share) ~= "string" or #share ~= 32 then
        return nil
    end
    local point = X25519.scalarmult(scalar, share)
    if point == IDENTITY then
        return nil
    end
    return point
end

-- The initiator (A) speaks first: transcript_ir.
function Cpace.transcript(ya, ada, yb, adb)
    return Cpace.lvCat(ya, ada) .. Cpace.lvCat(yb, adb)
end

-- The intermediate session key (64 bytes).
function Cpace.isk(sid, k, ya, ada, yb, adb)
    return Sha512.digest(Cpace.lvCat(Cpace.DSI .. "_ISK", sid, k) .. Cpace.transcript(ya, ada, yb, adb))
end

-- Explicit key confirmation (the draft's section 10.4): each side sends a tag over its own message.
function Cpace.macKey(sid, isk)
    return Sha512.digest("CPaceMac" .. sid .. isk)
end

function Cpace.tag(macKey, share, ad)
    return Sha512.hmac(macKey, Cpace.lvCat(share, ad))
end

return Cpace
