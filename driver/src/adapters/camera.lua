-- Camera proxy (camera.c4i). Cameras have no state to watch; snapshots are fetched on demand by
-- src/control4/camera.lua.
local Camera = {}

function Camera.matches(device)
    local driver = string.lower(tostring(device and device.proxy and device.proxy.driver or ""))
    return driver == "camera.c4i" or driver == "camera.c4z"
end

function Camera.initialize(device)
    device.supported = true
    device.adapter_error = nil
    device.capabilities = { snapshot = true }
    device.state = {}
    device.actions = {}
    return true
end

function Camera.onVariableChanged()
    return false
end

function Camera.execute()
    return false, {
        code = "ACTION_NOT_SUPPORTED",
        message = "Cameras have no commands",
    }
end

-- The adapters are initialized again on a project refresh: only the cached camera setups go (read
-- again for the next picture). Snapshots already asked for are still fetched and answered.
function Camera.reset()
    require("src.control4.camera").forgetAll()
end

return Camera
