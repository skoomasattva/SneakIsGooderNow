# Changelog

This is **SneakIsGooderNow**, a fork of MaxYari's *Sneak! (Sneak Is Good Now)*. Everything below is
the fork's divergence from the original. Internal file names are unchanged (still
`SneakIsGoodNow.omwaddon` / `scripts/MaxYari/SneakIsGoodNow/...`).

## Unreleased

### Playable now

#### Detection feel — organic post-detection decay
Getting spotted no longer latches sneak off until you fully break line of sight or change cells.

- On full detection the player now enters a **post-detection lockout** (`ps.lockedOut`) instead of a
  bare `controls.sneak = false` kick. Sneak is held off for the duration, but detection keeps being
  evaluated and **decays naturally** using the existing facing/distance-aware math.
- `detection_math.lua`'s `sneakCheck` now also runs while locked out (previously it short-circuited
  to "detected" the instant you weren't sneaking, jamming detection at full and never letting it
  drop). Lockout releases once **every** observer's detection has decayed to 0 (cell changes, which
  wipe the observer list, also clear it).
- Deliberate penalty: detection must fall **all the way to 0** before you can sneak again.
- Files: `detection_math.lua`, `SneakPlayer.lua`.

#### Single HUD detection meter
- New **Single HUD meter** mode (`SingleHudMeter`, default **ON**): one centered meter showing the
  highest current detection, instead of a marker floating over each NPC's head.
- Repositionable from screen center (`HudOffsetX` / `HudOffsetY`) and opacity-adjustable
  (`MarkersAlpha`).
- **Always show while sneaking** (`AlwaysShowMeter`, default OFF) keeps the meter up the entire time
  you're sneaking, even at zero detection.
- Event-driven behavior: turns **red and flashes** when you get caught; **flashes** if you try to
  sneak while blocked (combat or cooldown); shows a **decaying red gauge** through the
  post-detection cooldown. It is *not* pinned on-screen for the whole fight — the persistent
  "can't sneak" signal lives on the crosshair via the companion mod (see interface below).
- The classic **per-NPC head markers** are still available — just turn Single HUD meter off.
- Files: `SneakPlayer.lua` (event-driven eye state machine), `Sneak_ui_elements.lua` (new
  `flash()`, `setHudPos()`, `setLocked()`, and `new({ hud = true })` which skips the auto fade-in so
  the state machine owns alpha).

#### Optional mod-owned sneak key
- New **Use mod's own sneak key** (`UseModSneakInput`, default OFF): bind a dedicated sneak key
  (`SneakKeyBinding`) and unbind OpenMW's own Sneak, so the mod drives `controls.sneak` directly.
  This removes the brief sneak-stance **flicker** that happens when the engine starts sneaking a few
  frames before a detection kick.
- **Hold or toggle** (`ModSneakToggle`, default ON = tap to toggle).
- Stopgap: this exists to kill the kick-frame flicker and is expected to be superseded by the
  fake-sneak system once that's integrated.
- File: `SneakPlayer.lua` (input resolved at the top of `onUpdate`, before `isSneaking` is read).

#### Sneak-attack damage — mod-owned, configurable
The mod now owns sneak-attack damage outright (the engine's crit is neutralized in the omwaddon, see
*Engine GMST changes* below).

- **Base Damage Multiplier** (`BaselineSneakDamage`, default **2**, flat) — applies to every sneak
  attack regardless of weapon or skill.
- **Per-weapon-type bonuses** that **scale with Sneak skill** and **stack additively** on top of the
  baseline: Short blade **8**, One-handed **3**, Two-handed **1**, Marksman **1**, Hand-to-hand
  **8**. Formula: `sneakMult = BaselineSneakDamage + setting * (sneak / 100)`.
- Weapon category is chosen from the equipped weapon's **type** (short blade is its own type, so it
  naturally outranks the generic one-handed group); nothing equipped = hand-to-hand.
- Controller-friendly **"select" steppers** instead of fiddly number entry.
- Mechanism: the player computes the multiplier once per tick and **pushes it per-actor** (deduped,
  eligibility-gated) via the `SneakBonus` event; the actor applies it on a landed hit.
- Files: `SneakPlayer.lua` (`WEAPON_CATEGORY_SETTING`, push), `SneakActor.lua` (apply),
  `settings.lua`, `utils/sneak_defs.lua` (`SneakBonus` / `SneakHit` events).

#### Hand-to-hand sneak attacks can knock out in one hit
- Unarmed hits drain **fatigue** (not health) against an upright target; the mod multiplies the
  fatigue damage too, so a sneak punch can drop someone in a single hit. `SneakActor.lua` gates on
  health **or** fatigue damage landing.

#### Bow / ranged sneak-attack fix (the ancient vanilla bug)
- Vanilla routed ranged sneak attacks through `fCombatKODamageMult` (**1.5×**) instead of the melee
  critical multiplier (**4×**), making bow sneak attacks feeble. By zeroing **both** GMSTs and
  owning the multiplier in Lua, marksman sneak attacks now get the **same configurable baseline as
  melee**.

#### Ranged sneak crit reliability — release-time latch (fixes "the crit doesn't apply on distant targets")
**The bug:** marksman sneak crits were wildly inconsistent. They worked point-blank (and 100% of the
time on enemies spawned at your feet in the testing cell) but routinely **failed on anything sniped
from across a room/field** — distant rats, mudcrabs, etc. The on-screen multiplier readout looked
correct, yet the crit didn't land.

**Why it was there — two compounding causes:**
1. *Timing race.* The sneak bonus was applied at projectile **impact**. A projectile's flight time
   gives the target room to finish detecting you **mid-air**, stripping the bonus a frame before the
   hit lands. Worse with bows/crossbows (slow arrows) than thrown weapons.
2. *Observer-range gate (the real killer).* The mod's custom detection sim only tracks actors within
   `detectionRange` — which is read straight from `fSneakUseDist`. This build's omwaddon raises that
   GMST to **1000 units (~14 m)** (vanilla default is 500 / ~7 m) for an unrelated reason — to break
   the engine's `awarenessCheck` so the mod owns detection — and the sim inherits that value as a side
   effect. Only tracked "observers" receive the `SneakBonus` event that sets `sneakActive`/`sneakMult`
   on the target. A target you **snipe from beyond ~14 m and have never approached** is never an
   observer, so its `sneakActive` stays `false` forever → no crit, no matter what the readout says.
   (Point-blank spawns in the test cell are well inside that radius, hence the 100% there.)
   `detectionRange = fSneakUseDist` is conceptually wrong regardless of the number: in **vanilla** that
   GMST is only the radius for the crouch-eye HUD and Sneak XP — *not* a detection cutoff (vanilla's
   actual `awarenessCheck` has no distance cutoff at all; distance only scales the roll). The mod
   author repurposed it as a cheap scope radius for the sim and flagged it provisional (`-- to do,
   dont forget to change this`). It's an **acquisition** radius, not a maintenance one: once a target
   comes within that range (or enters combat) it stays tracked at any distance until detection decays
   — but a target you never get near is simply never acquired.

**The fix — resolve eligibility on the player at release and ship it to the target:**
- A shot is detected the frame the equipped **ammo / thrown stack count drops by one**
  (`getRangedShotState` in `SneakPlayer.lua`).
- At that instant the **player** resolves per-target eligibility (it alone knows both the multiplier
  *and* each target's detection state) and broadcasts the resolved multiplier inside a **`SneakLatch`**
  event to **every nearby actor** — not just observers. This is what reaches distant, never-acquired
  targets. A target with no status, or one we haven't fully alerted and aren't fighting, counts as
  **unaware → eligible**.
- The target **freezes** that release-time multiplier and honors it on impact regardless of detection
  completing during the flight — killing the timing race.
- **No timeout.** The latch is dropped only when (a) the hit consumes it, or (b) the player is
  **actually detected** by that actor — a **`SneakRevoke`** event sent from the player's detection
  loop on the rising edge of `progress >= 1.0` **or** `fightingPlayer`. (Earlier work used a 3-second
  TTL; removed, because a slow projectile can legitimately be airborne longer and we refuse to guess.)
- Revocation is deliberately **decoupled from the generic `eligible` flag**: standing up, dropping the
  sneak input, or getting locked out mid-flight does **not** cancel a shot already loosed from
  stealth — *only the target genuinely noticing you* does.
- **Melee is unchanged** (always inside detection range, so it keeps the live `sneakActive` path). For
  point-blank ranged shots whose latch event hasn't been processed yet, the actor falls back to live
  `sneakActive`.
- Self-consistent with the model: a far target the sim never simulates is never "detected," so the
  crit always lands; if detection is later widened to longer range, revocation tightens automatically
  with no changes here. The `detectionRange` gate is untouched — it still scopes the meter sim, it
  just no longer gates ranged crit eligibility.
- Files: `SneakPlayer.lua`, `SneakActor.lua`, `utils/sneak_defs.lua` (new `SneakLatch` / `SneakRevoke`
  events).

#### Crit-strike debug readout (diagnostic)
- Optional **Show crit-strike debug readout** (`CritStrikeDebugHud`, default OFF, *Combat & Feedback*).
  Styled like the fake-sneak debug text: a live on-screen breakdown of the sneak-attack multiplier —
  engine crit GMSTs, base multiplier, the weapon-type cap that should apply, the Sneak-scaled weapon
  factor, and the resolved total. Added to diagnose the ranged-crit bug above; left in for tuning.
- File: `SneakPlayer.lua` (`updateCritDebug`, computed every tick from the live equipped weapon).

#### Knockdown damage bonus restored (1.5×)
- Zeroing `fCombatKODamageMult` to take over sneak damage also removed the legitimate vanilla **1.5×
  vs knocked-down / knocked-out targets**. The mod quietly restores it as a hardcoded constant
  (`KNOCKDOWN_DAMAGE_MULT = 1.5` in `SneakActor.lua`) — **not** a setting, it just patches what we
  broke.
- Applies to **any** landed player hit on a prone target (sneaking or not), stacks with the sneak
  multiplier, and is **not** folded into the reported sneak-attack message.
- Detection keys on the `knockdown` / `knockout` (+ swim) animation groups, with a `canMove`-based
  fallback for creatures that lack those animations.

#### On-screen sneak-attack confirmation
- Optional **"Critical Strike for X.XX damage!"** message on a successful sneak hit (exact format
  string `"Critical Strike for %.1fX damage!"`). `ShowSneakAttackMessage` (default ON);
  `SneakMessageY` sets vertical position (default 0.85, horizontally centered).
- Reports the **true total** multiplier (`engineCrit × sneakMult`), reading the engine crit GMSTs
  live so the number stays exact even if another mod changes them.

#### Settings menu reorganized
- Split into **five ordered groups**: *Sneak Key*, *Detection*, *Sneak Attack Damage*, *Maximum
  Weapon Damage Multipliers*, *Combat & Feedback*. Each group has an explicit `order` (without it,
  groups all default to `order 0` and the menu **shuffles between sessions**).
- One-time **migration** (`pruneMovedSettings`) clears stale values left in the old single section,
  which would otherwise shadow (and freeze) a setting after it moved groups.
- `utils/settings_helper.lua` now accepts **multiple sections** and resolves each key to whichever
  section actually owns it.

#### Modder interface 1.0 → 1.1
- Added `isSneakBlocked()` (true during **combat OR** the **post-detection cooldown**) and
  `sneakBlockReason()` (`"combat"` | `"cooldown"` | `nil`).
- The companion mod **Dynamic Reticle** (same original author) reads these to tint the crosshair red
  while sneaking is blocked.

#### Engine GMST changes (in `SneakIsGoodNow.omwaddon`)
Verified against the omwaddon itself:

| GMST | Value | Purpose |
|---|---|---|
| `fSneakUseDist` | 1000.0 | Forces the engine's `awarenessCheck` to always fail while sneaking (you're genuinely "unaware-attackable" — guaranteed hit, evasion 0 — until the mod kicks you). The mod's own overlay decides *when* to kick. |
| `fSneakDistanceBase` | 9999.0 | Same — undetectability comes from the omwaddon, not the scripts. |
| `fCombatCriticalStrikeMult` | 1.0 | Neutralizes the engine's melee sneak crit so the mod is the single source of the multiplier. |
| `fCombatKODamageMult` | 1.0 | Neutralizes the engine's ranged sneak crit (and the vanilla knockdown 1.5×, restored in Lua above). |
| `sTargetCriticalStrike` | `""` | Blank string suppresses the engine's unconditional melee "Critical Strike!" popup (an empty message is erased the next frame). |
| `fSneakSpeedMultiplier` | 1.0 | Engine no longer slows you while sneaking — the mod owns sneak **speed** (via the animation-rate trick) so real and fake sneak match. |
| `i1stPersonSneakDelta` | 0 (Integer) | Engine no longer drops the first-person camera while sneaking — the mod owns sneak **height** (via actor scale). |

> The last two (`fSneakSpeedMultiplier`, `i1stPersonSneakDelta`) hand height/speed control to the
> fake-sneak layer below; they are intentionally neutralized so the mod can drive both itself.

---

### Experimental — not yet integrated (fake sneak)

A **visual-only sneak** that reproduces sneak's look and feel **without ever setting
`controls.sneak`**, so detection can eventually run at all times and the kick can soften into a mere
speed cap. Isolated in `FakeSneak.lua` (+ `FakeSneakGlobal.lua`); requires **OpenMWReAnimation** in
the load order. Not wired into detection yet — this changelog entry documents the visual layer only.

- **Height & speed parity** via one `FakeSneakScale` knob (default **0.9**), applied identically in
  real *and* fake sneak:
  - **First-person height** — shrink the whole actor with `setScale` (camera *and* arms drop
    together, like the real neck-drop). `setScale` is global-only, so the player script pushes a
    target to the global script.
  - **Movement speed** — the **animation root-motion trick**: OpenMW moves the body by the playing
    locomotion clip's accumulated root motion, so setting that clip's **playback rate** changes
    ground speed (constant `33.5452` = the sneak clip's baked root velocity). This is *why*
    `fSneakSpeedMultiplier` and `i1stPersonSneakDelta` are neutralized in the omwaddon. (Limits:
    third-person only; breaks if "Player movement ignores animation" is ON.)
- **Run forced to walk** via `input.bindAction('Run', …)` (upstream of the built-in controls), so
  fake sneak doesn't get run speed when Always Run is on.
- **Seamless real↔fake transitions** — OpenMW keeps one animation track per group name, so if both
  the engine and our override touch the same name, the boundary restarts it from frame 0 (a visible
  hitch). Our overrides are registered **parentless and span both sneak modes**, and they play
  **private `sig*` alias group names the engine never emits**, so one continuous instance owns the
  animation across a real↔fake switch.
- **Animation coverage:**
  - **Third person** — complete (vanilla ships every sneak group).
  - **First person idle + movement** — `1h` / `1s` / `bow` from ReAnimation's purpose-built FP sneak
    clips; `hh` / `2c` / `2w` sourced from vanilla's own first-person animation reel; `spell`
    aliased from the held `IdleSpell` pose (vanilla has no spell sneak-walk clip).
  - **Crossbow — NOT done.** Vanilla ships no crossbow sneak animation anywhere, so there's nothing
    to alias; fake sneak with a crossbow currently shows non-sneak movement. Next task.

> **On the `2c` and spell animations — an honest note.** We weren't hunting for "unused" clips; we
> were going through vanilla's own first-person animation reel trying to grab the clips real sneaking
> uses. What we bookmarked as those sneak clips came out looking *different* from what we expected —
> but it looked good as a crouch-walk, so we kept it. Whether those frames are truly unused in
> vanilla, and why they render differently than reading the engine source would predict, we never
> investigated. Don't look a gift horse in the mouth.
