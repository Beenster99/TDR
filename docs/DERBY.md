# Demolition Derby

A second race type next to circuit racing (Race type on the race setup
page: Circuit racing / Demolition Derby). Old road cars on short arenas
that cross themselves, with jumps and dirt, and a damage model that shows
every hit.

## The rules (`RaceSettings.apply_derby_rules`)

- Only the 20 Derby cars race (class "Derby", `discipline: "derby"`), on the
  5 derby arenas. Circuit cars and tracks never appear in a derby, and derby
  cars never appear in circuit races, seasons or multi-class grids.
- Damage is always full. There is no safety car, no yellow flags or
  penalties, no recovery trucks (wrecks stay where they stop and become part
  of the arena), no pit stops, fuel or tyre wear.
- No co-op: one driver per car, the co-op car shares are hidden in the
  lobby. Normal online multiplayer works as usual.
- A car is out when its engine fails or its bodywork adds up to
  `CarDamage.WRECKED_BODY` (3.0 of 4: all four sides badly bent).
- First to finish the laps wins, unless everyone else is out first: the
  last car still running wins (`last_car_standing` event).

## The arenas (`modules/tracks/tools/build_derby_tracks.py`)

| Arena | Length | Crossovers | Jumps | Dirt |
|---|---|---|---|---|
| Rustbelt Figure Eight | 652 m | 1 | 1 | 37% |
| Scrapyard Knot | 1072 m | 3 | 2 | 72% |
| Harbour Bowtie | 974 m | 1 | 1 | 22% |
| Quarry Pretzel | 1504 m | 2 | 3 | 32% |
| Mudflat Infinity | 1052 m | 1 | 2 | 85% |

Crossovers are flat: both roads meet at the same height, so cars T-bone
each other there. `TrackData.crossovers` lists them; the second pass is drawn
a touch higher so the two roads don't flicker. Jumps are table-tops baked
into the heights (up ramp, flat top, landing ramp), kept clear of the
crossovers and the grid. Dirt stretches (`TrackData.dirt_at`) grip 28% less
and drag a little more.

## Jumps and flying (`CarPhysics`)

On a track with jumps the car leaves the ground when the road drops away
faster than it falls (`CarState.air_h`, `vz`). In the air there's no tyre
grip; it lands where gravity puts it. Landings faster than 5 m/s down hurt
the suspension and alignment. `air_h` and `vz` are in the network state and
snapshots (`Net.PROTOCOL_VERSION` 18).

## The cars (`modules/cars/tools/build_derby_cars.py`)

Twenty made-up old road cars: saloons, estates, a limousine, a hearse,
muscle cars and coupes, hatchbacks, a minivan, a kei van, pickups, a ute, a
panel van, 4x4s, a taxi and a bubble car. `toughness` (1.1 for the bubble
car to 2.1 for the limousine) divides the damage every hit does. Their 3D
models come from `modules/graphics/tools/derby_shapes.py` (shape per
`body_style`) and `build_cars.py` (Blender), with a separate windscreen,
bonnet and boot lid.

## What the damage looks like (`CarView`, graphics)

- Bodywork crumples where it was hit: the paint, lights, grilles and glass
  all bend together in the vertex shader (`shaders/car_deform.gdshaderinc`),
  the roof sags after a pile of hits.
- The windscreen cracks from the hit point, then shatters (and throws glass).
- The bonnet and boot lid spring open on their hinges, then tear off and
  stay on the track for the rest of the race, with the bumpers, mirrors and
  shards (`Debris.lie_s`).
- A smashed nose steams (radiator), a hurt engine smokes from the bay, and
  a dying engine catches fire (flames, flickering light, soot).
- On dirt the cars throw up dust (dry) or mud (wet) and clods, lay earth
  ruts instead of rubber, and get dirtier as the race goes on.

Screenshots: `tests/derby_shot.tscn` (race, wrecks, jump, dirt).
