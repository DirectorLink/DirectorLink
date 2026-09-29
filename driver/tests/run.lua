-- Runs the driver test suites under plain Lua 5.1. From the repository root:
--   lua5.1 driver/tests/run.lua                             (every suite)
--   lua5.1 driver/tests/run.lua test_sun test_holy_times    (only these, in this order)

package.path = "./driver/?.lua;./driver/tests/?.lua;" .. package.path

local suites = {
    "test_json",
    "test_http",
    "test_router",
    "test_api",
    "test_discovery",
    "test_shades",
    "test_relay",
    "test_lock",
    "test_remote",
    "test_profiles",
    "test_scenes",
    "test_schedules",
    "test_calendar",
    "test_hebrew_date",
    "test_holidays",
    "test_parasha",
    "test_sun",
    "test_holy_times",
    "test_x25519",
    "test_security",
    "test_light_v1",
    "test_thermostat_v2_heat",
    "test_thermostat_proxy",
    "test_dual_thermostat",
}

if #arg > 0 then
    local known = {}
    for _, suiteName in ipairs(suites) do
        known[suiteName] = true
    end
    for _, suiteName in ipairs(arg) do
        if not known[suiteName] then
            print("unknown suite " .. suiteName .. " (driver/tests/run.lua lists them)")
            os.exit(1)
        end
    end
    suites = arg
end

local passed, failed = 0, 0

for _, suiteName in ipairs(suites) do
    local suite = require(suiteName)
    local names = {}
    for name in pairs(suite) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local ok, err = pcall(suite[name])
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            print("FAIL " .. suiteName .. " :: " .. name .. "\n     " .. tostring(err))
        end
    end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
