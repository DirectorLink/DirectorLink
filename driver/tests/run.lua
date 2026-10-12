-- Runs the driver test suites under plain Lua 5.1. From the repository root:
--   lua5.1 driver/tests/run.lua                             (every suite)
--   lua5.1 driver/tests/run.lua test_sun test_holy_times    (only these, in this order)
--   lua5.1 driver/tests/run.lua --shard 2/6                 (the second of six parts, as CI runs them)
--   lua5.1 driver/tests/run.lua --shard 2/6 --list          (which suites that part runs)
-- In a part, test_backup:1/2 is the first of the two pieces test_backup is cut into (below).

package.path = "./driver/?.lua;./driver/tests/?.lua;" .. package.path

-- A test that cannot run here (T.skip in helpers.lua, e.g. one for another time zone) is counted
-- and named, not failed.
local T = require("helpers")
local skipped = 0

local suites = {
    "test_json",
    "test_http",
    "test_router",
    "test_api",
    "test_discovery",
    "test_shades",
    "test_relay",
    "test_resend",
    "test_lock",
    "test_remote",
    "test_profiles",
    "test_scenes",
    "test_scene_links",
    "test_ask_links",
    "test_schedules",
    "test_calendar",
    "test_hebrew_date",
    "test_holidays",
    "test_parasha",
    "test_sun",
    "test_holy_times",
    "test_x25519",
    "test_cpace",
    "test_cpace_pairing",
    "test_key_expiry",
    "test_access",
    "test_people",
    "test_users",
    "test_add_user",
    "test_owner",
    "test_security",
    "test_light_v1",
    "test_light_v2",
    "test_thermostat_v2_heat",
    "test_thermostat_proxy",
    "test_dual_thermostat",
    "test_fahrenheit",
    "test_last_modes",
    "test_fans",
    "test_refrigerators",
    "test_driver_updates",
    "test_alarm",
    "test_backup",
    "test_auto_backup",
    "test_sonos",
    "test_sonos_groups",
    "test_activity",
    "test_alerts",
    "test_cameras",
    "test_camera_drivers",
    "test_camera_order",
    "test_door_controllers",
    "test_doorbell_doors",
    "test_https",
    "test_notify",
}

-- About how many seconds each suite takes (each alone, on one of a PC's fast cores, 2026-10-11;
-- test_backup takes 115 to 150 from run to run; CI takes about 1.3 to 1.7 times as long), for
-- --shard to split them into parts of about equal time. A suite not listed counts as
-- DEFAULT_SECONDS: add it here once measured (lua5.1 driver/tests/run.lua <suite>).
local SECONDS = {
    test_json = 1,
    test_access = 1,
    test_people = 17,
    test_users = 22,
    test_add_user = 9,
    test_owner = 7,
    test_http = 1,
    test_router = 1,
    test_api = 16,
    test_discovery = 5,
    test_shades = 13,
    test_relay = 9,
    test_resend = 26,
    test_activity = 9,
    test_auto_backup = 20,
    test_alerts = 49,
    test_cameras = 4,
    test_camera_drivers = 10,
    test_camera_order = 3,
    test_door_controllers = 9,
    test_doorbell_doors = 4,
    test_https = 24,
    test_notify = 8,
    test_lock = 1,
    test_remote = 20,
    test_profiles = 4,
    test_scenes = 9,
    test_scene_links = 13,
    test_ask_links = 12,
    test_schedules = 16,
    test_calendar = 16,
    test_hebrew_date = 1,
    test_holidays = 1,
    test_parasha = 1,
    test_sun = 1,
    test_holy_times = 1,
    test_x25519 = 1,
    test_cpace = 1,
    test_cpace_pairing = 12,
    test_key_expiry = 5,
    test_security = 13,
    test_light_v1 = 2,
    test_light_v2 = 4,
    test_thermostat_v2_heat = 7,
    test_thermostat_proxy = 1,
    test_dual_thermostat = 6,
    test_fahrenheit = 4,
    test_last_modes = 4,
    test_fans = 6,
    test_refrigerators = 8,
    test_driver_updates = 2,
    test_alarm = 41,
    test_backup = 135,
    test_sonos = 17,
    test_sonos_groups = 10,
}
local DEFAULT_SECONDS = 5

-- The suites of part `index` of `count`. A suite that alone takes longer than a part should (all
-- the seconds over `count`) is first cut into as many pieces as that takes, its tests dealt out in
-- turn: with six parts, test_backup into two. Then the suites and pieces, longest first, each go
-- to the part with the least time so far (the first of equals), so every test is in exactly one
-- part. Each part keeps the order. Returns the suites, and for each suite cut into pieces the
-- pieces this part runs: { [name] = { count = pieces, [piece] = true } }.
local function shard(list, index, count)
    local total = 0
    for _, suiteName in ipairs(list) do
        total = total + (SECONDS[suiteName] or DEFAULT_SECONDS)
    end
    local order = {}
    for position, suiteName in ipairs(list) do
        local seconds = SECONDS[suiteName] or DEFAULT_SECONDS
        local pieces = math.max(1, math.ceil(seconds * count / total))
        for piece = 1, pieces do
            order[#order + 1] = { name = suiteName, position = position, piece = piece, pieces = pieces, seconds = seconds / pieces }
        end
    end
    table.sort(order, function(a, b)
        if a.seconds ~= b.seconds then
            return a.seconds > b.seconds
        end
        if a.position ~= b.position then
            return a.position < b.position
        end
        return a.piece < b.piece
    end)
    local totals, mine = {}, {}
    for part = 1, count do
        totals[part] = 0
    end
    for _, unit in ipairs(order) do
        local least = 1
        for part = 2, count do
            if totals[part] < totals[least] then
                least = part
            end
        end
        totals[least] = totals[least] + unit.seconds
        if least == index then
            mine[unit.name] = mine[unit.name] or { count = unit.pieces }
            mine[unit.name][unit.piece] = true
        end
    end
    local result, cut = {}, {}
    for _, suiteName in ipairs(list) do
        local pieces = mine[suiteName]
        if pieces then
            result[#result + 1] = suiteName
            if pieces.count > 1 then
                cut[suiteName] = pieces
            end
        end
    end
    return result, cut
end

-- How a part names a suite: test_backup:1/2 for the first of its two pieces.
local function label(suiteName, pieces)
    if not pieces then
        return suiteName
    end
    local names = {}
    for piece = 1, pieces.count do
        if pieces[piece] then
            names[#names + 1] = suiteName .. ":" .. piece .. "/" .. pieces.count
        end
    end
    return table.concat(names, " ")
end

local named, shardIndex, shardCount, listOnly = {}, nil, nil, false
local position = 1
while position <= #arg do
    local value = arg[position]
    if value == "--shard" then
        local index, count = tostring(arg[position + 1]):match("^(%d+)/(%d+)$")
        shardIndex, shardCount = tonumber(index), tonumber(count)
        if not shardIndex or shardIndex < 1 or shardIndex > shardCount then
            print("--shard takes K/N: the K-th of N parts, such as 1/3")
            os.exit(1)
        end
        position = position + 2
    elseif value == "--list" then
        listOnly = true
        position = position + 1
    else
        named[#named + 1] = value
        position = position + 1
    end
end

if #named > 0 then
    local known = {}
    for _, suiteName in ipairs(suites) do
        known[suiteName] = true
    end
    for _, suiteName in ipairs(named) do
        if not known[suiteName] then
            print("unknown suite " .. suiteName .. " (driver/tests/run.lua lists them)")
            os.exit(1)
        end
    end
    suites = named
end

local cut = {}
if shardIndex then
    suites, cut = shard(suites, shardIndex, shardCount)
    if not listOnly then
        local labels = {}
        for _, suiteName in ipairs(suites) do
            labels[#labels + 1] = label(suiteName, cut[suiteName])
        end
        print(string.format("part %d/%d: %s", shardIndex, shardCount, table.concat(labels, " ")))
    end
end

if listOnly then
    for _, suiteName in ipairs(suites) do
        print(label(suiteName, cut[suiteName]))
    end
    os.exit(0)
end

local passed, failed = 0, 0

for _, suiteName in ipairs(suites) do
    local suite = require(suiteName)
    local names = {}
    for name in pairs(suite) do
        names[#names + 1] = name
    end
    table.sort(names)
    -- A piece of a suite: its tests dealt out in turn, the first to piece 1, the second to 2, ...
    local pieces = cut[suiteName]
    local mine = {}
    for position, name in ipairs(names) do
        if not pieces or pieces[(position - 1) % pieces.count + 1] then
            mine[#mine + 1] = name
        end
    end

    for _, name in ipairs(mine) do
        local ok, err = pcall(suite[name])
        if ok then
            passed = passed + 1
        elseif T.skipped(err) then
            skipped = skipped + 1
            print("SKIP " .. suiteName .. " :: " .. name .. " (" .. T.skipped(err) .. ")")
        else
            failed = failed + 1
            print("FAIL " .. suiteName .. " :: " .. name .. "\n     " .. tostring(err))
        end
    end
end

print(string.format("%d passed, %d failed", passed, failed) .. (skipped > 0 and string.format(", %d skipped", skipped) or ""))
os.exit(failed == 0 and 0 or 1)
