-- Requests the relay may send again (1.10.0, ADR-072, docs/RELAY.md "While the driver
-- reconnects"). The home's internet provider moves its route to Cloudflare now and then, which
-- cuts the relay connection without a close; a request already on its way is then lost. The relay
-- keeps such a request and sends it again, the same frame with the same id, once this driver says
-- hello on its next connection. Each request still runs at most once: the driver remembers, by
-- the relay's id, every request it got, and once it is answered its answer, and gives that answer
-- again instead of running the request a second time.
--
--   a request it has the answer of      the same answer again; nothing runs
--   a request still running              nothing now: its answer goes on the connection there is
--                                        when it is done (Relay's send writes to the current one)
--   a request done, answer not kept      ANSWER_NOT_KEPT (too large to keep, a picture, or over
--                                        the budget); the relay answers 502 HOME_DISCONNECTED
--   a request it never got               it runs, as any request
--
-- Memory only: a driver that restarts remembers nothing, so the relay sends again only to the
-- driver instance the request went to (the hello's `instance`, src/cloud/relay.lua).

local Json = require("src.core.json")

local Answers = {}

-- What the relay may send again, and the type of each one's answer.
Answers.TYPES = { e2e = "e2e", join = "join_result", claim = "claim_result", link = "link_result" }
-- How long a request is remembered. The relay sends one again only within 10 s of getting it.
Answers.SECONDS = 120
-- How long after it came a request may still come again: the relay sends it again only within 10 s
-- of getting it (docs/RELAY.md); 30 s leaves room. An answer older than that is never asked for
-- again, and a request forgotten older than that never comes again.
Answers.RESEND_SECONDS = 30
-- Requests remembered at most (their ids, about 350 bytes each with their entry), and answers kept
-- at most, in number and in bytes together. An answer larger than MAX_ANSWER_BYTES (a camera
-- picture, a long list) is not kept: the request is remembered as done. A command answers in well
-- under 2 KB.
Answers.MAX_REQUESTS = 512
Answers.MAX_ANSWERS = 64
Answers.MAX_BYTES = 512 * 1024
Answers.MAX_ANSWER_BYTES = 16 * 1024
-- Seconds as this module counts them: Relay's keep-alive ticks (every 5 s while connected), not the
-- clock, as its silence rule counts. No clock change, forward, back or back and forth, can make a
-- request be forgotten early; while the connection is down, nothing is forgotten.
Answers.TICK_SECONDS = 5
Answers.NOT_KEPT = "ANSWER_NOT_KEPT"

local state = {
    byId = {}, -- relay id -> { id, at, done, answer }
    order = {}, -- the same entries, oldest first
    answers = 0,
    bytes = 0,
    elapsed = 0, -- keep-alive ticks, in seconds
    forgotAt = nil, -- when the newest request forgotten before SECONDS (to stay within MAX_REQUESTS) came
}

local function dropAnswer(entry)
    if entry.answer then
        state.answers = state.answers - 1
        state.bytes = state.bytes - #entry.answer
        entry.answer = nil
    end
end

-- Forgets what is older than SECONDS, and the oldest beyond MAX_REQUESTS.
local function prune(at)
    while #state.order > 0 do
        local oldest = state.order[1]
        local old = at - oldest.at >= Answers.SECONDS
        if not old and #state.order <= Answers.MAX_REQUESTS then
            return
        end
        if not old then
            state.forgotAt = oldest.at
        end
        table.remove(state.order, 1)
        state.byId[oldest.id] = nil
        dropAnswer(oldest)
    end
end

-- The answer to let go to make room for `entry`'s: the oldest the relay can no longer ask for
-- (RESEND_SECONDS), else the largest (the oldest of the same size), so that lists and pictures go
-- before a press's few hundred bytes. Nil when no other answer is kept.
local function toDrop(entry)
    local largest = nil
    for _, other in ipairs(state.order) do
        if other ~= entry and other.answer then
            if state.elapsed - other.at >= Answers.RESEND_SECONDS then
                return other
            end
            if not largest or #other.answer > #largest.answer then
                largest = other
            end
        end
    end
    return largest
end

-- Keeps `text` as the answer of `entry` when it fits, letting other answers go (toDrop) to stay
-- within MAX_ANSWERS and MAX_BYTES.
local function keep(entry, text)
    entry.done = true
    -- Too large, or no longer remembered (it ran longer than SECONDS): not kept.
    if #text > Answers.MAX_ANSWER_BYTES or state.byId[entry.id] ~= entry then
        return
    end
    entry.answer = text
    state.answers = state.answers + 1
    state.bytes = state.bytes + #text
    while state.answers > Answers.MAX_ANSWERS or state.bytes > Answers.MAX_BYTES do
        local other = toDrop(entry)
        if not other then
            return
        end
        dropAnswer(other)
    end
end

local function notKept(message)
    return Json.encode({ type = Answers.TYPES[message.type], id = message.id, ok = false, code = Answers.NOT_KEPT })
end

-- Handles `message` from the relay: `run(message, reply)` handles it (remote.lua), `send(answer)`
-- writes to the relay connection there is when it is called. Returns what `run` returns for a
-- message of another type; for one the relay may send again, true and what happened, for the log:
-- nil (a request run for the first time), "new" (sent again, never got before: run now),
-- "answered again", "still running", "answer not kept" or "forgotten" (sent again, but a request
-- not yet RESEND_SECONDS old was forgotten meanwhile, so it may have run: it does not run again).
function Answers.handle(message, send, run)
    local kind = Answers.TYPES[message.type]
    local id = message.id
    if not kind or type(id) ~= "string" or id == "" or #id > 64 then
        return run(message, send)
    end
    local at = state.elapsed
    prune(at)
    local entry = state.byId[id]
    if entry then
        if entry.answer then
            send(entry.answer)
            return true, "answered again"
        elseif entry.done then
            send(notKept(message))
            return true, "answer not kept"
        end
        return true, "still running"
    end
    local resent = message.resent ~= nil
    -- A request it may have got and forgotten: one forgotten early had come within RESEND_SECONDS.
    if resent and state.forgotAt and at - state.forgotAt < Answers.RESEND_SECONDS then
        send(notKept(message))
        return true, "forgotten"
    end
    entry = { id = id, at = at, done = false }
    state.byId[id] = entry
    state.order[#state.order + 1] = entry
    prune(at)
    run(message, function(answer)
        if not entry.done and type(answer) == "table" and answer.id == id and answer.type == kind then
            local text = Json.encode(answer)
            keep(entry, text)
            send(text)
            return
        end
        send(answer)
    end)
    return true, resent and "new" or nil
end

-- A keep-alive tick, `seconds` apart (TICK_SECONDS): time goes on, and what is old is forgotten.
function Answers.tick(seconds)
    state.elapsed = state.elapsed + (tonumber(seconds) or Answers.TICK_SECONDS)
    prune(state.elapsed)
end

-- For tests and Remote Status: how many requests are remembered, answers kept and their bytes.
function Answers.counts()
    return #state.order, state.answers, state.bytes
end

-- Test support: forget everything (a fresh driver instance).
function Answers.reset()
    state.byId, state.order, state.answers, state.bytes = {}, {}, 0, 0
    state.elapsed, state.forgotAt = 0, nil
end

return Answers
