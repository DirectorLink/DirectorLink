-- API keys: named bearer secrets. Only a hash of each key is stored, so the controller's storage,
-- or a backup of it, holds nothing that opens the API. Each key also has a lock key for remote
-- access (src/cloud/lock.lua, derived from the key), made when the key is created or, for older
-- keys, the first time the key is used on the home network.

local Json = require("src.core.json")
local Clock = require("src.core.clock")
local Roles = require("src.auth.roles")
local Store = require("src.core.store")
local Lock = require("src.cloud.lock")

local Keys = {}

Keys.MAX_KEYS = 20

local STORE_KEY = "directorlink_api_key_hashes"
-- 0.8.0 and 0.9.0 kept the keys themselves, encrypted, under this name. They are moved to hashes
-- when Director can still read that store, which is then emptied.
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
            lock = key.lock,
            created_at = key.created_at,
        }
    end
    return Store.write(STORE_KEY, { version = 3, keys = records }, false)
end

local function validLock(value)
    return type(value) == "string" and value:match("^%x+$") and #value == 64 and value:lower() or nil
end

-- The lock key of a key (hex), or nil when this controller cannot make one.
local function lockFor(secret)
    local ok, lock = pcall(Lock.deviceKey, secret)
    return ok and lock or nil
end

local function addLoaded(key, hash, alg, lock)
    state.keys[#state.keys + 1] = {
        id = key.id,
        name = tostring(key.name or "API key"),
        -- Keys from before roles existed (0.6 and older) keep full access.
        role = Roles.valid(key.role) and key.role or "admin",
        alg = alg,
        hash = hash,
        lock = validLock(lock),
        created_at = type(key.created_at) == "string" and key.created_at or Clock.iso(),
    }
end

-- Moves keys from the encrypted store of 0.9.0 and older, when Director can still read it.
-- Returns how that store came back.
local function migrate()
    local old, form = Store.read(OLD_STORE_KEY, true)
    for _, key in ipairs(Store.items(old and old.keys)) do
        if type(key) == "table" and type(key.id) == "string" and type(key.secret) == "string" then
            local hash, alg = hashKey(key.secret)
            if hash then
                addLoaded(key, hash, alg, lockFor(key.secret))
            end
        end
    end
    if save() and old then
        Store.write(OLD_STORE_KEY, { version = 2, keys = Json.array() }, true)
    end
    return form
end

-- Returns the number of keys, how the store came back ("json", "table", "missing",
-- "unreadable") and, when it was missing, how the old encrypted store came back.
function Keys.load()
    state.keys = {}
    state.lastUsed = {}

    local stored, form = Store.read(STORE_KEY, false)
    if form == "missing" then
        return #state.keys, form, migrate()
    end
    for _, key in ipairs(Store.items(stored and stored.keys)) do
        if type(key) == "table" and type(key.id) == "string" and type(key.hash) == "string" and algorithmNamed(key.alg) then
            addLoaded(key, key.hash, key.alg, key.lock)
        end
    end
    -- Written by 0.9.1 as plain JSON, which Director hands back decoded: store it as it is now.
    if form == "table" then
        save()
    end
    return #state.keys, form
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
        -- A key from before remote access gets its lock key the first time it is used here.
        if not match.lock then
            match.lock = lockFor(presented)
            if match.lock then
                save()
            end
        end
    end
    return match
end

-- A key for a remote request: { id, name, role, lock }, or nil when unknown or without a lock key.
function Keys.remote(id)
    for _, key in ipairs(state.keys) do
        if key.id == id and key.lock then
            return { id = key.id, name = key.name, role = key.role, lock = key.lock }
        end
    end
    return nil
end

function Keys.touch(id)
    for _, key in ipairs(state.keys) do
        if key.id == id then
            state.lastUsed[id] = Clock.iso()
        end
    end
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
        lock = lockFor(secret),
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
