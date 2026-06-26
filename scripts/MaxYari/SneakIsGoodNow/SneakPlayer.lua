

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

gutils.print("Sneak! E-N-G-A-G-E-D", 0)

local sneakCheckPeriod = 0.33 -- seconds between sneak checks per actor
local followTargetsCheckPeriod = 2.0 -- seconds between follow target updates per actor
local losCheckPeriod = 0.2
local detectionDecreaseRate = 0.25  -- fixed decrease rate per second

-- "ps" stands for "Player State"
local ps = {
    isSneaking = false,
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

-- Event-driven HUD eye state machine ---------------------------------------------------------
local EYE_FADE = 0.5        -- seconds to quick-fade the eye out once there's nothing left to show
local eyePhase = nil        -- nil | "show" | "fade"
local eyeFadeTimer = 0
local eyeSneakAttempt = false  -- did the player press sneak this frame (rising edge, set in onUpdate)
local sneakIntentPrev = false  -- previous frame's raw sneak intent
local eyeWasLockedOut = false  -- previous frame's lockout state (for kick-edge detection)

-- Sneak-attack confirmation message ("Critical Strike for #.#X damage!") ------------------------
-- Mirrors the Horizontal Compass cell-name display: a single HUD Text element, shown solid then
-- faded out. The target script reports the total multiplier on a landed sneak hit; we just display.
local SNEAK_MSG_DURATION = 3.0     -- seconds the message is shown before it's gone
local SNEAK_MSG_FADE = 1.0         -- seconds of fade-out at the tail end
local SNEAK_MSG_COLOR = util.color.hex("caa676")-- ("efc36b")  -- the mod's tan/gold (matches the vanilla UI)
local sneakMsgElement = nil
local sneakMsgTimer = 0            -- counts down from SNEAK_MSG_DURATION

local function showSneakMessage(mult)
    if not settings.ShowSneakAttackMessage then return end
    local text = string.format("Critical Strike for %.1fX damage!", mult)
    local relY = settings.SneakMessageY or 0.85
    if not sneakMsgElement then
        sneakMsgElement = ui.create {
            layer = "HUD",
            type = ui.TYPE.Text,
            props = {
                text = text,
                textSize = 22,
                textColor = SNEAK_MSG_COLOR,
                textShadow = true,
                relativePosition = util.vector2(0.5, relY),
                anchor = util.vector2(0.5, 0.5),
                alpha = 1,
            }
        }
    else
        sneakMsgElement.layout.props.text = text
        sneakMsgElement.layout.props.relativePosition = util.vector2(0.5, relY)
        sneakMsgElement.layout.props.alpha = 1
        sneakMsgElement:update()
    end
    sneakMsgTimer = SNEAK_MSG_DURATION
end

local function onSneakHit(e)
    showSneakMessage(e.mult or 1)
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
    -- existing observers in observerActorStatuses continue to be processed every frame below
    nearbyCheckTimer = nearbyCheckTimer + dt
    if ps.isSneaking and nearbyCheckTimer >= nearbyCheckPeriod then
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
    -- zeroes the engine's crit GMSTs), so this multiplier IS the sneak crit.
    local sneakMult = 1
    if ps.isSneaking then
        local weaponFactor = 0
        local weaponObj = selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.CarriedRight)
        local setting
        if weaponObj and types.Weapon.objectIsInstance(weaponObj) then
            local key = WEAPON_CATEGORY_SETTING[types.Weapon.record(weaponObj).type]
            setting = key and settings[key]
        else
            -- Nothing in the weapon hand = unarmed (hand-to-hand).
            setting = settings.HandToHandSneakDamage
        end
        if setting and setting > 0 then
            weaponFactor = setting * (selfActor:getSkillStat("sneak").modified / 100)
        end
        sneakMult = settings.BaselineSneakDamage + weaponFactor
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
                -- Enter the post-detection lockout. Sneak stays forced off (enforced in onUpdate),
                -- but detection now decays naturally until it reaches 0 for all observers.
                ps.lockedOut = true
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
            -- Show markers only when sneaking and detection progress is happening
            local shouldShowMarker = (ps.isSneaking or ps.lockedOut) and not ast.isDead and not ast.isKnockedOut and ast.inLOS
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
    -- Event-driven: shows the live "being spotted" gauge while you can still sneak, and otherwise
    -- only flashes around lockout events (caught while sneaking, or trying to sneak while blocked)
    -- then fades. The persistent "can't sneak" signal lives on the crosshair (companion mod via
    -- isSneakBlocked), not here, so the eye no longer sits on screen for the whole fight.
    if useHudMeter then
        local kickEdge = ps.lockedOut and not eyeWasLockedOut

        -- Shown solid (at the configured opacity) while there's something to report:
        --   live     = sneaking, not blocked, actively being detected (the rising gauge); with
        --              AlwaysShowMeter on, the meter stays up the whole time you're sneaking.
        --   cooldown = caught while sneaking; show the decaying red gauge until it reaches 0.
        -- Combat is excluded (the red crosshair carries that); there the eye only flashes on attempts.
        local liveShow = ps.isSneaking and not ps.lockedOut and (settings.AlwaysShowMeter or maxProgress > 0)
        local cooldownShow = ps.lockedOut and not inCombat
        local shouldShow = liveShow or cooldownShow

        -- 1. Flash triggers
        if kickEdge and not inCombat then
            -- Caught while sneaking: pop the flash; the gauge then stays until detection decays to 0.
            if not hudMarker or hudMarker.destroyed then hudMarker = DetectionMarker:new({ hud = true }) end
            hudMarker:flash()
        elseif eyeSneakAttempt and ps.lockedOut then
            -- Trying to sneak while blocked: re-flash as a reminder.
            if not hudMarker or hudMarker.destroyed then hudMarker = DetectionMarker:new({ hud = true }) end
            hudMarker:flash()
            -- Mid-combat there's no persistent eye, so flash then fade it back out.
            if inCombat then eyePhase = "fade"; eyeFadeTimer = EYE_FADE end
        end

        -- 2. Phase resolution: stay solid while shown; quick-fade out once there's nothing to show.
        if shouldShow then
            eyePhase = "show"
        elseif eyePhase == "show" then
            eyePhase = "fade"; eyeFadeTimer = EYE_FADE
        elseif eyePhase == "fade" then
            eyeFadeTimer = eyeFadeTimer - dt
            if eyeFadeTimer <= 0 then eyePhase = nil end
        end

        -- 3. Render
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

    eyeWasLockedOut = ps.lockedOut
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
    -- During lockout, sneak is forced off (no stance flicker). Otherwise, when the player opted to
    -- let the mod own the sneak key, drive controls.sneak from the mod's own bound action.
    local modSneakHeld = input.getBooleanActionValue(SNEAK_ACTION)

    -- Capture the player's sneak *intent* this frame BEFORE the lockout zeroes controls.sneak below.
    -- With mod-owned input it's the raw action; otherwise it's whatever the engine set this frame.
    -- The rising edge is a sneak "attempt" the HUD eye uses to re-flash while locked out.
    local sneakIntent
    if settings.UseModSneakInput then
        sneakIntent = modSneakHeld
    else
        sneakIntent = omwself.controls.sneak == true
    end
    eyeSneakAttempt = sneakIntent and not sneakIntentPrev
    sneakIntentPrev = sneakIntent

    if ps.lockedOut then
        omwself.controls.sneak = false
        modSneakToggleState = false  -- don't auto-resume sneak when the cooldown ends
    elseif settings.UseModSneakInput then
        if settings.ModSneakToggle then
            -- Toggle on the press (rising edge): press once to sneak, again to stand
            if modSneakHeld and not modSneakHeldPrev then
                modSneakToggleState = not modSneakToggleState
            end
            omwself.controls.sneak = modSneakToggleState
        else
            -- Hold-to-sneak
            omwself.controls.sneak = modSneakHeld
        end
    end
    modSneakHeldPrev = modSneakHeld

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