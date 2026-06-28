

local mp = "scripts/MaxYari/SneakIsGoodNow/"
DebugLevel = 0

local I = require("openmw.interfaces")
local types = require("openmw.types")
local nearby = require("openmw.nearby")
local core = require("openmw.core")
local omwself = require("openmw.self")
local util = require("openmw.util")
local input = require("openmw.input")
local ui = require("openmw.ui")

local DEFS = require(mp .. 'utils/sneak_defs')
local gutils = require(mp .. 'utils/gutils')
local itemutil = require(mp .. "utils/item_utils")
local detection = require(mp .. "detection_math")
local aggression = require(mp .. "aggression_math")
local DetectionMarker = require(mp .. "Sneak_ui_elements")
local settings = require(mp .. 'settings').settings
local selfActor = gutils.Actor:new(omwself)

-- Maps each weapon TYPE to the setting key holding its Sneak-scaled sneak-damage bonus. Short blade is
-- its own type (distinct from the one-handed axe/blunt/longblade group), so it naturally takes priority.
-- Arrow/Bolt are ammo (never the CarriedRight weapon), included only for completeness.
local WT = types.Weapon.TYPE
local WEAPON_CATEGORY_SETTING = {
    [WT.ShortBladeOneHand] = "ShortBladeSneakDamage",
    [WT.AxeOneHand]        = "OneHandedSneakDamage",
    [WT.BluntOneHand]      = "OneHandedSneakDamage",
    [WT.LongBladeOneHand]  = "OneHandedSneakDamage",
    [WT.LongBladeTwoHand]  = "TwoHandedSneakDamage",
    [WT.AxeTwoHand]        = "TwoHandedSneakDamage",
    [WT.BluntTwoClose]     = "TwoHandedSneakDamage",
    [WT.BluntTwoWide]      = "TwoHandedSneakDamage",
    [WT.SpearTwoWide]      = "TwoHandedSneakDamage",
    [WT.MarksmanBow]       = "MarksmanSneakDamage",
    [WT.MarksmanCrossbow]  = "MarksmanSneakDamage",
    [WT.MarksmanThrown]    = "MarksmanSneakDamage",
    [WT.Arrow]             = "MarksmanSneakDamage",
    [WT.Bolt]              = "MarksmanSneakDamage",
}

-- Engine sneak-crit GMSTs, read live for the optional crit-strike debug readout. The mod's omwaddon
-- neutralizes these so the mod owns sneak damage; reading them at runtime shows what the engine itself
-- would still apply on an unaware hit (melee = fCombatCriticalStrikeMult, ranged = fCombatKODamageMult).
-- These mirror the constants SneakActor.lua reads. GMSTs don't change, so read once.
local MELEE_CRIT_MULT = core.getGMST("fCombatCriticalStrikeMult") or 4.0
local RANGED_CRIT_MULT = core.getGMST("fCombatKODamageMult") or 1.5

gutils.print("Sneak! E-N-G-A-G-E-D", 0)

local sneakCheckPeriod = 0.33 -- seconds between sneak checks per actor
local followTargetsCheckPeriod = 2.0 -- seconds between follow target updates per actor
local losCheckPeriod = 0.2
local detectionDecreaseRate = 0.25  -- fixed decrease rate per second

-- "ps" stands for "Player State"
local ps = {
    isSneaking = false,      -- real sneak (controls.sneak): attempting AND not locked out
    attemptingSneak = false, -- sustained sneak intent (hold/toggle); drives fake sneak + the meter
    detectedByNonAggro = false,
    lockedOut = false,
    isMoving = false,
    isInvisible = false,
    chameleon = 0
}

local extraMods = {
    elusivenessMod = 1.0,
    elusivenessConst = 0
}

local modifiedSkill = nil
local skillMod = 0
local lastCell = nil

local nearbyCheckTimer = 0
local nearbyCheckPeriod = 0.2

local effectsCheckTimer = 0
local effectsCheckPeriod = 0.2

local observerActorStatuses = {}
local persistantActorStatuses = {}

local SNEAK_ACTION = "SneakIsGoodNow_Sneak"
local hudMarker = nil  -- single shared HUD detection meter (when SingleHudMeter is enabled)
local modSneakHeldPrev = false  -- previous frame's mod-sneak action value (for toggle edge detection)
local modSneakToggleState = false  -- current toggled sneak state when ModSneakToggle is enabled

-- True while any observer is currently fighting the player. Module-level so the interface
-- accessors below can read it; recomputed every tick in detectionLogicTick.
local inCombat = false

-- Tracks the previous tick's sneaking state for the sneak-damage-bonus stale-cleanup sweep.
local lastSneakingForBonus = false

-- HUD eye visibility ---------------------------------------------------------------------------
-- The meter is shown iff the player is attempting to sneak (ps.attemptingSneak) -- nothing else.
-- While attempting it tracks live detection (and the cooldown decay during a lockout); when intent
-- ends it quick-fades out.
local EYE_FADE = 0.5        -- seconds to quick-fade the eye out once intent ends
local eyePhase = nil        -- nil | "show" | "fade"
local eyeFadeTimer = 0

-- Sneak-attack confirmation message ("Critical Strike for #.#X damage!") ------------------------
-- Mirrors the Horizontal Compass cell-name display: a single HUD Text element, shown solid then
-- faded out. The target script reports the total multiplier on a landed sneak hit; we just display.
local SNEAK_MSG_DURATION = 3.0     -- seconds the message is shown before it's gone
local SNEAK_MSG_FADE = 1.0         -- seconds of fade-out at the tail end
local SNEAK_MSG_COLOR = util.color.hex("caa676")-- ("efc36b")  -- the mod's tan/gold (matches the vanilla UI)
local sneakMsgElement = nil
local sneakMsgTimer = 0            -- counts down from SNEAK_MSG_DURATION

-- Crit-strike debug readout ---------------------------------------------------------------------
-- Optional diagnostic HUD (styled like FakeSneak's debug readout) showing the live sneak-attack
-- multiplier breakdown. Built/torn down by updateCritDebug below per the CritStrikeDebugHud setting.
local critDebugEl = nil

-- Ranged sneak-attack latch -------------------------------------------------------------------------
-- A projectile's flight time lets the target finish detecting the player AFTER the shot is loosed, which
-- would otherwise strip the sneak crit at impact. We detect the shot the frame it leaves the weapon (the
-- equipped ammo / thrown stack drops by one) and broadcast SneakLatch so each observer freezes its
-- release-time eligibility (see SneakActor.lua). Tracked here to spot the count decrement.
local RANGED_LATCH_TTL = 3.0  -- seconds a latch stays valid; generously covers a projectile's flight
local prevShotCount = nil     -- last frame's ammo/thrown-stack count
local prevShotKey = nil       -- record id of that stack, so a weapon/ammo swap isn't misread as a shot

local function showSneakMessage(mult)
    if not settings.ShowSneakAttackMessage then return end
    local text = string.format("Critical Strike for %.1fX damage!", mult)
    -- "Classic" routes through the engine's standard top-of-screen message; "Modern" uses the
    -- mod's own centered, fading HUD text below.
    if settings.SneakAttackMessageStyle == "Classic" then
        ui.showMessage(text)
        return
    end
    -- SneakMessageX/Y use the same 0=center convention as HudOffsetX/Y: convert to relativePosition.
    local relX = 0.5 + (settings.SneakMessageX or 0) * 0.5
    local relY = 0.5 + (settings.SneakMessageY or 0) * 0.5
    if not sneakMsgElement then
        sneakMsgElement = ui.create {
            layer = "HUD",
            type = ui.TYPE.Text,
            props = {
                text = text,
                textSize = 22,
                textColor = SNEAK_MSG_COLOR,
                textShadow = true,
                relativePosition = util.vector2(relX, relY),
                anchor = util.vector2(0.5, 0.5),
                alpha = 1,
            }
        }
    else
        sneakMsgElement.layout.props.text = text
        sneakMsgElement.layout.props.relativePosition = util.vector2(relX, relY)
        sneakMsgElement.layout.props.alpha = 1
        sneakMsgElement:update()
    end
    sneakMsgTimer = SNEAK_MSG_DURATION
end

local function onSneakHit(e)
    showSneakMessage(e.mult or 1)
end

-- Crit-strike debug readout. Same element style as FakeSneak.lua's updateDebug (white HUD Text, shadow,
-- top-center) but multi-line and positioned just below it so the two don't overlap. Gated on the setting,
-- tearing the element down when off.
local function updateCritDebug(label)
    if not settings.CritStrikeDebugHud then
        if critDebugEl then critDebugEl:destroy(); critDebugEl = nil end
        return
    end
    if not critDebugEl then
        critDebugEl = ui.create {
            layer = "HUD",
            type = ui.TYPE.Text,
            props = {
                text = label,
                textSize = 20,
                textColor = util.color.rgb(1, 1, 1),
                textShadow = true,
                multiline = true,
                textAlignH = ui.ALIGNMENT.Center,
                relativePosition = util.vector2(0.5, 0.18),
                anchor = util.vector2(0.5, 0),
            },
        }
    else
        critDebugEl.layout.props.text = label
        critDebugEl:update()
    end
end

local interface = {
    version = 1.1,
    observerActorStatuses = observerActorStatuses,
    playerState = ps,
    extraMods = extraMods,
    -- True while the player is blocked from sneaking — the post-detection cooldown OR active combat.
    -- Companion HUD/crosshair mods can poll this each frame (e.g. to tint the crosshair red).
    isSneakBlocked = function() return ps.lockedOut end,
    -- "combat" | "cooldown" | nil — for consumers that want to differentiate the two block sources.
    sneakBlockReason = function()
        if not ps.lockedOut then return nil end
        return inCombat and "combat" or "cooldown"
    end,
}

    
-- "ast" stands for "Actor's Status"
local function getAst(actor)
    local ast = persistantActorStatuses[actor.id]
    if not ast then
        -- gutils.print("Creating new persistant actor status for " .. actor.recordId)
        ast = {
            actor = actor,
            gactor = gutils.Actor:new(actor),
            cell = actor.cell,
            distance = 250,
            progress = 0.0,
            successRolls = 0
        }

        persistantActorStatuses[actor.id] = ast
    end
    return ast
end

local function getAstIfExists(actor)
    if not persistantActorStatuses[actor.id] then return nil end
    return getAst(actor)
end




local function getDetectionVelocity(sneakChance)
    -- returns a velocity multiplier based on sneak chance
    -- sneakChance is 0-100
    -- at 0 sneakChance, velocity is 2.0 (detected quickly)
    -- at 100 sneakChance, velocity is 0.05 (detection slows to a crawl)
    local maxDetectDur = 8
    local minDetectDur = 0.5
    if not sneakChance then
        sneakChance = 0
    end

    local detectDur = util.remap(sneakChance, 0, 100, minDetectDur, maxDetectDur)
    return 1 / detectDur
end

local function posAboveActor(actor)
    local bbox = actor:getBoundingBox()
    return bbox.center + util.vector3(0, 0, bbox.halfSize.z)
end

local function getFollowTargets(actor)
    actor:sendEvent("MaxYariUtil_GetFollowTargets")
end

local function isFriend(ast)    
    if not ast.followTargets then return false end
    if gutils.arrayContains(ast.followTargets, omwself.object) and (not ast.combatTargets or not gutils.arrayContains(ast.combatTargets, omwself.object)) then
        return true
    end
    return false
end





local function isActorKnockedOut(actor)
    for _, spell in pairs(types.Actor.activeSpells(actor)) do
        if spell.id == DEFS.KNOCKOUT_SPELL_ID then return true end
    end
    return false
end


-- Main logic starts here -----------------------------------------------
-------------------------------------------------------------------------
local function detectionLogicTick(dt)
    -- Fetching cell changes and removing actors from other cells
    local cell = omwself.cell
    if not lastCell or (lastCell ~= cell and not (lastCell.isExterior and cell.isExterior)) then
        lastCell = cell
        for id, ast in pairs(persistantActorStatuses) do
            if ast.cell ~= cell then
                if ast.marker then
                    ast.marker:destroy()
                end
                -- Clear any pending sneak state so a stale value can't buff/announce a later non-sneak hit
                if ast.pushedSneak or (ast.pushedSneakMult or 1) ~= 1 then
                    ast.actor:sendEvent(DEFS.e.SneakBonus, { mult = 1, sneak = false })
                end
                persistantActorStatuses[id] = nil
                observerActorStatuses[id] = nil
            end
        end
    end

    -- Throttled nearby scan: new observers picked up every ~0.2s instead of every frame;
    -- existing observers in observerActorStatuses continue to be processed every frame below.
    -- Runs at ALL times now (not gated on sneaking) so detection stays "warm" on standby: in-LOS
    -- observers climb to detected via sneakCheck's not-sneaking early-return, out-of-LOS ones decay.
    -- This means the meter has a current value the instant you enter sneak instead of restarting at 0,
    -- which closes the toggle-sneak grace-period exploit.
    nearbyCheckTimer = nearbyCheckTimer + dt
    if nearbyCheckTimer >= nearbyCheckPeriod then
        nearbyCheckTimer = 0
        for _, actor in ipairs(nearby.actors) do

            if actor == omwself.object then goto continue end

            local isDead = types.Actor.isDead(actor)

            -- Don't add dead actors to observers, but mark them dead if ast exists
            local ast = nil
            if isDead then
                ast = getAstIfExists(actor)
                if ast then ast.isDead = true end
                goto continue
            end

            if not ast then ast = getAst(actor) end

            local distance = (omwself.position - actor.position):length()
            ast.distance = distance
            ast.isDead = false

            -- Add to observerActorStatuses if within detection range and not a friend
            if distance <= detection.detectionRange and not ast.isFriend then
                observerActorStatuses[actor.id] = ast
            end

            ::continue::
        end
    end
    
    ps.detectedByNonAggro = false
    local anyDetection = false
    inCombat = false
    local useHudMeter = settings.SingleHudMeter
    local maxProgress = 0.0
    local maxAggressive = false

    -- Total sneak-attack damage multiplier for the currently equipped weapon, computed once per tick and
    -- pushed (eligibility-gated) to each observer below. Additive: the flat baseline plus a Sneak-scaled
    -- weapon factor (0 unless short blade / marksman). The mod now owns sneak damage outright (the omwaddon
    -- zeroes the engine's crit GMSTs), so this multiplier IS the sneak crit. The breakdown is computed every
    -- tick (even when not sneaking) so the optional crit-strike debug readout reflects the live equipped
    -- weapon; sneakMult itself is only applied to hits while actually sneaking.
    local baseMult = settings.BaselineSneakDamage
    local weaponObj = selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.CarriedRight)
    local weaponCategory, weaponSetting
    if weaponObj and types.Weapon.objectIsInstance(weaponObj) then
        weaponCategory = WEAPON_CATEGORY_SETTING[types.Weapon.record(weaponObj).type]
        weaponSetting = weaponCategory and settings[weaponCategory]
    else
        -- Nothing in the weapon hand = unarmed (hand-to-hand).
        weaponCategory = "HandToHandSneakDamage"
        weaponSetting = settings.HandToHandSneakDamage
    end
    local sneakSkill = selfActor:getSkillStat("sneak").modified
    local weaponFactor = 0
    if weaponSetting and weaponSetting > 0 then
        weaponFactor = weaponSetting * (sneakSkill / 100)
    end
    local sneakMult = 1
    if ps.isSneaking then
        sneakMult = baseMult + weaponFactor
    end

    -- Crit-strike debug readout: show the full multiplier breakdown so a wrong sneak hit can be diagnosed.
    if settings.CritStrikeDebugHud then
        updateCritDebug(string.format(
            "CRIT DEBUG\nGMST melee=%.2f  ranged=%.2f\nbase=%.2f  weapon cap=%s (%s)\nsneak=%.0f -> weapon factor=%.2f\nTOTAL sneakMult=%.2f%s",
            MELEE_CRIT_MULT, RANGED_CRIT_MULT,
            baseMult, tostring(weaponSetting), tostring(weaponCategory),
            sneakSkill, weaponFactor,
            sneakMult, ps.isSneaking and "" or "  (not sneaking)"))
    else
        updateCritDebug(nil)
    end

    for actorId, ast in pairs(observerActorStatuses) do
        -- LOS check for all observer actors (regardless of detection range)
        if ast.losChecker == nil then
            ast.losChecker = gutils.cachedFunction(detection.LOS, losCheckPeriod, math.random() * losCheckPeriod)
        end

        -- Sneak check for all observers (reuses inLOS from above)
        if ast.sneakChecker == nil then
            ast.sneakChecker = gutils.cachedFunction(detection.sneakCheck, sneakCheckPeriod, math.random() * sneakCheckPeriod)
        end
        if ast.followTargetsChecker == nil then
            ast.followTargetsChecker = gutils.cachedFunction(getFollowTargets, followTargetsCheckPeriod, math.random() * followTargetsCheckPeriod)
        end

        ast.inLOS = ast.losChecker(omwself.object, ast.actor)
        local isNotDetected, newSneakChance = ast.sneakChecker(ast, ps, extraMods)
        ast.followTargetsChecker(ast.actor)

        ast.noticing = not isNotDetected
        if newSneakChance ~= nil then ast.sneakChance = newSneakChance end
        
        if ast.fightingPlayer then
            ast.isAggressive = true
        else
            ast.isAggressive = aggression.isAggressive(ast, omwself.object)
        end        

        -- Manage detection progress ----
        ---------------------------------
        local detectionVel = getDetectionVelocity(ast.sneakChance)

        if ast.progress == nil then ast.progress = 0.0 end
        if ast.successRolls == nil then ast.successRolls = 0 end

        -- Handle knocked out actors (Devilish Sleep Spell compatibility)
        if ast.isKnockedOut then
            ast.isKnockedOut = isActorKnockedOut(ast.actor)
        end

        -- Handle dead/invalid actors
        if ast.isDead or ast.isKnockedOut or not ast.actor:isValid() then
            ast.noticing = false
            ast.progress = 0.0
            ast.successRolls = 0
        elseif ast.fightingPlayer then
            ast.noticing = true
            ast.progress = 1.0
        elseif not ast.inLOS then
            -- Out of LOS: immediate fixed decrease, set successRolls to 3
            ast.progress = math.max(0.0, ast.progress - dt * detectionDecreaseRate)
            ast.successRolls = 3
        elseif ast.noticing then
            -- Detected: increase with sneak-based velocity, reset counter
            ast.progress = math.min(1.0, ast.progress + dt * detectionVel)
            ast.successRolls = 0
        else
            -- Not detected: count success rolls
            ast.successRolls = ast.successRolls + 1
            if ast.successRolls >= 3 then
                -- After 3 successes, start decreasing at fixed rate
                ast.progress = math.max(0.0, ast.progress - dt * detectionDecreaseRate)
            end
            -- else: progress stays same
        end

        -- Track whether any observer still has detection progress; used to release the lockout
        if ast.progress > 0.0 then anyDetection = true end
        if ast.fightingPlayer and not ast.isDead and not ast.isKnockedOut then inCombat = true end

        -- Push the sneak-attack damage factor to this actor (deduped). Eligible = we're sneaking and
        -- this actor hasn't fully detected us and isn't already fighting us. The actor applies it on hit.
        local eligible = ps.isSneaking and not ast.fightingPlayer and ast.progress < 1.0 and not ast.isDead
        local desiredMult = eligible and sneakMult or 1
        if desiredMult ~= (ast.pushedSneakMult or 1) or eligible ~= (ast.pushedSneak or false) then
            ast.actor:sendEvent(DEFS.e.SneakBonus, { mult = desiredMult, sneak = eligible })
            ast.pushedSneakMult = desiredMult
            ast.pushedSneak = eligible
        end

        -- Track the highest detection for the single HUD meter
        if not ast.isDead and not ast.isKnockedOut and ast.progress > maxProgress then
            maxProgress = ast.progress
            maxAggressive = ast.isAggressive
        end

        -- Send spotted event and break sneak only when detection progress reaches 1.0
        if ast.progress >= 1.0 then
            if ast.isAggressive then
                if ast.fightingPlayer then
                    -- Active combat: lock out every frame the player is attempting to sneak,
                    -- since progress is pinned at 1.0 and there's no single crossing event.
                    if ps.attemptingSneak then ps.lockedOut = true end
                else
                    -- Non-combat: lock out whenever we're attempting and this observer is already at
                    -- full detection -- including the frame you press sneak with background-built
                    -- detection already maxed. (Previously this required a fresh crossing of 1.0, which
                    -- handed you a free hidden moment before the kick: the real sneak check would dip
                    -- progress below 1.0 then re-climb, and only that re-crossing tripped the lockout.)
                    if ps.attemptingSneak then
                        ps.lockedOut = true
                    end
                end
            else
                ps.detectedByNonAggro = true
            end
        end

        -- Manage ui markers ------------------
        ---------------------------------------
        if useHudMeter then
            -- Single HUD meter mode: no per-NPC markers. Clean up any leftover from a prior toggle.
            if ast.marker then
                ast.marker:destroy()
                ast.marker = nil
            end
        else
            -- Show markers only while attempting to sneak (matches the single-HUD meter's visibility)
            local shouldShowMarker = ps.attemptingSneak and not ast.isDead and not ast.isKnockedOut and ast.inLOS
            if shouldShowMarker then
                -- If marker doesnt exist but should - make it
                if not ast.marker then ast.marker = DetectionMarker:new() end
            elseif ast.marker then
                -- If it shouldnt exist but does - remove it
                local isSuccesful = ast.progress >= 1.0
                ast.marker:disappear(isSuccesful)
            end

            if ast.marker and ast.marker.destroyed then
                ast.marker = nil
            end

            if ast.marker then
                -- Update the marker's progress and position
                ast.marker:setProgress(ast.progress)
                ast.marker:setWorldPos(posAboveActor(ast.actor))
                ast.marker:setAggressive(ast.isAggressive)
            end

            -- Update tweeners here to avoid a second full pass over observerActorStatuses in onUpdate
            if ast.marker then ast.marker:updateTweeners(dt) end
        end

        -- Final cleanup, if no marker and no progress - remove the status object --
        ----------------------------------------------------------------------------
        if (ast.marker == nil) and (ast.progress <= 0.0) then
            observerActorStatuses[actorId] = nil
        end

        ::continue::
    end

    -- Release the post-detection lockout once every observer that noticed has fully decayed
    -- (also covers cell changes, which wipe the observer list above).
    if ps.lockedOut and not anyDetection then
        ps.lockedOut = false
    end

    -- On the frame sneaking stops, clear any sneak-damage bonus still pushed out — including to actors
    -- that already dropped out of the observer loop above — so it can't buff a later non-sneak hit.
    if not ps.isSneaking and lastSneakingForBonus then
        for _, ast in pairs(persistantActorStatuses) do
            if ast.pushedSneak or (ast.pushedSneakMult or 1) ~= 1 then
                ast.actor:sendEvent(DEFS.e.SneakBonus, { mult = 1, sneak = false })
                ast.pushedSneakMult = 1
                ast.pushedSneak = false
            end
        end
    end
    lastSneakingForBonus = ps.isSneaking

    -- Manage the single HUD detection eye ------
    ---------------------------------------------
    -- Visible iff the player is attempting to sneak -- nothing else. While attempting it shows the live
    -- detection gauge, including the cooldown decaying during a lockout (setLocked tints it). When intent
    -- ends it quick-fades out. (AlwaysShowMeter is now moot: the meter is always up while attempting.)
    if useHudMeter then
        local shouldShow = ps.attemptingSneak

        -- Phase resolution: stay solid while attempting; quick-fade out once intent ends.
        if shouldShow then
            eyePhase = "show"
        elseif eyePhase == "show" then
            eyePhase = "fade"; eyeFadeTimer = EYE_FADE
        elseif eyePhase == "fade" then
            eyeFadeTimer = eyeFadeTimer - dt
            if eyeFadeTimer <= 0 then eyePhase = nil end
        end

        -- Render
        if eyePhase == nil then
            if hudMarker then
                if not hudMarker.destroyed then hudMarker:destroy() end
                hudMarker = nil
            end
        else
            if not hudMarker or hudMarker.destroyed then hudMarker = DetectionMarker:new({ hud = true }) end
            hudMarker:setLocked(ps.lockedOut)
            hudMarker:setAggressive(maxAggressive or ps.lockedOut)
            hudMarker:setProgress(maxProgress)
            hudMarker:setHudPos(util.vector2(settings.HudOffsetX or 0, settings.HudOffsetY or 0))

            local alpha = settings.MarkersAlpha or 1
            if eyePhase == "fade" then
                alpha = alpha * math.max(0, eyeFadeTimer / EYE_FADE)
            end
            hudMarker.element.layout.props.alpha = alpha
            hudMarker.element:update()

            hudMarker:updateTweeners(dt)
        end
    elseif hudMarker then
        -- Setting was toggled off at runtime: drop the HUD eye.
        if not hudMarker.destroyed then hudMarker:destroy() end
        hudMarker = nil
        eyePhase = nil
    end
end


-- Current ammo/thrown-stack count for the equipped ranged weapon, plus a stable key identifying that
-- stack. The projectile leaves inventory exactly at release, so a drop in this count between frames is a
-- precise "shot fired" signal; the key lets us ignore count jumps caused by swapping weapon/ammo. Returns
-- nil when no ranged weapon (or no ammo for a bow/crossbow) is equipped.
local function getRangedShotState()
    local weapon = selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not (weapon and types.Weapon.objectIsInstance(weapon)) then return nil end
    local wtype = types.Weapon.record(weapon).type
    if wtype == WT.MarksmanBow or wtype == WT.MarksmanCrossbow then
        local ammo = selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.Ammunition)
        if not ammo then return nil end
        return ammo.count, ammo.recordId
    elseif wtype == WT.MarksmanThrown then
        -- Thrown weapon is its own projectile: the CarriedRight stack itself decrements on release.
        return weapon.count, weapon.recordId
    end
    return nil
end

local function onUpdate(dt)
    if dt == 0 then
        return
    end

    -- Fade out the sneak-attack confirmation message, then drop the element once it's gone.
    if sneakMsgTimer > 0 then
        sneakMsgTimer = sneakMsgTimer - dt
        if sneakMsgElement then
            if sneakMsgTimer <= 0 then
                sneakMsgElement:destroy()
                sneakMsgElement = nil
            else
                local alpha = math.min(1, sneakMsgTimer / SNEAK_MSG_FADE)
                if sneakMsgElement.layout.props.alpha ~= alpha then
                    sneakMsgElement.layout.props.alpha = alpha
                    sneakMsgElement:update()
                end
            end
        end
    end

    -- Resolve sneak input before reading isSneaking, so the whole tick sees a consistent value.
    local modSneakHeld = input.getBooleanActionValue(SNEAK_ACTION)

    -- Resolve the sustained "attempting to sneak" intent, INDEPENDENT of the lockout. This is the
    -- player's request to sneak (hold or toggle); it drives fake sneak (FakeSneak.lua reads it via the
    -- interface) and the meter's visibility. It must keep updating during the lockout so a cancel-press
    -- still registers and so fake sneak can take over while real sneak is suppressed.
    local attempting
    if settings.ModSneakToggle == "Toggle" then
        -- Toggle on the press (rising edge): press once to sneak, again to stand.
        if modSneakHeld and not modSneakHeldPrev then
            modSneakToggleState = not modSneakToggleState
        end
        attempting = modSneakToggleState
    else
        -- Hold-to-sneak.
        attempting = modSneakHeld
    end
    modSneakHeldPrev = modSneakHeld
    ps.attemptingSneak = attempting

    -- The mod always owns the sneak key: drive real sneak from the resolved intent.
    omwself.controls.sneak = attempting

    -- Post-detection cooldown: real sneak forced off while locked out (UNCHANGED). Fake sneak still
    -- carries the crouch because attemptingSneak stays true, so the kick lands you in fake sneak. Real
    -- sneak returns once the cooldown decays to 0 (lockout clears) and you're still attempting -- there
    -- is no explicit "resume"; it just falls out of (attempting AND not lockedOut). NOTE: unlike before,
    -- we deliberately do NOT clear modSneakToggleState here, so the lockout can't cancel the player's
    -- sneak intent and stop fake sneak from taking over.
    if ps.lockedOut then
        omwself.controls.sneak = false
    end

    -- Fetching locomotion statuses
    ps.isMoving = selfActor:getCurrentSpeed() > 0 or not selfActor:isOnGround()
    ps.isSneaking = omwself.controls.sneak

    -- Fetching invisibility and chameleon status (throttled, effects change infrequently)
    effectsCheckTimer = effectsCheckTimer + dt
    if effectsCheckTimer >= effectsCheckPeriod then
        effectsCheckTimer = 0
        local activeEffects = selfActor:activeEffects()
        local invisibilityEffect = activeEffects:getEffect(core.magic.EFFECT_TYPE.Invisibility)
        ps.isInvisible = (invisibilityEffect ~= nil) and (invisibilityEffect.magnitude > 0)
        local chameleonEffect = activeEffects:getEffect(core.magic.EFFECT_TYPE.Chameleon)
        ps.chameleon = chameleonEffect and chameleonEffect.magnitude or 0
    end

    detectionLogicTick(dt)

    -- Ranged-shot latch: detect a projectile leaving the weapon (ammo/thrown stack dropped by one this
    -- frame, same stack as last frame) and broadcast SneakLatch to nearby actors. Sent on EVERY ranged
    -- shot, not just sneaking ones: each actor decides from its own current eligibility whether to freeze
    -- the bonus or clear a stale latch (see onSneakLatch in SneakActor.lua). Sent after detectionLogicTick
    -- so it's queued behind this frame's SneakBonus push and the actor latches its up-to-date state.
    local shotCount, shotKey = getRangedShotState()
    if shotCount and prevShotCount and shotKey == prevShotKey and shotCount < prevShotCount then
        for _, actor in ipairs(nearby.actors) do
            if actor ~= omwself.object then
                actor:sendEvent(DEFS.e.SneakLatch, { ttl = RANGED_LATCH_TTL })
            end
        end
    end
    prevShotCount = shotCount
    prevShotKey = shotKey

    -- Hold sneak off for the duration of the post-detection lockout (the kick no longer fires
    -- once progress falls below 1.0, so the flag keeps it suppressed until detection decays to 0).
    if ps.lockedOut then
        omwself.controls.sneak = false
    end

    -- Weapon skill modifier: only runs while sneaking or when cleaning up a leftover modifier
    if ps.isSneaking or modifiedSkill then
        local weaponObj = selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.CarriedRight)
        local skill = "handtohand"
        if weaponObj and types.Weapon.objectIsInstance(weaponObj) then
            skill = itemutil.getSkillTypeForEquipment(weaponObj).id
        end
        local stat = selfActor:getSkillStat(skill)

        if ps.isSneaking then
            if modifiedSkill ~= skill then
                -- if we switched to a different skill, remove old modifier
                if modifiedSkill then
                    local oldStat = selfActor:getSkillStat(modifiedSkill)
                    oldStat.modifier = oldStat.modifier - skillMod
                end

                skillMod = stat.base * settings.WeaponBonus
                modifiedSkill = skill
                stat.modifier = stat.modifier + skillMod
            end
        else
            if modifiedSkill then
                -- remove modifier when not sneaking; use modifiedSkill's stat, not current weapon's,
                -- in case the player unequipped their weapon on the same frame they stopped sneaking
                local oldStat = selfActor:getSkillStat(modifiedSkill)
                oldStat.modifier = oldStat.modifier - skillMod
                modifiedSkill = nil
                skillMod = 0
            end
        end
    end
end





-- Event handlers ----------------------------------------------
----------------------------------------------------------------
local function onCombatTargetsChanged(e)
    
    if e.actor == omwself.object then return end
    -- print("Combat targets changed for " .. e.actor.recordId)

    local ast = getAst(e.actor)    
    ast.combatTargets = e.targets    
    ast.isFriend = isFriend(ast)
    ast.isDead = types.Actor.isDead(e.actor) 

    if not ast.isDead and gutils.arrayContains(ast.combatTargets, omwself.object) then
        gutils.print("Player: Combat targets changed for " .. e.actor.recordId, "Player is a target", 1)
        ast.fightingPlayer = true
        ast.isAggressive = true
        observerActorStatuses[e.actor.id] = ast
    else
        ast.fightingPlayer = false
        if ast.isFriend then
            observerActorStatuses[e.actor.id] = nil
        end
    end
end

local function onGetFollowTargets(e)
    -- gutils.print("Player: Received follow targets resp from " .. e.actor.recordId, 1)    
    if e.actor == omwself.object then return end

    local ast = getAst(e.actor)
    ast.followTargets = e.targets
    ast.isFriend = isFriend(ast)
    if ast.isFriend then
        observerActorStatuses[e.actor.id] = nil
    end
    -- gutils.print(e.actor.recordId, "Is a friend",ast.isFriend, 1)
end

local function onReportAttack(e)
    if e.target == omwself.object then return end

    -- gutils.print("Reported attack by " .. e.attacker.recordId .. " on " .. e.target.recordId)
    local ast = getAst(e.target)
    ast.isFriend = isFriend(ast)
    ast.isDead = types.Actor.isDead(e.target) 

    if e.attacker == omwself.object and not ast.isDead then
        ast.fightingPlayer = true
        ast.isAggressive = true
        ast.isKnockedOut = isActorKnockedOut(e.target)
        observerActorStatuses[e.target.id] = ast
    end
end

local function onSave()
    return {
        modifiedSkill = modifiedSkill,
        skillMod = skillMod
    }
end

local function onLoad(data)
    if data.modifiedSkill then
        modifiedSkill = data.modifiedSkill
        skillMod = data.skillMod
    end
end

return {    
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad
    },
    eventHandlers = { 
        OMWMusicCombatTargetsChanged = onCombatTargetsChanged,
        MaxYariUtil_FollowTargets = onGetFollowTargets,
        [DEFS.e.ReportAttack] = onReportAttack,
        [DEFS.e.SneakHit] = onSneakHit
    },
    interfaceName = DEFS.mod_name,
    interface = interface
}