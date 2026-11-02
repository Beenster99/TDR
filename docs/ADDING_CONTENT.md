# Adding cars and tracks

## A car

1. Copy a car in `modules/cars/data/` that is close to the new one (a GT3
   racer or a road car) to `<new_id>.json`. The id is the file's `id` field;
   keep it stable once released, because saves and lobbies refer to it.
2. Set `name` (shown in game), `description`, `class_tag` (the car class:
   `GT3`, `Road`, or a new one; a new class appears in the lobby's Class list
   by itself), `colour`, and the specs: mass, weight split, dimensions,
   torque curve, gears, brakes, aero, tyre compound (`race_slick` for race
   cars, `road_semi_slick` for road cars), fuel.
3. Gearing: pick `final_drive` so top gear reaches the redline just above the
   car's real top speed: `final_drive = redline_rpm * 2π / 60 / (v_max_m_s * 1.03 / wheel_radius_m) / top_gear_ratio`.
4. Run the tests (below). `tests/debug_ai.gd` prints AI lap times for every
   car on one track, handy for checking the new car sits where it should
   against its class.

## A track

Tracks are built, not hand-written, by `modules/tracks/tools/build_tracks.py`.

1. Add an entry to `modules/tracks/tools/tracks.json`:
   - `id`, `name` (shown in game), `short_name`, `location`, `country`,
     `real_length_m` (to check the result), `environment` (default air and
     track temperature) and `climate` (day/night air temperature, chance of
     rain).
   - `tumftm`: the track's name in the
     [TUMFTM racetrack-database](https://github.com/TUMFTM/racetrack-database/tree/master/tracks)
     if it's there, else `null`.
   - `osm_query`: what to search OpenStreetMap for to find the circuit (or
     `osm_center: [lat, lon]`).
   - Only for tracks not in TUMFTM: `width_m` (track width), and
     `osm_exclude_names` for loops that aren't part of the layout (short
     circuits, bypasses).
   - Optional: `pit_ways` (OpenStreetMap way ids of the pit lane, if the
     tool picks the wrong road), `pit_speed_kph` (default 60), `pit_boxes`
     (default 30), `reverse` (OpenStreetMap-only tracks raced the other way).
2. Run `python3 modules/tracks/tools/build_tracks.py <id>` (needs numpy and
   internet). It prints how well OpenStreetMap lined up with the layout, the
   race direction check, the length against the real length, and where the
   pit lane is. Downloads are cached in `~/.cache/tdr-tracks`.
3. Run the tests. The "tracks" test checks every track loads, has a pit lane
   that starts and ends on the track, and that an AI car laps it cleanly.
4. Add the source to `modules/tracks/data/ATTRIBUTION.md` if it's a new one.

Elevation is added by the same run: `tools/elevation.py` reads heights from
the free Terrarium elevation tiles (AWS Open Data) for the centre line, the
pit lane and a 20 m terrain grid around the circuit, and smooths them. To
redo just the elevation without downloading OpenStreetMap again, run
`python3 modules/tracks/tools/elevation.py <id>` (the track file needs the
`geo` block that `build_tracks.py` writes). Real banking that the elevation
data is too coarse to see goes in the track's `tracks.json` entry as
`"banking": [{"from_m": 1200, "to_m": 1350, "deg": 18}]` (distance from the
start/finish line in race direction; positive degrees lower the right side
of the track, which banks a right-hand corner).

The racing line comes from `tools/raceline.py` (also run by `build_tracks.py`,
about two minutes a track): the fastest line for a GT3 car on slicks, found by
moving the line sideways until the lap time stops dropping. It uses the track
up to 1 m from the edge, or 0.3 m where there are kerbs (corners), so the
wheels ride the kerbs at apexes and exits. Late apexes before straights and
compromises through corner sequences come out of the lap time, not by hand.
To redo the lines of existing tracks without rebuilding them, run
`python3 modules/tracks/tools/raceline.py [ids]` (needs numpy and a C
compiler); `--check` prints the old and new model lap times without writing.
`tests/line_shot.tscn` takes screenshots of the driving line through the
slowest corners to check it by eye.

Barriers and run-off come from `tools/barriers.py` (also run by
`build_tracks.py`, or on its own from the cached OpenStreetMap downloads):
for each point and side, the barrier at the edge of the run-off (concrete
wall, tyre wall, armco, catch fencing) and the run-off surface (grass,
gravel trap, paved). OpenStreetMap barriers (`barrier=wall`, `guard_rail`,
`tyres`, `fence`, `jersey_barrier`) and gravel or sand areas next to the
track are used where mapped; defaults fill the rest. In `tracks.json`,
`"runoff_style": "gravel" | "paved" | "grass"` sets the default run-off on
the outside of corners, and `"street": true` puts walls all round.

## A rallycross track

Rallycross venues come from OpenStreetMap too, through
`modules/tracks/tools/build_rx_tracks.py` and its list `tools/rx_tracks.json`
(centre point, search radius, name, description, climate). The builder takes
the venue's raceway ways (only `sport=rallycross` ones where they are
tagged), cuts them where they meet, finds the longest closed one-way loop for
the lap and the way named "Joker" (or `joker_ways`) for the joker lane. Way
`surface` tags give the dirt stretches (`dirt_override` fixes them by hand,
as fractions of the lap); the start is `start_way`, a `raceway=start` way or
the longest straight tarmac. Run-off is grass. Afterwards run
`tools/raceline.py <id>` for the racing line. Track JSON gets
`"discipline": "rallycross"`, `"dirt"` and `"joker"`, and no pit lane.
`tests/rx_probe.gd` races six AI on each rallycross track and prints lap
times, jokers taken and offs.

A rallycross car is a normal car file with `"discipline": "rallycross"`,
class `RX1` and the `rx_tyre`.

## Tests

```
godot --headless --path . --script res://tests/run_tests.gd
```
Use Godot 4.6.2.
