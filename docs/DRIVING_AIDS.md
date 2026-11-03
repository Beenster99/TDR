# Driving aids

The feel target: difficult, but not a sim. A bit closer to arcade, still not
very forgiving. Every aid is the player's own choice in Settings > Gameplay
(kept in `GameData.prefs`, read by the race scene when the race starts and
when a co-op driver takes the wheel). AI cars never use them.

| Setting (prefs key) | Values | What it does |
|---|---|---|
| Driving help (`driving_help`) | 2 full, 1 traction + ABS, 0 off | Traction control, ABS and the stability assist (catches slides, counter-steer, keeps the front tyres near their best slip angle). |
| Braking zones (`aid_braking_zones`) | on (default) / off | Colours the driving line: green = your speed is fine, yellow = lift, get ready, red = brake now. With the racing line off, only the braking zones show. |
| Driving line (`aid_driving_line`) | 2 full (default), 1 corners only, 0 off | Full: the driving line along the whole lap ahead (320 m), soft at the edges. Corners only: just from the braking zone through each corner to its exit, hidden on the straights (a red "brake now" still shows wherever you are too fast). Replaces the old on/off `aid_racing_line`; a saved "off" loads as Off. |
| Track assist (`aid_track_assist`) | 0 off, 1 light (default), 2 strong | With no steering input it cancels part of any yaw, so the car runs straight; near the edge (2.5 m light, 3.5 m strong) and heading off, it steers gently back. It never adds more than 3 degrees (light) / 5 degrees (strong) of steering, so a bad line or a slide still costs you. |
| Manual gears (`manual_gears`) | off (default) / on | Shift Up: Shift or `.`, pad B. Shift Down: Ctrl or `,`, pad X. One gear per press; a downshift that would over-rev is refused. With manual gears on, the pad's X stops working as the brake (the trigger does that). Pad A is the handbrake; next tyres moved from B to D-pad up. |

## How the braking line works

`DrivingLine` (physics) builds the racing line every 4 m for the player's car
and its tyres, with two speed profiles:

- `speed`: the brake envelope, the fastest the car can be going at each point
  and still make every corner ahead (92% of the grip in corners, 82% under
  braking, so a player who brakes when the line turns red makes the corner).
- `lap_speed`: a full-power lap, used to find the real braking zones (`zones`,
  each one at least 22 km/h of slowing).

`DrivingLineView` (graphics) draws a 2 m band along the line ahead of the car.
Its shader compares the car's speed with `speed` at each point: below 90% it's
green, 90-97% turns yellow, from 99% it turns red.

Corners only uses `DrivingLine.corner` (0..1 per point): each braking zone
from 30 m before the brakes go on, past the apex while the line is still
turning (tighter than 250 m radius, at most 250 m) and 20 m on; plus any bend
tighter than 125 m radius taken flat out. The edges fade over 16 m. On most
circuits that is about half the lap (35% at Monza, 72% at the Hungaroring).

## Brake marker boards

`BrakeBoards` (graphics) puts numbered boards before every braking zone on the
outside of the corner: 300 / 200 / 100 before corners entered above 200 km/h,
150 / 100 / 50 before slower ones (the distance to the slowest point of the
corner, in metres). Boards that wouldn't fit on the straight are left out.
They're scenery only: nothing in the race sim knows about them, so they can't
be hit, knocked down or damaged. The numbers face the camera.

## Steering

Steering lock falls with speed (`LocalInput.steer_lock`: full lock up to
about 29 km/h, 67% at 54 km/h, 50% at 80 km/h, 18% at 250 km/h, never below
14%), so a full stick or a held key turns the car about as hard at 250 km/h as
at 80, while hairpins, the pit lane and turning round after a spin get most
or all of the lock. Keyboard steering
winds on more slowly at speed (`LocalInput.key_steer`), so a tap is a small
correction.

## Testing

- `tests/run_tests.gd`: `test_driving_aids` (zones, track assist strength,
  manual gearbox, snapshots) and `test_race_start` (every AI car gets away).
- `tests/track_assist_probe.gd -- [track] [car] [laps]`: a clumsy pad player
  (0.18 s reaction) laps with the track assist off / light / strong and
  reports time off the track (`TDR_KEYS=1` for a keyboard player).
- `tests/start_probe.gd -- [ai] [track] [human]`: speeds and stops of every
  car over the first 20 s of a race.
