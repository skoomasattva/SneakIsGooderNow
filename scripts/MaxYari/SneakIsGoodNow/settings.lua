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
            key = "UseModSneakInput",
            renderer = "checkbox",
            default = false,
            name = "Use mod's own sneak key",
            description = "Let the mod drive sneaking. Bind the key below, then unbind OpenMW's own Sneak in Options > Controls. Removes the sneak-stance flicker.",
        },
        {
            key = "SneakKeyBinding",
            renderer = "inputBinding",
            default = "",
            argument = { type = "action", key = "SneakIsGoodNow_Sneak" },
            name = "Mod sneak key",
            description = "Key/button used when the mod owns the sneak key.",
        },
        {
            key = "ModSneakToggle",
            renderer = "checkbox",
            default = true,
            name = "Sneak key toggles",
            description = "On: tap to toggle. Off: hold to sneak. Only applies to the mod's own key.",
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
            description = "From screen center. Negative = left, positive = right.",
        },
        {
            key = "HudOffsetY",
            renderer = "number",
            default = 0,
            argument = { min = -1, max = 1 },
            name = "Meter vertical offset",
            description = "From screen center. Negative = up, positive = down.",
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
    description = "Sneak attack damage can now scale per weapon type based on sneak level. Base multiplier always applies flat bonus, then weapon damage bonuses scale with sneak and stack on top.",
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
            default = 8,
            argument = { l10n = 'SneakIsGoodNow', items = BONUS_STEPS },
            name = "Hand-to-hand",
            description = "Unarmed drains fatigue until knockout; the mod multiplies that too, so a sneak punch can drop someone in one hit.",
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
            default = 0.5,
            argument = { min = 0, max = 1 },
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
            key = "SneakMessageY",
            renderer = "number",
            default = 0.85,
            argument = { min = 0, max = 1 },
            name = "Message height",
            description = "Vertical position. 0 = top, 1 = bottom. (Horizontally centered.)",
        },
    },
}

-- One-time migration. Earlier versions kept most settings in the single 'SettingsSneakIsGoodNow' group;
-- they've since been split into their own groups. Because these are permanentStorage settings, the old
-- values still linger in that section, and SettingsHelper resolves a key to the FIRST section that has a
-- value for it -- so a stale leftover here would shadow (and freeze) the real, moved setting. Drop any
-- key from the old section that no longer belongs to it. Idempotent: after the first run there's nothing
-- left to prune. Keep this list in sync with the 'Sneak Key' group above.
local function pruneMovedSettings(sectionName, keptKeys)
    local section = storage.playerSection(sectionName)
    local keep = {}
    for _, k in ipairs(keptKeys) do keep[k] = true end
    for key in pairs(section:asTable()) do
        if not keep[key] then section:set(key, nil) end
    end
end
pruneMovedSettings('SettingsSneakIsGoodNow', { 'UseModSneakInput', 'SneakKeyBinding', 'ModSneakToggle' })

return {
    settings = SettingsHelper:new({
        'SettingsSneakIsGoodNow',
        'SettingsSneakIsGoodNowDetection',
        'SettingsSneakIsGoodNowDamage',
        'SettingsSneakIsGoodNowWeaponDamage',
        'SettingsSneakIsGoodNowFeedback',
    })
}
