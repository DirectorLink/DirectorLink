-- The driver's CPace for tests/app/cpace.test.mjs, which checks that the app computes the same:
--   lua5.1 driver/tests/cpace_cli.lua exchange < cases.json
-- Each case { code, name, expires_in, sid, ya, yb } (hex for bytes, null for none) gives
-- { ci, g, Ya, Yb, isk, Ta, Tb, lock_key } in hex: the controller is A (ya), the app B (yb).

package.path = "./driver/?.lua;./driver/tests/?.lua;" .. package.path

local Mock = require("c4mock")
Mock.install()

local Json = require("src.core.json")
local Base64 = require("src.core.base64")
local Cpace = require("src.core.cpace")
local CpacePairing = require("src.auth.cpace_pairing")
local Lock = require("src.cloud.lock")

local function value(field)
    if field == nil or field == Json.null then
        return nil
    end
    return field
end

assert(arg[1] == "exchange", "usage: lua5.1 driver/tests/cpace_cli.lua exchange < cases.json")
local answers = Json.array()
for _, case in ipairs(Json.decode(io.read("*a"))) do
    local sid, ya, yb = Base64.fromHex(case.sid), Base64.fromHex(case.ya), Base64.fromHex(case.yb)
    local ci = CpacePairing.channel(value(case.name), value(case.expires_in))
    local g = Cpace.generator(case.code, ci, sid)
    local Ya, Yb = Cpace.share(ya, g), Cpace.share(yb, g)
    local isk = Cpace.isk(sid, Cpace.secret(ya, Yb), Ya, "", Yb, "")
    local macKey = Cpace.macKey(sid, isk)
    answers[#answers + 1] = {
        ci = Base64.toHex(ci),
        g = Base64.toHex(g),
        Ya = Base64.toHex(Ya),
        Yb = Base64.toHex(Yb),
        isk = Base64.toHex(isk),
        Ta = Base64.toHex(Cpace.tag(macKey, Ya, "")),
        Tb = Base64.toHex(Cpace.tag(macKey, Yb, "")),
        lock_key = Lock.cpaceKey(Base64.toHex(isk)),
    }
end
io.write(Json.encode(answers))
