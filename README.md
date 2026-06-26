## What this fork changes (SneakIsGooderNow)

This is a fork of MaxYari's original **Sneak!** still under heavy development. Not quite in a fully
playable, ship ready state at this time

All new changes and features:

- **Dedicated sneak key** eliminates animation jitter you would see when attemtping to enter sneak
  while kicked ou of sneak.

- **A single, repositionable detection meter.** Instead of a marker floating over every NPC's head,
  you can have one meter on screen. You can move it, change its opacity, or switch back to the old
  per-NPC markers in the settings.

- **Organic cooldown being detected** Normal sneak detection logic now runs after being detected and
  kicked out of sneak, allowing for an organic cooldown. The penalty for being detected is that the
  detection has to fully cooldown before sneaking again. The original behavior kept detection locked
  at fully detected until you broke line of sight, and NPCs could see an infinite distance in all 
  directions after detecting you.

- **Configurable sneak-attack damage.** A base Critical Strike damage multiplier that always applies,
  plus per weapon type bonuses that scale with your Sneak skill and stack on top of the base sneak 
  multiplier. Short blades can be better at sneak attacks than warhammers.
  
- **Marksman Critical Strike Fix.**
  The old bug where marksman only got a 1.5x multiplier instead of 4x with no Critical Strike! message
  has been fixed. It's now treated the same as any other weapon on sneak attacks.

- **Kock someone out.**
  Hand to hand sneak attacks have their fatigue damage multiplied. I'm not here to fix hand to hand,
  but it hasnt been left out.

- **New "Critical Strike!" message** Vanilla style Critical Strike message now works for all weapon
  types and confirms the final damage multiplier applied.

- **Coming soon** I figured out how to fake sneaking visually, meaning soon you'll be able to sneak
  while detected like the vanilla behavior in all other TES titles. Animation work is complete, real
  and fake sneak are visually 100% identical, transitioning between the two is 100% seamless. Not yet
  incorproated into gameplay, but you can assign a key in the settings to test it out. 
  
---

Features (original):

- Gradual visual detection progress instead of instant detection.

- Weapon skill is boosted by 50% while in sneak stance.

- Slight increase of sneak speed (it's 90% of the walk speed now). Due to how sneak animations and footstep sounds work it *might* feel like sneaking is faster than walking now - it is not, footstep sounds are just more frequent in sneaking stance.

- Contrary to vanilla boots don't affect your sneak chances. All in all your equipment has no effect on your sneak.

- Mod works by kicking you out of a sneaking stance when you are detected, so the engine can take over the NPC agression/attack logic, so dont be surprised when you are suddenly forced out of a sneaking stance - this is intended.