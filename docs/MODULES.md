# Modules

The game is split into modules under `modules/`. Each module owns one area,
has a version, says which other modules it uses, and lists the classes other
modules may use (its public API). Different people or threads can work on
different modules at the same time, at their own pace, without breaking each
other, as long as they keep to the rules below.

Each module's facts live in its `modules/<id>/module.json`. This page explains
them. `tests/run_tests.gd` checks the rules automatically on every run.

## The map

Lower modules never use higher ones. Read the table from top (bottom layer)
to bottom (top layer).

| Module | Version | Owns | Public API | Uses |
|---|---|---|---|---|
| **core** | 1.4.1 | Shared basics: the driver-intent contract, JSON reading, the module registry, shared game state (incl. the season being played, `GameData.season`), the player's settings saved in `user://settings.cfg` with the list of options the Settings screen shows (`GameData.register_setting`, `set_pref`, `pref_changed`), and units of measure for display (`Units`: speed, power in hp/kW/PS, temperature, distance, fuel) | `CarInput`, `JsonData`, `ModuleRegistry`, `Units`, autoload `GameData` | nothing |
| **cars** | 1.6.0 | What each car is (engine, gears, mass, aero, brakes, aids, tyres, engine sound family) and its class (Hypercar, LMP2, GT3, Road); car JSON in `data/`; the safety car in `special/` (`load_safety_car`); overrides for upgrades and balance (`engine.torque_scale`, `ballast_kg`, a `visual` block kept in `raw`); car setups (21 settings, ranges, plain explanations, see docs/SETUPS.md) | `CarDefinition`, `CarCatalog`, `CarSetup` | core |
| **tracks** | 1.3.2 | Circuit layouts, surfaces, sectors, grid slots, pit lanes (speed-limit zone around the garages), real elevation (heights, gradients, crests, banking, terrain grid), barrier types and run-off surfaces (gravel, paved); track JSON in `data/`; track builder in `tools/` | `TrackData` (incl. `TrackData.Surface`), `TrackCatalog` | core |
| **input** | 1.7.0 | Keyboard and controller bindings, rebindable in Settings > Controller (`InputSetup.REBINDABLE`, `with_binding`, `apply_bindings`, saved in `GameData.prefs["controls"]`), the stick dead zone (incl. zoom, the pit wall button and the pit calls: box, limiter, tyres, fuel; team radio and the pit wall tab switch; manual gear shifts; the timing tower key), turning them into `CarInput` (speed-sensitive steering lock, `LocalInput.steer_lock` / `key_steer`); only the controller in use feeds sticks and triggers (`ActivePad`) | `LocalInput`, `InputSetup`, `ActivePad` | core |
| **physics** | 1.8.0 | How cars move: vehicle model, damage and repairs (`CarDamage`), tyre grip, temperatures and wear (dry, intermediate and wet compounds); slopes, crests and banking; weather and time of day (clock, air and track temperature, rain, standing water, drying line, rubber); tyre JSON in `data/`; what a setup does (ride height and bottoming, springs, dampers, bars, camber, toe, diff, tyre pressures) and the setup advisor; driving aids: track assist and manual gearbox (`CarState.assist_track`, `manual_gears`) and the reference driving line with braking zones (`DrivingLine`, see docs/DRIVING_AIDS.md) | `CarState`, `CarPhysics`, `CarDamage`, `TyreCompound`, `TyreCatalog`, `SimEnvironment`, `SetupAdvisor`, `DrivingLine` | core, cars, tracks |
| **race** | 1.16.0 | Race rules: grid size (25 cars in one class, 45 multi-class: `RaceSettings.max_cars`), qualifying sessions (`session_type`, classified by best lap), countdown, laps, sectors, positions, finish, contacts and the damage they cause, incidents and retirements (`is_retired`), race control (yellow flags, virtual safety car, safety car, penalties: `RaceControl`, `add_penalty`, `safety_car_active`, `pit_time_saving`), pit lane and pit stops (fuel, tyres, repairs, limiter, mandatory stops and pit window, pit-stop setup changes for wings and tyre pressures; which tyres a stop changes, `PitRules.WHEEL_CHOICES`; each car's box `box_index`; see docs/PITS.md), snapshots, settings, entries and crews (with each car's setup and livery; co-op roles `ROLE_PIT_WALL`, `role_covers`, `share_roles`; driver change in the box `PitRules.add_driver_change`; drivers sharing a car, `RaceSettings.drivers_per_car`: AI line-ups `RaceEntry.lineup` and a solo player's AI co-driver `RaceEntry.AI_PEER`, from `RaceFactory.add_co_drivers`), building a race from start data (a season's AI keep their team car), the host's upgrades option (`upgrades_mode`: on, balance of performance, stock; `RaceFactory.apply_balance`), the host's car setups switch (`tuning_enabled`) and AI setups; `post_event` for AI radio/strategy calls | `RaceSim`, `RaceSettings`, `RaceEntry`, `RaceFactory`, `RaceControl`, `PitRules` | core, cars, tracks, physics |
| **ai** | 1.4.0 | Computer drivers with personalities (see docs/AI.md), aware of slopes and crests, with a pit strategy (when to stop and for what); 50 named drivers with teams and traits in `data/` | `AIDriver`, `DriverCatalog`, `DriverTraits` | core, cars, tracks, physics, race |
| **graphics** | 2.6.0 | The 3D world: track and terrain, trackside (trees, grandstands, pits), Blender-built car models (GT3s and the Hypercar and LMP2 prototypes) with liveries, sponsor stickers, door numbers and upgrade parts (splitter, wings, canards, calipers, rims, ride height), sun, sky, weather and the camera; the driving line aid (green / yellow / red braking line) and brake marker boards; effects: tyre smoke and dust, rubber marks, crash debris and parts flying off, sparks; animated pit crews doing each stop | `WorldView`, `TrackView`, `CarView`, `WeatherView`, `GfxSettings`, `PitCrews`, `DrivingLineView` | core, cars, tracks, physics |
| **audio** | 1.2.0 | Every sound, all synthesised: engine families (V8 cross/flat-plane, V10, V12, flat-six, straight-six, V6, four) baked at many rpm bands with rev limiter, shifts, pops, turbo, supercharger, hybrid and gearbox whines; tyre squeal, scrub, lock-up, road, kerbs, gravel, grass, wind, rain spray; Doppler; crashes, start lights, menu clicks (switch clicks, not beeps) and the intro's GT3 pass-by (`Sound.passby()`, `samples/`) (see docs/AUDIO.md) | `RaceAudio`, `SoundBank`, autoload `Sound` | core, cars, physics |
| **telemetry** | 1.0.3 | Race data for the pit wall: lap and sector log, last-5-lap averages, gaps and intervals from timing loops, tyre state, pit-window analysis (pit lane loss per track), weather radar and forecast, feed of radio/strategy/race control/timing calls; host syncs gaps and feed to clients; full race log export | `RaceTelemetry`, `CarTelemetry`, `PitWindow`, `WeatherForecast`, `RaceFeed` | core, tracks, physics, race |
| **multiplayer** | 1.9.0 | Online play the Torque Shed way (lobby with each player's car setup and livery, the season standings `season_info`, a host `start_planner` for season races, ENet, UPnP, streaming cars) and running a race offline / as host / as client; pit state and pit calls from any crew member; co-op crews: 2-3 players share a car with roles, role swaps, driver changes at a pit stop that hand the car to the new driver's machine (or to the host's AI for a solo player's AI co-driver), team radio (see docs/COOP.md) | `RaceSession`, `NetTimeline`, autoload `Net` | core, physics, race, ai, telemetry |
| **season** | 1.0.0 | Single races and championships: calendar of rounds (track, laps, weather, start time), points systems (presets, custom, pole and fastest-lap bonus), qualifying (off, simulated, driven), driver and team standings, saved seasons in `user://seasons/` with each session's race log, AI drivers keep team, car and traits all season, careers between seasons (growth, retirements, hires, fires, rookies); see docs/SEASONS.md | `Season`, `PointsSystem`, `SeasonResults`, `SeasonStore` | core, cars, physics, race, ai, telemetry |
| **ui** | 1.15.0 | Intro screen (key art + GT3 pass-by), main menu over a loop of race highlights filmed in the game, the profile badge top right, Settings (Gameplay, Controller with the keybinds page, Graphics, Sound, Garage, Debug; built from `GameData.settings_catalog`), main menu, seasons (saved seasons, new season with calendar and points, season hub with standings), lobby (incl. co-op car shares and roles), race settings (incl. fuel, tyre wear, mandatory stops, car upgrades, car setups free/fixed), in-race HUD (incl. the pit panel, sector times with gaps to the cars ahead and behind, and the optional timing tower with manufacturer badges), the pit wall (strategist screen), the garage (upgrades, livery, 3D preview), the car setup screen and saved setups, the co-op pit wall console (pit crew and strategist around the zoomed-out 3D race, see docs/PIT_WALL_ROLES.md) and team radio calls, controller-friendly widgets | `RaceHud`, `Stepper`, `StrategistScreen`, `GarageScreen`, `SetupScreen`, `SetupStore`, `CrewConsole`, `TeamRadio`, `SettingsScreen`; scenes `splash.tscn` (first scene), `main_menu.tscn` | core, input, cars, tracks, physics, race, telemetry, multiplayer, audio, graphics, business, season |
| **business** | 1.1.1 | The player's team: money (prize money, R&D spending), cars bought into the garage, car upgrades (engine, aero, brakes, suspension, weight, tyres; levels 0-3) and liveries, saved in `user://profile.json`; see docs/BUSINESS.md | `UpgradeCatalog`, `TeamProfile`, `Economy` | core, cars |
| **game** | 1.4.10 | Puts it all together: start-up (loads content, registers controls) and the race scene (records season sessions, pays prize money into the team budget) | autoload `Game`; scene `race.tscn` | everything |

Start-up order: `GameData` (core) parses the command line, `Game` (game)
registers controls and loads all content into `GameData`, `Net`
(multiplayer) gets ready, `Sound` (audio) sets up the audio buses, then the intro screen (ui) applies the
saved settings and opens the main menu.

**Adding a setting:** call `GameData.register_setting(section, key, label, [[value, "label"], ...], default, help)`
(or `register_number`) at start-up and read `GameData.prefs[key]`. The Settings screen shows it, and it's saved.

## The rules

1. **Stay in your module.** A module's code, data and tools live in its
   folder. Content JSON goes in its `data/` folder.
2. **Only use what's public.** Code may use another module's classes only
   if that module is listed in its `depends` and the class is in that
   module's `api` (or `autoloads`). Every `class_name` must be listed in its
   module's `api` (public) or `internal` (only that module may use it).
3. **No loops.** Dependencies only point down the table. If two modules need
   to talk both ways, the lower one raises an event or signal, or takes a
   value as a parameter, and the higher one listens or passes it. (Example:
   core's `GameData` holds content as plain dictionaries, filled in by the
   game module, so core doesn't need to know about cars or tracks.)
4. **Version every change to a module's API**, in its `module.json`, with
   `major.minor.patch`:
   - patch: fixes and tuning, API unchanged (1.0.0 to 1.0.1)
   - minor: API added, nothing removed or changed (1.0.1 to 1.1.0)
   - major: something in the API removed or changed (1.1.0 to 2.0.0)
5. **Depend on a major version.** `depends` maps each module used to the
   major version it was written for, e.g. `"cars": "1"`. When a module goes
   to a new major version, the tests fail for every module still pointing
   at the old one, until someone checks that module still works and updates
   its entry. That's the signal to the threads working on those modules.
6. **The simulation stays pure.** core, cars, tracks, physics, race, ai and telemetry
   have no nodes, no `Input`, no clock and no drawing, so races stay
   deterministic and run the same on a headless server and in tests.
7. **Network messages:** bump `Net.PROTOCOL_VERSION` (multiplayer) whenever a
   message changes shape, so old and new builds refuse to play together
   politely.

## Adding things

- **A car, track or tyre:** add a JSON file to that module's
  `data/` folder. No code, no version bump needed beyond a patch. Tracks
  are built rather than hand-written: see `docs/ADDING_CONTENT.md`.
- **An AI driver:** add an entry to `modules/ai/data/drivers.json` (see `docs/AI.md`).
- **A new class:** put it in the right module, give it a `class_name`, and
  add it to `api` or `internal` in `module.json`. Adding to `api` is a minor
  version bump.
- **A new module:** create `modules/<id>/module.json` (copy one), list its
  `depends`, and add it to the table above and to the plan doc.

## Who works where

One thread per module (or per few small modules) at a time. Changes to
**core** affect everyone, so keep them rare and additive (minor bumps). A
change that touches several modules should bump each one's version and
update the `depends` entries in the same change.
