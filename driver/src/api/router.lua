-- Matches method + path against route templates such as /v1/lights/{lightId}.

local Http = require("src.api.http")

local Router = {}
Router.__index = Router

local function compile(template)
    local names = {}
    local escaped = template:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    local pattern = escaped:gsub("{([%w_]+)}", function(name)
        names[#names + 1] = name
        return "([^/]+)"
    end)
    return "^" .. pattern .. "$", names
end

function Router.new(routes)
    local self = setmetatable({ entries = {} }, Router)
    for _, route in ipairs(routes) do
        local pattern, names = compile(route.path)
        self.entries[#self.entries + 1] = {
            route = route,
            pattern = pattern,
            names = names,
        }
    end
    return self
end

-- Returns { route = ..., params = {...} }, { error = "not_found" }
-- or { error = "method_not_allowed", allowed = { "GET", ... } }.
function Router:match(method, path)
    if #path > 1 then
        path = path:gsub("/+$", "")
    end

    local allowed = {}
    for _, entry in ipairs(self.entries) do
        local captures = { path:match(entry.pattern) }
        if captures[1] ~= nil then
            if entry.route.method == method then
                local params = {}
                for index, name in ipairs(entry.names) do
                    params[name] = Http.decodePathSegment(captures[index])
                end
                return { route = entry.route, params = params }
            end
            allowed[#allowed + 1] = entry.route.method
        end
    end

    if #allowed > 0 then
        return { error = "method_not_allowed", allowed = allowed }
    end
    return { error = "not_found" }
end

return Router
