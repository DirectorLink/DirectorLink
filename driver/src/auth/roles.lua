-- API key roles. Each role can do everything the roles before it can:
--   viewer  read everything (rooms, devices, states, camera pictures)
--   member  also control lights, thermostats and blinds
--   doors   also open doors and gates (relays; needs "Door Control" enabled in Composer)
--   admin   also manage API keys, room names and the log

local Roles = {}

Roles.ORDER = { "viewer", "member", "doors", "admin" }

local RANK = {}
for index, role in ipairs(Roles.ORDER) do
    RANK[role] = index
end

function Roles.valid(role)
    return RANK[role] ~= nil
end

-- True when a key with role `have` may use a route that needs `need`.
function Roles.allows(have, need)
    return RANK[have] ~= nil and RANK[need] ~= nil and RANK[have] >= RANK[need]
end

function Roles.list()
    return table.concat(Roles.ORDER, ", ")
end

return Roles
