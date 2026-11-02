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
| Pit window | automatic (no menu yet) | `pit_window_open_lap`, `pit_window_close_lap` (0 = automatic) |

Command line: `--fuel 2 --tyre-wear 2 --pit-stops 1`.

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
   `keep`), `fuel` (litres, -1 = enough to finish, 0 = none) and `repair`.
2. **Driving in.** With a box call, the car is driven in automatically from
   about 300 m before the pit entry (the pit guide follows a route along the
   pit side of the track, then the lane). A player can also drive into the
   lane themselves: they must be down to the limit (60 km/h) at the limit
   line or get a 5 s penalty; the pit limiter button cuts the power above
   the limit. From the limit line the guide takes the car to its box.
3. **The stop.** Stop time = 2.5 s (car up and down) + the slower of a tyre
   change (6 s) and refuelling (3 L/s) + repairs (`CarDamage.repair_time`,
   parts one after another). New tyres arrive warm and fix punctures.
4. **Leaving.** The guide drives to the end of the speed limit; AI cars are
   driven to the end of the lane, players take over at the limit line.

Speed-limit zones are about 330-440 m around the garages by the start/finish
line (`modules/tracks/tools/pit_limit_zone.py`), so a stop costs roughly
30-40 s in the game's current pace.

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
| Box this lap (toggle) | B | D-pad left |
| Pit limiter | L | L3 |
| Next stop's tyres | T | B (when the pit wall is closed) |
| Next stop's fuel | F | (auto: to the end) |
