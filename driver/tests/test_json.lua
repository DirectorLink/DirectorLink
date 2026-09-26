local Json = require("src.core.json")
local T = require("helpers")

local tests = {}

function tests.encodes_primitives()
    T.eq(Json.encode(true), "true")
    T.eq(Json.encode(false), "false")
    T.eq(Json.encode(Json.null), "null")
    T.eq(Json.encode(nil), "null")
    T.eq(Json.encode(42), "42")
    T.eq(Json.encode(-3), "-3")
    T.eq(Json.encode(4294966301), "4294966301", "integers beyond 32 bits")
    T.eq(Json.encode(22.5), "22.5")
    T.eq(Json.encode(0 / 0), "null")
    T.eq(Json.encode(math.huge), "null")
end

function tests.empty_tables_are_objects_unless_marked()
    T.eq(Json.encode({}), "{}")
    T.eq(Json.encode(Json.array()), "[]")
end

function tests.escapes_strings_and_keeps_utf8()
    T.eq(Json.encode('say "hi"\n'), '"say \\"hi\\"\\n"')
    T.eq(Json.encode("a\\b"), '"a\\\\b"')
    T.eq(Json.encode("\1"), '"\\u0001"')
    T.eq(Json.encode("מטבח"), '"מטבח"')
end

function tests.orders_keys_with_id_and_name_first()
    T.eq(Json.encode({ zeta = 1, name = "x", alpha = 2, id = 7 }), '{"id":7,"name":"x","alpha":2,"zeta":1}')
end

function tests.distinguishes_empty_array_from_empty_object()
    T.eq(Json.encode(Json.array()), "[]")
    T.eq(Json.encode({}), "{}")
    T.eq(Json.encode({ items = Json.array() }), '{"items":[]}')
    T.eq(Json.encode({ 1, 2, 3 }), "[1,2,3]")
end

function tests.rejects_circular_references()
    local value = {}
    value.self = value
    T.truthy(not pcall(Json.encode, value), "circular tables must not encode")
end

function tests.decodes_documents()
    local value = Json.decode(' {"on": true, "brightness": 40, "tags": ["a", "b"], "x": null, "t": -1.5e2} ')
    T.eq(value.on, true)
    T.eq(value.brightness, 40)
    T.eq(#value.tags, 2)
    T.truthy(Json.isArray(value.tags), "arrays are marked")
    T.eq(value.x, Json.null)
    T.eq(value.t, -150)
    T.truthy(Json.isArray(Json.decode("[]")), "empty arrays stay arrays")
end

function tests.decodes_unicode_escapes()
    T.eq(Json.decode('"\\u05de"'), "מ")
    T.eq(Json.decode('"\\ud83d\\ude00"'), "\240\159\152\128")
    T.eq(Json.decode('"a\\/b\\tc"'), "a/b\tc")
end

function tests.reports_invalid_json()
    local cases = { "", "{", '{"a":}', "[1,]", '"open', "01", "tru", "1 2", '"\1"', "{'a':1}" }
    for _, text in ipairs(cases) do
        local value, err = Json.decode(text)
        T.eq(value, nil, "should reject " .. text)
        T.truthy(err, "error message for " .. text)
    end
    T.eq(select(1, Json.decode(string.rep("[", 40) .. string.rep("]", 40))), nil, "depth limit")
end

function tests.round_trips()
    local original = { id = 5, name = "Desk", on = false, levels = Json.array({ 1, 2 }), empty = Json.array(), none = Json.null }
    T.eq(Json.encode(Json.decode(Json.encode(original))), Json.encode(original))
end

return tests
