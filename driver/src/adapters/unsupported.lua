local Unsupported = {}
Unsupported.__index = Unsupported

function Unsupported.matches(_device)
    return true
end

function Unsupported.describe(device)
    return {
        kind = "unsupported",
        supported = false,
        capabilities = {},
        actions = {},
        source = device,
    }
end

return Unsupported
