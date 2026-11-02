# Top Down Racer

A top-down racing game in Godot 4 with physics-based sports cars, real-world
track layouts, AI drivers, and online multiplayer.
Keyboard and game controller are supported.

**Wave 2:** 23 real circuits (Mugello, Monza, Spa, Silverstone, Suzuka and
most of the F1 calendar), each with its real pit lane ready for pit stops,
and ten real cars in two classes: GT3 racers (Ferrari 296, Porsche 911 GT3 R,
Mercedes-AMG, BMW M4, Lamborghini Huracán, McLaren 720S) and road sports cars.
Races can be one class or multi-class. Tyre temperatures react to driving,
air temperature and track temperature. You can play a single race against
AI, or host and join an online race with friends (set up like Torque Shed's
co-op). The HUD shows timing, standings, tyre temperatures and a minimap.

## Play

Just run `TopDownRacer.exe` (a single file, nothing to install). Or, from the source:

1. Install [Godot 4.6.2](https://godotengine.org/download) (standard build, not .NET), the same version Torque Shed uses.
2. Open `project.godot` and press **F5**.
3. **Single race** to drive against AI, or **Host online race** /
   **Join online race**.

### Online

One player picks **Host online race**, and the others type the host's
address into the join box and pick **Connect**. The game uses UDP port
**24690**. The host's lobby shows exactly which address to give friends.

- Same network: use the host's local address (192.168.x.x or similar).
- Over the internet: friends use the host's public IP. When hosting, the
  game asks the router to open UDP port 24690 itself (UPnP), and the lobby
  says whether that worked. If it didn't, forward UDP 24690 to the host's PC
  by hand. Windows asks about the firewall the first time: allow Private and
  Public networks.
- The join box takes `81.2.3.4`, `81.2.3.4:24690`, an IPv6 address or a host name.
- Each player drives their own car on their own PC, so there's no input lag.
  The host runs the AI cars and the race timing.

| | Keyboard | Controller |
|---|---|---|
| Throttle | W / Up | RT (or A) |
| Brake / reverse | S / Down | LT (or X) |
| Steer | A D / Left Right | Left stick |
| Camera rotate | C | Y |
| Restart (single race) | R | Back |
| Menu | Esc | Start |
| Zoom in / out (hold) | E / Q, + / -, mouse wheel | LB / RB, right stick up / down, D-pad up / down |
| Whole track and back | Z or Tab | Click the right stick |
| Timing tower on / off | H | Settings > Gameplay |

**Race HUD:** bottom centre shows your sector times for this lap (purple is
the fastest anyone has gone, green your personal best, yellow slower; white
is the sector you're in) with the gap to the car ahead on the left and the
car behind on the right (green when you're gaining, red when you're losing).
The timing tower on the left lists every car: position, manufacturer badge,
driver, last lap and gap to the car ahead. On big grids it shows the top
three and the cars around you.

**Co-op pit wall (wave 5):** players who share a car but aren't driving run
the pit wall: the pit crew calls the stops (tyres, fuel, repairs, wing and
tyre pressure changes) and the strategist reads the race (gaps, pace, pit
window, weather, rivals); with two players these are one role. Both watch
the whole track in 3D and radio the driver (X / V). See
[docs/PIT_WALL_ROLES.md](docs/PIT_WALL_ROLES.md).

**Driving help** (main menu): Full adds a stability assist that catches
slides and counter-steers for you, on top of traction control and ABS. Some
is traction control and ABS only. Off is the raw car.

Menus work fully with a controller: D-pad or stick to move, A to select, B
to go back, left/right to change a value.

## Dedicated server

```
godot --headless --path . -- --server --port 24690 --laps 5 --ai 6 --min-players 2
```

Race options work here and with `--single` / `--host`: `--weather heavy_rain`
(`dry`, `overcast`, `light_rain`, `heavy_rain`, `random`), `--weather-changes`,
`--time 20` (start hour), `--clock-speed 60` (60x clock), `--grid reversed`.

## Tests

```
godot --headless --path . --script res://tests/run_tests.gd   # module boundaries, sim, physics, AI race, determinism
GODOT=godot tests/net_loopback.sh                             # server + 2 clients over localhost
godot --headless --path . --script res://tests/handling_probe.gd  # spins in beginner manoeuvres (--raw: no driving help)
```

The code is split into modules (core, cars, tracks, physics, race, ai, input,
graphics, multiplayer, ui, game, and business later), each with its own
version and public API, so each area can move at its own pace. See
[docs/MODULES.md](docs/MODULES.md) for the module map and rules, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it fits together,
the extension points for the later waves, and the wave 2 plan.
