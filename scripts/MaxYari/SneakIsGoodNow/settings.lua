local mp = "scripts/MaxYari/SneakIsGoodNow/"

local I = require('openmw.interfaces')
local input = require('openmw.input')
local storage = require('openmw.storage')

local SettingsHelper = require(mp .. "utils/settings_helper")

-- Controller-friendly "select" steps for the multiplier settings (no fiddly number typing).
-- The "select" renderer stores the chosen item itself, so these are the actual multipliers.
local BASELINE_STEPS = { 1, 2, 3, 4, 5 }
local BONUS_STEPS    = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

-- Mod-owned sneak action. Lets the player bind a dedicated sneak key (and unbind OpenMW's own
-- Sneak binding) so this mod drives controls.sneak directly, removing the brief sneak-stance
-- flicker that happens when the engine starts sneaking a few frames before a detection kick.
input.registerAction {
    key = "SneakIsGoodNow_Sneak",
    type = input.ACTION_TYPE.Boolean,
    l10n = 'SneakIsGoodNow',
    defaultValue = false,
}

I.Settings.registerPage {
    key = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Sneak! Sneak Is Good Now.',
    description = "The mod is active. Go sneak now.",
}

-- Group: sneak key handling -------------------------------------------------
I.Settings.registerGroup {
    key = 'SettingsSneakIsGoodNow',
    page = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Sneak Key',
    -- Groups with no `order` all default to 0, and the engine's group sort can't break that tie
    -- deterministically -> menu order shuffles between sessions. Give every group an explicit order.
    order = 1,
    permanentStorage = true,
    settings = {
        {
            key = "SneakKeyBinding",
            renderer = "inputBinding",
            default = "",
            argument = { type = "action", key = "SneakIsGoodNow_Sneak" },
            name = "Sneak Binding",
            description = "Key/button used when the mod owns the sneak key. Bind it here, then unbind OpenMW's own Sneak in Options > Controls.",
        },
        {
            key = "ModSneakToggle",
            renderer = "select",
            default = "Toggle",
            argument = { l10n = 'SneakIsGoodNow', items = { "Toggle", "Hold" } },
            name = "Sneak Mode",
            description = "Toggle: tap to toggle sneak. Hold: hold the key to sneak.",
        },
    },
}

-- Group: detection display + difficulty -------------------------------------
I.Settings.registerGroup {
    key = 'SettingsSneakIsGoodNowDetection',
    page = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Detection',
    order = 2,
    permanentStorage = true,
    settings = {
        {
            key = "SingleHudMeter",
            renderer = "checkbox",
            default = true,
            name = "Single HUD meter",
            description = "One centered meter (highest detection) instead of a marker over each NPC's head.",
        },
        {
            key = "AlwaysShowMeter",
            renderer = "checkbox",
            default = false,
            name = "Always show while sneaking",
            description = "Keep the single meter on screen the whole time you're sneaking, even at zero detection.",
        },
        {
            key = "MarkersAlpha",
            renderer = "number",
            default = 1,
            argument = { min = 0, max = 1 },
            name = "Meter opacity",
        },
        {
            key = "HudOffsetX",
            renderer = "number",
            default = 0,
            argument = { min = -1, max = 1 },
            name = "Meter horizontal offset",
            description = "Center is 0. Increase to move right, decrease to move down.",
        },
        {
            key = "HudOffsetY",
            renderer = "number",
            default = 0.45,
            argument = { min = -1, max = 1 },
            name = "Meter vertical offset",
            description = "Center is 0. Increase to move down, decrease to move up.",
        },
        {
            key = "DifficultyMultiplier",
            renderer = "number",
            default = 1.0,
            argument = { min = 0.1, max = 5.0 },
            name = "Difficulty multiplier",
            description = "Higher = enemies notice you faster.",
        },
    },
}

-- Group: sneak-attack damage ------------------------------------------------
-- Shared explanation lives in the group description so the individual settings don't repeat it.
I.Settings.registerGroup {
    key = 'SettingsSneakIsGoodNowDamage',
    page = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Sneak Attack Damage',
    description = "Sneak attack damage scales per weapon type, based on sneak level. Base multiplier always applies a flat bonus, then weapon damage bonuses scale with sneak and stack on top.",
    order = 3,
    permanentStorage = true,
    settings = {
        {
            key = "BaselineSneakDamage",
            renderer = "select",
            default = 2,
            argument = { l10n = 'SneakIsGoodNow', items = BASELINE_STEPS },
            name = "Base Damage Multiplier",
            description = "Sneak attack damage is always multiplied by at least this much regardless of weapon or sneak level.",
        },
    }
}
I.Settings.registerGroup {
    key = 'SettingsSneakIsGoodNowWeaponDamage',
    page = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Maximum Weapon Damage Multipliers',
    description = "Maximum damage multplier per weapon type to add to base sneak damage multiplier. Scales with sneak level.",
    order = 4,
    permanentStorage = true,
    settings = {
        {
            key = "ShortBladeSneakDamage",
            renderer = "select",
            default = 8,
            argument = { l10n = 'SneakIsGoodNow', items = BONUS_STEPS },
            name = "Short blade",
        },
        {
            key = "OneHandedSneakDamage",
            renderer = "select",
            default = 3,
            argument = { l10n = 'SneakIsGoodNow', items = BONUS_STEPS },
            name = "One-handed",
        },
        {
            key = "TwoHandedSneakDamage",
            renderer = "select",
            default = 1,
            argument = { l10n = 'SneakIsGoodNow', items = BONUS_STEPS },
            name = "Two-handed",
        },
        {
            key = "MarksmanSneakDamage",
            renderer = "select",
            default = 1,
            argument = { l10n = 'SneakIsGoodNow', items = BONUS_STEPS },
            name = "Marksman",
        },
        {
            key = "HandToHandSneakDamage",
            renderer = "select",
            default = 13,
            argument = { l10n = 'SneakIsGoodNow', items = BONUS_STEPS },
            name = "Hand-to-hand",
            description = "Multiplies fatigue damage for hand so a sneak punch can knock someone down.",
        },
    },
}

-- Group: combat tweaks + on-screen feedback ---------------------------------
I.Settings.registerGroup {
    key = 'SettingsSneakIsGoodNowFeedback',
    page = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Combat & Feedback',
    order = 5,
    permanentStorage = true,
    settings = {
        {
            key = "WeaponBonus",
            renderer = "number",
            default = 1,
            argument = { min = 0, max = 2 },
            name = "Weapon skill bonus",
            description = "Bonus to weapon skill while sneaking (0.5 = +50%).",
        },
        {
            key = "ShowSneakAttackMessage",
            renderer = "checkbox",
            default = true,
            name = "Show sneak attack message",
            description = "Show a 'Critical Strike for <X> damage!' confirmation on a successful sneak hit.",
        },
        {
            key = "SneakAttackMessageStyle",
            renderer = "select",
            default = "Classic",
            argument = { l10n = 'SneakIsGoodNow', items = { "Classic", "Modern" } },
            name = "Sneak attack message style",
            description = "Classic: standard vanilla style message box. Modern: Floating text that fades out, looks better with some mods and scaling settings, but can get covered by message boxes.",
        },
        {
            key = "SneakMessageX",
            renderer = "number",
            default = 0,
            argument = { min = -1, max = 1 },
            name = "Message horizontal offset",
            description = "Center is 0. Increase to move right, decrease to move left.",
        },
        {
            key = "SneakMessageY",
            renderer = "number",
            default = 0.7,
            argument = { min = -1, max = 1 },
            name = "Message vertical offset",
            description = "Center is 0. Increase to move down, decrease to move up.",
        },
    },
}

-- One-time migration. Earlier versions kept most settings in the single 'SettingsSneakIsGoodNow' group;
-- they've since been split into their own groups. Because these are permanentStorage settings, the old
-- values still linger in that section, and SettingsHelper resolves a key to the FIRST section that has a
-- value for it -- so a stale leftover here would shadow (and freeze) the real, moved setting. Drop any
-- key from the old section that no longer belongs to it. Idempotent: after the first run there's nothing
-- left to prune. Keep this list in sync with the 'Sneak Key' group above.
-- NOTE: 'UseModSneakInput' is intentionally NOT in the kept list -- it was removed (the mod always owns
-- the sneak key now), so its leftover value is pruned here.
local function pruneMovedSettings(sectionName, keptKeys)
    local section = storage.playerSection(sectionName)
    local keep = {}
    for _, k in ipairs(keptKeys) do keep[k] = true end
    for key in pairs(section:asTable()) do
        if not keep[key] then section:set(key, nil) end
    end
end
pruneMovedSettings('SettingsSneakIsGoodNow', { 'SneakKeyBinding', 'ModSneakToggle' })

-- ModSneakToggle changed from a checkbox (boolean) to a select (string "Toggle"/"Hold"). An old boolean
-- value lingering in permanentStorage would not match the new items list and breaks the select renderer.
-- Clear any non-string value so the new "Toggle" default takes over.
local sneakKeySection = storage.playerSection('SettingsSneakIsGoodNow')
if type(sneakKeySection:get('ModSneakToggle')) ~= 'string' then
    sneakKeySection:set('ModSneakToggle', nil)
end

return {
    settings = SettingsHelper:new({
        'SettingsSneakIsGoodNow',
        'SettingsSneakIsGoodNowDetection',
        'SettingsSneakIsGoodNowDamage',
        'SettingsSneakIsGoodNowWeaponDamage',
        'SettingsSneakIsGoodNowFeedback',
    })
}
