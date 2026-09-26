-- Runs the driver test suites under plain Lua 5.1. From the repository root:
--   lua5.1 driver/tests/run.lua

package.path = "./driver/?.lua;./driver/tests/?.lua;" .. package.path

local suites = {
    "test_json",
    "test_http",
    "test_router",
    "test_api",
    "test_approvals",
    "test_navigator",
}

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
