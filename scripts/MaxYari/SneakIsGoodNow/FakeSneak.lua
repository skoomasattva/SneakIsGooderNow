-- FakeSneak.lua  --  ISOLATED EXPERIMENT (PLAYER scope)
--
-- A visual-only "fake sneak": reproduce real sneak's look/feel WITHOUT ever setting
-- `controls.sneak`, so the omwaddon's undetectable-while-sneaking GMSTs never trigger and the
-- mod's own detection could (later) run at all times. This file validates VISUAL PARITY only --
-- it does not touch detection, the kick, or any base script. Remove it by deleting its one line
-- from SneakIsGoodNow.omwscripts.
--
-- Three real-sneak effects, faked here:
--   * 3rd-person crouch animation  -> ReAnimation locomotion/idle overrides (dependency).
--   * 1st-person view height        -> actor scale (lowers camera AND arms together, via a global bridge).
--   * reduced speed                 -> no running + movement scaling.
-- See memory [[sneakisgoodnow-fakesneak]] and [[openmw-reanimation-override]].

local mp = "scripts/MaxYari/SneakIsGoodNow/"

local I         = require("openmw.interfaces")
local input     = require("openmw.input")
local async     = require("openmw.async")
local storage   = require("openmw.storage")
local camera    = require("openmw.camera")
local util      = require("openmw.util")
local omwself   = require("openmw.self")
local ui        = require("openmw.ui")
local animation = require("openmw.animation")
local core      = require("openmw.core")
local types     = require("openmw.types")

local SettingsHelper = require(mp .. "utils/settings_helper")

local FAKE_ACTION = "SneakIsGoodNow_FakeSneak"

-- 1) Test binding + tuning settings ----------------------------------------------------------
input.registerAction {
    key = FAKE_ACTION,
    type = input.ACTION_TYPE.Boolean,
    l10n = 'SneakIsGoodNow',
    defaultValue = false,
}

I.Settings.registerGroup {
    key = 'SettingsSneakIsGoodNowExperimental',
    page = 'SneakIsGoodNowPage',
    l10n = 'SneakIsGoodNow',
    name = 'Experimental: Fake Sneak (testing)',
    description = "Throwaway test controls for the visual-only 'fake sneak' stance. Bind a key, then " ..
        "move and look around in 1st and 3rd person and compare against real sneak. Requires the " ..
        "OpenMWReAnimation mod for the 3rd-person crouch animation.",
    -- High order so this experimental group always sorts to the bottom of the page, below the real
    -- groups in settings.lua (which use orders 1-5). See settings.lua for why explicit orders matter.
    order = 100,
    permanentStorage = true,
    settings = {
        {
            -- The inputBinding renderer keys its GLOBAL binding store (OMWInputBindings) by this
            -- setting's VALUE string -- which, for a binding, is just its `default`. It MUST be
            -- unique across every inputBinding in the whole game or two bindings clobber each other
            -- (the mod's real-sneak binding uses "", so this must be something non-empty).
            -- permanentStorage makes the value sticky once registered, so we also need a FRESH key
            -- here: the original "FakeSneakKeyBinding" already persisted "" and would keep colliding.
            key = "FakeSneakKeyBindV2",
            renderer = "inputBinding",
            default = "SneakIsGoodNow_FakeSneak",
            argument = { type = "action", key = FAKE_ACTION },
            name = "Fake sneak test key",
            description = "Key/button that enters fake sneak.",
        },
        {
            key = "FakeSneakToggle",
            renderer = "checkbox",
            default = true,
            name = "Test key toggles",
            description = "On: tap to toggle fake sneak. Off: hold to stay in it.",
        },
        {
            key = "FakeSneakScale",
            renderer = "number",
            default = 0.9,
            argument = { min = 0.75, max = 1.0 },
            name = "Sneak strength (height + speed)",
            description = "Scales height and speed in first person sneaking both fake and real. Scales speed in third person fake sneak.",
        },
        {
            key = "FakeSneakDebugHud",
            renderer = "checkbox",
            default = true,
            name = "Show debug readout",
            description = "On-screen FAKE / REAL / OFF indicator + speed readout so you can tell the modes apart and " ..
                "tune pace while testing.",
        },
    },
}

local settings = SettingsHelper:new('SettingsSneakIsGoodNowExperimental')

-- 2) State -----------------------------------------------------------------------------------
local fakeSneakActive  = false   -- module-level: the override conditions below read this
local toggleState      = false   -- latched state when in toggle mode
local heldPrev         = false   -- previous-frame action value (toggle edge detection)
local overridesDone    = false   -- ReAnimation overrides registered yet?
local reanimReady      = false   -- did registration actually succeed (I.ReAnimation present)?
local debugEl          = nil
local hudGait          = "WALK"  -- gait sampled in onFrame after forcing walk (for the debug readout)

-- First-person scale lerp state. setScale is global-only, so we drive a lerped target here and push
-- it to FakeSneakGlobal.lua each frame while it's moving; once settled we stop sending.
local baseScale        = nil     -- the player's scale before we ever touch it (captured once)
local appliedScale     = nil     -- the scale we're currently lerping toward `desired`
local lastSentScale    = nil     -- last scale actually pushed across to the global script
local prevInFP         = nil     -- was the camera in first person last frame? (snap on a mode change)
local enteringFP       = false   -- mid "slow scale-down on FP entry" lerp? (masks the shrink we can't hide)

local SCALE_LERP_RATE  = 8       -- normal scale lerp speed (sneak enter/exit while already in 1st person)
local SCALE_ENTER_RATE = 2       -- slower lerp used ONLY when zooming into 1st person, to hide the shrink

-- Actual ground-speed measurement (units/s) from position delta. Animation-driven movement is very
-- noisy frame-to-frame (~40% swing in 3rd person), so we keep a TIME-WEIGHTED rolling average. 3rd
-- person needs a long window to settle (2s only got 160-200 down to ~180-187); 1st person is far
-- cleaner so a short window keeps it responsive. Diagnostic only -- never feeds movement.
local prevPos          = nil
local speedSamples     = {}      -- queue of { v = speed, dt = dt }, oldest first
local speedSumVdt      = 0       -- running sum of v*dt across the queue
local speedSumDt       = 0       -- running sum of dt across the queue (= current window length)
local TP_SPEED_WINDOW  = 3.0     -- 3rd-person averaging window (seconds)
local FP_SPEED_WINDOW  = 0.5     -- 1st-person averaging window (seconds)

-- 3) ReAnimation overrides -------------------------------------------------------------------
-- Each override is parented to the engine's own anim choice; ReAnimation captures that parent's
-- options when it plays, and we replay the sneak variant ONE priority above the parent so it wins,
-- while the parent keeps running underneath to satisfy the engine's character controller. This is
-- the exact pattern ReAnimation ships in AnimationOverrides.lua for sneak idles.
--
-- NOTE: the earlier uniquifyPriority/blendMask=0 approach is for ALT ATTACKS (two anims coexisting),
-- not a sustained stance -- and it crashed here, because on the `startOnUpdate` path ReAnimation
-- calls anim:options() with NO parent-options arg. We read self.parentOptions instead.

-- First-person sneak IDLE groups (the lowered HANDS pose). These come from ReAnimation's own
-- first-person assets, so they only exist with a weapon/spell readied (idle1h / idle1s / idlebow);
-- unarmed first person relies on the camera/scale offset alone. We drive them with PARENTLESS,
-- both-mode-spanning overrides (addParentlessFPIdle) -- NOT parent-keyed -- so ONE continuous
-- instance owns the group across a real<->fake toggle and never restarts (perfect both ways, the
-- same sole-owner mechanism that makes third-person walking seamless).
--
-- The catch unique to FP idle: ReAnimation ships its OWN built-in idle sneak overrides
-- (idle1h->idle1hsneak etc., gated on REAL controls.sneak -- AnimationOverrides.lua:81/193). If both
-- it and ours touched idle1hsneak we'd have TWO managers fighting over one shared track, each
-- restarting from keyframe 0 at the boundary (the "hitch, no smoothing" we saw). So we NEUTRALIZE
-- the built-ins (neutralizeBuiltinFPIdle) and become the sole owner for BOTH real and fake sneak.
local FP_IDLE_GROUPS = { idle1hsneak = true, idle1ssneak = true, idlebowsneak = true }

-- First-person MOVING sneak. In REAL first person sneak the ENGINE plays the sneak locomotion variant
-- natively (sneak state + weapon suffix -> "sneakforward1h" ...) and ReAnimation just supplies the asset;
-- fake sneak never sets controls.sneak, so the engine plays the WALK clip and we get vanilla walk arms.
-- We replay the sneak variant ourselves over the engine's clip. ReAnimation ships purpose-built
-- first-person sneak assets for three weapon short-groups: 1h (long blade), 1s (short blade), bow
-- (weapontype.cpp). Vanilla has no FP sneak-movement for hand-to-hand / close-grip-2H / wide-grip-2H /
-- spell, so we alias the THIRD-PERSON vanilla clips into the FP folder under private sig* group names
-- (see tools/build_aliases.py: xbaseAnimSIG_fp_{hh,2c,2w,spell}.kf). Only shared upper-body bones bind in
-- FP. blunt/axe one-hand map to "1h" via currentSuffix; crossbow has no vanilla sneak anim at all (none).
--
-- These are registered PARENTLESS and span BOTH sneak modes (see addParentlessFP), exactly like the
-- third-person groups -- NOT parent-keyed. A parent-keyed override is auto-cancelled the instant its
-- parent stops (ReAnimationAPI:279); at a fake->real switch the engine swaps walkforward1h -> its OWN
-- sneakforward1h, and our cancel of that shared group name then nuked the engine's just-issued clip, so
-- the moving anim FROZE until you stopped and moved again. Parentless + both-modes never cancels at the
-- boundary, so the clip plays continuously across the switch. UNLIKE an idle, a moving clip needs its
-- rate driven: these are foot-synced per-frame below (FP_SNEAK_MOVE_GROUPS).
--
-- FP_IDLE_WEAPONS is kept SEPARATE from FP_MOVE_WEAPONS: we ship sig FP *idle* assets only for 1h/1s/bow,
-- so only those get an FP idle override (addParentlessFPIdle). The extra move classes (hh/2c/2w/spell)
-- have working vanilla FP idles already -- we only need to fix their MOVING transition.
local FP_IDLE_WEAPONS = { "1h", "1s", "bow" }
local FP_MOVE_WEAPONS = { "1h", "1s", "bow", "hh", "2c", "2w", "spell", "crossbow" }
local FP_MOVE_DIRS    = { "forward", "back", "left", "right" }
-- Played FP move groups, resolved to alias names at registration (see playable / registerOverrides).
local FP_SNEAK_MOVE_GROUPS = {}

-- First-person sneak locomotion playback divisor. First-person move clips carry NO baked root velocity
-- (character.cpp:749), so the engine sets their playback rate explicitly: for real first-person sneak it
-- uses speedMult = currentSpeed / 33.5452 (character.cpp:754 sneak branch -> adjustSpeedMult). So we use
-- that same plain base velocity (the SAME number the third-person foot-sync uses) to make the faked arms
-- swing at the exact rate real sneak does. (NOTE: ReAnimation's locomotionAnimSpeed() multiplies this by
-- 2.8, but that fudge is for ITS shield/runbounce clips -- using it here ran the sneak clip 2.8x too slow.)
-- Same constant as SNEAK_ANIM_BASE_VELOCITY (defined below for the third-person foot-sync).
local FP_SNEAK_DIVISOR = 33.5452

-- Alias animation groups ----------------------------------------------------------------------
-- TP-idle and FP-walking collide with the ENGINE's own copy of their group name (idlesneak /
-- sneakforward1h ...): a real<->fake toggle stops that shared track and our clip is forced to
-- restart (the REAL->FAKE smoothed-hitch). The asset-side fix ships the SAME frames under a
-- private, engine-never-played name ("sig" + the group) in animations/, so our override owns that
-- track alone -- exactly why TP-walking (suffixless sneakforward) is already perfect. We play the
-- alias IF its .kf is installed (animation.hasGroup true), else fall back to the real name so the
-- mod still works (degrades to today's smoothed-hitch) without the asset pack. Groups for which we
-- ship NO alias (TP move, FP idle) resolve to themselves automatically -- those are already perfect.
-- See ALIAS_ANIMATIONS_MINIPROJECT.md and memory [[sneakisgoodnow-fakesneak]].
local ALIAS_PREFIX = "sig"
local function playable(real)
    local a = ALIAS_PREFIX .. real
    if animation.hasGroup(omwself, a) then return a end
    return real
end

-- Third-person: vanilla already ships every sneak group (idlesneak, sneak{forward,back,left,right}).
-- We drive them with PARENTLESS overrides so ONE continuous instance can span BOTH real and fake sneak,
-- killing the keyframe-reset hitch at the real<->fake boundary. Parent-keyed overrides can't do this:
-- the engine plays different parents in each mode (walkforward<weapon> in fake, sneakforward in real --
-- with no common parent), and ReAnimation cancels an override the moment its parent stops playing
-- (ReAnimationAPI.lua:279), forcing a stop+restart at the boundary.
--
-- Instead each override is parentless and gated on a CONDITION we own. Direction is chosen from the
-- player's movement INPUT (controls.movement/sideMovement), NOT the engine's current group: input does
-- not change when controls.sneak flips, so the selected group is identical across a real<->fake toggle,
-- the same override's condition stays true, and it never stops -> no reset. Phase continuity across the
-- handoff is preserved by starting at the currently-visible completion (tpSneakOptions, via startPoint).
local TP_SNEAK_GROUPS = { "idlesneak", "sneakforward", "sneakback", "sneakleft", "sneakright" }

-- Sneaking in EITHER sense: engine real sneak OR our fake sneak. Our TP override runs in both so the
-- displayed crouch is one continuous instance (no handoff between the engine's clip and ours).
local function sneakingActive()
    return fakeSneakActive or omwself.controls.sneak == true
end

-- Pick the directional sneak group from movement INPUT (transition-stable -- see above). Diagonals
-- collapse to the dominant cardinal axis, matching vanilla (only 4 directional sneak clips exist).
local MOVE_DEADZONE = 0.1
local function selectedGroup()
    local fwd  = omwself.controls.movement or 0
    local side = omwself.controls.sideMovement or 0
    if math.abs(fwd) < MOVE_DEADZONE and math.abs(side) < MOVE_DEADZONE then
        return "idlesneak"
    elseif math.abs(fwd) >= math.abs(side) then
        return fwd > 0 and "sneakforward" or "sneakback"
    else
        return side > 0 and "sneakright" or "sneakleft"
    end
end

-- The bare direction word (first-person move overrides key on direction + weapon, not the TP group name).
-- Returns nil when standing -- the FP idle overrides handle that, no movement override should fire.
local function selectedDir()
    local g = selectedGroup()
    if     g == "sneakforward" then return "forward"
    elseif g == "sneakback"    then return "back"
    elseif g == "sneakleft"    then return "left"
    elseif g == "sneakright"   then return "right" end
    return nil
end

-- The drawn weapon's animation short-group, mapped to the first-person sneak assets we have available.
-- ReAnimation ships purpose-built FP sneak for short blade (1s), bow (bow) and 1h (long blade); the
-- engine's fallbackShortWeaponGroup (character.cpp:615-625, oneHandFallback="1h") resolves blunt-1h
-- ("1b"), axe-1h ("1b") and thrown ("1t") to that SAME 1h animation, so we map them to "1h" too. For
-- hand-to-hand ("hh"), close-grip two-hand ("2c"), wide-grip two-hand ("2w") and readied spell ("spell")
-- vanilla ships no FP sneak clip, so we alias the third-person clips into the FP folder (build_aliases.py)
-- and map to those suffixes here. Returns nil only where there is genuinely no asset (sheathed, crossbow).
local function currentSuffix()
    -- Spell stance has no weapon; the engine plays the suffixless base sneak for it (our "spell" alias).
    if types.Actor.getStance(omwself) == types.Actor.STANCE.Spell then return "spell" end
    if types.Actor.getStance(omwself) ~= types.Actor.STANCE.Weapon then return nil end
    local w = types.Actor.getEquipment(omwself)[types.Actor.EQUIPMENT_SLOT.CarriedRight]
    -- Weapon stance with no weapon in hand = hand-to-hand (fists), short-group "hh".
    if not w then return "hh" end
    -- Lockpicks/probes aren't types.Weapon but are held weapon-stance and real sneak shows the 1h
    -- animation for them (confirmed via the engine's own debug readout), matching getWeaponShortGroup
    -- "1h" for PickProbe.
    if w.type == types.Lockpick or w.type == types.Probe then return "1h" end
    if w.type ~= types.Weapon then return nil end
    local t  = types.Weapon.record(w).type
    local WT = types.Weapon.TYPE
    if t == WT.ShortBladeOneHand then return "1s" end
    if t == WT.MarksmanBow       then return "bow" end
    -- engine resolves these to the 1h animation via fallbackShortWeaponGroup -> oneHandFallback "1h"
    if t == WT.LongBladeOneHand or t == WT.BluntOneHand or t == WT.AxeOneHand
        or t == WT.MarksmanThrown then return "1h" end
    -- two-handed melee -> twoHandFallback "2c" (close grip) / "2w" (wide grip), aliased FP clips
    if t == WT.LongBladeTwoHand or t == WT.AxeTwoHand or t == WT.BluntTwoClose then return "2c" end
    if t == WT.BluntTwoWide or t == WT.SpearTwoWide then return "2w" end
    -- crossbow: vanilla ships no crossbow movement clip at all (only a held IdleCrossbow pose), so the FP
    -- "crossbow" alias is that held pose synthesized into the four sig move groups (build_aliases.py:
    -- build_fp_crossbow) -- same approach as spell. Crouch comes from actor scale.
    if t == WT.MarksmanCrossbow then return "crossbow" end
    return nil
end

-- The directional sneak locomotion groups (third person). We foot-sync whichever is playing per-frame
-- in onUpdate via animation.setSpeed -- the options() builder only runs once at start, so a speed set
-- there would freeze and cause the stride to mismatch (slow/fast) as actual velocity changes.
-- Played TP move groups, resolved at registration (alias if installed, else real). Filled in
-- registerOverrides because animation.hasGroup is only reliable once the actor is in-world.
local SNEAK_MOVE_GROUPS = {}
local TP_MOVE_DIRS = { "sneakforward", "sneakback", "sneakleft", "sneakright" }

-- Options for the PARENTLESS overrides (third- AND first-person). No parent options to clone, so build explicit ones.
-- The key trick: start at the group's CURRENT visible completion (startPoint), so when this override
-- (re)starts -- including right after the engine reasserts its own sneak clip on a fake<->real switch --
-- it continues from the phase already on screen instead of snapping to keyframe 0. Priority sits one
-- above Movement so our full-body crouch wins over the engine's movement/idle clip (real & fake look
-- identical), while attacks (Priority_Weapon) still outrank us on the arms.
local function tpSneakOptions(self)
    local comp = animation.getCompletion(omwself, self.groupname) or 0
    return {
        loops     = 999,
        forceloop = true, forceLoop = true,
        -- FULL-BODY override at Movement + 1, so our sneak clip wins the WHOLE body over the engine's
        -- walkforward (Movement = 5) and real & fake third-person sneak look 100% identical head-to-toe.
        -- Attacks still show: an attack plays at Priority_Weapon (7) > 6, so it outranks us on the arms.
        -- (Numerically Movement + 1 == Priority_Hit (6), which makes the engine DEFER first<->third view
        -- switches while this loops -- camera.cpp:225 / upperBodyReady. That camera block is a known,
        -- separately-tracked issue to be fixed later via camera.setMode(force); it is NOT worked around
        -- here by touching the animation, because doing so breaks the head-to-toe parity.)
        priority  = animation.PRIORITY.Movement + 1,
        startpoint = comp, startPoint = comp,
    }
end

-- The sneak clip's BAKED-IN root velocity -- a property of the NIF asset (how far the animation itself
-- travels per second at 1.0x playback), NOT a movement speed. OpenMW doesn't expose a clip's root
-- velocity to Lua; this is the value ReAnimation/the engine use for the sneak locomotion clip
-- (AnimationOverrides.lua:37 / character.cpp:754). Because OpenMW moves the body by the playing clip's
-- root motion (speed_manipulation.md), setting playback = getCurrentSpeed()/divisor makes BOTH the
-- visual stride AND the actual ground speed scale together off one number -- always foot-synced.
-- We expose the pace as a 0-1 "fraction of normal speed" setting and derive the divisor from it:
--   playbackMult = getCurrentSpeed() / (baseVel / moveScale) = (getCurrentSpeed()/baseVel) * moveScale
--   => displacement ~= getCurrentSpeed() * moveScale  (moveScale 1.0 = full speed, lower = slower).
local SNEAK_ANIM_BASE_VELOCITY = 33.5452

local regCount = 0

-- Register the five parentless third-person sneak overrides. Each owns its own condition closure
-- (capturing its group string) so it runs only while sneaking AND that direction is selected. No parent
-- => starts only via ReAnimation's onUpdate path once tracked (needs a stance/armature rebuild to enter
-- the tracked list -- see the cold-start caveat in the plan).
local function addParentlessTP()
    for _, g in ipairs(TP_SNEAK_GROUPS) do
        local grp = g                  -- selector (real engine name -- matches selectedGroup())
        local play = playable(grp)     -- what we actually PLAY (alias if installed, else real)
        I.ReAnimation.addAnimationOverride {
            id               = "fakesneak-tp-" .. grp,
            parent           = nil,
            groupname        = play,
            armatureType     = I.ReAnimation.ARMATURE_TYPE.ThirdPerson,
            stance           = I.ReAnimation.STANCE.Any,
            startOnAnimEvent = false,  -- no parent to event on
            startOnUpdate    = true,   -- runs purely on our condition, once tracked
            condition        = function() return sneakingActive() and selectedGroup() == grp end,
            stopCondition    = function() return not (sneakingActive() and selectedGroup() == grp) end,
            options          = tpSneakOptions,
        }
        regCount = regCount + 1
    end
end

-- First-person directional sneak MOVEMENT, parentless and spanning both sneak modes (see the FP_MOVE_*
-- block above for why parent-keyed froze at the fake->real switch). One override per (direction, weapon):
-- runs only while sneaking AND that direction is the movement input AND that weapon's short-group is drawn.
-- Same phase-continuity options (tpSneakOptions: Movement+1, startPoint = current completion) as the
-- third-person groups; foot-synced per-frame in onUpdate via FP_SNEAK_MOVE_GROUPS.
local function addParentlessFP()
    for _, w in ipairs(FP_MOVE_WEAPONS) do
        for _, d in ipairs(FP_MOVE_DIRS) do
            local dir, wpn = d, w
            I.ReAnimation.addAnimationOverride {
                id               = "fakesneak-fp-move-" .. d .. w,
                parent           = nil,
                groupname        = playable("sneak" .. d .. w),
                armatureType     = I.ReAnimation.ARMATURE_TYPE.FirstPerson,
                stance           = I.ReAnimation.STANCE.Any,
                startOnAnimEvent = false,
                startOnUpdate    = true,
                condition        = function() return sneakingActive() and selectedDir() == dir and currentSuffix() == wpn end,
                stopCondition    = function() return not (sneakingActive() and selectedDir() == dir and currentSuffix() == wpn) end,
                options          = tpSneakOptions,
            }
            regCount = regCount + 1
        end
    end
end

-- First-person directional sneak IDLE, parentless and spanning both sneak modes -- the sole-owner fix
-- for the one fully-broken transition (FP idle real<->fake). Mirrors addParentlessFP exactly but for
-- standing: one override per weapon short-group, runs only while sneaking AND standing (selectedGroup ==
-- "idlesneak") AND that weapon is drawn. tpSneakOptions gives the same phase-continuity (Movement+1,
-- startPoint = current completion) as every other parentless override. Requires neutralizeBuiltinFPIdle
-- to have removed ReAnimation's competing built-in idle overrides first, so this is the only owner.
local function addParentlessFPIdle()
    for _, w in ipairs(FP_IDLE_WEAPONS) do
        local wpn = w
        I.ReAnimation.addAnimationOverride {
            id               = "fakesneak-fp-idle-" .. w,
            parent           = nil,
            groupname        = playable("idle" .. w .. "sneak"),
            armatureType     = I.ReAnimation.ARMATURE_TYPE.FirstPerson,
            stance           = I.ReAnimation.STANCE.Any,
            startOnAnimEvent = false,
            startOnUpdate    = true,
            condition        = function() return sneakingActive() and selectedGroup() == "idlesneak" and currentSuffix() == wpn end,
            stopCondition    = function() return not (sneakingActive() and selectedGroup() == "idlesneak" and currentSuffix() == wpn) end,
            options          = tpSneakOptions,
        }
        regCount = regCount + 1
    end
end

-- Neutralize ReAnimation's built-in first-person sneak IDLE overrides (idle1h->idle1hsneak etc., gated on
-- real controls.sneak) so OUR parentless override is the sole owner of those groups across both modes.
-- ReAnimation exposes its raw override map (I.ReAnimation.animations, keyed by parent group). We disable
-- only the three entries whose groupname is an FP idle sneak group, by clearing BOTH start flags AND
-- enabled: enabled=false alone is not enough because the onUpdate start path (ReAnimationAPI:283-295)
-- never checks enabled, so a startOnUpdate override would still re-start itself. Belt and suspenders.
local function neutralizeBuiltinFPIdle()
    local map = I.ReAnimation.animations
    if not map then return end
    for _, anims in pairs(map) do
        for _, anim in ipairs(anims) do
            if anim.groupname and FP_IDLE_GROUPS[anim.groupname] and anim.id ~= "fakesneak-fp-idle-1h"
                and anim.id ~= "fakesneak-fp-idle-1s" and anim.id ~= "fakesneak-fp-idle-bow" then
                anim.startOnUpdate    = false
                anim.startOnAnimEvent = false
                anim.enabled          = false
            end
        end
    end
end

local function registerOverrides()
    if overridesDone or not I.ReAnimation then return end
    overridesDone = true
    reanimReady = true
    neutralizeBuiltinFPIdle()  -- remove ReAnimation's competing built-in FP sneak idles FIRST
    addParentlessFPIdle()      -- FP sneak IDLES   (parentless, sole owner, spans both modes)
    addParentlessFP()          -- FP sneak MOVEMENT (parentless, spans both modes)
    addParentlessTP()          -- TP sneak idle + movement (parentless, spans both modes)
    -- Foot-sync targets must be the PLAYED group names (alias if installed) so setSpeed/isPlaying
    -- hit the clip we actually run -- otherwise an aliased move clip would never get its rate driven.
    for _, g in ipairs(TP_MOVE_DIRS) do
        SNEAK_MOVE_GROUPS[#SNEAK_MOVE_GROUPS + 1] = playable(g)
    end
    for _, w in ipairs(FP_MOVE_WEAPONS) do
        for _, d in ipairs(FP_MOVE_DIRS) do
            FP_SNEAK_MOVE_GROUPS[#FP_SNEAK_MOVE_GROUPS + 1] = playable("sneak" .. d .. w)
        end
    end
end

-- Registration (and the alias resolution inside it) is deferred to the first onUpdate: animation
-- .hasGroup is only reliable once the actor is in-world, and playable() depends on it. ReAnimation
-- rebuilds its tracked list on the next stance/armature change, so a one-frame-late register is
-- fine (same cold-start caveat the parentless overrides already have: draw weapon / toggle once).

-- 4) Effects ---------------------------------------------------------------------------------
local function updateDebug(label)
    if not settings.FakeSneakDebugHud then
        if debugEl then debugEl:destroy(); debugEl = nil end
        return
    end
    if not debugEl then
        debugEl = ui.create {
            layer = "HUD",
            type = ui.TYPE.Text,
            props = {
                text = label,
                textSize = 20,
                textColor = util.color.rgb(1, 1, 1),
                textShadow = true,
                relativePosition = util.vector2(0.5, 0.12),
                anchor = util.vector2(0.5, 0.5),
            },
        }
    else
        debugEl.layout.props.text = label
        debugEl:update()
    end
end

-- Diagnostics: which engine group is the player actually playing, and is any of OUR sneak
-- overrides live? This is how we tell, in-game, whether the override even fires.
local ENGINE_GROUPS = {
    "idle1h", "idle1s", "idle1b", "idle2c", "idle2b", "idle2w", "idle1t", "idlehh", "idlebow",
    "idlecrossbow", "idlespell", "idlesneak", "idle", "turnleft", "turnright",
    "walkforward", "sneakforward", "runforward",
}
local OUR_GROUPS = {
    "idle1hsneak", "idle1ssneak", "idlebowsneak",
    "idlesneak", "sneakforward", "sneakback", "sneakleft", "sneakright",
    -- alias groups (shown when the asset pack is installed and we're playing the private track)
    "sigidlesneak", "sigsneakforward1h", "sigsneakforward1s", "sigsneakforwardbow",
    "sigsneakforwardhh", "sigsneakforward2c", "sigsneakforward2w", "sigsneakforwardspell",
    "sigsneakforwardcrossbow",
}
local function firstPlaying(list)
    for _, g in ipairs(list) do
        if animation.hasGroup(omwself, g) and animation.isPlaying(omwself, g) then return g end
    end
    return "-"
end

-- 5) Per-frame -------------------------------------------------------------------------------
local function onUpdate(dt)
    registerOverrides()
    if dt <= 0 then return end

    -- Fake sneak is driven by the player's sneak INTENT, published by SneakPlayer.lua: whenever the
    -- player is attempting to sneak (hold/toggle), fake sneak is on. Real sneak runs on top when active
    -- (sneakingActive() ORs both); when the lockout drops real sneak, intent stays true so fake sneak
    -- carries the crouch. SneakPlayer runs before us in the omwscripts order, so this is fresh this frame.
    local sp = I.SneakIsGoodNow
    local attempting = sp and sp.playerState and sp.playerState.attemptingSneak or false

    -- The experimental test action stays as an optional manual/debug override (toggle or hold), OR'd in.
    local held = input.getBooleanActionValue(FAKE_ACTION)
    local testKeyActive
    if settings.FakeSneakToggle then
        if held and not heldPrev then toggleState = not toggleState end
        testKeyActive = toggleState
    else
        testKeyActive = held
    end
    heldPrev = held

    fakeSneakActive = attempting or testKeyActive

    -- This file runs after SneakPlayer.lua in the omwscripts order, so controls.sneak already
    -- reflects this frame's real-sneak decision. The scale below applies to EITHER sneak.
    local realSneaking = omwself.controls.sneak == true
    local fpSneaking   = realSneaking or fakeSneakActive   -- either sneak should lower the FP view
    -- NOTE: forcing WALK (controls.run = false) is done in onFrame, NOT here -- control writes don't
    -- stick from onUpdate (see onFrame below / HBFS player.lua:161).

    -- First-person view height: shrink the whole actor so the camera AND arms lower together, the way
    -- the sneak neck-drop does. Applies in FIRST PERSON during real OR fake sneak (identical look,
    -- and switching between them never changes scale); never in third person (the crouch anim handles
    -- that). setScale is global-only, so we lerp a target and push it to FakeSneakGlobal.lua. We LERP
    -- for sneak enter/exit, but SNAP on a camera-mode change so the player never watches themselves
    -- grow/shrink across the cut.
    baseScale = baseScale or omwself.object.scale
    appliedScale = appliedScale or baseScale
    -- Drive the scale off the camera's PENDING mode, not just the current one. getQueuedMode() reports
    -- a first<->third switch at the START of its transition animation, while getMode() still says the
    -- old mode until the animation ends. So the instant we begin leaving first person we snap back to
    -- base -- many frames before the third-person body is actually revealed -- hiding the resize behind
    -- the swap. We only count as "in FP" for scaling when fully first person with no switch queued away.
    local queued    = camera.getQueuedMode()
    local leavingFP = queued ~= nil and queued ~= camera.MODE.FirstPerson
    local inFP      = camera.getMode() == camera.MODE.FirstPerson and not leavingFP
    local desired   = (inFP and fpSneaking) and (baseScale * (settings.FakeSneakScale or 1)) or baseScale
    -- Leaving FP: snap to base -- the queued-mode detection above gives us lead time to do it before
    -- the body is revealed, so it's invisible. Entering FP we can't hide it (the body is already
    -- on-screen during the zoom-in), so instead of a pop we SLOW-lerp the shrink to make it subtle.
    if prevInFP and not inFP then
        appliedScale = desired
        enteringFP = false
    else
        if (not prevInFP) and inFP then enteringFP = true end
        local rate = enteringFP and SCALE_ENTER_RATE or SCALE_LERP_RATE
        appliedScale = appliedScale + (desired - appliedScale) * math.min(1, dt * rate)
        if math.abs(desired - appliedScale) < 0.002 then
            appliedScale = desired
            enteringFP = false                            -- slow entry finished; back to normal speed
        end
    end
    prevInFP = inFP
    if lastSentScale == nil or math.abs(appliedScale - lastSentScale) > 0.0005 then
        core.sendGlobalEvent("SneakIsGoodNow_SetScale", { object = omwself.object, scale = appliedScale })
        lastSentScale = appliedScale
    end

    -- Third-person pace + foot-sync in one: set whichever directional sneak group is playing to
    -- playback = commanded / (baseVel / scale), every frame (animation.setSpeed is "until the sequence
    -- ends", so re-set it). Since OpenMW moves the body by this clip's root motion, this single rate
    -- scales BOTH the visual stride AND the ground speed together (always synced); final speed ~=
    -- commanded * scale (confirmed in-game). Runs whenever sneaking (real OR fake) because our override
    -- now plays the sneak clip in BOTH modes and thus drives movement in both. We apply the SAME
    -- FakeSneakScale reduction in real AND fake: with fSneakSpeedMultiplier = 1.0 the engine does NOT
    -- slow real sneak, so to make 3rd-person real sneak match 1st-person (scale 0.9) and fake (0.9) we
    -- drive its sneak clip to 90% here too. CAVEAT (speed_manipulation.md #5): in REAL sneak the engine
    -- also plays sneakforward and re-applies its own speedMult each frame, which may clobber ours -- the
    -- speed HUD will show whether real TP actually lands at 90% or the engine wins. Pure playback --
    -- never touches controls.movement.
    local commanded = types.Actor.getCurrentSpeed(omwself) or 0
    local moveScale = sneakingActive() and (settings.FakeSneakScale or 1) or 1
    if sneakingActive() and commanded > 0 then
        local divisor = SNEAK_ANIM_BASE_VELOCITY / math.max(0.01, moveScale)
        local s = commanded / divisor
        for _, g in ipairs(SNEAK_MOVE_GROUPS) do
            if animation.isPlaying(omwself, g) then animation.setSpeed(omwself, g, s) end
        end
    end

    -- First-person foot-sync. Same idea as the third-person block above, but first-person move clips
    -- carry no baked velocity, so this rate only drives the visible arm-swing (not ground speed). We use
    -- the same base velocity (33.5452) the engine drives real first-person sneak at (character.cpp:754
    -- sneak branch -> speedMult = currentSpeed / 33.5452), so faked and real first-person sneak hands
    -- swing identically. Without this the moving sneak hands have no rate and look frozen/floating.
    if sneakingActive() and commanded > 0 then
        local fps = commanded / FP_SNEAK_DIVISOR
        for _, g in ipairs(FP_SNEAK_MOVE_GROUPS) do
            if animation.isPlaying(omwself, g) then animation.setSpeed(omwself, g, fps) end
        end
    end

    -- Measure ACTUAL horizontal ground speed from position delta (Z is up, so x/y only), then feed a
    -- time-weighted rolling average to kill the per-frame root-motion noise. Window depends on the
    -- camera: long in 3rd person (noisy), short in 1st. This is read-only -- it never drives movement.
    local inFirstPerson = camera.getMode() == camera.MODE.FirstPerson
    local pos = omwself.object.position
    if prevPos then
        local d = pos - prevPos
        local measured = math.sqrt(d.x * d.x + d.y * d.y) / dt
        if measured < 5000 then                       -- guard against teleport/cell-load spikes
            speedSamples[#speedSamples + 1] = { v = measured, dt = dt }
            speedSumVdt = speedSumVdt + measured * dt
            speedSumDt  = speedSumDt + dt
            local window = inFirstPerson and FP_SPEED_WINDOW or TP_SPEED_WINDOW
            while #speedSamples > 1 and (speedSumDt - speedSamples[1].dt) >= window do
                local s = table.remove(speedSamples, 1)
                speedSumVdt = speedSumVdt - s.v * s.dt
                speedSumDt  = speedSumDt - s.dt
            end
        end
    end
    prevPos = pos
    local avgSpeed = speedSumDt > 0 and (speedSumVdt / speedSumDt) or 0

    local mode = realSneaking and "REAL" or (fakeSneakActive and "FAKE" or "OFF")
    -- cam shows CURRENT mode and, if a switch is mid-flight, the QUEUED target. If pressing POV in
    -- 3rd-person sneak makes this read "3rd>1st" (even briefly), the engine DID queue the switch
    -- (case A); if it never changes, the engine refuses to queue it at all (case B).
    local qmode = camera.getQueuedMode()
    local function camName(m)
        if m == camera.MODE.FirstPerson then return "1st" end
        if m == camera.MODE.ThirdPerson then return "3rd" end
        return tostring(m)
    end
    local cam = camName(camera.getMode())
    if qmode ~= nil and qmode ~= camera.getMode() then cam = cam .. ">" .. camName(qmode) end
    -- Authoritative gait, sampled in onFrame AFTER we force walk (reading controls.run here in onUpdate
    -- would be stale). If this ever reads RUN during fake sneak, the no-run enforcement broke.
    local gait = hudGait
    updateDebug(string.format("%s %s | RA:%s %s | scale=%.2f | spd=%.0f~%.1fs cmd=%.0f | play:%s | ours:%s",
        mode, gait, reanimReady and "Y" or "N", cam, moveScale,
        avgSpeed, (inFirstPerson and FP_SPEED_WINDOW or TP_SPEED_WINDOW), commanded,
        firstPlaying(ENGINE_GROUPS), firstPlaying(OUR_GROUPS)))
end

-- Force WALK while FAKE sneaking, robustly, from the INPUT layer (the only place that beats the built-in).
-- The built-in playercontrols.lua reads the 'Run' action and computes controls.run = RunAction ~= alwaysRun
-- in its onFrame, which runs AFTER ours -- so directly writing controls.run loses the race when "Always Run"
-- is on (that was the exact-2x run-speed bug). bindAction supplies the 'Run' action value BEFORE
-- processMovement consumes it, so we win regardless of handler order. To force the XOR to false (= walk) we
-- return RunAction = alwaysRun (true~=true and false~=false both yield false). Read from the same storage
-- section the built-in uses (SettingsOMWControls/alwaysRun -- the live value the Caps Lock toggle flips).
-- Passes input through untouched when not fake sneaking. Touches no controls.* field (movement/sneak safe).
local omwControls = storage.playerSection('SettingsOMWControls')
input.bindAction('Run', async:callback(function(_dt, runValue)
    if fakeSneakActive then return omwControls:get('alwaysRun') == true end
    return runValue
end), {})

-- Force WALK while FAKE sneaking -- the ROBUST mechanism is the input.bindAction('Run', ...) above,
-- not this line. We can't win the per-frame controls.run write: the built-in playercontrols.lua onFrame
-- (controls.run = RunAction ~= alwaysRun) runs AFTER ours, so writing controls.run=false here gets
-- clobbered whenever "Always Run" is on (the exact-2x run-speed bug). bindAction fixes it upstream; this
-- write is kept only as belt-and-suspenders (and to keep the gait sample below truthful for the HUD).
-- Real sneak already walks (engine-forced); only fake needs this. Never touches controls.sneak.
-- Persist our TRUE pre-sneak scale across save/load. setScale mutates object.scale, which the engine
-- bakes into the save; on reload a fresh script can't tell our 0.9 from the real base, so the
-- `baseScale or object.scale` capture above used to re-grab the already-shrunk value and shrink AGAIN,
-- compounding every load (the "incredible shrinking player" -- save while sneaking, reload, repeat).
-- Race/sex height is a separate model-side multiplier (npcanimation.cpp) and is NOT involved; this is
-- purely about not re-deriving our base from a contaminated live scale. We carry our own base across
-- and snap the live scale back to it on load, so a save made mid-sneak can never stack.
local function onSave()
    return { baseScale = baseScale }
end

local function onLoad(data)
    if data and data.baseScale then baseScale = data.baseScale end
    -- Undo whatever shrunk scale the save restored: reset to the true base and force a resend so the
    -- player can't appear shrunk for even one frame. (If there's no persisted base -- a pre-fix save --
    -- we leave it to onUpdate's capture, which now at least stops compounding instead of healing.)
    if baseScale then
        appliedScale  = baseScale
        lastSentScale = nil
        core.sendGlobalEvent("SneakIsGoodNow_SetScale", { object = omwself.object, scale = baseScale })
    end
end

local function onFrame()
    if fakeSneakActive then omwself.controls.run = false end
    hudGait = omwself.controls.run and "RUN" or "WALK"

    -- Camera unblock. Our full-body sneak override plays at Priority_Hit, so while sneaking the engine
    -- DEFERS first<->third view switches (camera.cpp:225 upperBodyReady gate) instead of performing them,
    -- parking the request in its queue. camera.getQueuedMode() exposes that queue -- the very signal the
    -- builtin camera script itself trusts (camera.lua:214). When a switch is pending and we're the cause
    -- (sneaking), complete it forcibly: setMode(mode, true) takes the `force` path that skips the gate
    -- (camera.cpp:225 is `if (!force && ...)`). This only ever acts on a switch the engine ALREADY wants
    -- to make, so it can't fight normal camera behavior; outside this stuck case getQueuedMode() is nil.
    if sneakingActive() then
        local queued = camera.getQueuedMode()
        if queued ~= nil and queued ~= camera.getMode() then
            camera.setMode(queued, true)
        end
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onFrame = onFrame,
        onSave = onSave,
        onLoad = onLoad,
    },
}
