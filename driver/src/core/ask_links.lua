-- Ask to open (ADR-058, docs/SCENES.md): a private link like a scene's (ADR-051) that opens nothing.
-- A phone's automation runs it (iPhone Shortcuts when arriving, Siri, an Android app); the
-- controller then asks the person who made it, by an alert sealed to their own devices (ADR-050),
-- whether to open one door or gate. Only their answer, from one of those devices with its own key and
-- checked as any opening, opens it (src/api/handlers/ask_links.lua). A leaked link can only make the
-- owner's phone ask.
-- One link per door and key. The controller keeps only a hash of its secret (as for scene links and
-- API keys, ADR-028), the home id the address names, the door and the key that made it: the person
-- asked is that key's, and the link goes with the key. Kept apart from the scene links
-- (directorlink_ask_links): DirectorLink 1.7.0 never reads it, so going back and forth loses
-- nothing.
-- A run makes a request: in memory only, for OPEN_SECONDS, answered once, at most one at a time for
-- a door and person, and at most REQUESTS_PER_HOUR a link.

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Random = require("src.core.random")
local Store = require("src.core.store")
local SceneLinks = require("src.core.scene_links")

local AskLinks = {}

local STORE_KEY = "directorlink_ask_links"
AskLinks.STORE_VERSION = 1
AskLinks.ID_LENGTH = SceneLinks.ID_LENGTH
-- At most this many ask links in all (one per door and key).
AskLinks.MAX_LINKS = 50
-- Runs of one link: as a scene link's (6 a minute).
AskLinks.RUNS_PER_WINDOW = SceneLinks.RUNS_PER_WINDOW
AskLinks.WINDOW_SECONDS = SceneLinks.WINDOW_SECONDS
-- How long a request may be answered, and how many runs a link may make that ask (or say why
-- nobody was asked) in an hour: a leaked link can make the owner's phone ask at most that often, and
-- takes at most that many of the home's alerts and History entries.
AskLinks.OPEN_SECONDS = 120
AskLinks.REQUESTS_PER_HOUR = 10
-- A request's id: 16 hex digits (64 bits), in the sealed alert only.
AskLinks.REQUEST_LENGTH = 16

local HOUR = 3600

-- `complete` is false after the stored links could not be read: saving then would lose them.
-- `runs`: link id -> the times its last runs went through; `asked`: link id -> the times it made a
-- request in the last hour; `requests`: request id -> { id, link_id, relay_id, person, keys, label,
-- at, expires, answered } (all memory only).
local state = { links = {}, complete = true, runs = {}, asked = {}, requests = {} }

local function isLowerHex(value, length)
    return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function readLink(item)
    if type(item) ~= "table" or not isLowerHex(item.id, AskLinks.ID_LENGTH) or type(item.relay_id) ~= "number" then
        return nil
    end
    if not SceneLinks.validHash(item.alg, item.hash) or not isLowerHex(item.home, 32) or not isLowerHex(item.by, 8) then
        return nil
    end
    return {
        id = item.id,
        relay_id = item.relay_id,
        label = type(item.label) == "string" and item.label ~= "" and item.label:sub(1, 256) or nil,
        alg = item.alg,
        hash = item.hash,
        home = item.home,
        by = item.by,
        created_at = type(item.created_at) == "string" and item.created_at or Clock.iso(),
        last_used_at = type(item.last_used_at) == "string" and item.last_used_at or nil,
    }
end

local function record(link)
    return {
        id = link.id,
        relay_id = link.relay_id,
        label = link.label,
        alg = link.alg,
        hash = link.hash,
        home = link.home,
        by = link.by,
        created_at = link.created_at,
        last_used_at = link.last_used_at,
    }
end

-- What the API shows of a link: never its hash.
local function view(link)
    return {
        id = link.id,
        relay_id = link.relay_id,
        label = link.label,
        home = link.home,
        by = link.by,
        created_at = link.created_at,
        last_used_at = link.last_used_at,
    }
end

local function save()
    local records = Json.array()
    for _, link in ipairs(state.links) do
        records[#records + 1] = record(link)
    end
    local ok = Store.write(STORE_KEY, { version = AskLinks.STORE_VERSION, links = records }, false)
    if ok then
        state.complete = true
    else
        Log.error("doors", "could not save the ask-to-open links")
    end
    return ok
end

local function forget(linkId)
    state.runs[linkId], state.asked[linkId] = nil, nil
    for id, request in pairs(state.requests) do
        if request.link_id == linkId then
            state.requests[id] = nil
        end
    end
end

-- Returns how many links there are and how the store came back ("json", "missing", "unreadable").
function AskLinks.load()
    local data, form = Store.read(STORE_KEY, false)
    state.complete = form ~= "unreadable"
    state.runs, state.asked, state.requests = {}, {}, {}
    state.links = {}
    local ids, dropped = {}, 0
    for _, item in ipairs(Store.items(type(data) == "table" and data.links or nil)) do
        local link = readLink(item)
        if link and not ids[link.id] then
            ids[link.id] = true
            state.links[#state.links + 1] = link
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        Log.warn("doors", "stored ask-to-open links that are not valid were left out", { links = dropped })
    end
    return #state.links, form
end

function AskLinks.complete()
    return state.complete
end

function AskLinks.list()
    local items = {}
    for _, link in ipairs(state.links) do
        items[#items + 1] = view(link)
    end
    return items
end

function AskLinks.count()
    return #state.links
end

function AskLinks.find(linkId)
    for _, link in ipairs(state.links) do
        if link.id == linkId then
            return view(link)
        end
    end
    return nil
end

-- The link the key `keyId` made for the door `relayId`, or nil.
function AskLinks.forDoor(relayId, keyId)
    for _, link in ipairs(state.links) do
        if link.relay_id == relayId and link.by == keyId then
            return view(link)
        end
    end
    return nil
end

-- A new link for the door `relayId`, made for the home `home` by the key `by`, with an optional
-- `label`. It replaces the link that key had for that door, which stops working at once. `taken(id)`:
-- true for an id a scene link has (a run finds a link by its id). Returns the link (as the API shows
-- it), its secret (never kept) and the link it replaced, or nil and a code.
function AskLinks.create(relayId, label, home, by, taken)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    local replaced
    for _, link in ipairs(state.links) do
        if link.relay_id == relayId and link.by == by then
            replaced = view(link)
        end
    end
    if not replaced and #state.links >= AskLinks.MAX_LINKS then
        return nil, "LIMIT_REACHED"
    end
    local ok, idSource, secret = pcall(function()
        return Random.hex(32), Random.hex(SceneLinks.SECRET_LENGTH)
    end)
    if not ok then
        return nil, "RANDOM_UNAVAILABLE"
    end
    local hash, alg = SceneLinks.hashSecret(secret)
    if not hash then
        return nil, "HASH_UNAVAILABLE"
    end
    local used = {}
    for _, link in ipairs(state.links) do
        used[link.id] = true
    end
    local id
    for start = 1, #idSource - AskLinks.ID_LENGTH + 1, AskLinks.ID_LENGTH do
        local candidate = idSource:sub(start, start + AskLinks.ID_LENGTH - 1)
        if not used[candidate] and not (taken and taken(candidate)) then
            id = candidate
            break
        end
    end
    if not id then
        return nil, "RANDOM_UNAVAILABLE"
    end
    local link = { id = id, relay_id = relayId, label = label, alg = alg, hash = hash, home = home, by = by, created_at = Clock.iso() }
    local before = state.links
    local links = {}
    for _, other in ipairs(before) do
        if not (replaced and other.id == replaced.id) then
            links[#links + 1] = other
        end
    end
    links[#links + 1] = link
    state.links = links
    if not save() then
        state.links = before
        return nil, "PERSIST_FAILED"
    end
    if replaced then
        forget(replaced.id)
    end
    return view(link), secret, replaced
end

-- Removes the links for which `drop(link)` is true. Returns the removed links (as the API shows
-- them), or nil when they could not be saved (then they stay).
local function removeWhere(drop)
    local kept, removed = {}, {}
    for _, link in ipairs(state.links) do
        if drop(link) then
            removed[#removed + 1] = view(link)
        else
            kept[#kept + 1] = link
        end
    end
    if #removed == 0 then
        return removed
    end
    local before = state.links
    state.links = kept
    if not save() then
        state.links = before
        return nil
    end
    for _, link in ipairs(removed) do
        forget(link.id)
    end
    return removed
end

-- Removes one link. Returns it, or nil and a code (NOT_FOUND, STORE_UNREADABLE, PERSIST_FAILED).
function AskLinks.remove(linkId)
    if not state.complete then
        return nil, "STORE_UNREADABLE"
    end
    if not AskLinks.find(linkId) then
        return nil, "NOT_FOUND"
    end
    local removed = removeWhere(function(link)
        return link.id == linkId
    end)
    if not removed then
        return nil, "PERSIST_FAILED"
    end
    return removed[1]
end

-- Every link goes (Remove All Scene Links, Revoke All API Keys, a new remote identity). Returns how
-- many there were and whether that was saved: when it could not be, they stay.
function AskLinks.removeAll()
    local count, links = #state.links, state.links
    state.links = {}
    if not save() then
        state.links = links
        return count, false
    end
    state.runs, state.asked, state.requests = {}, {}, {}
    return count, true
end

-- The links for which `why(link)` gives a reason go (the key that made it is gone, its person may
-- no longer open the door, another home, the door is gone). Returns them, each with `reason`.
function AskLinks.prune(why)
    if not state.complete or #state.links == 0 then
        return {}
    end
    local reasons = {}
    local removed = removeWhere(function(link)
        reasons[link.id] = why(view(link))
        return reasons[link.id] ~= nil
    end) or {}
    for _, link in ipairs(removed) do
        link.reason = reasons[link.id]
    end
    return removed
end

-- The link with this id when `secret` is its secret, or nil: an unknown link and a wrong secret look
-- the same.
function AskLinks.check(linkId, secret)
    local found
    for _, link in ipairs(state.links) do
        if link.id == linkId then
            found = link
        end
    end
    if SceneLinks.secretMatches(found and found.alg, found and found.hash, secret) and found then
        return view(found)
    end
    return nil
end

-- Times of `list` within `seconds` before `now`.
local function within(list, seconds, now)
    local kept = {}
    for _, at in ipairs(list or {}) do
        if now - at < seconds and at <= now then
            kept[#kept + 1] = at
        end
    end
    return kept
end

-- Whether another run of this link may go through now (as a scene link's: RUNS_PER_WINDOW a
-- window); if not, also how many seconds until one may.
function AskLinks.allow(linkId, now)
    now = now or Clock.now()
    local kept = within(state.runs[linkId], AskLinks.WINDOW_SECONDS, now)
    if #kept >= AskLinks.RUNS_PER_WINDOW then
        state.runs[linkId] = kept
        return false, math.max(1, AskLinks.WINDOW_SECONDS - (now - kept[1]))
    end
    kept[#kept + 1] = now
    state.runs[linkId] = kept
    return true
end

-- Whether this link may ask (or say why nobody was asked) once more this hour; if not, how many
-- seconds until it may. Counted by AskLinks.counted.
function AskLinks.mayAsk(linkId, now)
    now = now or Clock.now()
    local kept = within(state.asked[linkId], HOUR, now)
    state.asked[linkId] = kept
    if #kept >= AskLinks.REQUESTS_PER_HOUR then
        return false, math.max(1, HOUR - (now - kept[1]))
    end
    return true
end

function AskLinks.counted(linkId, now)
    local list = state.asked[linkId] or {}
    list[#list + 1] = now or Clock.now()
    state.asked[linkId] = list
end

-- The link ran now: when it was last used, for the app's list.
function AskLinks.used(linkId, now)
    for _, link in ipairs(state.links) do
        if link.id == linkId then
            link.last_used_at = Clock.iso(now)
            save()
        end
    end
end

-- ---- requests ---------------------------------------------------------------------------------

local function expireRequests(now)
    for id, request in pairs(state.requests) do
        if now >= request.expires or now < request.at then
            state.requests[id] = nil
        end
    end
end

-- The request still waiting for an answer about the door `relayId` for the person `person`, or nil.
function AskLinks.waiting(relayId, person, now)
    now = now or Clock.now()
    expireRequests(now)
    for _, request in pairs(state.requests) do
        if request.relay_id == relayId and request.person == person and not request.answered then
            return request
        end
    end
    return nil
end

-- A new request for the link `link` to open the door `relayId`, for the person `person` (a profile
-- id, or the key's own id when it has none). Returns it, or nil when no id could be made.
function AskLinks.ask(link, relayId, person, now)
    now = now or Clock.now()
    expireRequests(now)
    local ok, id = pcall(Random.hex, AskLinks.REQUEST_LENGTH)
    if not ok or not isLowerHex(id, AskLinks.REQUEST_LENGTH) or state.requests[id] then
        return nil
    end
    local request = {
        id = id,
        link_id = link.id,
        label = link.label,
        relay_id = relayId,
        person = person,
        keys = {},
        at = now,
        expires = now + AskLinks.OPEN_SECONDS,
        seconds = AskLinks.OPEN_SECONDS,
    }
    state.requests[id] = request
    return request
end

-- The keys the request went to: only their devices may answer it.
function AskLinks.sentTo(requestId, keyIds)
    local request = state.requests[requestId]
    if request then
        for id in pairs(keyIds or {}) do
            request.keys[id] = true
        end
    end
end

-- Nobody was asked: the request goes.
function AskLinks.drop(requestId)
    state.requests[requestId] = nil
end

-- The request with this id while it may be answered, or nil and EXPIRED (unknown, or its time is
-- over) or ANSWERED.
function AskLinks.request(requestId, now)
    now = now or Clock.now()
    expireRequests(now)
    local request = type(requestId) == "string" and state.requests[requestId] or nil
    if not request then
        return nil, "EXPIRED"
    end
    if request.answered then
        return nil, "ANSWERED"
    end
    return request
end

-- The request was answered: the door was opened with it. It can be used no more.
function AskLinks.answered(requestId)
    local request = state.requests[requestId]
    if request then
        request.answered = true
    end
end

-- Test support: what a fresh start has.
function AskLinks.reset()
    state.links, state.complete, state.runs, state.asked, state.requests = {}, true, {}, {}, {}
end

return AskLinks
