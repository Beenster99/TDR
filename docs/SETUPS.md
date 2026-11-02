# Car setups (per-track tuning)

Wave 4. Every car can be tuned for each track. A setup is saved per car per
track, the AI picks a good one for every race, and the host can switch
setups off for equal-car races ("Car setups: Fixed").

## Where things live

| What | Where |
|---|---|
| The 21 settings, their ranges, defaults and plain explanations | `modules/cars/car_setup.gd` (`CarSetup`) |
| What each setting does to the car | `modules/physics/car_physics.gd` (`CarPhysics`), `modules/physics/tyre_compound.gd` (pressures) |
| A good setup for a car and track (AI and the "Recommended" button) | `modules/physics/setup_advisor.gd` (`SetupAdvisor`) |
| AI setups at race start, the host switch, fuel load | `modules/race/race_factory.gd`, `race_settings.gd` (`tuning_enabled`), `race_sim.gd` |
| Setup screen and saved setups (`user://setups/<car>/<track>.json`) | `modules/ui/setup_screen.gd`, `modules/ui/setup_store.gd` |
| Multiplayer: each lobby player's `setup` goes into the start data | `modules/multiplayer/net.gd` (protocol 9) |

## How a setup travels

A setup is a Dictionary of the values the player sees (`CarSetup.KEYS`),
for example `{"wing_rear": 3, "ride_front": 56, "pressure_front": -0.5}`.
Keys left out keep the car's default. It goes into a race entry's setup
overrides as `{"tuning": {...}}`, next to `tyre_compound` and any upgrade
overrides, so every machine builds the same car from the start data:
`CarDefinition.with_overrides(entry.setup)` parses the car (with upgrades),
then `CarSetup.apply()` turns the tuning block into physical numbers on top.

When `RaceSettings.tuning_enabled` is false the sim drops the tuning block
for every car, players and AI alike.

## The settings and what they do

| Setting | Effect in the physics |
|---|---|
| Front splitter, rear wing (0..10, GT3 only) | Downforce at that end (+5% / +6% per click) and drag (+1% / +2.4% per click) |
| Ride height front/rear | Lower: more downforce (ground effect, +0.4% per mm) and a lower centre of gravity. Rake (rear minus front) moves the aero balance forward. The floor touches the ground when the ride height drops below the plank (GT3 34 mm): grip and downforce drop sharply (bottoming) |
| Springs front/rear (N/mm) | How far the car sinks under downforce, braking and in dips. Stiffer loses grip over bumps, crests, dips and kerbs, softer gains it. Half of the roll stiffness at that end |
| Dampers front/rear | Slow the dips and crests (less sink in a compression), stiffer adds grip loss over bumps, front adds steering response |
| Anti-roll bars | The other half of the roll stiffness. Front share of roll stiffness sets the balance (more front = understeer). Total roll changes the camber in corners |
| Camber front/rear | Cornering grip is best when camber plus body roll reaches the best working camber; more camber costs braking/traction grip and heats the tyre |
| Toe front/rear | Front toe-out: quicker steering. Rear toe-in: more rear grip. Both add drag and tyre heat |
| Brake bias | Share of braking force on the front axle |
| Diff on/off power | On power: how much of the driven axle's grip can drive (an open diff only what the inside wheel holds) and how hard a locked diff resists turning (understeer). Off power: stability on entry |
| Gearing (final drive) | Top speed at the limiter vs acceleration |
| Tyre pressures (cold, vs the compound's own) | Hot pressure = cold × T / 293 K. Grip is best at the compound's best hot pressure (slicks 27.5 psi); over it costs more than under it. Lower pressure heats the tyre more and wears it more |
| Fuel load | Start fuel when fuel use is on (Auto = race default). Lighter is faster |

## The setup advisor

`SetupAdvisor.recommend(car, track, conditions)` drives a point-mass lap of
the track (cornering, braking and power limits with the car's own aero and
gearing) and picks the rear wing with the best lap time (splitter follows),
gearing that reaches the limiter at the top speed, springs and dampers from
how bumpy the track is, ride heights that clear the worst 2% of
compressions, camber and diff from the corner mix, tyre pressures for the
expected tyre temperature (lower on a hot track), wet-weather changes, and a
fuel load for the race distance when fuel is on. `SetupAdvisor.notes()`
gives the plain track notes on the setup screen.

## Tyre temperatures (the cold-tyre fix)

Before wave 4 slicks ran 60-70 C at the front (best 95 C). Rolling heat now
follows the load against what each tyre carries at rest (rear tyres are
bigger), air cooling grows more slowly with speed, and pressure and camber
add heat. GT3 slicks now settle around 92-105 C (front and rear within a few
degrees), a little hotter on hot tracks. `tests/tyre_probe.gd` prints lap
times and average tyre temperatures per lap for tuning.

## Tools

- `godot --headless --path . --script res://tests/tyre_probe.gd -- mugello 6 3 GT3`:
  lap times and tyre temperatures per car and lap (env `TDR_HOT=1` pins tyres
  at 95 C, `TDR_ALIEN=1` uses perfect drivers, `TDR_TRACE=1` prints a trace).
