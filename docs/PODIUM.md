# The podium

Finish a race in the top three and, before the results, you go up on the
podium. Qualifying has no podium. In Demolition Derby the top three by the
final order go up, wrecked or not. Settings > Gameplay > Podium celebration
turns it off.

## What happens

1. The race fades to black and the podium comes up: three steps (1 in the
   middle, 2 on the left, 3 on the right), a backdrop with the circuit's
   name, a crowd of mechanics in the three teams' colours behind a barrier,
   and photographers. Ticker tape comes down and the drivers wave.
2. The drivers lift their trophies (gold, silver, bronze).
3. The champagne. Every driver has a bottle. The other two spray on their
   own, at each other, at you (more than anyone) and at the crowd.
4. Once every bottle is empty, or when you skip, it fades to black and the
   results come up as usual.

## The champagne

- **Shake** to build pressure: right mouse button, G, or pad X
  (`crew_grab`), or waggle the stick hard from side to side.
- **Spray**: hold the left mouse button, Space / Enter, or RT / A
  (`crew_gun`). The first spray pops the cork. More pressure sprays
  further and harder; spraying uses it up, so shake again for more.
- **Aim**: the mouse (the stream lands under the pointer, a gold ring shows
  where), or W A S D / the arrows / the left stick.
- A bottle lasts about ten seconds of spraying.
- People hit by the spray flinch and cover up. Someone wet enough counts as
  soaked: the panel bottom left counts how many you've soaked.
- **Skip to the results**: Esc, B or Start, or the Results button. When the
  bottle's empty, Enter / A also goes on.

Online, each player on the podium sees their own ceremony (it isn't sent
over the network); the other drivers' bottles are sprayed by the computer.

## Code

- graphics `PodiumView`: the 3D podium in its own world, the people (jointed
  figures, posed every frame), the bottles, the droplets (moved each frame,
  drawn as one MultiMesh, tested against the people through a small grid)
  and the ticker tape. Purely visual.
- ui `PodiumCeremony`: the SubViewport the podium is drawn in, the fades,
  the timing (intro, trophies, champagne), the controls and the on-screen
  cards, and the sounds (audio `cork_pop`, `champagne_spray`,
  `crowd_cheer`).
- game `race_scene.gd`: `_podium_drivers()` decides if there's a podium,
  `_start_podium()` plays it and then shows the results. The cars' sound
  fades out under it.

Testing: `tests/podium_shot.tscn -- <dir> [slot]` saves screenshots of the
ceremony on its own (the player's bottle plays itself). In a real race,
`--podium` forces a podium whatever the result, `--podium-autoplay` plays the
player's bottle and `--podium-shots DIR` saves pictures, then one of the
results (`--quit-after-shots` quits after). `TDR_ONLY=test_podium` runs the
champagne checks.
