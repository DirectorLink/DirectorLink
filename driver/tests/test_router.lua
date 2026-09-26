local Router = require("src.api.router")
local Routes = require("src.api.routes")
local T = require("helpers")

local tests = {}

local router = Router.new({
    { method = "GET", path = "/v1/lights", handler = "lights.list" },
    { method = "GET", path = "/v1/lights/{lightId}", handler = "lights.get" },
    { method = "PATCH", path = "/v1/lights/{lightId}", handler = "lights.update" },
    { method = "GET", path = "/v1/openapi.json", handler = "system.openapi" },
    { method = "DELETE", path = "/v1/api-keys/{keyId}", handler = "auth.delete_key" },
})

function tests.matches_static_and_templated_paths()
    T.eq(router:match("GET", "/v1/lights").route.handler, "lights.list")
    local match = router:match("PATCH", "/v1/lights/259")
    T.eq(match.route.handler, "lights.update")
    T.eq(match.params.lightId, "259")
    T.eq(router:match("GET", "/v1/lights/").route.handler, "lights.list", "trailing slash")
    T.eq(router:match("GET", "/v1/openapi.json").route.handler, "system.openapi")
    T.eq(router:match("GET", "/v1/openapiXjson").error, "not_found", "dot is literal")
    T.eq(router:match("DELETE", "/v1/api-keys/ab%20cd").params.keyId, "ab cd", "path params are decoded")
end

function tests.distinguishes_404_from_405()
    T.eq(router:match("GET", "/v1/nothing").error, "not_found")
    local match = router:match("DELETE", "/v1/lights/1")
    T.eq(match.error, "method_not_allowed")
    T.eq(table.concat(match.allowed, ","), "GET,PATCH")
end

function tests.route_table_has_no_duplicates()
    local seen = {}
    for _, route in ipairs(Routes) do
        local key = route.method .. " " .. route.path
        T.truthy(not seen[key], "duplicate route " .. key)
        seen[key] = true
        T.truthy(route.path:match("^/v1/"), "routes live under /v1: " .. key)
    end
end

return tests
