# Top Down Racer: architecture

Godot 4.6.2 (GDScript, same version as Torque Shed), top-down racing with physics-based cars and online
multiplayer from day one, built the same way as Torque Shed's co-op. This document describes how
wave 1 is put together and where each later feature plugs in.

## Principles

1. **The simulation is pure data.** Everything under `src/sim/` is
   `RefCounted` and has no nodes, no `Input`, no clock and no rendering. It runs
   the same on a headless dedicated server, a listen-server host, a client, or
   in a unit test.
2. **One fixed tick.** `RaceSim.step(inputs)` advances exactly 1/60 s (4
   physics substeps inside). The sim never reads wall time.
3. **Every driver produces `CarInput`.** Humans and AI produce the same
   per-tick intent (throttle, brake, steer and a few flags, with a 4-byte
   wire form). Replays and tests are recorded input streams.
4. **Deterministic and snapshot-able.** The same settings, seed and input
   stream reproduce a race bit for bit. `RaceSim.snapshot()` and
   `apply_snapshot()` capture and restore the full authoritative state. Both
   properties are covered by tests.
5. **Data-driven content.** Cars, tyre compounds, tracks and AI drivers are
   JSON in `data/`. New content needs no code.

## Folder map

```
data/
  cars/*.json         car specs (engine curve, gears, mass, aero, brakes, tyres)
  tyres/*.json        tyre compounds (grip, temperature window, heating/cooling)
  tracks/*.json       centre line + widths + racing line, sectors, defaults
  ai/drivers.json     AI driver names + traits
src/
  sim/                authoritative simulation (no nodes)
    car_input.gd        per-tick driver intent + wire format
    car_state.gd        one car's physical state (+ serialize)
    car_definition.gd   parsed car spec, with_overrides() for upgrades/tuning
    tyre_compound.gd    grip vs temperature/load, lateral force curve
    sim_environment.gd  air/track temp, time of day, weather hooks
    track_data.gd       track geometry, projection, surfaces, grid slots
    car_physics.gd      vehicle model (one substep)
    race_settings.gd    host options (laps, AI, fuel/damage/SC switches...)
    race_entry.gd       competitor, crew (players + roles), timing
    race_sim.gd         race state machine, laps, positions, collisions, snapshots
  ai/ai_driver.gd     placeholder AI producing CarInput
  race/
    race_factory.gd     plan() (host) + build() (everyone) => identical sims
    race_session.gd     runs a race in OFFLINE / SERVER / CLIENT mode
    race_scene.gd       views, camera, local input, results
  net/net.gd          autoload: ENet lobby + RPC transport
  input/local_input.gd  keyboard + gamepad -> CarInput
  view/               track, car and HUD drawing
  ui/                 menu, lobby, controller-friendly Stepper
  core/               GameData autoload (content cache, input map, cmdline), DataLoader
tests/
  run_tests.gd        headless sim tests (data, physics, AI race, determinism, snapshots)
  net_loopback.sh     dedicated server + 2 bot clients over localhost
  debug_ai.gd         solo AI laps per car, for tuning
tools/import_tumftm_track.py   converts open track data to our format
```

## Simulation

### Tick and substeps

`RaceSim.TICK_RATE = 60`, `SUBSTEPS = 4` (240 Hz physics). Per tick:

1. countdown / phase handling (cars are held on the grid until green)
2. for each substep: `CarPhysics.step()` per car, then car-to-car contacts
3. lap/sector timing from centre-line progress, then positions
4. race-end check, and events (`countdown`, `green`, `lap`, `finished`,
   `chequered`, `race_finished`, `collision`, `barrier_impact`)

Events are how the HUD, audio and, later, damage and safety-car logic
react without polling. The server replicates them reliably.

### Car model (`car_physics.gd`)

A 2D "bicycle" model with per-tyre temperatures:

- **Loads:** static weight split from `weight_front`, aero downforce
  (`cla`, `balance_front`), longitudinal transfer (`cg_height`), and lateral
  transfer per tyre, split front/rear by `roll_stiffness_front` (this sets the
  balance between understeer and oversteer).
- **Grip per tyre:** `peak_mu × temperature factor × load sensitivity ×
  surface (track/kerb/grass) × environment × front/rear grip`. These are
  summed per axle.
- **Lateral force:** simplified Pacejka `sin(C·atan(B·α))` on front and rear
  slip angles. The front wheel frame handles steering and reversing.
- **Longitudinal:** torque curve × gear × final drive. Automatic gearbox in
  wave 1, with manual flags already in `CarInput`. Brakes use `bias_front`,
  engine braking and reverse. Air density from ambient temperature scales
  power, drag and downforce.
- **Combined slip:** friction circle per axle. Driver aids, chosen per car
  in `CarState` so they replicate: TC/ESC limits drive to the grip the
  cornering force leaves spare, and ABS does the same for braking.
- **Tyre temperature:** heat from slip power (lateral slip speed × force,
  plus longitudinal slip and spin), plus rolling heat ∝ speed × load. Heat is
  lost to the air (more at speed, relative to `ambient_c`) and to the track
  surface (relative to `track_c`). Tyres start between air and track
  temperature. Grip falls off on both sides of `optimal_temp_c`.
- **Damage hooks:** `damage_engine`, `damage_aero` and `damage_suspension`
  (0..1) are already read by the physics (power, downforce/drag, rear grip).
  Wave 3 only has to write them.
- **Fuel:** burned from engine power × `bsfc_l_per_kwh` when the host turns
  fuel on. Fuel mass is part of the car mass either way.

### Track data

`tools/import_tumftm_track.py` converts the TUMFTM racetrack-database
(LGPL-3.0, OpenStreetMap-derived) into `data/tracks/<id>.json`. The fields
are a centre line with left/right widths, an optimised racing line, sector
split fractions, run-off width, default environment, and `pit_lane` (null
for now). Index 0 is the start/finish line and points run in race direction.
The Y axis is flipped for Godot. 20+ real circuits are available from the
same source.

Surfaces: on track, kerb (track edge + `kerb_width_m`), grass (to
`runoff_m`), then a soft barrier.

### Race state machine

`COUNTDOWN → RACING → CHEQUERED (leader finished) → FINISHED`. Laps count
only when every sector boundary was crossed in order, so cutting back across
the line doesn't count. Lap 1 is timed from the green light. After the
leader finishes, everyone else finishes on their next crossing, or gets a
DNF after `finish_timeout_s`. Positions come from finish order, then total
race distance.

### Determinism

The sim uses only its inputs, fixed iteration order and float64 maths.
`AIDriver` has its own seeded RNG and runs only on the authority. Local and
AI inputs are quantised to the wire format before use, so a host's own car
gets exactly what a remote client's car would get. Tests check:

- replaying the recorded inputs of a full 8-car race gives an identical
  state hash
- restoring a mid-race snapshot and replaying the rest gives the same hash

Cross-platform bit-exactness isn't required: in multiplayer each car is
simulated by one machine and streamed to the rest.

## Multiplayer (wave 1), the Torque Shed way

Multiplayer uses the same setup as Torque Shed's co-op, at the user's
request:

- **Transport:** ENet (Godot high-level multiplayer). One player hosts and
  plays; friends type the host's address into the join box (`81.2.3.4`,
  `81.2.3.4:24690`, IPv6 or a host name, parsed by `Net.parse_address`).
  Packets are ZSTD-compressed, and peers get a 15 s timeout instead of
  ENet's default 5 s. The UDP port is **24690** (Torque Shed uses 24680, so
  both games can run side by side).
- **Internet play:** when hosting, the game asks the router to open the port
  itself (UPnP, on a thread), and looks up the public IP if the router
  doesn't give it. The host's lobby shows `Net.join_instructions()`: LAN
  addresses, whether the port is open, and what address to give friends.
- **Who simulates what:** each player simulates **their own car** and
  streams its state about 30 times a second (`CarState.pack_net`, 22
  floats). The host relays it to everyone. There's no input lag on your own
  car, whatever the ping. The **host** simulates the AI cars and streams
  them the same way, and it alone decides the race: countdown, laps,
  sectors, positions, finish, DNFs. It sends that race state 10 times a
  second, and events (laps, finish, chequered flag) reliably.
- **Remote cars** are drawn from a `NetTimeline`: the sender stamps each
  state with its physics clock, and receivers show the car 100 ms in the
  past, blending between the two states either side (up to 250 ms of
  extrapolation if packets stop). These cars are `external` in the local
  `RaceSim`. Physics skips them, the track position is refreshed from their
  streamed position (that's how the host times them), and contacts push only
  the locally simulated car. The other owner applies the matching push on
  their side.
- **Trust:** like Torque Shed, players are trusted with their own car. A car
  state is only accepted from the peer that owns that car. A modified game
  could still cheat; wave 2 adds host-side sanity checks on speed and
  position jumps.

| Direction | What | Channel |
|---|---|---|
| each player → everyone (host relays) | states of the cars they simulate, 30 Hz | unreliable ordered, ch 1 |
| host → clients | race state: phase, timing, entries, car owners, 10 Hz | unreliable ordered, ch 2 |
| host → clients | race events | reliable, ch 3 |

**Lobby:** clients register with a protocol version, name and car. The host
owns the `RaceSettings` and broadcasts the lobby on every change. A
dedicated server (`--server`) owns only the AI, and auto-starts when
`--min-players` players are ready.

**Start:** the host's `RaceFactory.plan()` picks the AI drivers and cars
from the seed, and puts players into crews. Everyone then builds the same
race from that start data with `RaceFactory.build()`.

**Disconnects:** when a driver leaves mid-race, another crew member takes
over that car, or the host's AI takes it from where it was. Car ownership
travels in the race state, so every client switches to the new owner's
stream. Joining mid-race is refused for now (spectating is in wave 2).

**Crews (ready for co-op):** a `RaceEntry` has `crew: [{peer_id, name,
role}]`, with roles `driver`, `pit_crew` and `strategist`. The car's owner
is its driver's machine. Lobby players carry `team` (which car) and `role`,
and `Net.start_race()` already groups players by team. The wave 1 UI gives
every player their own car as driver.

**Offline and tests:** single player runs the same `RaceSession` with every
car local, so the deterministic sim, replays and snapshots (`RaceSim.snapshot`)
still hold. They're the base for replays, spectating and late join.

## Input and controllers

`GameData` registers all actions in code. Keyboard: WASD or arrows.
Gamepad: RT throttle, LT brake, left-stick steering (analog, with
deadzones), A/X as digital throttle/brake for pads without triggers, Y
camera, Back restart, Start menu. `LocalInput` passes analog input straight
through with a steering expo curve. It smooths digital keys, and both get
speed-sensitive steering lock. Menus and lobby use Godot's `ui_*` actions,
so the D-pad/stick move focus, A selects and B goes back. `Stepper` makes
every option adjustable with left/right.

## Running

- Play: open the project in Godot 4.6.2 and press F5, or run the Windows exe.
- Windows exe (as Torque Shed): `godot --headless --path . --export-release "Windows Desktop" build/windows/TopDownRacer.exe` (needs the 4.6.2 Windows export template). The game data is packed inside the exe.
- Tests: `godot --headless --path . --script res://tests/run_tests.gd`
- Network test: `GODOT=godot tests/net_loopback.sh`
- Dedicated server: `godot --headless --path . -- --server --port 24690 --laps 5 --ai 6 --min-players 2`
- Quick race: `godot --path . -- --single --laps 2 --ai 5`
- Bots: add `--autodrive` (the AI drives your car), `--ready`, `--quit-after-race`
- Screenshot: `--screenshot out.png --screenshot-at 20`
- Export: include `data/*` in the export filter, since the JSON files aren't resources.

## Naming and licensing

Cars are generic and unbranded ("Flat-Six RS", "Berlinetta V8T", "Grand
Tourer V8", "Featherweight S"). Each one's description says what kind of
real car it's modelled on, and the specs are realistic. Tracks use real
layouts with place names ("Spielberg GP Circuit"), not sponsor or
commercial circuit names. Track data attribution is in
`data/tracks/ATTRIBUTION.md`.

## Extension points by feature

| Feature | Where it plugs in |
|---|---|
| Weather / time of day | `SimEnvironment.update(dt)` (deterministic timeline from seed), `wetness` already scales grip via `TyreCompound.wet_grip_factor`; settings carry `time_of_day_h`; view tints by time of day |
| Damage + repairs | write `CarState.damage_*` from `collision`/`barrier_impact` events (impulse); repairs reset them during a pit stop |
| Safety car | consume `collision` events → `RaceSim` phase `SAFETY_CAR`; a scripted SC car follows `AIDriver`-style line; overtaking rule via positions |
| Fuel + pit stops | `RaceSettings.fuel_enabled/fuel_rate/mandatory_pit_stops`; `track.pit_lane` geometry; `CarInput.pit_request`; RaceEntry gains `pit_stops_done`; AI strategy picks a lap within the pit window |
| Co-op crews (wave 5) | `RaceEntry.crew` roles; new reliable RPCs for pit-crew/strategist commands (`pit_plan`, tyre choice, fuel amount); role swap during stops |
| AI traits | `AIDriver` reads `traits`; `aggression`, `racecraft`, `tyre_management` reserved |
| Upgrades + tuning | `CarDefinition.with_overrides()` + `RaceEntry.setup`; `tuning_ranges` in car JSON bound what a setup may change; server validates |
| Seasons | a `Championship` resource above `RaceSession`: list of (track, settings), points table, standings; results come from `race_finished` |
| More tracks | run the importer on another TUMFTM CSV; add sector splits and a pit lane |

## Wave 2 breakdown

Goal: make online racing feel good, add choice (cars, tracks, conditions) and
make AI drivers feel like people.

1. **Netcode polish**
   - Host-side sanity checks on streamed cars (speed, position jumps).
   - Smoother car-to-car contact between two players' cars: exchange
     contact impulses so both sides agree.
   - Quantised car states (positions in cm, angles in 16 bits) for big grids.
   - Mid-race join as a spectator. Reconnect to your own car within a time
     limit.
   - Ping and connection-quality display. Lobby chat. Kick for the host.
   - Steam invites for players behind carrier-grade NAT (planned in Torque
     Shed too).
2. **Race settings UI**
   - Track select, and time of day with a lighting tint.
   - Weather presets: dry, overcast, damp, wet, changing. Uses a
     deterministic `SimEnvironment` timeline, track temperature that follows
     sun and cloud, and wet-tyre compounds (`data/tyres/wet.json`,
     `intermediate.json`).
   - Driver aids per player (TC/ABS on/off, auto/manual gears). Manual
     shifting via the `shift_up`/`shift_down` flags.
3. **AI with traits**
   - Racecraft: overtaking lines and defending (aggression, racecraft).
   - Mistakes driven by consistency (lock-ups, running wide).
   - Tyre management: back off when tyres are out of their window.
   - Skill-based grid order, or a short qualifying session.
   - Better collision avoidance at race starts.
4. **Content**
   - Two or three more real circuits through the importer, e.g. Monza and
     Suzuka (generic names), plus a pit-lane polyline per track to get
     ready for wave 3.
   - Two or three more cars (a hot-hatch class, a GT3-style race car on slicks).
5. **Feel and presentation**
   - Skid marks, tyre smoke, engine/tyre audio from RPM and slip.
   - Better car sprites, and a camera option that rotates with the car.
   - Rebindable controls and controller vibration on kerbs and slides.
6. **Tooling**
   - CI running `run_tests.gd` and `net_loopback.sh` headless on each PR.
   - Export presets for Windows, macOS and Linux.

Wave 3: damage and repairs, safety car, fuel and pit stops (mandatory stop
count set by the host; AI must make the same number, choosing a lap within
the pit window).

Wave 4: seasons and championships, upgrades, per-track tuning.

Wave 5: co-op crews (2 or 3 players share a car as driver / pit crew /
strategist; with 2 players, pit crew and strategist are one joined role).

The living plan document (scope and wave order) is the source of truth:
https://claude.ai/artifact/4yY11Dm9qpB9XUBczLi2HP
