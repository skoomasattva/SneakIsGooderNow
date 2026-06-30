local mp = "scripts/MaxYari/SneakIsGoodNow/"

local types = require("openmw.types")
local nearby = require("openmw.nearby")
local omwself = require("openmw.self")
local core = require("openmw.core")
local I = require('openmw.interfaces')
local animation = require("openmw.animation")


local DEFS = require(mp .. 'utils/sneak_defs')

-- Knockdown damage multiplier. The mod's omwaddon sets fCombatKODamageMult to 1.0 to take over sneak
-- damage, which also removes the legit vanilla 1.5x vs knocked-down/KO'd targets. We quietly restore that
-- here. Hardcoded to the vanilla value — not exposed as a setting, it's just patching what we broke.
local KNOCKDOWN_DAMAGE_MULT = 1.5

-- The engine's own sneak-crit multipliers (read straight from the GMSTs the combat code uses, so the
-- displayed total matches the actual hit even if a mod/setup changed them). On an unaware hit the engine
-- multiplies melee damage by fCombatCriticalStrikeMult (vanilla 4.0) and ranged by fCombatKODamageMult
-- (vanilla 1.5 — this is the path that gives bows their weak sneak crit). Read once at load; GMSTs don't change.
local MELEE_CRIT_MULT = core.getGMST("fCombatCriticalStrikeMult") or 4.0
local RANGED_CRIT_MULT = core.getGMST("fCombatKODamageMult") or 1.5

-- Sneak-attack state for the player attacking THIS actor, pushed by the player script.
--   sneakActive = the player is sneaking and this actor hasn't detected it (so any hit is a sneak attack)
--   sneakMult   = the total sneak damage multiplier (baseline + Sneak-scaled weapon factor); 1 = no bonus
local sneakActive = false
local sneakMult = 1

-- Release-time sneak latch (ranged only). A projectile's flight gives this actor time to finish detecting
-- the player AFTER the shot leaves the bow, which would otherwise strip the bonus mid-air (the classic
-- "ranged sneak feels unreliable" problem). The player script broadcasts SneakLatch the frame a projectile
-- spawns, having already resolved eligibility ITS side -- it's the only place that knows the multiplier AND
-- works for targets beyond the mod's detection range (which never become observers, so sneakActive/sneakMult
-- are never set on them -- i.e. anything sniped from a distance). So we just honor whatever it sends: a mult
-- means "eligible, freeze it"; nil means "not a sneak shot, clear any stale latch". The latch has NO timeout:
-- it stays valid until the hit consumes it, OR the player tells us via SneakRevoke that we've actually
-- detected them -- and ONLY then. A slow projectile can be airborne arbitrarily long, so we never guess.
local latchedMult = nil

local function onSneakLatch(e)
    latchedMult = e.mult  -- a number freezes the release-time bonus; nil clears any stale latch
end

-- We've actually detected the player (full detection or combat) while a latch was pending: cancel the
-- pending ranged crit. Sent by the player script's detection loop. This is the only thing that drops a
-- latch short of the hit consuming it.
local function onSneakRevoke()
    latchedMult = nil
end


local function onGetFollowTargets(dt)
    for _, player in ipairs(nearby.players) do
        player:sendEvent("MaxYariUtil_FollowTargets", {actor = omwself.object, targets = I.AI.getTargets("Follow")})
    end
end

local function onSneakBonus(e)
    sneakMult = e.mult or 1
    sneakActive = e.sneak or false
end


-- Knockdown detection. The engine's fCombatKODamageMult keys on the getKnockedDown() stat (a stored
-- bool), and the character controller plays exactly these animation groups while that stat is true — so
-- the animation is a faithful, encumbrance-false-positive-free proxy. Covers knockdown AND knockout (the
-- fatigue-KO case the engine also rewards) plus swim variants.
local KNOCK_GROUPS = { "knockdown", "knockout", "swimknockdown", "swimknockout" }

-- Whether this actor's skeleton even has the knockdown/knockout groups. Static, so computed once and
-- cached. Some creatures lack them; those fall back to canMove below.
local hasKnockAnim = nil
local function actorHasKnockAnim()
    if hasKnockAnim == nil then
        if not animation.hasAnimation(omwself.object) then return false end -- not loaded yet: don't cache
        hasKnockAnim = false
        for _, g in ipairs(KNOCK_GROUPS) do
            if animation.hasGroup(omwself.object, g) then hasKnockAnim = true; break end
        end
    end
    return hasKnockAnim
end

local function isVictimKnockedDown()
    local v = omwself.object
    if actorHasKnockAnim() then
        for _, g in ipairs(KNOCK_GROUPS) do
            if animation.isPlaying(v, g) then return true end
        end
        return false
    end
    -- Creature with no knockdown animation: fall back to the canMove proxy. canMove is false for dead,
    -- paralyzed, OR knocked-down (and over-encumbered), so exclude dead/paralyzed to isolate knockdown.
    -- The remaining false positive (a standing over-encumbered creature) is acceptable here.
    if not types.Creature.objectIsInstance(v) then return false end
    return not types.Actor.canMove(v)
        and not types.Actor.isDead(v)
        and types.Actor.activeEffects(v):getEffect(core.magic.EFFECT_TYPE.Paralyze).magnitude == 0
end


I.Combat.addOnHitHandler(function(a)
    if not a.attacker then return end
    if types.Player.objectIsInstance(a.attacker) and a.sourceType == I.Combat.ATTACK_SOURCE_TYPES.Melee or a.sourceType == I.Combat.ATTACK_SOURCE_TYPES.Ranged then
        -- Sneak attack: the player is sneaking and unseen by this actor (sneakActive, pushed by the
        -- player script), so this landed hit is a real sneak attack. Re-check the attacker is the player
        -- here (the if above's `and/or` lets non-player ranged in) and that real damage landed.
        -- Health damage for armed hits; fatigue for unarmed against an upright target (hand-to-hand only
        -- converts to health once the victim is KO'd/paralyzed), so check both.
        local healthDmg = (a.damage and a.damage.health) or 0
        local fatigueDmg = (a.damage and a.damage.fatigue) or 0
        local playerDamageHit = types.Player.objectIsInstance(a.attacker)
            and a.successful and (healthDmg > 0 or fatigueDmg > 0)

        -- Knockdown bonus: independent of sneak. Quietly restores the vanilla fCombatKODamageMult the
        -- omwaddon zeroes (1.5x vs knocked-down/KO'd targets). Applies to any landed player hit on a prone
        -- target and stacks with the sneak multiply below; refresh the locals so the sneak block builds on
        -- top. Deliberately NOT folded into the reported sneak total — it just patches what we broke.
        if playerDamageHit and isVictimKnockedDown() then
            if healthDmg > 0 then a.damage.health = healthDmg * KNOCKDOWN_DAMAGE_MULT; healthDmg = a.damage.health end
            if fatigueDmg > 0 then a.damage.fatigue = fatigueDmg * KNOCKDOWN_DAMAGE_MULT; fatigueDmg = a.damage.fatigue end
        end

        -- Resolve the sneak multiplier for this hit. Live state (sneakActive/sneakMult, pushed by the
        -- player script) is authoritative. For RANGED hits we additionally honor the release-time latch:
        -- it preserves the eligibility we had when the projectile left the bow, so detection completing
        -- during its flight doesn't silently strip the crit on impact. effMult is nil when no bonus applies.
        -- Latch is a player-only concept (only the player's sneaking sets one), so gate it on the attacker
        -- being the player -- an NPC's ranged hit on this actor must not consume the player's pending latch.
        local isPlayerRanged = a.sourceType == I.Combat.ATTACK_SOURCE_TYPES.Ranged
            and types.Player.objectIsInstance(a.attacker)
        local effMult = nil
        if isPlayerRanged then
            -- Ranged is latch-driven: the player froze release-time eligibility (and the mult) when the
            -- projectile loosed, so detection finishing mid-flight can't strip it -- the latch is dropped
            -- only by an explicit SneakRevoke (we actually detected them) or by being consumed here. It
            -- also covers targets sniped from beyond detection range that never get a live SneakBonus
            -- (sneakActive stays false). Fall back to live state for a point-blank shot whose latch
            -- event hasn't been processed yet.
            if latchedMult then
                effMult = latchedMult
            elseif sneakActive then
                effMult = sneakMult
            end
            -- Consume the latch (on a hit or a miss) so it can't carry to a later shot.
            latchedMult = nil
        elseif sneakActive then
            effMult = sneakMult
        end

        if effMult and playerDamageHit then
            -- Multiply whichever damage actually landed by the mod's total sneak multiplier (baseline +
            -- weapon factor). effMult is never 1 here without a real bonus, so this is always safe to apply.
            if effMult ~= 1 then
                if healthDmg > 0 then a.damage.health = healthDmg * effMult end
                if fatigueDmg > 0 then a.damage.fatigue = fatigueDmg * effMult end
            end
            -- Report the true total multiplier to the player for the optional "Critical Strike for #.#X!"
            -- message. engineCrit = whatever sneak crit the engine still applied before this handler (read
            -- live from the GMSTs above; normally 1.0 once the omwaddon zeroes them). actual landed damage
            -- = base × engineCrit × effMult, so this report is exact even if a mod overwrites the GMSTs.
            local engineCrit = isPlayerRanged and RANGED_CRIT_MULT or MELEE_CRIT_MULT
            a.attacker:sendEvent(DEFS.e.SneakHit, { mult = engineCrit * effMult })
        end

        a.attacker:sendEvent(DEFS.e.ReportAttack, {attacker = a.attacker, target = omwself.object})
    end
end)

return {
    eventHandlers = {
        MaxYariUtil_GetFollowTargets = onGetFollowTargets,
        [DEFS.e.SneakBonus] = onSneakBonus,
        [DEFS.e.SneakLatch] = onSneakLatch,
        [DEFS.e.SneakRevoke] = onSneakRevoke
    }
}