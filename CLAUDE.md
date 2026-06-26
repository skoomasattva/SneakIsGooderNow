# SneakIsGoodNow — developer notes

OpenMW Lua mod (author MaxYari) that replaces the engine's sneak detection with its own parallel model
and overhauls sneak-attack damage. Companion mod: **Dynamic Reticle** (same author) tints the crosshair
when sneaking is blocked, wired via this mod's `I.SneakIsGoodNow` interface.

## Engine sneak modifiers are neutralized — the mod owns height & speed

Two GMSTs are deliberately neutralized in the omwaddon, by the user, on purpose (values verified by
dumping `SneakIsGoodNow.omwaddon` with tes3conv):

- **`fSneakSpeedMultiplier = 1.0`** (Float) — the engine no longer slows you while sneaking.
- **`i1stPersonSneakDelta = 0`** (Integer) — the engine no longer drops the first-person camera while
  sneaking. (It's an integer pixel delta, so `0` = no drop. Not `1.0`.)

**Why:** removing the engine-forced sneak height and speed modifiers lets the mod take over *both* offsets
itself, so **real and fake sneak look and move identically** (parity). The single knob is the
**`FakeSneakScale`** setting (default **0.9**, range 0.75–1.0; "Sneak strength (height + speed)"), applied
in `FakeSneak.lua`:

- **First-person height** is recreated by **shrinking the whole actor** to `baseScale * FakeSneakScale`
  (so the camera *and* the arms lower together, like the real neck-drop). `setScale` is global-only, so
  `FakeSneak.lua` lerps a target and pushes it via `core.sendGlobalEvent("SneakIsGoodNow_SetScale", …)`
  to the GLOBAL script. Applies in first person during **either** sneak; snaps (not lerps) on a
  camera-mode change so you never watch yourself resize across the cut.
- **Movement speed** is recreated with the **animation-root-motion trick** — *not* by writing
  `controls.movement`. OpenMW moves the body by the playing locomotion clip's accumulated root motion, so
  setting that clip's **playback rate** changes ground speed. Each frame, for the playing 3rd-person sneak
  group: `animation.setSpeed(group, commanded / (33.5452 / FakeSneakScale))` → final ground speed
  ≈ `commanded × FakeSneakScale`. Because `fSneakSpeedMultiplier = 1.0`, the engine doesn't slow real
  sneak either, so the mod drives the **same** `FakeSneakScale` rate in real *and* fake sneak to match.
  The deep mechanism (and its limits — third-person only, dies if "Player movement ignores animation" is
  ON) is in **`plans and docs/speed_manipulation.md`**; the constant `33.5452` is the sneak clip's baked
  root velocity (`character.cpp:754`). First-person move clips carry no root velocity, so the FP
  `setSpeed` there only drives the visible **arm-swing**, not ground speed.

**Do not "fix" these GMSTs back to vanilla** — that would double-apply the slowdown/height-drop on top of
the mod's. They are intentionally neutralized (`fSneakSpeedMultiplier = 1.0`, `i1stPersonSneakDelta = 0`).

## Script layout (`SneakIsGoodNow.omwscripts`)

| Context | File | Role |
|---|---|---|
| `PLAYER` | `SneakPlayer.lua` | Detection math, HUD, the kick, sneak-attack factor computed here and pushed per-actor. |
| `NPC, CREATURE` | `SneakActor.lua` | Defender-side `onHit` handler that applies the damage multipliers. |

Detection math: `detection_math.lua`; aggression: `aggression_math.lua`; markers:
`Sneak_ui_elements.lua`; settings: `settings.lua` (+ `utils/settings_helper.lua`); events: `utils/sneak_defs.lua`.

## How it works (the important constraints)

- **The kick is foundational.** On full detection the player script sets `controls.sneak = false` so the
  engine takes over aggression. Do not remove it.
- **Undetectability comes from the omwaddon, not the scripts.** `SneakIsGoodNow.omwaddon` sets
  `fSneakUseDist=1000` / `fSneakDistanceBase=9999`, forcing the engine's `awarenessCheck` to always fail
  while sneaking → the engine genuinely treats every sneak hit as unaware (guaranteed hit, evasion 0)
  until the mod kicks you. The mod's own detection overlay decides *when* to kick.
- **The mod owns sneak damage.** The omwaddon also sets `fCombatCriticalStrikeMult=1.0` and
  `fCombatKODamageMult=1.0`, neutralizing the engine crit so the mod is the single source of the
  multiplier. To suppress the engine's unconditional melee "Critical Strike!" popup, the omwaddon blanks
  the `sTargetCriticalStrike` GMST string to `""` (an empty message is erased the next frame).

## Experimental: "fake sneak" (isolated, pre-integration)

The kick exists only because detection can't run while really sneaking (the omwaddon makes you
undetectable in real sneak). The next direction removes that whole problem with a **visual-only fake
sneak**: reproduce sneak's look/feel WITHOUT ever setting `controls.sneak`, so detection can run at all
times and the kick becomes a gentle speed cap. Lives entirely in `FakeSneak.lua` (PLAYER) + a tiny
`FakeSneakGlobal.lua` (GLOBAL, just applies `setScale`), with its own test binding
`SneakIsGoodNow_FakeSneak` and an "Experimental: Fake Sneak (testing)" settings group — base files
untouched, removable via one omwscripts line. Requires `OpenMWReAnimation` in load order (guarded on
`I.ReAnimation`). `sneakingActive()` = `fakeSneakActive or controls.sneak` — everything below runs for
**either** sneak so the two are pixel/pace-identical and switching between them is seamless.

The four faked effects:

- **Height (first person)** — actor `setScale` to `FakeSneakScale`. **Speed (both views)** — animation
  playback-rate trick. Both covered in detail in the "Engine sneak modifiers" section above (they're why
  `fSneakSpeedMultiplier` is 1.0 and `i1stPersonSneakDelta` is 0).
- **Run→walk** — fake sneak has `isSneaking=false`, so `getMaxSpeed` would hand it **run** speed. We force
  walk via **`input.bindAction('Run', …)`** (returns `alwaysRun` while fake-sneaking, so the built-in
  `playercontrols.lua` XOR yields false), **not** a `controls.run` write — a `controls.run=false` from our
  `onFrame` gets clobbered by the built-in's later write when Always Run is on. `bindAction` injects
  upstream of `processMovement` and wins regardless. (`controls.run=false` is kept only as belt-and-braces.)
- **Crouch animation + seamless transitions** — via **ReAnimation** (dependency, same author) and the
  **sole-ownership / `sig` alias** model below.

### Sole-ownership / `sig` aliases (why transitions don't hitch)

OpenMW keeps one AnimState per group name. If both the engine and our override touch the *same* group
name, each restarts it from keyframe 0 at the real↔fake boundary → a visible hitch. So our overrides are
registered **parentless and span both sneak modes**, and they play a **private group name no engine code
ever plays**: for any real group `g`, `playable(g)` returns `"sig"..g` when that alias asset is installed,
else `g`. The `sig*` clips are the *same frames* shipped under the private name (built by
`tools/build_aliases.py`; mechanism in `plans and docs/01 ALIAS_ANIMATIONS_MINIPROJECT.md` and
`03 ANIMATION_BOOKMARK_TECHNIQUE.md`).

- **Third person** — vanilla already ships every sneak group; parentless overrides drive `sigidlesneak` +
  `sigsneak{forward,back,left,right}`. Done.
- **First-person idle** — `sigidle{1h,1s,bow}sneak` (ReAnimation's FP sneak idles, renamed). We
  *neutralize* ReAnimation's own built-in FP sneak idles first so we're the sole owner.
- **First-person movement** — `sigsneak{dir}{weapon}`. Asset coverage by weapon short-group:
  - `1h / 1s / bow` — ReAnimation's purpose-built FP sneak-movement clips.
  - `hh / 2c / 2w` — aliased from time-windows in vanilla's `xbase_anim.1st.kf` that we bookmarked
    while looking for the clips real sneaking uses. **Honest caveat:** what we grabbed came out
    looking *different* from what we expected, but it read well as a crouch-walk so it was kept.
    Whether these frames are genuinely unused in vanilla, and why they render differently than the
    engine source would predict, was never investigated — don't assert "authored-but-unseen vanilla
    sneak clips" as settled fact. See `03 ANIMATION_BOOKMARK_TECHNIQUE.md`.
  - `spell` — aliased from the held `IdleSpell` pose (vanilla has no spell movement clip at all); same
    "looked surprisingly good, kept it" story as above.
  - **`crossbow` — NOT YET DONE.** Vanilla ships no crossbow sneak animation anywhere, so there's nothing
    to alias; fake sneak with a crossbow currently shows non-sneak idle/movement. **This is the next task.**

`currentSuffix()` maps the drawn weapon/stance to the short-group (`hh` for fists, `1h` for the whole
one-hand family incl. lockpick/probe/thrown, `2c`/`2w` for two-handers, `spell` for spell stance,
`nil` for crossbow). `FP_IDLE_WEAPONS` (idle assets we ship: 1h/1s/bow) is kept separate from
`FP_MOVE_WEAPONS` (idle set + hh/2c/2w/spell). Engine-group cross-checks live in the HUD's `ENGINE_GROUPS`
/ `OUR_GROUPS` lists; `ours:` shows which `sig*` group is live (the real signal — `play:` cosmetically
reads `idle<weapon>` because the upper body keeps its own track while moving).

**Status:** FP + TP parity complete for everything except crossbow. Detection rewiring / kick removal
still come after the visual layer is finished.

## Sneak-attack damage (additive, mod-owned)

Computed player-side per tick from the equipped weapon, pushed per-actor via `DEFS.e.SneakBonus
{ mult, sneak }`:

```
weaponFactor = (per-weapon setting) * sneakSkill.modified / 100   -- 0 if no qualifying weapon
sneakMult    = BaselineSneakDamage + weaponFactor                  -- additive, baseline default 2.0 (flat)
```

`SneakActor.lua` caches `sneakMult` and, on a real player hit on an undetected actor, multiplies the
landed `a.damage.health`/`.fatigue` by it. It reports the **true total** `engineCrit * sneakMult * koMult`
to the player for the optional "Critical Strike for %.1fX damage!" message (`engineCrit` read live from the
GMSTs, so the report stays exact even if a mod overwrites them).

## Knockdown bonus (hardcoded 1.5×)

Zeroing `fCombatKODamageMult` also kills the legit vanilla 1.5× vs knocked-down/KO'd targets, so the mod
quietly restores it. It's a hardcoded constant (`KNOCKDOWN_DAMAGE_MULT` in `SneakActor.lua`) — deliberately
**not** a setting; it just patches what the omwaddon broke. Applied **independent of sneak**, stacking with
`sneakMult`, and **not** folded into the reported "Critical Strike for #.#X" total.

- **Detection** keys on the engine's `getKnockedDown()` stat, which the character controller mirrors as
  the `knockdown`/`knockout` (+ swim) animation groups. So `isVictimKnockedDown()` checks those groups via
  `animation.isPlaying`, gated by `animation.hasGroup` (cached). Creatures lacking those groups fall back
  to `not canMove and not isDead and not paralyzed` (the only false positive is over-encumbrance).

## Working agreements

- `settings.lua` is user-managed; preserve their edits. `WeaponBonus` (hit-chance skill modifier) stays.
- Don't change established default setting values without asking.
- When investigating engine behavior, prefer the Lua API docs; the C++ source under
  `openmw-xbox-XBOX-Overhaul/apps/openmw` is the authority but expensive to read — use it to *confirm*,
  not to browse.
