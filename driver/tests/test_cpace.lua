-- CPace (src/core/cpace.lua), SHA-512 (src/core/sha512.lua) and Elligator 2 (src/core/x25519.lua)
-- against tests/vectors/cpace.json: the draft's X25519 vectors, RFC 9380's curve25519 map, FIPS
-- 180-4 and RFC 4231. The app checks the same file (tests/app/cpace.test.mjs).

local T = require("helpers")
local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Cpace = require("src.core.cpace")
local Sha512 = require("src.core.sha512")
local X25519 = require("src.core.x25519")

local tests = {}

local function vectors()
    local file = assert(io.open("tests/vectors/cpace.json", "rb"))
    local text = file:read("*a")
    file:close()
    return Json.decode(text)
end

local bytes, hex = Base64.fromHex, Base64.toHex

function tests.sha512_matches_fips_180_4()
    for _, case in ipairs(vectors().sha512) do
        T.eq(hex(Sha512.digest(bytes(case.message))), case.digest, #case.message / 2 .. " bytes")
    end
end

function tests.sha512_pads_every_length_right()
    -- Every message length from 0 to 260 bytes (the padding needs a second block from 112, a third
    -- from 240), chained: each message is 8 bytes of the digest before and that many "a"s. The
    -- value is Python's hashlib's.
    local chained = ""
    for length = 0, 260 do
        chained = Sha512.digest(chained:sub(1, 8) .. string.rep("a", length))
    end
    T.eq(hex(chained), "d620c18db15512f1dc73b16613f0cde67fbfdf86918c6aa8aec61afb74320c5362434c39d969bc6b55e1fa272c5d0a6c5d17043ea0e1aede328771c45d78d3bb")
end

function tests.hmac_sha512_matches_rfc_4231()
    for _, case in ipairs(vectors().hmac_sha512) do
        T.eq(hex(Sha512.hmac(bytes(case.key), bytes(case.data))), case.mac, "test case " .. case.case)
    end
end

function tests.prepend_len_and_lv_cat_match_the_draft()
    local v = vectors()
    for _, case in ipairs(v.prepend_len) do
        T.eq(hex(Cpace.prependLen(bytes(case.data))), case.out, #case.data / 2 .. " bytes")
    end
    local parts = {}
    for index, part in ipairs(v.lv_cat.parts) do
        parts[index] = bytes(part)
    end
    T.eq(hex(Cpace.lvCat(unpack(parts))), v.lv_cat.out)
end

function tests.the_generator_matches_the_draft()
    local g = vectors().generator
    local prs, ci, sid = bytes(g.prs), bytes(g.ci), bytes(g.sid)
    T.eq(hex(Cpace.generatorString(prs, ci, sid)), g.generator_string, "generator string")
    T.eq(hex(Sha512.digest(Cpace.generatorString(prs, ci, sid)):sub(1, 32)), g.hash, "its hash")
    T.eq(hex(X25519.elligator2(bytes(g.hash))), g.g, "Elligator 2 ignores bit 255 (decodeUCoordinate)")
    T.eq(hex(X25519.elligator2(bytes(g.u))), g.g, "the decoded field element")
    T.eq(hex(Cpace.generator(prs, ci, sid)), g.g, "calculate_generator")
end

function tests.elligator2_matches_rfc_9380()
    for index, case in ipairs(vectors().elligator2) do
        T.eq(hex(X25519.elligator2(bytes(case.u))), case.x, case.suite .. " #" .. index)
    end
end

function tests.an_exchange_matches_the_draft()
    local e = vectors().exchange
    local g = bytes(e.g)
    T.eq(hex(Cpace.generator(bytes(e.prs), bytes(e.ci), bytes(e.sid))), e.g, "generator")
    local ya, yb = bytes(e.ya), bytes(e.yb)
    local Ya, Yb = Cpace.share(ya, g), Cpace.share(yb, g)
    T.eq(hex(Ya), e.Ya, "message from A")
    T.eq(hex(Yb), e.Yb, "message from B")
    T.eq(hex(Cpace.secret(ya, Yb)), e.K, "K at A")
    T.eq(hex(Cpace.secret(yb, Ya)), e.K, "K at B")
    local sid, k, ada, adb = bytes(e.sid), bytes(e.K), bytes(e.ada), bytes(e.adb)
    T.eq(hex(Cpace.isk(sid, k, Ya, ada, Yb, adb)), e.isk_ir, "ISK, initiator-responder")
end

function tests.low_order_points_give_the_neutral_element_and_stop_the_exchange()
    local v = vectors().low_order
    local scalar = bytes(v.scalar)
    for index, case in ipairs(v.points) do
        T.eq(hex(X25519.scalarmult(scalar, bytes(case.u))), case.q, "u" .. (index - 1))
        T.eq(Cpace.secret(scalar, bytes(case.u)) == nil, case.aborts, "u" .. (index - 1) .. " aborts")
    end
    T.truthy(Cpace.secret(scalar, "short") == nil, "a share that is not 32 bytes")
end

return tests
