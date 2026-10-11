-- Direct HTTPS (1.12.0, ADR-082; src/api/direct_https.lua): its status for admins. Since 1.12.2 it is
-- turned on and off in Composer only (DirectorLink → Direct HTTPS); the home's owner's switch of
-- 1.12.0 and 1.12.1 is gone, and PUT /v1/https says so to the apps that still offer it.

local Problem = require("src.api.problem")

local Https = {}

Https.SET_IN_COMPOSER = "Direct HTTPS is turned on and off in Composer: DirectorLink → Direct HTTPS."

-- GET /v1/https.
function Https.status(ctx)
    return 200, ctx.services.https.status()
end

-- PUT /v1/https: 409 SET_IN_COMPOSER for every admin, whatever the body; nothing changes. A 1.12.0
-- or 1.12.1 app shows the detail under its switch.
function Https.set(_ctx)
    return Problem.new(409, "SET_IN_COMPOSER", Https.SET_IN_COMPOSER)
end

return Https
