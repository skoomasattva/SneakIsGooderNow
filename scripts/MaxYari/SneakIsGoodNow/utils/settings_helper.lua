local storage = require("openmw.storage")
local async = require("openmw.async")

--- A little helper for live settings updates without constantly hitting storage.
--- Accepts a single section name or a list of them (settings are now split across several
--- groups for the in-game menu); a key is looked up in whichever section actually owns it.
local SettingsHelper = {}
SettingsHelper.__index = SettingsHelper
function SettingsHelper:new(sectionNames)
    if type(sectionNames) == "string" then sectionNames = { sectionNames } end

    local stores = {}
    for _, name in ipairs(sectionNames) do
        stores[#stores + 1] = storage.playerSection(name)
    end

    local inst = {
        stores = stores,
        settings = {},
        keyStore = {},        -- cached: key -> the store that owns it
        trackedSettings = {}
    }

    -- Any of the sections changing refreshes every tracked key from its owning store.
    for _, store in ipairs(stores) do
        store:subscribe(async:callback(function()
            for key, _ in pairs(inst.trackedSettings) do
                local s = inst.keyStore[key]
                if s then inst.settings[key] = s:get(key) end
            end
        end))
    end

    setmetatable(inst, self)
    return inst
end

function SettingsHelper:__index(key)
    if rawget(self, key) then return rawget(self, key) end
    if not self.trackedSettings[key] then
        self.trackedSettings[key] = true
        -- Find the section that owns this key (the first one returning a non-nil value).
        local store = self.stores[1]
        local val = nil
        for _, s in ipairs(self.stores) do
            local ok, v = pcall(function() return s:get(key) end)
            if ok and v ~= nil then store = s; val = v; break end
        end
        self.keyStore[key] = store
        self.settings[key] = val
    end
    return self.settings[key]
end

return SettingsHelper
----------------------------------
