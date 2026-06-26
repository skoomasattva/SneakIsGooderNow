-- FakeSneakGlobal.lua  --  ISOLATED EXPERIMENT (GLOBAL scope)
--
-- Tiny bridge for FakeSneak.lua. `setScale` can only be called from a global script, so the player
-- script lerps its fake-sneak body scale and sends SneakIsGoodNow_SetScale{ object, scale } across
-- while it's changing; we just apply it. Remove by deleting this file's line from the omwscripts.

return {
    eventHandlers = {
        SneakIsGoodNow_SetScale = function(data)
            if data and data.object then data.object:setScale(data.scale) end
        end,
    },
}
