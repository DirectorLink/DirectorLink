-- Favorites of devices removed in Composer (1.8.0, ADR-059, docs/PREFERENCES.md). The owner
-- replaced cameras in Composer: the app kept asking for the old ones and showed empty tiles. Now the
-- controller tells the app which of a person's favorites are of devices the project no longer has
-- (GET /v1/profile `gone_favorites`: the app shows them as "Removed in Composer", with Remove), and
-- drops them from every profile once they have been gone GONE_DAYS. Never on a single read:
-- - Only a project read that worked counts (main.lua, discover): a read that failed, or Director
--   listing no devices at all (it does while it loads a project), changes nothing.
-- - A favorite is marked gone, with the time, by the first such read in which no device of the
--   project has its id (whatever its kind now). A later read that has the device again clears the
--   mark: a device missing for a moment (a driver being replaced) keeps its favorites.
-- - A mark GONE_DAYS old removes the favorite from every profile, at a read or at the scheduler's
--   minute tick, but only once a read in this run of the driver has looked at the marks (a mark
--   kept from before a restart may be of a device that came back meanwhile). Logged.
-- - A kind DirectorLink does not know (a newer version's favorites) is never marked or removed.
-- The marks are kept in the driver's data (MARKS_KEY), so a restart does not start the days again.
-- DirectorLink 1.7.0 does not read them; a favorite removed here is gone there too.

local Access = require("src.auth.access")
local Clock = require("src.core.clock")
local Json = require("src.core.json")
local Log = require("src.core.log")
local Profiles = require("src.auth.profiles")
local Store = require("src.core.store")

local FavoritesGone = {}

FavoritesGone.GONE_DAYS = 7
FavoritesGone.GONE_SECONDS = FavoritesGone.GONE_DAYS * 24 * 3600
FavoritesGone.MARKS_KEY = "directorlink_favorites_gone"
-- The kinds of favorites ("kind:id") and the devices they name (as src/core/backup.lua matches them).
FavoritesGone.KINDS = { light = "light", thermostat = "climate", fan = "fan", blind = "blind", camera = "camera", relay = "relay", doorbell = "doorbell", refrigerator = "refrigerator" }
local MAX_NAME = 100

local state = {
    marks = {}, -- entry -> { since, name, room_id, kind }
    looked = false, -- a project read in this run has looked at the marks
}

local function parse(entry)
    local kind, id = tostring(entry or ""):match("^(%l+):(%d+)$")
    if kind and FavoritesGone.KINDS[kind] then
        return kind, tonumber(id)
    end
    return nil
end

local function save()
    local items = Json.array()
    local entries = {}
    for entry in pairs(state.marks) do
        entries[#entries + 1] = entry
    end
    table.sort(entries)
    for _, entry in ipairs(entries) do
        local mark = state.marks[entry]
        items[#items + 1] = { entry = entry, since = mark.since, name = mark.name, room_id = mark.room_id, kind = mark.kind }
    end
    if not Store.write(FavoritesGone.MARKS_KEY, { version = 1, items = items }, false) then
        Log.warn("profiles", "could not save which favorites are of removed devices")
    end
end

function FavoritesGone.load()
    state.marks, state.looked = {}, false
    local data = Store.read(FavoritesGone.MARKS_KEY, false)
    for _, item in ipairs(Store.items(type(data) == "table" and data.items or nil)) do
        if type(item) == "table" and parse(item.entry) and tonumber(item.since) then
            state.marks[item.entry] = {
                since = tonumber(item.since),
                name = type(item.name) == "string" and item.name:sub(1, MAX_NAME) or nil,
                room_id = tonumber(item.room_id),
                kind = type(item.kind) == "string" and item.kind or nil,
            }
        end
    end
end

-- Every favorite of a known kind in some profile: entry -> device id.
local function favorites()
    local wanted = {}
    for _, profile in ipairs(Profiles.list()) do
        for _, entry in ipairs(profile.prefs.favorites or {}) do
            local _, id = parse(entry)
            if id then
                wanted[entry] = id
            end
        end
    end
    return wanted
end

-- A project read that worked (main.lua): `devices` is the project's (id -> device), `previous`
-- the devices of the read before it in this run (for a gone device's name and room), or nil.
-- Marks favorites whose device is gone, clears those whose device is back, then drops what has been
-- gone GONE_DAYS. Returns how many favorites were dropped.
function FavoritesGone.projectRead(devices, previous, now)
    if type(devices) ~= "table" or next(devices) == nil then
        return 0
    end
    now = now or Clock.now()
    local wanted = favorites()
    local changed = false
    for entry in pairs(state.marks) do
        if not wanted[entry] then
            state.marks[entry] = nil -- no longer anyone's favorite
            changed = true
        end
    end
    for entry, id in pairs(wanted) do
        if devices[id] then
            if state.marks[entry] then
                state.marks[entry] = nil
                changed = true
                Log.info("profiles", "a favorite's device is in the project again", { entry = entry })
            end
        elseif not state.marks[entry] then
            local before = type(previous) == "table" and previous[id] or nil
            state.marks[entry] = {
                since = now,
                name = before and before.name and tostring(before.name):sub(1, MAX_NAME) or nil,
                room_id = before and tonumber(before.room_id) or nil,
                kind = before and before.kind or nil,
            }
            changed = true
            Log.info("profiles", "a favorite's device is not in the project", { entry = entry, drop_in_days = FavoritesGone.GONE_DAYS })
        end
    end
    state.looked = true
    if changed then
        save()
    end
    return FavoritesGone.prune(now)
end

-- Drops from every profile the favorites gone GONE_DAYS (once a read in this run looked at them).
-- Returns how many favorites went.
function FavoritesGone.prune(now)
    if not state.looked then
        return 0
    end
    now = now or Clock.now()
    local due = {}
    for entry, mark in pairs(state.marks) do
        if now - mark.since >= FavoritesGone.GONE_SECONDS then
            due[entry] = mark
        end
    end
    if next(due) == nil then
        return 0
    end
    local removed = 0
    for _, profile in ipairs(Profiles.list()) do
        local kept, dropped = Json.array(), 0
        for _, entry in ipairs(profile.prefs.favorites or {}) do
            if due[entry] then
                dropped = dropped + 1
            else
                kept[#kept + 1] = entry
            end
        end
        if dropped > 0 and Profiles.updatePrefs(profile.id, { favorites = kept }) then
            removed = removed + dropped
        end
    end
    for entry, mark in pairs(due) do
        state.marks[entry] = nil
        Log.info("profiles", "a favorite of a device removed in Composer was dropped", { entry = entry, days = math.floor((now - mark.since) / 86400) })
    end
    save()
    return removed
end

-- The favorites of `list` whose device is gone, for GET /v1/profile: { entry, since, name } in
-- their order; the name the device had, only for an `actor` who may see such a device there.
function FavoritesGone.list(list, actor)
    local gone = Json.array()
    for _, entry in ipairs(list or {}) do
        local mark = state.marks[entry]
        if mark then
            local kind, id = parse(entry)
            local item = { entry = entry, since = Clock.iso(mark.since) }
            if mark.name and Access.canSee(actor, { id = id, kind = mark.kind or FavoritesGone.KINDS[kind], room_id = mark.room_id }) then
                item.name = mark.name
            end
            gone[#gone + 1] = item
        end
    end
    return gone
end

return FavoritesGone
