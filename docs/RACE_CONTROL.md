# Race control: flags, VSC, safety car, penalties

`RaceControl` (modules/race/race_control.gd) is part of the pure race sim. Only
the host (or offline game) decides anything; clients get the state with the
race state and just move the safety car along between updates.

## What triggers what

| Situation | Result |
|---|---|
| Contact between cars (rubbing, a tap, a bump: `collision` events, or a car-to-car `incident` under severity 0.6) | Nothing: it's racing. From severity 0.35 it leaves debris for the marshals (below) |
| A heavy crash between cars (car-to-car `incident` severity >= 0.6), a car into the barrier or an engine failure (severity >= 0.25) | Local yellow flag over that part of the track (about 120 m before to 60 m after), held 12 s after the hazard is gone |
| A car spun (under 25 m/s and facing more than ~105 degrees away from the track direction, or still rotating fast) or crawling off the track (under 12 m/s on grass or gravel) for 0.75 s | Local yellow at the car |
| Puncture or gearbox failure | Nothing until the car stops (then the stopped-car rule) |
| Car stopped (< 3 m/s) for 2 s | Local yellow at the car |
| Car stopped on the racing surface for 6 s, a retired car stopped for 6 s, or two cars stopped | Virtual safety car (VSC) |
| Car stopped on the racing surface for 16 s, three or more stopped cars, or a crash with severity >= 0.85 and a stopped car | Safety car (SC) |
| An AI car stuck off the racing surface for 15 s (stopped, or crawling under 8 m/s in the gravel, on the grass or against the barrier), or stopped on it for 20 s, without getting 30 m further along the track | It retires (`retired` event, reason `stuck`) and is fetched like any retired car (next row). Cars driven by people are left to get themselves out |
| Retired car stopped on the circuit for 6 s | A recovery vehicle: a crane if the car is in the wall, a tractor anywhere else (see below), under the safety car ("Recovery vehicle on track") when the car is on the racing surface, or a VSC with the same reason when it is off it |
| A live car (a person's) stopped for the recovery time (VSC 25 s, SC 40 s, plus 6 s) | Marshals push it clear: yellow flag only from then on |

No new SC is sent out on the leader's final lap. The host's "Safety car" setting
(`RaceSettings.race_control_mode()`): "On" (yellows, VSC and SC), "Yellow flags
only" (`safety_car_enabled = false`: no VSC or SC) or "Off" (`flags_enabled = false`
too: no yellow or double yellow flags either; marshals still clear debris in the
gaps and recovery vehicles still fetch retired cars, with no flags or penalties).

## Marshals clearing debris (double yellows)

`TrackMarshals` (modules/race/track_marshals.gd). Every barrier hit or engine failure
(severity >= 0.25) and every car-to-car hit from severity 0.35 leaves debris where it happened; debris within 60 m piles up (`RaceControl.debris`).
When a pile reaches 1.4 (summed severity, e.g. two or three decent crashes in one
place), a crew of 4 marshals goes to the barrier there (`RaceControl.marshal_jobs`).

- They only go on the track when it is safe: they wait behind the barrier until the
  next car (`time_to_traffic(s)`: seconds until it arrives; stopped, retired and
  pitting cars don't count) is far enough away to run out, sweep at least 4 s and be
  back off 1.5 s before it arrives. They run off early if a car comes sooner, then
  wait for the next gap. The sweeping adds up over the gaps until 16 s in all.
  Same on circuits and in rallycross (`marshal_clear_s`).

- On circuits, double yellow flags from 220 m before the marshals to 80 m after,
  from when the crew is sent until it is back behind the barrier for good (gaps or not): no overtaking, and slow right down. The limit is the VSC reference speed x 1.2
  (`double_yellow_limit(s)`, shown on the HUD); passing the marshals more than 10 %
  over it is a 5 s penalty. The AI drives 8 % under it.
- `double_yellow_at(s)`; `yellow_at(s)` is also true there; `neutralisation()` is
  "yellow". Events: `flag` `double_yellow`, then `clear`.
- Drawing: `marshal_views()` gives `{pos, heading, action ("run"/"sweep"/"wave"), t}`
  per marshal; `WorldView.set_marshals` draws them (orange overalls, brooms) and
  clears the debris bits where they sweep.
- Screenshots: `tests/fx_race_shot.tscn -- out.png marshals spa <secs after sent>`.

## Recovery vehicles

`CarRecovery` (modules/race/car_recovery.gd) plans and moves them; `RaceControl.recoveries`
holds one job per retired car out on the circuit. Pure data, in the snapshot and the race
state, so clients see the same thing.

- **Crane** (car within about 4.5 m of the barrier): a crane truck drives up the service
  road behind the barrier, swings its boom over the car, lifts it 4.2 m clear of the
  barrier, swings it onto its flatbed, lowers it and drives off. About 50 s.
- **Tractor** (car on the track, in the gravel or on the grass): comes in through a
  marshals' gate in the barrier, along the run-off, pulls up in front of the car, hooks
  a strap on and tows it out through the next gate. About 35 s.
- The car is out of the physics from the moment it is lifted or hooked
  (`RaceControl.out_of_play`), and hidden once the vehicle has gone (`recovered`).
- A retired AI car is parked (`RaceControl.parked_input`: brakes, then the handbrake
  once stopped) so it comes to rest where the vehicle will find it. Before, the AI kept
  driving it and a stuck car crept about and was never fetched.
- The safety car (or the VSC, for a car off the racing surface) stays out until the car is clear of the circuit (over the wall, or out
  of the gate), then goes through its normal procedure. With the safety car off, the
  vehicles still come, under yellow flags. No new safety car on the final lap.
- Events: `flag` `recovery` (vehicle sent, with `kind`) and `recovered`.
- Drawing: `RaceControl.recovery_vehicles()` gives `{car, kind, pos, heading, speed,
  reach, hook, hoist, phase, towing, car_pos, car_heading}` per vehicle;
  `WorldView.set_recovery_vehicles` draws them and the race scene sets the lifted car's
  `CarView.hoist`.
- Screenshots: `tests/fx_race_shot.tscn -- out.png crane|tractor spa <secs after sent> --autodrive`.

## VSC

Everyone keeps above a reference pace (about 60 % of race pace, from the
track's corners). The HUD shows the delta: positive is fine. Below -0.5 s
gives a warning, below -2 s a 5 s penalty. After at least 20 s with the track
clear: "VSC ending", then green 6 s later.

## Safety car

1. The SC (Mercedes-AMG GT Black Series, amber lights) comes out of the pit
   exit if it's just ahead of the leader, otherwise about 160 m ahead of the
   leader. It waits for the leader, then laps with the leader about 25 m
   behind. It drives the same racing line as the AI (the track's line,
   pulled in from the edges the same way), quick through the corners (about
   1 g) but held to 137 km/h on the straights, easing in from the pit exit
   and over to the pit entry. `sc_d` is its distance along that line;
   `sc_s` (track distance) follows from it.
2. Cars close up to the queue at race pace, then follow. No overtaking.
3. Once the track is clear and the leader has done a lap behind the SC,
   "lapped cars may overtake": they pass the queue and the SC and go round
   to the back. The queue makes room.
4. "Safety car in this lap" (green lights) when the field is bunched and the
   unlapping is done (or after 2-4 laps). The SC leaves at the pit entry and
   drives down the pit lane.
5. Restart: the leader controls the pace and goes when they like (the AI goes
   200-300 m before the line). Green flag when the leader crosses the line;
   every other car may overtake once it crosses the line itself.

## Penalties

Overtaking under yellow flags, the VSC or the SC, before the restart line, or
passing the safety car: a warning to give the place back within 12 s, then a
5 s time penalty. While the order stands, the car to let past (or the safety
car) is picked out on track with a pulsing orange-red outline and a "LET PAST"
tag, its timing tower row turns orange, the race control box names it with
how far ahead or behind it is, and an arrow on the screen edge points to it
when it's out of view (`RaceControl.give_back_target(i)`; all of it clears
the moment the place is given back). Passing a stopped, crawling or off-track car, a car in the
pit lane, or (when waved by) as a lapped car is allowed.

Only clear gains count (so the player isn't told to give places back for
racing incidents):
- A pass counts once the passer is more than `PASS_MARGIN_M` (6 m, over a car
  length) ahead; side by side or nose to tail in a queue is not an overtake.
- A car in trouble may always be passed: off the circuit, spun, stopped,
  causing a yellow, or any of those in the last `TROUBLE_GRACE_S` (6 s), or
  going under `SLOW_CAR_FRAC` (70 %) of the passer's speed
  (`RaceControl.in_trouble(j)`).
- A move started under green stands: if the passer was within `ALONGSIDE_M`
  (8 m) of the car a moment before (a picture of the field taken every 0.5 s)
  and both were racing under green, a yellow / VSC / SC that comes out
  mid-move doesn't count it.
- An order is dropped with no further action if the victim loses the place by
  itself (goes off, spins, stops or pits) before it's given back.
- Once given back, the victim counts as ahead again straight away, so the two
  cars don't trade "overtakes" while they're still close.
- Test: `TDR_ONLY=test_give_back_clear_gains`; probe:
  `tests/give_back_probe.gd` (one car ignores yellows, prints every order). Pit-lane penalties
from the fuel/pit stop rules use the same `RaceSim.add_penalty(car, s, reason)`.
Penalties go in `RaceEntry.penalty_s` and are added to the race time in the
classification (laps first, then time + penalties).

## For other modules

- `RaceSim.safety_car_active()`, `neutralisation()` ("green", "yellow", "vsc",
  "sc"), `pit_time_saving()` (about 0.55 under the SC, 0.3 under the VSC: AI
  pit strategy and the pit-window analysis use it for cheap stops).
- Events in `sim.events`: `flag` (yellow, clear, recovery, recovered), `safety_car`
  (vsc, vsc_ending, sc, lapped_may_overtake, in_this_lap, restart, green),
  `warning`, `penalty`. The pit wall feed shows them as race control.
- Drawing the safety car: `sim.race_control.sc_visible`, `sc_pos`,
  `sc_heading`, `sc_speed`, `sc_lights` ("off", "amber", "green").
- Tuning aid: `tests/sc_report.gd` runs a race, stops a car and prints what
  race control does.
