-- API keys: named bearer secrets, persisted encrypted on Director.

local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Roles = require("src.auth.roles")

local Keys = {}

Keys.MAX_KEYS = 20

local STORE_KEY = "c4bridge_api_keys"

local state = {
    keys = {},
    lastUsed = {},
}

local function randomHex()
    local uuid, err = C4:UUID("RANDOM")
    if not uuid then
        error("UUID generation failed: " .. tostring(err))
    end
    return (tostring(uuid):gsub("[^%x]", "")):lower()
end

local function constantTimeEqual(left, right)
    if #left ~= #right then
        return false
    end
    local same = true
    for index = 1, #left do
        if left:byte(index) ~= right:byte(index) then
            same = false
        end
    end
    return same
end

local function save()
    local records = Json.array()
    for _, key in ipairs(state.keys) do
        records[#records + 1] = {
            id = key.id,
            name = key.name,
            role = key.role,
            secret = key.secret,
            created_at = key.created_at,
        }
    end
    return pcall(function()
        C4:PersistSetValue(STORE_KEY, Json.encode({ version = 2, keys = records }), true)
    end)
end

function Keys.load()
    state.keys = {}
    state.lastUsed = {}

    local ok, raw = pcall(function()
        return C4:PersistGetValue(STORE_KEY, true)
    end)
    if ok and type(raw) == "string" and raw ~= "" then
        local data = Json.decode(raw)
        if type(data) == "table" and type(data.keys) == "table" then
            for _, key in ipairs(data.keys) do
                if type(key) == "table" and type(key.id) == "string" and type(key.secret) == "string" then
                    state.keys[#state.keys + 1] = {
                        id = key.id,
                        name = tostring(key.name or "API key"),
                        -- Keys from before roles existed (0.6 and older) keep full access.
                        role = Roles.valid(key.role) and key.role or "admin",
                        secret = key.secret,
                        created_at = type(key.created_at) == "string" and key.created_at or Clock.iso(),
                    }
                end
            end
        end
    end

    return #state.keys
end

function Keys.count()
    return #state.keys
end

-- Returns the key record for a presented secret, or nil.
function Keys.verify(presented)
    if type(presented) ~= "string" or presented == "" then
        return nil
    end
    local match
    for _, key in ipairs(state.keys) do
        if constantTimeEqual(presented, key.secret) then
            match = key
        end
    end
    if match then
        state.lastUsed[match.id] = Clock.iso()
    end
    return match
end

-- Returns the new record (including its secret), or nil plus an error code.
function Keys.create(name, role)
    role = role or "member"
    if not Roles.valid(role) then
        return nil, "INVALID_ROLE"
    end
    if #state.keys >= Keys.MAX_KEYS then
        return nil, "KEY_LIMIT_REACHED"
    end

    local ok, idSource, secretA, secretB = pcall(function()
        return randomHex(), randomHex(), randomHex()
    end)
    if not ok then
        return nil, "RANDOM_UNAVAILABLE"
    end

    local id = idSource:sub(1, 8)
    for _, key in ipairs(state.keys) do
        if key.id == id then
            id = idSource:sub(9, 16)
        end
    end

    local record = {
        id = id,
        name = name,
        role = role,
        secret = "ak_" .. secretA .. secretB:sub(1, 16),
        created_at = Clock.iso(),
    }
    table.insert(state.keys, record)

    if not save() then
        table.remove(state.keys)
        return nil, "PERSIST_FAILED"
    end
    return record
end

function Keys.list()
    local items = {}
    for _, key in ipairs(state.keys) do
        items[#items + 1] = {
            id = key.id,
            name = key.name,
            role = key.role,
            created_at = key.created_at,
            last_used_at = state.lastUsed[key.id],
        }
    end
    return items
end

function Keys.adminCount()
    local count = 0
    for _, key in ipairs(state.keys) do
        if key.role == "admin" then
            count = count + 1
        end
    end
    return count
end

function Keys.find(id)
    for _, key in ipairs(state.keys) do
        if key.id == id then
            return {
                id = key.id,
                name = key.name,
                role = key.role,
                created_at = key.created_at,
                last_used_at = state.lastUsed[key.id],
            }
        end
    end
    return nil
end

-- Changes a key's name and/or role. Returns the updated record, or nil plus an error code.
function Keys.update(id, changes)
    for _, key in ipairs(state.keys) do
        if key.id == id then
            if changes.role and not Roles.valid(changes.role) then
                return nil, "INVALID_ROLE"
            end
            if changes.role and key.role == "admin" and changes.role ~= "admin" and Keys.adminCount() == 1 then
                return nil, "LAST_ADMIN"
            end
            local previous = { name = key.name, role = key.role }
            key.name = changes.name or key.name
            key.role = changes.role or key.role
            if not save() then
                key.name, key.role = previous.name, previous.role
                return nil, "PERSIST_FAILED"
            end
            return Keys.find(id)
        end
    end
    return nil, "NOT_FOUND"
end

function Keys.revoke(id)
    for index, key in ipairs(state.keys) do
        if key.id == id then
            table.remove(state.keys, index)
            state.lastUsed[id] = nil
            save()
            return true
        end
    end
    return false
end

function Keys.revokeAll()
    local count = #state.keys
    state.keys = {}
    state.lastUsed = {}
    save()
    return count
end

return Keys
