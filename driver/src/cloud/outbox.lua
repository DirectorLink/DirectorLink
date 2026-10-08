-- Alerts the driver sends the relay on its own (1.10.1, ADR-073, docs/RELAY.md): a `notify` (ADR-050:
-- a doorbell rang, a camera saw someone, a door or gate was opened, the refrigerator's door was left
-- open, a schedule failed, a door's ask-to-open question). Up to 1.10.0 one written into a connection
-- that had died without the driver knowing yet (ADR-072) was lost. Now each gets a random id and is
-- kept here until the relay answers `notify_result` with that id; after a reconnect to a relay that
-- said it answers them (`relay_features`, src/cloud/relay.lua), what was not answered goes again on
-- the new connection, oldest first, marked `resent`. The relay pushes each id once, so an alert
-- that did arrive (only its answer was lost) is not pushed twice. Only one that went to a relay
-- known to answer alerts goes again: a relay before 1.10.1 pushed what it got and ignored its id,
-- so the next relay would push it a second time.
--
-- Bounded: an alert is kept at most its `seconds` (Alerts.KEEP_SECONDS: a minute for a doorbell's
-- ring or a door's question, two for the others), counted by a timer of its own, so in real time
-- whatever the controller's clock does, and also while the connection is down; and at most MAX
-- alerts and MAX_BYTES together (the oldest go first). Memory only: a driver that restarts sends
-- nothing again. An alert let go before it ever went is told so (`letGo`): the hourly limits count
-- only what was sent (src/cloud/alerts.lua).

local Json = require("src.core.json")
local Log = require("src.core.log")
local Random = require("src.core.random")

local Outbox = {}

-- A notify is about 1 KB a key it names (each part 684 base64 characters and its IV and MAC); a
-- home's alerts name a few keys each. Twenty hold a burst of camera alerts with a ring and a door.
Outbox.MAX = 20
Outbox.MAX_BYTES = 128 * 1024

local state = {
    -- Oldest first: { id, text, kind, sends, connection, known, timer, letGo }. `connection`: the
    -- number of the connection it last went on; `known`: that connection's relay was known then (or
    -- later, on that connection) to answer alerts.
    entries = {},
    bytes = 0,
}

local function cancel(timer)
    if timer then
        pcall(function()
            timer:Cancel()
        end)
    end
end

local function removeAt(index)
    local entry = table.remove(state.entries, index)
    state.bytes = state.bytes - #entry.text
    cancel(entry.timer)
    entry.timer = nil
    -- Never sent (kept while the connection was down): as if it had not been made.
    if entry.sends == 0 and entry.letGo then
        pcall(entry.letGo)
    end
    entry.letGo = nil
    return entry
end

local function indexOf(entry)
    for index, other in ipairs(state.entries) do
        if other == entry then
            return index
        end
    end
    return nil
end

-- Keeps `message` (a table with its `type`) until the relay answers it: gives it an id
-- (`message.id`, 16 random hex digits) and makes its text once (the sealed parts are not encoded
-- again). `seconds`: how long it is worth sending; `kind`: for the log only; `letGo()`, if given:
-- called when it is let go before it ever went. Returns the entry ({ id, text }) and whether it is
-- kept: not when no timer could bound it, nor when it alone is over MAX_BYTES (it is sent once
-- then, as before 1.10.1).
function Outbox.add(message, seconds, kind, letGo)
    message.id = Random.hex(16)
    local entry = { id = message.id, kind = kind, sends = 0 }
    entry.text = Json.encode(message)
    pcall(function()
        entry.timer = C4:SetTimer(math.max(1, tonumber(seconds) or 60) * 1000, function()
            entry.timer = nil
            local index = indexOf(entry)
            if index then
                removeAt(index)
                Log.info("relay", "an alert was not acknowledged in time", { kind = kind, sent = entry.sends })
            end
        end, false)
    end)
    if not entry.timer then
        return entry, false
    end
    state.entries[#state.entries + 1] = entry
    state.bytes = state.bytes + #entry.text
    while #state.entries > Outbox.MAX or state.bytes > Outbox.MAX_BYTES do
        local dropped = removeAt(1)
        Log.info("relay", "an alert was let go to keep fewer", { kind = dropped.kind, sent = dropped.sends })
    end
    local kept = indexOf(entry) ~= nil
    if kept then
        entry.letGo = letGo
    end
    return entry, kept
end

-- The text to write for `entry` now on the connection numbered `connection`: as it was made, or,
-- when it went before, marked `resent` with how many times. `known`: that connection's relay is
-- known to answer alerts (it said so); while it has not said yet, false.
function Outbox.text(entry, connection, known)
    local text = entry.text
    if entry.sends > 0 then
        text = '{"resent":' .. entry.sends .. "," .. text:sub(2)
    end
    entry.sends = entry.sends + 1
    entry.connection = connection
    entry.known = known == true
    return text
end

-- The relay of the connection numbered `connection` said it answers alerts: what went on it is known
-- to have gone to such a relay, and every other alert kept goes now, with `send(text)`, oldest
-- first: one made while no connection was open, and one that went on a connection that ended, if
-- that connection's relay was known to answer alerts. One that went to a relay not known to (it
-- had said nothing yet when the alert went, and may be one before 1.10.1, which pushed it) is let
-- go: sent to this relay it could be pushed a second time. Returns how many went, and how many of
-- them had gone before.
function Outbox.resend(connection, send)
    local count, again = 0, 0
    local index = 1
    while index <= #state.entries do
        local entry = state.entries[index]
        if entry.connection == connection then
            entry.known = true
            index = index + 1
        elseif entry.sends == 0 or entry.known then
            if entry.sends > 0 then
                again = again + 1
            end
            count = count + 1
            send(Outbox.text(entry, connection, true))
            index = index + 1
        else
            removeAt(index)
            Log.info("relay", "an alert was not sent again: the relay it went to had not said it answers alerts", { kind = entry.kind, sent = entry.sends })
        end
    end
    return count, again
end

-- The relay answered the alert `id`: it is no longer kept. True when it was.
function Outbox.done(id)
    for index, entry in ipairs(state.entries) do
        if entry.id == id then
            removeAt(index)
            return true
        end
    end
    return false
end

-- Forgets every alert kept (the relay does not answer them, remote access went off, the identity
-- changed). Returns how many there were.
function Outbox.clear()
    local count = #state.entries
    while #state.entries > 0 do
        removeAt(#state.entries)
    end
    state.bytes = 0
    return count
end

-- For tests and the log: how many alerts are kept, and their bytes.
function Outbox.counts()
    return #state.entries, state.bytes
end

-- Test support: a fresh driver instance.
function Outbox.reset()
    Outbox.clear()
end

return Outbox
