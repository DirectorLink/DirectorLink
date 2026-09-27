-- API keys: named bearer secrets. Only a hash of each key is stored, in plain driver persistence:
-- Director drops encrypted values when the driver is updated (it logs "has no driverKey"), and a
-- hash of a random key is useless to anyone who reads the controller's storage or a backup.

local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Roles = require("src.auth.roles")

local Keys = {}

Keys.MAX_KEYS = 20

local STORE_KEY = "directorlink_api_key_hashes"
-- Up to 0.9.0 the keys themselves were kept encrypted under this name. They are moved to hashes
-- if that store can still be read, and it is emptied either way.
local OLD_STORE_KEY = "directorlink_api_keys"
-- Keys are "ak_" plus 48 hex digits; anything much longer is not worth hashing.
local MAX_PRESENTED_LENGTH = 128
-- Strongest first. Each key keeps the algorithm it was hashed with.
local ALGORITHMS = {
    { name = "sha256", c4 = "SHA256", length = 64 },
    { name = "sha1", c4 = "SHA1", length = 40 },
}

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

local function algorithmNamed(name)
    for _, algorithm in ipairs(ALGORITHMS) do
        if algorithm.name == name then
            return algorithm
        end
    end
    return nil
end

local function digest(algorithm, text)
    local ok, hash = pcall(function()
        return C4:Hash(algorithm.c4, text, { return_encoding = "HEX" })
    end)
    if ok and type(hash) == "string" and #hash == algorithm.length then
        return hash:lower()
    end
    return nil
end

-- Hashes a key with the strongest algorithm this controller offers.
local function hashKey(secret)
    for _, algorithm in ipairs(ALGORITHMS) do
        local hash = digest(algorithm, secret)
        if hash then
            return hash, algorithm.name
        end
    end
    return nil
end

local function save()
    local records = Json.array()
    for _, key in ipairs(state.keys) do
        records[#records + 1] = {
            id = key.id,
            name = key.name,
            role = key.role,
            alg = key.alg,
            hash = key.hash,
            created_at = key.created_at,
        }
    end
    return pcall(function()
        C4:PersistSetValue(STORE_KEY, Json.encode({ version = 3, keys = records }), false)
    end)
end

local function readStore(name, encrypted)
    local ok, raw = pcall(function()
        return C4:PersistGetValue(name, encrypted)
    end)
    if ok and type(raw) == "string" and raw ~= "" then
        local data = Json.decode(raw)
        if type(data) == "table" and type(data.keys) == "table" then
            return data.keys
        end
    end
    return nil
end

local function addLoaded(key, hash, alg)
    state.keys[#state.keys + 1] = {
        id = key.id,
        name = tostring(key.name or "API key"),
        -- Keys from before roles existed (0.6 and older) keep full access.
        role = Roles.valid(key.role) and key.role or "admin",
        alg = alg,
        hash = hash,
        created_at = type(key.created_at) == "string" and key.created_at or Clock.iso(),
    }
end

-- Moves keys from the encrypted store of 0.9.0 and older, when Director can still read it.
local function migrate()
    for _, key in ipairs(readStore(OLD_STORE_KEY, true) or {}) do
        if type(key) == "table" and type(key.id) == "string" and type(key.secret) == "string" then
            local hash, alg = hashKey(key.secret)
            if hash then
                addLoaded(key, hash, alg)
            end
        end
    end
    if save() then
        pcall(function()
            C4:PersistSetValue(OLD_STORE_KEY, "", true)
        end)
    end
end

function Keys.load()
    state.keys = {}
    state.lastUsed = {}

    local stored = readStore(STORE_KEY, false)
    if not stored then
        migrate()
        return #state.keys
    end
    for _, key in ipairs(stored) do
        if type(key) == "table" and type(key.id) == "string" and type(key.hash) == "string" and algorithmNamed(key.alg) then
            addLoaded(key, key.hash, key.alg)
        end
    end
    return #state.keys
end

function Keys.count()
    return #state.keys
end

-- Returns the key record for a presented secret, or nil.
function Keys.verify(presented)
    if type(presented) ~= "string" or presented == "" or #presented > MAX_PRESENTED_LENGTH then
        return nil
    end
    local hashes = {}
    local match
    for _, key in ipairs(state.keys) do
        if hashes[key.alg] == nil then
            hashes[key.alg] = digest(algorithmNamed(key.alg), presented) or false
        end
        if hashes[key.alg] and constantTimeEqual(hashes[key.alg], key.hash) then
            match = key
        end
    end
    if match then
        state.lastUsed[match.id] = Clock.iso()
    end
    return match
end

-- Returns the new record (including its secret, which is not kept), or nil plus an error code.
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

    local secret = "ak_" .. secretA .. secretB:sub(1, 16)
    local hash, alg = hashKey(secret)
    if not hash then
        return nil, "HASH_UNAVAILABLE"
    end

    local record = {
        id = id,
        name = name,
        role = role,
        alg = alg,
        hash = hash,
        created_at = Clock.iso(),
    }
    table.insert(state.keys, record)

    if not save() then
        table.remove(state.keys)
        return nil, "PERSIST_FAILED"
    end
    return {
        id = record.id,
        name = record.name,
        role = record.role,
        created_at = record.created_at,
        secret = secret,
    }
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
