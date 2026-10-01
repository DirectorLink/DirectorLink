-- DirectorLink's own settings (ADR-043): its Composer properties, which of them an admin may also
-- change in the app, the properties it only shows, and its actions. A change in the app is made as
-- Composer makes it: the property is set, so Composer shows the new value, and then takes effect
-- through the same code as a change in Composer (propertyChanged in src/main.lua). A later change
-- in Composer wins as usual.
--
-- Door Control, Relay Hold, Alarm Status and Remote Access, and the actions New Pairing Code, Revoke
-- All API Keys and Reset Remote Identity, are set in Composer only: the API refuses them for every
-- key, admins included. scripts/check_package.py keeps it so.

local Json = require("src.core.json")

local Settings = {}

-- In Composer's order. `choices`: the API's value and Composer's, the default first unless
-- `default` says otherwise. `app`: an admin may change it in the app (PATCH /v1/settings).
Settings.LIST = {
    { key = "door_control", property = "Door Control", choices = { { "disabled", "Disabled" }, { "enabled", "Enabled" } }, app = false },
    { key = "relay_hold", property = "Relay Hold", choices = { { "not_allowed", "Not allowed" }, { "allowed", "Allowed" } }, app = false },
    { key = "alarm_status", property = "Alarm Status", choices = { { "off", "Off" }, { "on", "On" } }, app = false },
    { key = "remote_access", property = "Remote Access", choices = { { "off", "Off" }, { "on", "On" } }, app = false },
    { key = "schedules", property = "Schedules", choices = { { "on", "On" }, { "paused", "Paused" } }, app = true },
    { key = "jewish_calendar", property = "Jewish Calendar", choices = { { "off", "Off" }, { "on", "On" } }, app = true },
    { key = "log_level", property = "Log Level", choices = { { "debug", "Debug" }, { "info", "Info" }, { "warn", "Warning" }, { "error", "Error" } }, default = "info", app = true },
}

-- What DirectorLink shows in Composer and nobody sets. Never the pairing code: whoever reads it
-- could pair.
Settings.STATUS = {
    { key = "status", property = "Status" },
    { key = "version", property = "Version" },
    { key = "api_status", property = "API Status" },
    { key = "pairing_status", property = "Pairing Status" },
    { key = "api_keys", property = "API Keys" },
    { key = "remote_status", property = "Remote Status" },
    { key = "schedule_status", property = "Schedule Status" },
    { key = "last_automation", property = "Last Automation" },
    { key = "calendar_status", property = "Calendar Status" },
    { key = "inventory", property = "Inventory" },
}

-- Composer's actions. `app`: the app may run it too: Refresh Project (POST /v1/project/refresh),
-- and what Print Schedules and Scenes prints (GET /v1/settings/printout).
Settings.ACTIONS = {
    { key = "new_pairing_code", action = "New Pairing Code", app = false },
    { key = "revoke_api_keys", action = "Revoke All API Keys", app = false },
    { key = "print_automation", action = "Print Schedules and Scenes", app = true },
    { key = "refresh_project", action = "Refresh Project", app = true },
    { key = "reset_remote_identity", action = "Reset Remote Identity", app = false },
}

local byKey, byProperty = {}, {}
for _, setting in ipairs(Settings.LIST) do
    byKey[setting.key] = setting
    byProperty[setting.property] = setting
end

local state = {
    -- What a change does (src/main.lua): function(property, by), by being the API key or nil.
    apply = nil,
    -- The read-only properties as DirectorLink last showed them in Composer.
    shown = {},
    -- property -> the value DirectorLink last applied (from the app or Composer). Director may
    -- report a value DirectorLink set back to OnPropertyChanged, at once or later, once or more:
    -- it is the value applied, so it is not taken for a change in Composer.
    applied = {},
}

function Settings.configure(options)
    state.apply = options.apply
end

-- DirectorLink showed `value` in a property of its own (src/main.lua, updateProperty).
function Settings.shown(property, value)
    state.shown[property] = value
end

function Settings.find(key)
    return byKey[key]
end

function Settings.forProperty(property)
    return byProperty[property]
end

local function defaultOf(setting)
    return setting.default or setting.choices[1][1]
end

-- The setting as the API names it: from Composer's value, or the default while it has none
-- (as the driver's code reads it: only the exact value turns a switch on).
function Settings.value(setting)
    local current = Properties and Properties[setting.property]
    for _, choice in ipairs(setting.choices) do
        if choice[2] == current then
            return choice[1]
        end
    end
    return defaultOf(setting)
end

-- Composer's name of the API's `value`, or nil when it is not one of the setting's.
function Settings.composerValue(setting, value)
    for _, choice in ipairs(setting.choices) do
        if choice[1] == value then
            return choice[2]
        end
    end
    return nil
end

local function view(setting)
    local choices = Json.array()
    for _, choice in ipairs(setting.choices) do
        choices[#choices + 1] = choice[1]
    end
    local value = Settings.value(setting)
    return {
        key = setting.key,
        property = setting.property,
        value = value,
        composer_value = Settings.composerValue(setting, value),
        choices = choices,
        changeable = setting.app == true,
        set_in = setting.app == true and "app_and_composer" or "composer",
    }
end

-- GET /v1/settings: every setting, the status properties and the actions.
function Settings.document()
    local settings, actions, status = Json.array(), Json.array(), {}
    for _, setting in ipairs(Settings.LIST) do
        settings[#settings + 1] = view(setting)
    end
    for _, action in ipairs(Settings.ACTIONS) do
        actions[#actions + 1] = { key = action.key, action = action.action, in_app = action.app == true }
    end
    for _, item in ipairs(Settings.STATUS) do
        local text = state.shown[item.property]
        status[item.key] = (text ~= nil and tostring(text) ~= "") and tostring(text) or Json.null
    end
    return { settings = settings, status = status, actions = actions }
end

-- A PATCH /v1/settings body, { key = value, ... }: nil when every field may be set to its value,
-- otherwise what is wrong with the first that may not ({ code, field, detail }). A setting made in
-- Composer only is refused whatever its value.
function Settings.check(changes)
    local names = {}
    for name in pairs(changes) do
        names[#names + 1] = tostring(name)
    end
    table.sort(names)
    if #names == 0 then
        return { code = "EMPTY", detail = "Send at least one setting to change" }
    end
    for _, name in ipairs(names) do
        local setting = byKey[name]
        if not setting then
            return { code = "UNKNOWN", field = name, detail = "Unknown setting: " .. name }
        end
        if not setting.app then
            return { code = "SET_IN_COMPOSER", field = name, detail = setting.property .. " is set in Composer only (DirectorLink's properties), for every key" }
        end
    end
    for _, name in ipairs(names) do
        local setting = byKey[name]
        if Settings.composerValue(setting, changes[name]) == nil then
            local choices = {}
            for index, choice in ipairs(setting.choices) do
                choices[index] = choice[1]
            end
            return { code = "INVALID", field = name, detail = name .. " must be one of " .. table.concat(choices, ", ") }
        end
    end
    return nil
end

-- Sets each setting of a checked body as Composer would, then applies it as a change in Composer
-- is applied (`by`: the API key that sent it). A setting already at its value is left alone.
-- Returns the keys changed, in Composer's order, and the ones whose change was set but could not
-- be applied at once ({ key, property, value, error }): the property keeps the new value, which is
-- the one DirectorLink reads, and the answer says so (src/api/handlers/settings.lua).
function Settings.change(changes, by)
    local changed, failed = {}, {}
    for _, setting in ipairs(Settings.LIST) do
        local value = changes[setting.key]
        if setting.app and value ~= nil and Properties ~= nil and value ~= Settings.value(setting) then
            local composerValue = Settings.composerValue(setting, value)
            Properties[setting.property] = composerValue
            -- Before Composer is told: Director may report it back at once (Settings.changed).
            state.applied[setting.property] = composerValue
            pcall(function()
                C4:UpdateProperty(setting.property, composerValue)
            end)
            changed[#changed + 1] = setting.key
            if state.apply then
                local ok, err = pcall(state.apply, setting.property, by)
                if not ok then
                    failed[#failed + 1] = { key = setting.key, property = setting.property, value = composerValue, error = tostring(err) }
                end
            end
        end
    end
    return changed, failed
end

-- DirectorLink applied `value` of `property` (src/main.lua, propertyChanged).
function Settings.applied(property, value)
    state.applied[property] = value
end

-- OnPropertyChanged: true when the property's value is not the one DirectorLink applied last, so
-- a change made in Composer. Director reporting back a value DirectorLink set, however late and
-- however often, is not one.
function Settings.changed(property)
    return Properties == nil or Properties[property] ~= state.applied[property]
end

-- What the log says of a change: who made it, from where, and the value now.
function Settings.changeData(property, by)
    local setting = byProperty[property]
    local data = {
        property = property,
        value = Properties and Properties[property] or Json.null,
        from = by and "app" or "composer",
    }
    if setting then
        data.setting = setting.key
    end
    if by then
        data.key_id = by.id
        data.key_name = by.name
    end
    return data
end

return Settings
