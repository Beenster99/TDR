# Demolition Derby

A second race type next to circuit racing (Race type on the race setup
page: Circuit racing / Demolition Derby). Old road cars on short arenas
that cross themselves, with jumps and dirt, and a damage model that shows
every hit.

## The rules (`RaceSettings.apply_derby_rules`)

- Only the 20 Derby cars race (class "Derby", `discipline: "derby"`), on the
  5 derby arenas. Circuit cars and tracks never appear in a derby, and derby
  cars never appear in circuit races, seasons or multi-class grids.
- Damage is always full. There is no safety car, VSC, yellow flags,
  penalties or marshals, no recovery trucks (wrecks stay where they stop and
  become part of the arena), no pit stops or repairs, fuel or tyre wear. The
  pit wall screen and its HUD hint are off.
- No co-op: one driver per car, the co-op car shares are hidden in the
  lobby. Normal online multiplayer works as usual.
- You drive the wreck until it won't drive any more. A car is out when its
  engine fails, or when it hasn't moved for `RaceSim.DERBY_STILL_OUT_S`
  (15 s; reason "stopped"). Once its bodywork adds up to
  `CarDamage.WRECKED_BODY` (3.0 of 4) the engine boils dry at
  `CarDamage.WRECK_BOIL_RATE` (about a minute of driving) and then dies.
- Up to 16 cars (`RaceSettings.MAX_CARS_DERBY`), two abreast in tight rows
  on the grid (`TrackData.DERBY_ROW_M`, 7.5 m).
- First to finish the laps wins, unless everyone else is out first: the
  last car still running wins (`last_car_standing` event).

## The arenas (`modules/tracks/tools/build_derby_tracks.py`)

| Arena | Length | Crossovers | Jumps | Dirt |
|---|---|---|---|---|
| Rustbelt Figure Eight | 336 m | 1 | 1 | 28% |
| Scrapyard Knot | 408 m | 3 | 2 | 59% |
| Harbour Bowtie | 458 m | 1 | 1 | 22% |
| Quarry Pretzel | 568 m | 2 | 3 | 27% |
| Mudflat Infinity | 398 m | 1 | 2 | 69% |

The arenas are small and 11-12 m wide so the field keeps running into
itself.

Crossovers are flat: both roads meet at the same height, so cars T-bone
each other there. `TrackData.crossovers` lists them; the second pass is drawn
a touch higher so the two roads don't flicker. Jumps are table-tops baked
into the heights (up ramp, flat top, landing ramp), kept clear of the
crossovers and the grid, and kept off the dirt (packed hard, so a car that
stalls on one can still drive up it). The ramps are painted to read from
above (`TrackView._build_jump_markings`): yellow chevrons up the take-off
ramp, a yellow and black hazard stripe on the lip, white chevrons down the
landing. No braking boards in the arenas.

Dirt (`TrackData.dirt_at`, shared with rallycross) grips less (the tyre's
`dirt_grip`) and on derby cars the rear loses much more than the front
(`chassis.dirt_rear_grip`: 0.6 rear-drive, 0.68 four-wheel drive, 0.74
front-drive), so they slide their tails out on the dirt.

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
