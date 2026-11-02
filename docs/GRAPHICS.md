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
- `CarView` is one car: its model, livery, wheels, lights and spray.
- `WeatherView` puts rain on the screen; light, wet roads and spray are 3D.
- `GfxSettings` holds the switches: camera lens and tilt, shadows, elevation
  cues, tree density and so on.

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
- Preview pictures: `blender -b --python modules/graphics/tools/preview_cars.py -- <out_dir> [car_id ...]`.

Each model is split into parts so upgrades and damage can swap or move them:
`body`, `bumper_front`, `bumper_rear`, `cabin`, `splitter`, `diffuser`,
`wing_rear`, `mirror_l`, `mirror_r`, `interior`, and `wheel_fl/fr/rl/rr`
(each with a spinning `_spin` part and a fixed `_caliper`). Materials are
found by name: `paint` is the livery; others include `carbon`, `glass`,
`light_head`, `light_tail`, `tyre`, `rim` and `caliper`.

Liveries: the paint shader draws a pattern (solid, stripes, split, sash,
chevron, M stripes, two-tone) in three colours from the car's position, so it
lines up across every part. Each model also has a livery UV unwrap (UV0: nose
to tail, and round the body from sill to sill), ready for painted livery
textures later.

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

## Performance

At the whole-track zoom the full scene is still drawn. Trees are MultiMeshes
in 256 m tiles with automatic LODs, car parts that are too small to see
(mirrors, interior, calipers) hide beyond `GfxSettings.car_detail_distance`,
and shadows cover just what's on screen.
