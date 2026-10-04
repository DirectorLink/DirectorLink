-- Ask to open (ADR-058, docs/SCENES.md, src/core/ask_links.lua): a private link, bound to one door or
-- gate and to the key (and so the person) that made it, for the phone's own automations. Its run
-- opens nothing: the controller asks that person's devices, by a sealed alert (ADR-050), whether to
-- open the door, and answers the phone `asked`. Tapping the alert opens the app's confirm screen,
-- whose Open is an ordinary pulse with that device's own key and the request's id
-- (POST /v1/relays/{id}/pulse {"request"}), checked as any opening, while the request lasts, once.
-- Made by someone who may open the door, with Door Control on; a person sees their own links, an
-- admin everyone's.
--   GET    /v1/ask-links             the links this key's person made (admins: every link)
--   POST   /v1/ask-links             {"relay_id", "label"}: a new link, replacing this key's for
--                                    that door; its secret once
--   DELETE /v1/ask-links/{linkId}    removes one (its person's, or any for admins)

local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Problem = require("src.api.problem")
local Validate = require("src.api.validate")
local AskLinks = require("src.core.ask_links")
local SceneLinks = require("src.core.scene_links")
local Activity = require("src.core.activity")
local Access = require("src.auth.access")
local Keys = require("src.auth.keys")
local Alerts = require("src.cloud.alerts")
local Relay = require("src.cloud.relay")
local Registry = require("src.core.registry")

local Handlers = {}

-- Refused runs are logged at most this often, as for scene links.
Handlers.REFUSAL_LOG_SECONDS = 60

local refusals = { loggedAt = nil, count = 0 }

local function nullable(value)
    if value == nil then
        return Json.null
    end
    return value
end

-- The home id links are made for: the identity the relay has accepted, else nil.
local function linkedHome()
    local identity = Relay.storedIdentity()
    return identity and identity.linked and identity.home_id or nil
end

-- The address a phone calls, as a scene link's (with the secret after "#" for a browser).
function Handlers.url(home, linkId, secret)
    return "https://" .. Relay.HOST .. "/run/" .. home .. "." .. linkId .. (secret and ("#" .. secret) or "")
end

local function relayOf(registry, id)
    local device = registry and registry.getDevice(id)
    if device and device.kind == "relay" and device.supported == true then
        return device
    end
    return nil
end

-- The keys as actors for Access: id -> { id, name, role, profile }.
local function keyMap()
    local keys = {}
    for _, key in ipairs(Keys.list()) do
        keys[key.id] = key
    end
    return keys
end

-- The person a key belongs to: its profile, or the key itself when it has none.
local function personOf(key)
    return key and (key.profile or ("key:" .. key.id)) or nil
end

local function samePerson(a, b)
    return a ~= nil and b ~= nil and (a.id == b.id or (a.profile ~= nil and a.profile == b.profile))
end

local function view(services, link, keys, caller)
    local relay = relayOf(services.registry, link.relay_id)
    local maker = keys[link.by]
    local profile = maker and maker.profile and services.profiles and services.profiles.find(maker.profile)
    return {
        link_id = link.id,
        relay_id = link.relay_id,
        relay_name = relay and relay.name or Json.null,
        room_id = relay and tonumber(relay.room_id) or Json.null,
        label = nullable(link.label),
        made_by = link.by,
        -- The person it asks: the key's.
        person = profile and profile.name or Json.null,
        -- Made on the device asking (its key).
        this_device = caller ~= nil and link.by == caller.id,
        created_at = link.created_at,
        last_used_at = nullable(link.last_used_at),
    }
end

local function unreadable()
    return Problem.new(503, "UNAVAILABLE", "The saved ask-to-open links could not be read when DirectorLink started; restart the driver and try again")
end

-- Links made for another home than the one the relay knows, whose key is gone (revoked or
-- expired), whose person may no longer open the door, or whose door is gone, go: at start, after a
-- restore, when keys change (src/api/handlers/scene_links.lua's prune), before a list and when one
-- is refused. A door is gone only once the project was read (at start nothing is).
function Handlers.prune(services)
    if AskLinks.count() == 0 or not AskLinks.complete() then
        return {}
    end
    local registry = services and services.registry or Registry
    local home = linkedHome()
    local complete = Keys.complete()
    local keys = complete and keyMap() or nil
    local projectRead = next(registry.devices or {}) ~= nil
    local removed = AskLinks.prune(function(link)
        if home and link.home ~= home then
            return "other_home"
        elseif keys and not keys[link.by] then
            return "key_gone"
        end
        local relay = relayOf(registry, link.relay_id)
        if not relay then
            return projectRead and "door_gone" or nil
        elseif keys and not Access.canOpen(keys[link.by], relay) then
            return "no_access"
        end
        return nil
    end)
    for _, link in ipairs(removed) do
        local relay = relayOf(registry, link.relay_id)
        Log.info("doors", "ask-to-open link removed", { link_id = link.id, relay_id = link.relay_id, reason = link.reason })
        Activity.record("access", "ask_link_removed", {
            what = relay and relay.name or nil,
            room = relay and relay.room_name or nil,
            reason = link.reason,
            note = link.label,
            ids = { device_id = link.relay_id, room_id = relay and relay.room_id or nil, link_id = link.id },
        })
    end
    return removed
end

function Handlers.list(ctx)
    Handlers.prune(ctx.services)
    local keys = keyMap()
    local caller = keys[ctx.apiKey.id] or ctx.apiKey
    local admin = Access.isAdmin(ctx.apiKey)
    local items = Json.array()
    for _, link in ipairs(AskLinks.list()) do
        if admin or samePerson(keys[link.by], caller) then
            items[#items + 1] = view(ctx.services, link, keys, ctx.apiKey)
        end
    end
    return 200, {
        items = items,
        -- What a link needs to work: Remote Access on, a home the relay has accepted, and Door
        -- Control on. The app says so when one is missing.
        remote_access = ctx.services.remote.enabled(),
        home_linked = linkedHome() ~= nil,
        door_control = ctx.services.doorControlEnabled(),
    }
end

-- POST {"relay_id": 70, "label": "Arriving home"}: a new link for that door, made by this key; the
-- one it had for that door stops working at once.
function Handlers.create(ctx)
    local body = ctx.body or {}
    local problem = Validate.body(body, { relay_id = true, label = true }, true)
    if problem then
        return problem
    end
    if type(body.relay_id) ~= "number" or body.relay_id < 1 or body.relay_id ~= math.floor(body.relay_id) then
        return Problem.invalidField("relay_id", "relay_id must be the id of a door or gate")
    end
    local label = nil
    if body.label ~= nil and body.label ~= Json.null and not (type(body.label) == "string" and body.label:match("^%s*$")) then
        label, problem = Validate.name(body.label, "label")
        if problem then
            return problem
        end
    end
    local relay = relayOf(ctx.services.registry, body.relay_id)
    if not relay or not Access.canSee(ctx.apiKey, relay) then
        return Problem.notFound("Relay", body.relay_id)
    end
    -- Only someone who may open the door may have it asked about.
    if not Access.canOpen(ctx.apiKey, relay) then
        return Problem.new(403, "FORBIDDEN", "This key may not open this door or gate")
    end
    if not ctx.services.doorControlEnabled() then
        return Problem.new(403, "DOOR_CONTROL_DISABLED", "Door control is off; turn on the Door Control property of DirectorLink in Composer")
    end
    if not ctx.services.remote.enabled() then
        return Problem.new(409, "REMOTE_ACCESS_OFF", "A link reaches the home through remote access: turn on Remote Access in Composer first")
    end
    local home = linkedHome()
    if not home then
        return Problem.new(409, "HOME_NOT_LINKED", "DirectorLink's servers have not accepted this home yet: link it to your account first")
    end
    if not AskLinks.complete() then
        return unreadable()
    end
    local link, secret, replaced = AskLinks.create(relay.id, label, home, ctx.apiKey.id, function(id)
        for _, other in ipairs(SceneLinks.list()) do
            if other.id == id then
                return true
            end
        end
        return false
    end)
    if not link then
        if secret == "LIMIT_REACHED" then
            return Problem.new(409, "ASK_LINK_LIMIT_REACHED", "This home has as many ask-to-open links as it can keep (" .. AskLinks.MAX_LINKS .. "); remove one first")
        end
        return Problem.internal("The link could not be made (" .. tostring(secret) .. ")")
    end
    ctx.services.log.info("doors", replaced and "ask-to-open link replaced" or "ask-to-open link made", { relay_id = relay.id, link_id = link.id, by = ctx.apiKey.id })
    Activity.record("access", replaced and "ask_link_replaced" or "ask_link_created", {
        by = ctx.apiKey,
        what = relay.name,
        room = relay.room_name,
        note = label,
        ids = { device_id = relay.id, room_id = relay.room_id, link_id = link.id },
    })
    local answer = view(ctx.services, link, keyMap(), ctx.apiKey)
    answer.home_id = home
    answer.secret = secret
    answer.url = Handlers.url(home, link.id, secret)
    answer.replaced = replaced ~= nil
    return 201, answer
end

function Handlers.delete(ctx)
    local id = tostring(ctx.params.linkId or "")
    if #id ~= AskLinks.ID_LENGTH or not id:match("^[0-9a-f]+$") then
        return Problem.invalidParameter("linkId", "linkId is 8 hex characters")
    end
    local link = AskLinks.find(id)
    local keys = keyMap()
    -- Another person's link is not there for a key that is not an admin's.
    if not link or not (Access.isAdmin(ctx.apiKey) or samePerson(keys[link.by], keys[ctx.apiKey.id] or ctx.apiKey)) then
        return Problem.notFound("Ask-to-open link", id)
    end
    local removed, failure = AskLinks.remove(id)
    if not removed then
        if failure == "STORE_UNREADABLE" then
            return unreadable()
        elseif failure == "NOT_FOUND" then
            return Problem.notFound("Ask-to-open link", id)
        end
        return Problem.internal("The link could not be removed")
    end
    local relay = relayOf(ctx.services.registry, removed.relay_id)
    ctx.services.log.info("doors", "ask-to-open link removed", { link_id = id, by = ctx.apiKey.id })
    Activity.record("access", "ask_link_removed", {
        by = ctx.apiKey,
        what = relay and relay.name or nil,
        room = relay and relay.room_name or nil,
        note = removed.label,
        ids = { device_id = removed.relay_id, room_id = relay and relay.room_id or nil, link_id = id },
    })
    return 204
end

-- ---- the run ------------------------------------------------------------------------------------

local function refused(services, why, linkId)
    local now = os.time()
    refusals.count = refusals.count + 1
    if refusals.loggedAt and now - refusals.loggedAt < Handlers.REFUSAL_LOG_SECONDS and now >= refusals.loggedAt then
        return
    end
    services.log.warn("doors", "refused an ask-to-open link run", { why = why, link_id = linkId, refusals = refusals.count })
    refusals.loggedAt, refusals.count = now, 0
end

-- History: the link asked to open the door (`count` devices), or why nobody was asked.
local function noteAsked(link, relay, count, reason)
    Activity.record("door", "asked", {
        who = { type = "link", link_id = link.id, name = link.label },
        what = relay.name,
        room = relay.room_name,
        count = count,
        reason = reason,
        outcome = reason and "skipped" or nil,
        ids = { device_id = relay.id, room_id = relay.room_id, link_id = link.id },
    })
end

-- A run from the account service (`link`, docs/RELAY.md) whose link is an ask-to-open link: answered
-- here, and true; false for a link that is not one (the scene links' handler answers NOT_FOUND).
-- Answers {"type":"link_result","ok":true,"result":…}: `asked` (the person's devices were asked),
-- `waiting` (a request for this door and person waits for an answer: nothing new is sent), `nobody`
-- (no device of the person that may open the door has alerts on), `doors_off` (Door Control is off
-- in Composer), `not_asked` (the alert could not be sent now); or "ok":false with NOT_FOUND (also a
-- link whose key, door or permission is gone) or RATE_LIMITED. Nothing is ever opened here.
function Handlers.relayRun(services, message, send)
    local linkId = type(message.link) == "string" and #message.link == AskLinks.ID_LENGTH and message.link:match("^[0-9a-f]+$") and message.link or nil
    local link = linkId and AskLinks.check(linkId, message.secret) or nil
    if not link then
        return false
    end
    local function answer(fields)
        fields.type = "link_result"
        fields.id = message.id
        send(fields)
        return true
    end
    local allowed, wait = AskLinks.allow(link.id)
    if not allowed then
        refused(services, "too many runs", link.id)
        return answer({ ok = false, code = "RATE_LIMITED", retry_s = wait })
    end
    local keys = Keys.complete() and keyMap() or nil
    local maker = keys and keys[link.by]
    local relay = relayOf(services.registry, link.relay_id)
    -- Checked again at every run: the key may have gone a moment ago, its person may have lost the
    -- door (or its room), the door may be gone, the home's identity may have changed.
    if not maker or not relay or link.home ~= linkedHome() or not Access.canOpen(maker, relay) then
        Handlers.prune(services)
        refused(services, "the key, the door or the permission is gone", link.id)
        return answer({ ok = false, code = "NOT_FOUND" })
    end
    local now = Clock.now()
    local person = personOf(maker)
    if AskLinks.waiting(relay.id, person, now) then
        AskLinks.used(link.id, now)
        return answer({ ok = true, result = "waiting" })
    end
    local may, hour = AskLinks.mayAsk(link.id, now)
    if not may then
        refused(services, "asked too often this hour", link.id)
        return answer({ ok = false, code = "RATE_LIMITED", retry_s = hour })
    end
    AskLinks.counted(link.id, now)
    AskLinks.used(link.id, now)
    if not services.doorControlEnabled() then
        noteAsked(link, relay, 0, "doors_off")
        return answer({ ok = true, result = "doors_off" })
    end
    -- The person's devices that may open this door; the alerts module keeps those with alerts on.
    local recipients = {}
    for id, key in pairs(keys) do
        if samePerson(key, maker) and Access.canOpen(key, relay) then
            recipients[id] = true
        end
    end
    local request = AskLinks.ask(link, relay.id, person, now)
    if not request then
        noteAsked(link, relay, 0, "not_sent")
        return answer({ ok = true, result = "not_asked" })
    end
    local ok, count, ids = pcall(Alerts.openRequest, relay, request, recipients, now)
    if not ok then
        services.log.warn("doors", "open request failed", { error = tostring(count), link_id = link.id })
        count, ids = nil, "error"
    end
    if count and count > 0 then
        AskLinks.sentTo(request.id, ids)
        noteAsked(link, relay, count, nil)
        services.log.info("doors", "asked to open by its link", { link_id = link.id, relay_id = relay.id, devices = count })
        return answer({ ok = true, result = "asked" })
    end
    AskLinks.drop(request.id)
    if count == 0 then
        noteAsked(link, relay, 0, "nobody")
        return answer({ ok = true, result = "nobody" })
    end
    noteAsked(link, relay, 0, "not_sent")
    return answer({ ok = true, result = "not_asked" })
end

-- ---- the answer -------------------------------------------------------------------------------

-- POST /v1/relays/{id}/pulse with {"request": "<id>"} (src/api/handlers/relays.lua): the device
-- answers a request it was sent. Returns what the pulse needs ({ link_id, note, done() }), or nil
-- and a problem: an unknown or expired request, one for another door or another device
-- (OPEN_REQUEST_EXPIRED), one answered already (OPEN_REQUEST_ANSWERED), or a key that may not open
-- the door. Door Control and the pulse itself are the pulse's own checks, as for any opening.
function Handlers.claim(ctx, device, requestId)
    if type(requestId) ~= "string" or #requestId ~= AskLinks.REQUEST_LENGTH or not requestId:match("^[0-9a-f]+$") then
        return nil, Problem.invalidField("request", "request is the 16 hex digits of an open request")
    end
    if not Access.canOpen(ctx.apiKey, device) then
        return nil, Problem.new(403, "FORBIDDEN", "This key may not open this door or gate")
    end
    local request, failure = AskLinks.request(requestId)
    if not request and failure == "ANSWERED" then
        return nil, Problem.new(409, "OPEN_REQUEST_ANSWERED", "This request was answered already: the door was opened")
    end
    if not request or request.relay_id ~= tonumber(device.id) or not request.keys[ctx.apiKey.id] then
        return nil, Problem.new(409, "OPEN_REQUEST_EXPIRED", "This request is over: it lasts " .. AskLinks.OPEN_SECONDS .. " seconds, for the door and the devices it was sent to")
    end
    return {
        link_id = request.link_id,
        note = request.label,
        done = function()
            AskLinks.answered(request.id)
        end,
    }
end

-- Test support.
function Handlers.reset()
    refusals.loggedAt, refusals.count = nil, 0
end

return Handlers
