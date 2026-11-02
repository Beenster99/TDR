# Fuel, tyres and pit stops

Wave 3. The rules live in the race module (`PitRules`, held as `RaceSim.pits`),
tyre wear in physics (`CarPhysics`), the AI's decisions in the ai module
(`AIPitStrategy`), and syncing in multiplayer (`RaceSession`, `Net`).

## Host options (lobby / single race page)

| Setting | Values | `RaceSettings` |
|---|---|---|
| Fuel use | Off, Real, 2x, 3x, 5x | `fuel_enabled`, `fuel_rate` |
| Tyre wear | Off, Real, 2x, 3x, 5x | `tyre_wear_enabled`, `tyre_wear_rate` |
| Mandatory pit stops | 0-3 | `mandatory_pit_stops` |
| Drivers per car | 1-3 | `drivers_per_car` (menu default 2) |
| Pit window | automatic (no menu yet) | `pit_window_open_lap`, `pit_window_close_lap` (0 = automatic) |

Command line: `--fuel 2 --tyre-wear 2 --pit-stops 1 --drivers 2`.

- **Fuel**: cars start full. Consumption follows engine power; "Real" is about
  3-4 L a lap for a GT3. Out of fuel = no power.
- **Tyre wear**: wear follows the sliding work on each tyre and grows quickly
  on a tyre run too hot (wets on a drying track). "Real" is about 3.5% a lap on
  slicks. A worn tyre loses up to a third of its grip, mostly near the end.
- **Mandatory stops** must be made inside the pit window. Automatic window:
  from about a fifth of the race in to a fifth before the end, never the last
  lap (the boxes are past the finish line). A stop counts in the lap the car
  came into the pits. Each missing stop costs 60 s at the finish.

## A pit stop

1. **The call.** "Box this lap" comes from the AI strategy, the player's box
   button, or (co-op, wave 5) a pit crew / strategist via
   `RaceSession.request_pit(car, changes)`. The plan says what to do:
   `tyre` (`auto` = suit the weather, `dry`, `intermediate`, `full_wet`,
   `keep`), `wheels` (which tyres: `all`, `front`, `rear`, `left`, `right`,
   or one tyre `fl`, `fr`, `rl`, `rr`), `driver_change` (AI line-ups), `fuel` (litres, -1 = enough to finish, 0 = none), `repair`, and
   (co-op pit crew, when the host allows car setups) `setup`: new values for
   the front splitter, rear wing and tyre pressures, applied in the box (see
   docs/PIT_WALL_ROLES.md).
2. **Driving in.** A player drives their own stop (Settings > Gameplay >
   Pit stops: "Drive in yourself", the default; solo and co-op, whoever is
   at the wheel): with a box call, a dashed pit guide line leads from the
   track into the lane and onto their box (`PitRules.guide_line`, drawn by
   graphics `PitGuideView`), blue where the speed is fine, yellow to get
   ready, red where they must brake to make the limit by the limit line or
   to stop on the box. Lines across the lane mark where the limit starts
   and ends and the box is outlined; the HUD's pit lane guide shows the
   metres to the limit line / box and BRAKE, STOP cues (`guide_info`). They
   must be at the limit (60 km/h) at the limit line or get a 5 s penalty;
   from there the limiter is held on to the end of the limit. In the box:
   stopped within 3 m short / 2 m past the marks and 2.6 m sideways is spot
   on; up to 12 m past costs 1 s + 0.35 s a metre (the crew move to the
   car); further than that the box is missed and the call stays for the
   next lap. After the stop they drive out themselves. With "Automatic",
   and for AI cars, the car is driven in from about 300 m before the pit
   entry (the guide follows a route along the pit side of the track, then
   the lane), to its box and out to the end of the limit. A player can also
   just drive into the lane without a box call: from the limit line the
   guide takes the car to its box. A car handed to an AI co-driver mid-stop
   goes back to the guide (`set_self_drive`).
   **Single player pit call menu** (Settings > Gameplay > Pit call menu):
   calling a stop opens a quick menu and the race waits while it's open:
   tyres, which tyres, front splitter and rear wing (when the race allows
   car setups and the car's wings adjust), fuel and repairs, with the stop
   time worked out as you go (ui `PitCallMenu`). A / Enter or the box
   button again: box this lap; B / Esc: no stop. Online the keys and the
   pit wall do this, as the race can't wait.
3. **The stop.** Stop time = 2.5 s (car up and down) + refuelling (3 L/s), then
   the tyre change (tyres only once the fuel is in, as in the WEC rules,
   `PitRules.TYRES_AFTER_FUEL`; +0.2 s to get the hose off) + repairs (`CarDamage.repair_time`, parts
   one after another). Tyres take 1.5 s + 1.125 s a tyre: all four 6 s, a
   pair 3.75 s, one 2.6 s. New tyres arrive warm and fix punctures. A change
   to a different compound always fits all four (compounds aren't mixed), and
   with repairs on a punctured tyre is always changed, even on a "no tyres"
   stop. A driver change keeps the car in the box for at least 5 s.
   That's the standard: the AI crew play the stop out the Le Mans way and
   are a little quicker or slower each time, now and then fumbling a wheel
   (docs/PIT_CREW_GAME.md).
4. **Leaving.** The guide drives to the end of the speed limit; AI cars are
   driven to the end of the lane, players take over at the limit line.

Speed-limit zones are about 330-440 m around the garages by the start/finish
line (`modules/tracks/tools/pit_limit_zone.py`), so a stop costs roughly
30-40 s in the game's current pace.

## Driver changes

With **Drivers per car** at 2 or 3:

- **Every AI car** has a line-up (`RaceEntry.lineup`): its lead driver and
  one or two co-drivers (names from `modules/race/data/co_drivers.json`,
  traits a little below the lead's). An AI car changes driver at a stop once
  the driver at the wheel has done about half their share of the race or
  more; from there the new driver's traits drive the car (`AIDriver`
  follows `pit["driver_idx"]`). The timing tower shows who is at the wheel;
  results stay under the lead driver's name.
- **A player racing alone** gets an AI co-driver in their crew
  (`RaceEntry.AI_PEER`). Press **N** (pad: **Y** on the pit wall) and the
  co-driver takes over at the next stop; you move to the pit wall (pit crew
  and strategist) while they drive, and can call them in and take the wheel
  back from the crew console ("Driver change"). In multiplayer the host runs
  the co-driver.
- **Co-op crews** change drivers between themselves (docs/COOP.md).

## AI strategy (`modules/ai/pit_strategy.gd`)

Decided once a lap, a little before the pit entry:

- mandatory stops: laps picked at the start, spread over the window; earlier
  for aggressive drivers, later for good tyre managers, a little random. A
  stop waits a lap if the car would come out in traffic and the window allows;
  aggressive drivers stop early to undercut a car just ahead.
- fuel: never runs dry.
- tyres: worn past a limit set by tyre management (higher near the end), or
  the wrong tyres for the weather (wet skill decides how long to stay out on
  slicks; forecast rain keeps them on wets).
- damage worth repairing.
- which tyres: when the compound stays the same and one axle has worn much
  more than the other (still fresh), only that axle, which is quicker.
- driver changes for cars with a line-up (see above).
- safety car: a stop that's needed anyway is taken while it's cheap
  (`RaceSim.pit_time_saving()`, from the safety car work).

Gaps and the forecast come from the race data (`RaceTelemetry`) when the
session has it.

## Multiplayer

A car's pit state (`RaceEntry.pit`) belongs to the machine that simulates
the car, like its physics: that machine runs the lane for it and sends the
state to the host when it changes (`Net.send_pit_state`). The host counts
stops, hands out penalties, raises `pit_*` events and shares every car's pit
state in the race state. Pit calls from other crew members go through the host
to the car's owner (`Net.send_pit_request`); the host checks the sender is in
the car's crew.

Events: `pit_request`, `pit_entry`, `pit_box` (with the work), `pit_stop`
(stop number, lap, stationary time, tyres, fuel, in window), `pit_exit`
(time in the lane), `penalty`.

## Controls

| | Keyboard | Pad |
|---|---|---|
| Box this lap (toggle; single player opens the pit call menu) | B | D-pad left |
| Pit limiter | L | L3 |
| Next stop's tyres | T | B (when the pit wall is closed) |
| Next stop's fuel | F | (auto: to the end) |
| Which tyres the next stop changes | Y | LB / RB on the pit wall |
| Driver change at the next stop (toggle) | N | Y on the pit wall |
