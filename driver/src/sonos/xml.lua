-- A small XML reader for what Sonos players answer (docs/SONOS.md): SOAP envelopes, DIDL-Lite
-- metadata and the zone group state. Names are kept without their namespace prefix ("dc:title" is
-- "title"); text is unescaped. Not a validating parser: it reads well-formed answers and gives up
-- (nil) on anything too large or too deep.

local Xml = {}

Xml.MAX_BYTES = 512 * 1024
Xml.MAX_NODES = 5000
Xml.MAX_DEPTH = 64

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function utf8(code)
    if code < 0 or code > 0x10FFFF then
        return ""
    elseif code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40, 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

function Xml.unescape(text)
    return (tostring(text or ""):gsub("&(#?)([xX]?)(%w+);", function(numeric, hex, name)
        if numeric == "#" then
            local code = tonumber(name, hex ~= "" and 16 or 10)
            return code and utf8(code) or nil
        end
        return ENTITIES[hex .. name]
    end))
end

-- Text as an element's content or an attribute's value.
function Xml.escape(text)
    return (tostring(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function localName(name)
    return name:match(":([^:]+)$") or name
end

local function attributes(text)
    local result = {}
    for name, _, value in text:gmatch("([%w_%.:%-]+)%s*=%s*([\"'])(.-)%2") do
        result[localName(name)] = Xml.unescape(value)
    end
    return result
end

local function close(node)
    node.text = table.concat(node.parts)
    node.parts = nil
end

-- The document's root node ({ name = "#document", children }), each element being
-- { name, attrs, children, text }; nil and why when the text cannot be read.
function Xml.parse(text)
    if type(text) ~= "string" then
        return nil, "no text"
    end
    if #text > Xml.MAX_BYTES then
        return nil, "too large"
    end
    local root = { name = "#document", attrs = {}, children = {}, parts = {} }
    local stack = { root }
    local nodes, position = 0, 1
    while true do
        local start = text:find("<", position, true)
        local current = stack[#stack]
        if not start then
            current.parts[#current.parts + 1] = Xml.unescape(text:sub(position))
            break
        end
        if start > position then
            current.parts[#current.parts + 1] = Xml.unescape(text:sub(position, start - 1))
        end
        if text:sub(start, start + 3) == "<!--" then
            local finish = text:find("-->", start + 4, true)
            position = (finish or #text) + 3
        elseif text:sub(start, start + 8) == "<![CDATA[" then
            local finish = text:find("]]>", start + 9, true) or (#text + 1)
            current.parts[#current.parts + 1] = text:sub(start + 9, finish - 1)
            position = finish + 3
        elseif text:sub(start + 1, start + 1) == "?" or text:sub(start + 1, start + 1) == "!" then
            local finish = text:find(">", start, true)
            position = (finish or #text) + 1
        elseif text:sub(start + 1, start + 1) == "/" then
            local name, finish = text:match("^</([%w_%.:%-]+)%s*>()", start)
            if not name then
                return nil, "bad closing tag"
            end
            name = localName(name)
            -- Closes the element it names (and any left open inside it).
            for index = #stack, 2, -1 do
                if stack[index].name == name then
                    for open = #stack, index, -1 do
                        close(stack[open])
                        stack[open] = nil
                    end
                    break
                end
            end
            position = finish
        else
            local name, attrText, empty, finish = text:match("^<([%w_%.:%-]+)(.-)(/?)>()", start)
            if not name then
                return nil, "bad tag"
            end
            nodes = nodes + 1
            if nodes > Xml.MAX_NODES or #stack > Xml.MAX_DEPTH then
                return nil, "too large"
            end
            local node = { name = localName(name), attrs = attributes(attrText), children = {}, parts = {} }
            current.children[#current.children + 1] = node
            if empty == "/" then
                close(node)
            else
                stack[#stack + 1] = node
            end
            position = finish
        end
    end
    for index = #stack, 1, -1 do
        close(stack[index])
    end
    return root
end

-- The first element named `name` inside `node` (depth first), or nil.
function Xml.find(node, name)
    for _, child in ipairs(node and node.children or {}) do
        if child.name == name then
            return child
        end
        local found = Xml.find(child, name)
        if found then
            return found
        end
    end
    return nil
end

-- The direct children of `node` named `name`.
function Xml.children(node, name)
    local result = {}
    for _, child in ipairs(node and node.children or {}) do
        if child.name == name then
            result[#result + 1] = child
        end
    end
    return result
end

-- The text of the first element named `name` inside `node`, or nil.
function Xml.text(node, name)
    local found = Xml.find(node, name)
    return found and found.text or nil
end

return Xml
