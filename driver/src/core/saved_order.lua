-- An order of the home's rooms or cameras (docs/PREFERENCES.md), one for everyone, set by an admin
-- and kept in the driver's store as { version = 1, order = { ids } }. Control4 has its own order;
-- this is DirectorLink's. What is not in the order follows the ordered ones, in the order it is
-- given (Control4's, by name); an id no longer in the project is passed over, and comes back to its
-- place if that room or camera does. RoomLayout and CameraLayout are each one.

local Log = require("src.core.log")
local Store = require("src.core.store")
local Json = require("src.core.json")

local SavedOrder = {}

-- `storeKey`: where the order is kept; `area` and `what`: the log's area and words ("rooms",
-- "room order").
function SavedOrder.new(storeKey, area, what)
    local layout = {}
    local state = { order = {} }

    local function list()
        local order = Json.array()
        for _, id in ipairs(state.order) do
            order[#order + 1] = id
        end
        return order
    end

    local function save()
        if not Store.write(storeKey, { version = 1, order = list() }, false) then
            Log.error(area, "could not save the " .. what)
            return false
        end
        return true
    end

    -- The ids of a stored record ({ version, order }, as the store or a backup holds it), without
    -- repeats.
    function layout.read(data)
        local order, seen = {}, {}
        for _, id in ipairs(Store.items(type(data) == "table" and data.order or nil)) do
            id = tonumber(id)
            if id and not seen[id] then
                seen[id] = true
                order[#order + 1] = id
            end
        end
        return order
    end

    function layout.load()
        state.order = layout.read(Store.read(storeKey, false))
    end

    -- Backups (ADR-042, src/core/backup.lua): the order as the store keeps it.
    function layout.backup()
        return { version = 1, order = list() }
    end

    -- Replaces the order with the one of `data`. Returns true once saved.
    function layout.restore(data)
        state.order = layout.read(data)
        return save()
    end

    -- `items` in the home's order: the ordered ones first, then the rest as given. `idOf(item)` is
    -- the id the order names it by (by default its `id`).
    function layout.sort(items, idOf)
        idOf = idOf or function(item)
            return item.id
        end
        local rank = {}
        for index, id in ipairs(state.order) do
            rank[id] = index
        end
        local indexed = {}
        for index, item in ipairs(items) do
            indexed[#indexed + 1] = { item = item, rank = rank[tonumber(idOf(item))], index = index }
        end
        table.sort(indexed, function(a, b)
            if a.rank and b.rank then
                return a.rank < b.rank
            end
            if a.rank or b.rank then
                return a.rank ~= nil
            end
            return a.index < b.index
        end)
        local sorted = {}
        for _, entry in ipairs(indexed) do
            sorted[#sorted + 1] = entry.item
        end
        return sorted
    end

    -- The new order (ids, already checked by the API).
    function layout.setOrder(ids)
        state.order = {}
        for _, id in ipairs(ids) do
            state.order[#state.order + 1] = id
        end
        return save()
    end

    return layout
end

return SavedOrder
