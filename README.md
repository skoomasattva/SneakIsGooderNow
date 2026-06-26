# SNEAK IS GOODER NOW

This is a fork of MaxYari's original **Sneak! Sneak Is Good Now** - still very much a WIP **currently under heavy development**. Now playable. Probably. But still has some small known bugs, unfinished features, and missing polish. I might accidentally break it at any time as I continue working on it because I barely understand git or version control and am flying by the seat of my pants here.

#### ReAnimationV2 IS NOW A HARD REQUIREMENT
[Get it here](https://www.nexusmods.com/morrowind/mods/52596?tab=files) and thank MaxYari for making all of this possible. No, really. Not only did he make the original mod this fork is based on, the biggest thing this mod fixes (fake sneaking visuals) was only possible thanks to another mod of his.

## FORK CHANGES AND FEATURES

#### SNEAK WHILE DETECTED

  I figured out how to fake sneaking visually, meaning you can now sneak while detected with this fork like you would normally expect to be able to. The mod still fundamentaly works using the same trick as the original: you are always undetected while sneaking, and the mod's own detection logic decides when to kick you out of sneaking so other actors can detect you. But now, you still *look* like you are sneaking any time you are attempting to sneak, even while detected and technically stil kicked out of (real) sneaking.

#### DEDICATED SNEAK KEY

  Sneaking while detected requires removing your binding for sneak in the OpenMW's control options, then binding the key in this mod's script settings page.

#### COMBINED DETECTION METER

  Instead of a marker floating over every NPC's head, you can have one meter on screen. You can move it, change its opacity, or switch back to the old per-NPC markers in the settings. **COMING SOON** - Seamless vanilla style HUD sneak icon integration option. 

#### Organic cooldown being detected

  Normal sneak detection logic now runs after being detected and kicked out of sneak, allowing for an organic cooldown. The penalty for being detected is that the detection has to fully cooldown before sneaking again. The original behavior kept detection locked at fully detected until you broke line of sight, and NPCs could see an infinite distance in all directions after detecting you.

#### Configurable sneak-attack damage

  A base Critical Strike damage multiplier that always applies, plus per weapon type bonuses that scale with your Sneak skill and stack on top of the base sneak multiplier. Short blades can be better at sneak attacks than warhammers.
  
#### Marksman Critical Strike Fix

  The old bug where marksman only got a 1.5x multiplier instead of 4x with no Critical Strike! message has been fixed. It's now treated the same as any other weapon on sneak attacks.

#### Kock someone out

  Hand to hand sneak attacks have their fatigue damage multiplied. I'm not here to fix hand to hand, but it hasnt been left out.

#### New "Critical Strike!" message

  Vanilla style Critical Strike message now works for all weapon types and confirms the final damage multiplier applied.

---

## FEATURES FROM ORIGINAL MOD

- Gradual visual detection progress instead of instant detection.

- Weapon skill is boosted by 50% while in sneak stance.

- Slight increase of sneak speed (it's 90% of the walk speed now). Due to how sneak animations and footstep sounds work it *might* feel like sneaking is faster than walking now - it is not, footstep sounds are just more frequent in sneaking stance.

- Contrary to vanilla boots don't affect your sneak chances. All in all your equipment has no effect on your sneak.

- Mod works by kicking you out of a sneaking stance when you are detected, so the engine can take over the NPC agression/attack logic, so dont be surprised when you are suddenly forced out of a sneaking stance - this is intended.

---

## GMST CHANGE NOTES

- **fCombatKODamageMult** (Modified from vanilla by fork)

  `1.5` -> `1`

  In vanilla Morrowind, there has always been an engine bug where marksman sneak attacks used fCombatKODamageMult(1.5) instead of fCombatCrticalStrikeMult(4.0) - and because the damage was routed incorrectly, it also never produced the standard `Critical Strike!` confirmation message either. To fix this bug and reliably control marksman sneak attack damage without modifying the engine, I set this to 1.0. Then, I approximately reproduced the logic used to apply the normal 1.5x damage bonus on knockout so that setting this to 1.0 doesnt break anything. It's 100% accurate on actors that use the standard player/NPC skeleton. It might not be always be 100% accurate on other creatures in very niche scenarios, but unlike the bug it fixes you would likely never even notice this. Still, I plan on doing a deep dive into how the engine handles this to make it more accurate in the future.

- **fCombatCrticalStrikeMult** (Modified from vanilla by fork)

  `4.0` -> `1`

  This was done to give the mod control over sneak damage. This is why we can set base multipliers lower than 4.0, then add onto that multiplier per weapon type. It always annoyed me that stealth characters had zero reason to use short blades beyond RP. Now you can the maximum shortblade damage multiplier as high as 20.

- **fSneakSpeedMultiplier** (Modified from original mod by fork)

   `0.75` (Vanilla) -> `0.9` (Sneak Is Good Now) -> `1` (Sneak Is Gooder Now)

- **i1stPersonSneakDelta** (Modified from vanilla by fork)
  
  `0.1` -> `0`

  These control camera height and movement speed while sneaking. These were changed to effectivley do nothing so I could take full control over real sneaking movement speed and height the same way I do for fake sneaking so that they both match. In third person this is accomplished by an animation trick I stumbled upon by pure luck. It turns out third person movement is actually driven by the walking/running animation speed, so by applying a multiplier here I can control speed in third person without touching the speed or athletic stats like most mods do. In first person I simply modify player scale, as this lowers the camera and speed together, which is exactly what I want. This slightly reduces your reach in first person, but vanilla weapon reach is generally completely insane, and getting close for a melee sneak attack makes perfect sense anyway. You likely will never notice a 10% reach reduction here, and I'd argue the trade off is more than worth it. The only hypothetical problem this could potentially cause is if you somehow found some spot in the game you could only fit into at the reduced scale, then exited sneak or exited first person. That should be unlikely since scale already varies between races and sexes, so so please don't go out of your way to get stuck then complain to me about it. 

- **sTargetCrticialStrike** (Modified from vanilla by fork)
  
  `Critical Strike!` -> `""`

  This was blanked out to supress the vanila `Critical Strike!` message so I could replace it with one that confirms your actual final damage multiplier. This also reads the GMSTs for `fCombatKODamageMult` and `fCombatCrticalStrikeMult`, just in case some other mod modifies them so the message always remains accurate. 
