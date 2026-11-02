# Race control: flags, VSC, safety car, penalties

`RaceControl` (modules/race/race_control.gd) is part of the pure race sim. Only
the host (or offline game) decides anything; clients get the state with the
race state and just move the safety car along between updates.

## What triggers what

| Situation | Result |
|---|---|
| Incident (damage `incident` event, or a big `collision`) with severity >= 0.25 | Local yellow flag over that part of the track (about 120 m before to 60 m after), held 12 s after the hazard is gone |
| Car stopped (< 3 m/s) for 2 s | Local yellow at the car |
| Car stopped on the racing surface for 6 s, a retired car stopped for 6 s, or two cars stopped | Virtual safety car (VSC) |
| Car stopped on the racing surface for 16 s, three or more stopped cars, or a crash with severity >= 0.85 and a stopped car | Safety car (SC) |
| Retired car stopped on the circuit for 6 s | Safety car ("Recovery vehicle on track") and a recovery vehicle: a crane if the car is in the wall, a tractor anywhere else (see below) |
| A live car stopped for the recovery time (VSC 25 s, SC 40 s, plus 6 s) | Marshals push it clear: yellow flag only from then on |

No new SC is sent out on the leader's final lap. With the host setting
"Safety car: Off" (`RaceSettings.safety_car_enabled = false`) there is no VSC or
SC, but yellow flags still apply.

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
- The safety car stays out until the car is clear of the circuit (over the wall, or out
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
   leader. It waits for the leader, then laps about 40 % slower than race
   pace with the leader about 25 m behind.
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
5 s time penalty. Passing a stopped, crawling or off-track car, a car in the
pit lane, or (when waved by) as a lapped car is allowed. Pit-lane penalties
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
