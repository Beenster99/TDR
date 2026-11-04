# Graphics

The game is a 3D racer seen from above. The graphics module (`modules/graphics`)
builds a real 3D world for each race and draws it with Godot's Forward+
renderer: sun and soft shadows, sky lighting and reflections, ambient
occlusion and glow. The camera always shows this full 3D scene at every zoom
(no icons).

## How it fits together

- `WorldView` (Node3D) is the whole world for a race. The race scene keeps its
  camera maths in 2D (centre in metres, zoom in pixels per metre, rotation)
  and calls `world.set_camera(centre, zoom, rotation)`. WorldView turns that
  into a Camera3D looking down (narrow lens, slight tilt; see `GfxSettings`).
- `TrackView` builds the circuit from `TrackData`: terrain, asphalt (rubbered
  racing line, edge lines, wet look), kerbs, tarmac and gravel run-off, walls,
  tyre walls, start line, grid and the pit lane. When `TrackData` has
  elevation, the meshes follow it (`height_at`, `ground_height_at`, ...).
- `Trackside` adds woods, grandstands with crowds, pit garages, the paddock
  and the start gantry. Placement comes from the track's shape and is the
  same every time for the same track.
- `Scenery` replaces the made-up trackside with the real one on tracks that
  have `data/scenery/<id>.json` (every circuit placed on the map, all but Albert Park): every building at its
  real size and height, the named grandstands (seats facing the circuit,
  roofs on the big ones), road and foot bridges, trees and hedges where they
  really stand, and the ground itself modelled under it all (fields with
  crop rows and tramlines, woods, car parks with their bays, roads with edge
  lines and centre dashes, paths, ponds with ripples, sand and the circuit's
  other loops). The ground is geometry, not a picture: build_scenery.py cuts
  every shape along the terrain mesh's own triangles, and the terrain shader
  lays those meshes on the hillside (`drape`) and draws each surface's detail
  from world position, so edges and texture stay sharp at any zoom.
  Settings > Graphics > Trackside switches it off (`GfxSettings.real_scenery`).
  See "Real trackside scenery" below for how the data is made.
- `CarView` is one car: its model, livery, wheels, lights, spray, tyre smoke
  and the bits that come off it in a crash.
- `WeatherView` puts rain on the screen; light, wet roads and spray are 3D.
- `GfxSettings` holds the switches: camera lens and tilt, shadows, elevation
  cues, tree density and so on.

## Effects and the pit lane

- **Tyre smoke and rubber.** `CarView` works out how hard each tyre slides
  from the car's motion (slip angles from velocity, yaw rate and steering, the
  wheelspin flag, lock-ups without ABS), so it works for cars driven on other
  machines too. Sliding tyres smoke (pale on tarmac; brown dust on gravel and
  grass, where any fast car churns some up) and leave marks: dark rubber on
  the road, torn earth on the grass (`SkidMarks`, a ring buffer of 12,000
  short strips). The wet washes both out.
- **Crashes.** New dents throw shards of carbon and painted bodywork from that
  side of the car; a part that breaks away (bumper, splitter, wing, diffuser,
  mirror, at visual damage above 0.85) flies off as a copy, tumbles, bounces
  and lies on the road for about 50 s (`Debris`). Car-to-car contacts and
  barrier hits send sparks (not off tyre walls) via `WorldView.impact`, which
  the race scene calls from the race's `collision` and `barrier_impact` events.
  Debris is only drawn; the race never sees it.
- **Staying visible off the road.** Run-off and gravel traps are drawn at the
  same height a car there is drawn at (the road's edge easing into the
  hillside, as `TrackData.surface_height_at`), and off the road a car is kept
  on top of the grass mesh as drawn (`TrackView.terrain_mesh_height`). On the
  inside of tight corners run-off stops short of the corner's centre, so it
  can't fold over itself.
- **Pit crews** (`PitCrews`). Every garage has people in it: the crew of each
  car in the race in its livery colour, and other teams' mechanics in the
  spare garages, with tyre stacks under blankets, a trolley and a fuel rig,
  and a strategist on a stool at the pit wall. When a car is called in, its
  crew jog to their marks; in the stop the lollipop man waits in front, the
  jack men lift the car, four wheel gunners kneel at the wheels while the
  wheels come off and go back on and two tyre men carry tyres, the fueller
  leans in on the hose for as long as the fuel takes, mechanics work on the
  nose and tail for repairs, and the lollipop turns green to send the car
  away. The race scene passes each car's pit phase and work every frame
  (`WorldView.add_pit_crew`, `fill_pit_lane`, `set_pit_stop`). People hide
  beyond 450 m camera distance and crews off screen stand still.

Screenshots of the effects in a real race: `tests/fx_race_shot.tscn`
(scenarios `pit`, `crash`, `slide`); one car standing at a point of a track:
`tests/fx_shot.tscn`.

## Car models

Every car model is built in Blender from the car's real dimensions:

    blender -b --python modules/graphics/tools/build_cars.py -- [car_id ...]

- Inputs: `modules/cars/data/<id>.json` (length, width, wheelbase, track,
  wheel size, weight split) and `modules/graphics/tools/car_shapes/<id>.json`
  (the car's shape: body cross-sections nose to tail, cabin and glass, wing,
  splitter, diffuser, lights, vents, intakes, default livery).
- Outputs: `modules/graphics/cars/<id>.glb` (what the game loads),
  `modules/graphics/cars_blend/<id>.blend` (open it in Blender) and
  `modules/graphics/data/liveries.json`.
- Preview pictures: `blender -b --python modules/graphics/tools/preview_cars.py -- <out_dir> [car_id ...]`,
  or the cars in the game's own renderer with their stickers:
  `godot --path . res://tests/car_gallery.tscn -- <out.png> [top|three] [class or car ids] [copies]`.
- Only the sticker slots (after changing a shape's cabin, wing or regions):
  `blender -b --python modules/graphics/tools/build_cars.py -- --liveries-only`.

Each model is split into parts so upgrades and damage can swap or move them:
`body`, `bumper_front`, `bumper_rear`, `cabin`, `splitter`, `diffuser`,
`wing_rear`, `mirror_l`, `mirror_r`, `interior`, and `wheel_fl/fr/rl/rr`
(each with a spinning `_spin` part and a fixed `_caliper`). Materials are
found by name: `paint` is the livery; others include `carbon`, `glass`,
`light_head`, `light_tail`, `tyre`, `rim` and `caliper`.

Upgrade parts (wave 4, see docs/BUSINESS.md) are built into every model and
hidden until a car has them: `splitter_up`, `wing_rear_up2`, `wing_rear_up3`
and `canards`. `CarView` shows them from the car's `visual` overrides, and
also recolours calipers and rims, widens tyres and lowers the body.

Liveries: the paint shader draws a pattern (solid, stripes, split, sash,
chevron, M stripes, two-tone) in three colours from the car's position, so it
lines up across every part. Each model also has a livery UV unwrap (UV0: nose
to tail, and round the body from sill to sill), ready for painted livery
textures later.

Sponsor stickers and numbers (race cars only: GT3, LMP2, Hypercar): every
sponsor is invented for the game, no real brands. `tools/build_decals.py`
(plain Python + Pillow) draws 60 sponsor logos and 4 strips of small
"contingency" stickers into `textures/decals.png` (4 x 16 cells; red =
lettering, green = sticker panel, blue = second colour) and lists them in
`data/sponsors.json`; it also draws the race-number digits
(`textures/digits.png`). The builder works out where stickers fit on each
car (`decal_slots` in `data/liveries.json`: bonnet, windscreen banner, rear
deck, rear wing top and end plates, doors, sills, behind the front wheels,
rear haunches, and the door number), keeping clear of vents and lights. The
paint shader projects them onto the body from car space, so they line up
across parts; the rear wing gets the same shader on bare carbon. `CarView`
picks a title sponsor and two more for each car from the livery's
`sponsor_seed` (default: the car and its race number), so every car in a
field has its own set; the title sponsor shows either as its own coloured
sticker or as lettering in the team colours. `"sponsors": false` in a livery
leaves a car clean. `CarView.sponsors` lists the names, title sponsor first.

Prototypes (Hypercar and LMP2) use the same builder with `"prototype": true`
in their shape file: the body sections dip in the middle (`zt` below `ze`)
so the front and rear wings stand up as pods over the wheels; a narrow
canopy; a `fin` (shark fin from the cockpit to the wing); two-element wings
(`wing.flap`), one central swan neck (`wing.mount_count: 1`) or none
(`wing.mount: "none"`), tall end plates (`endplate_h`, `endplate_back`,
`endplate_top`); mirrors out on the front wings (`mirrors.y`); no roll cage
(`"cage": false`); and a smaller roof number board (`number_board`). Any
shape can use `"louvres": n` on a region to cut it into n slats (fender and
bonnet louvres).

The safety car (`modules/cars/special/safety_car_amg_gt_black_series.json`,
a Mercedes-AMG GT Black Series) is built the same way; its shape adds a
`light_bar` (roof bar with amber lenses at the ends and green ones in the
middle, materials `light_bar_amber` / `light_bar_green`). The race scene calls
`WorldView.set_safety_car(visible, pos, heading, speed, lights)` every frame
from `race_control`; the lights flash amber while it is out and green when it
comes in, and "SAFETY CAR" is written on the roof.

To hand-edit a car, open its `.blend`, change it, export the `.glb` (glTF
binary, default settings) over the old one, and set `"hand_edited": true` in
its shape file so the builder leaves it alone. To replace a car with a better
model, export it with the same part and material names and the same car space:
+X forward, +Y left, +Z up in Blender, with the origin on the ground at the
car's centre of gravity.

## Real trackside scenery

`tools/build_scenery.py <track>` makes `data/scenery/<track>.json` from open
data only, so it can ship in the game:

- **OpenStreetMap** (ODbL, credited in the file's `sources`): building
  footprints and names, grandstands, landuse (fields, woods, grass, car
  parks, water, sand), roads, paths, hedges, bridges, single trees.
- **Environment Agency LIDAR** (England, 1 m surface model, Open Government
  Licence), for tracks with `"lidar": "ea_england"` in
  `tools/scenery.json`: the real height of each building and bridge, and
  each tree and hedge found where it stands (the surface minus an estimate of
  the bare ground). Deep inside big woods the estimate fails, so those are
  filled with trees. Without LIDAR, heights come from OpenStreetMap
  (`height`, `building:levels`) or defaults and woods are filled evenly:
  a 7.5 m grid within 250 m of the circuit, bigger trees on a 12 m grid
  further out (keeps forest tracks like Spa near 150,000 trees).
- Satellite imagery (Google Maps and the like) is **not** used: its terms
  forbid copying it. It's fine as a reference when checking a result.

The tool reads the track's `geo` block (written by the tracks module's
`build_tracks.py`) to line map data up with the circuit, covers the whole
terrain square, and drops anything that would stand on the track or pit
lane (where OpenStreetMap and the track disagree by a few metres). The
land cover is stored as ready-made meshes in 320 m tiles (`land`: vertices,
a kind and variant per vertex, indices; see `_doc` in the file), cut for the
terrain grid TrackView builds (10 m cells on hilly tracks, 16 m on flat ones),
so a change to the track's shape or terrain size means rebuilding it.
`--land-only` rebuilds just the land cover and keeps the buildings, bridges
and trees (no LIDAR download); `--preview out.png` draws it flat. Kinds are
listed in `KINDS` in the tool and `K_*` in `shaders/terrain.gdshader` (the
tests check they agree). Needs shapely as well. To add a
track: build the track first, add it to `tools/scenery.json` (with
`"lidar": "ea_england"` for English circuits), run the tool, check a
screenshot (`-- --single --track <id> --zoom 1 --screenshot out.png`).
Needs numpy and Pillow, plus scipy, pyproj and tifffile for LIDAR.
Downloads are cached in `~/.cache/tdr-tracks`.

## Performance

At the whole-track zoom the full scene is still drawn. Trees are MultiMeshes
in 256 m tiles with automatic LODs, car parts that are too small to see
(mirrors, interior, calipers) hide beyond `GfxSettings.car_detail_distance`,
and shadows cover just what's on screen.

- **One shadow map from above.** Seen from above everything on screen is
  about the same distance from the camera, so the sun uses a single
  orthogonal shadow map that just covers the view (`WorldView.set_camera`)
  instead of four cascades, which drew the world into the shadow map up to
  four times. The trackside TV cameras, which look across the ground, still
  use four cascades.
- **The ground in tiles.** The terrain is 24 x 24 cell tiles (240 m with
  elevation), so only the tiles in view and in the sun's shadow view are
  drawn; the shader takes its normals from the heights texture, so they meet
  without seams.
- **No shadows from the little things**: car lights, numbers, calipers,
  canards, splitters, mirrors and interior, and bushes and hedges.
- **Far trees.** Beyond 1200 m camera distance (zoomed well out) every tree
  swaps to a ~20-triangle shape (`Trackside.TREE_FAR_FROM`).

Measured with `tests/render_probe.tscn` (camera over the lap every few hundred
metres, then each part of the world switched off in turn at the costliest
spot) and `tests/perf_probe.tscn` (frame times along a lap with a full grid).
At the usual close zoom triangles drawn per frame fell 3-8x and draw calls
about 40 % at Brands Hatch, Silverstone and Spa; at Spa's whole-track zoom
from 42 million to 5.6 million triangles.
