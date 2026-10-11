-- DirectorLink's alerts on the home's screens (1.13.0, ADR-086, docs/NOTIFY_DRIVERS.md): every alert
-- the controller raises (src/cloud/alerts.lua: a doorbell rang, a camera's alert, a door or gate
-- opened, the refrigerator's door left open, a schedule that failed) goes to each screen of
-- DirectorLink's notification agreement that shows its kind (src/control4/notify_targets.lua), as
-- the command DIRECTORLINK_NOTIFY with the words a phone would show, in the home owner's language
-- (src/core/notify_words.lua).
--
-- All of it happens on the controller, apart from the phones' alerts: a screen is told whether or
-- not any phone switched alerts on, whatever the phones' limits, and while the relay is away. It is
-- told at once, never waited for (C4:SendToDevice, in a pcall): a screen that fails stops nothing,
-- neither the other screens nor the phones' alerts. At most one notification of a kind a screen in
-- SECONDS, but a doorbell's and an alarm's always; the screen keeps its own limits (one pop-up in 5 s,
-- its kinds, its quiet hours).
--
-- A doorbell's and a camera's notification has a picture: PICTURE, an address on the controller's
-- own API (http, port 41999, its LAN address) that gives that camera's picture for PICTURE_SECONDS,
-- at most PICTURE_USES times, to anyone who has it, without a key: its 128 random bits are the
-- key, and it goes only to the screen's driver, on the controller. Fetched when it is asked for, as
-- GET /v1/cameras/{id}/snapshot fetches one, PICTURE_WIDTH pixels wide (a camera's small picture
-- where it has one). Plain http: a TV checks no certificate of the controller's either way.
--
-- The log has a line for each notification (the screen's driver id and the kind; never its words),
-- and the history nothing (it would be every alert again).

local Clock = require("src.core.clock")
local Log = require("src.core.log")
local Random = require("src.core.random")
local Words = require("src.core.notify_words")

local Notify = {}

-- At most one notification of a kind a screen in this many seconds; the kinds in UNLIMITED always.
Notify.SECONDS = 5
Notify.UNLIMITED = { doorbell = true, alarm = true }
-- What each of the controller's alerts is on a screen (the agreement's kinds); a camera's smoke or CO
-- alarm (ADR-080) is an alarm. An ask-to-open link's question (ADR-058) is for its user's devices
-- only, and goes to no screen.
Notify.KINDS = { doorbell = "doorbell", camera = "camera", door_opened = "door", fridge_door = "door", schedule_failed = "other" }
Notify.ALARMS = { smoke_alarm = true, co_alarm = true }
-- A notification's picture.
Notify.PICTURE_SECONDS = 60
Notify.PICTURE_USES = 3
Notify.PICTURE_WIDTH = 640
-- Pictures waiting to be asked for, at most (the oldest go first).
Notify.MAX_PICTURES = 32
Notify.PICTURE_PATH = "/v1/notify-pictures/"
Notify.PORT = 41999

local state = {
    options = nil,
    -- "<driver id>:<kind>" -> when it was told last.
    last = {},
    -- token -> { camera, expires, uses, made }
    pictures = {},
}

-- options: targets (src/control4/notify_targets.lua: list, send), language() (the owner's profile
-- language, or nil), address() (the controller's LAN address, or nil), port (the API's).
function Notify.configure(options)
    state.options = options
    state.last = {}
    state.pictures = {}
end

-- The owner's language (options.language), or nil when it cannot be known now.
local function ownersLanguage()
    local options = state.options
    if not options or not options.language then
        return nil
    end
    local ok, language = pcall(options.language)
    return ok and language or nil
end

-- The agreement's kind of a controller's alert (its sealed detail), or nil: it goes to no screen.
function Notify.kindOf(detail)
    if type(detail) ~= "table" then
        return nil
    end
    if detail.kind == "camera" and Notify.ALARMS[detail.what] then
        return "alarm"
    end
    return Notify.KINDS[detail.kind]
end

local function sweep(now)
    local list = {}
    for token, picture in pairs(state.pictures) do
        if now >= picture.expires or now < picture.made or picture.uses >= Notify.PICTURE_USES then
            state.pictures[token] = nil
        else
            list[#list + 1] = { token = token, made = picture.made }
        end
    end
    return list
end

-- A picture of the camera `cameraId` for PICTURE_SECONDS from `now`: its address (http, the
-- controller's LAN address), or nil when the controller does not know its address.
local function picture(cameraId, now)
    local options = state.options
    local ok, address = pcall(options.address)
    if not ok or type(address) ~= "string" or not address:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil
    end
    local waiting = sweep(now)
    if #waiting >= Notify.MAX_PICTURES then
        table.sort(waiting, function(a, b)
            return a.made < b.made
        end)
        for index = 1, #waiting - Notify.MAX_PICTURES + 1 do
            state.pictures[waiting[index].token] = nil
        end
    end
    local token = Random.hex(32)
    state.pictures[token] = { camera = tonumber(cameraId), expires = now + Notify.PICTURE_SECONDS, uses = 0, made = now }
    return "http://" .. address .. ":" .. tostring(options.port or Notify.PORT) .. Notify.PICTURE_PATH .. token .. ".jpg"
end

-- The picture `name` asks for (GET /v1/notify-pictures/{picture}: "<token>.jpg") at `now`: the
-- camera's id, counted as one of its uses; nil when there is no such picture (any more).
function Notify.takePicture(name, now)
    now = now or Clock.now()
    local token = type(name) == "string" and name:match("^(%x+)%.jpg$") or nil
    if not token or #token ~= 32 or token ~= string.lower(token) then
        return nil
    end
    sweep(now)
    local found = state.pictures[token]
    if not found then
        return nil
    end
    found.uses = found.uses + 1
    return found.camera
end

-- Tells the screens of an alert the controller raised (Alerts.onRaised): `detail` as sealed for a
-- phone (its kind, name, what, ...), `camera` the id of the camera whose picture goes with it (a
-- doorbell's or the camera's own), `at` when it happened (seconds, or an ISO time), `now` the
-- controller's time. Returns how many screens were told.
function Notify.alert(detail, camera, at, now)
    local options = state.options
    local kind = Notify.kindOf(detail)
    if not options or not kind then
        return 0
    end
    now = now or Clock.now()
    local screens = {}
    for _, target in ipairs(options.targets.list()) do
        if target.kinds[kind] then
            screens[#screens + 1] = target
        end
    end
    if #screens == 0 then
        return 0
    end
    local when = type(at) == "string" and Clock.parseIso(at) or tonumber(at) or now
    local title, message = Words.say(detail, ownersLanguage(), when)
    local id = Random.hex(16)
    local told = 0
    for _, screen in ipairs(screens) do
        local slot = tostring(screen.id) .. ":" .. kind
        local last = state.last[slot]
        if not Notify.UNLIMITED[kind] and last and now - last < Notify.SECONDS and now >= last then
            Log.info("notify", "notification not sent to a screen", { driver_id = screen.id, kind = kind, why = "too soon" })
        else
            local params = { VERSION = tostring(1), ID = id, KIND = kind, TITLE = title, MESSAGE = message }
            if camera then
                params.PICTURE = picture(camera, now)
            end
            local ok, err = options.targets.send(screen.id, params)
            if ok then
                state.last[slot] = now
                told = told + 1
                Log.info("notify", "notification sent to a screen", { driver_id = screen.id, kind = kind, picture = params.PICTURE ~= nil or nil })
            else
                Log.warn("notify", "notification not sent to a screen", { driver_id = screen.id, kind = kind, error = err })
            end
        end
    end
    return told
end

-- The screens, as GET /v1/alerts/screens lists them, and the language they are told in.
function Notify.screens()
    local options = state.options
    local list = options and options.targets.list() or {}
    return list, Words.language(ownersLanguage())
end

return Notify
