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
| **core** | 1.1.0 | Shared basics: the driver-intent contract, JSON reading, the module registry, shared game state | `CarInput`, `JsonData`, `ModuleRegistry`, autoload `GameData` | nothing |
| **cars** | 1.1.0 | What each car is (engine, gears, mass, aero, brakes, aids, tyres) and its class (GT3, Road); car JSON in `data/` | `CarDefinition`, `CarCatalog` | core |
| **tracks** | 1.2.0 | Circuit layouts, surfaces, sectors, grid slots, pit lanes, real elevation (heights, gradients, crests, banking, terrain grid); track JSON in `data/`; track builder in `tools/` | `TrackData` (incl. `TrackData.Surface`), `TrackCatalog` | core |
| **input** | 1.1.0 | Keyboard and controller bindings, turning them into `CarInput` | `LocalInput`, `InputSetup` | core |
| **physics** | 1.3.0 | How cars move: vehicle model, tyre grip and temperatures (dry, intermediate and wet compounds); slopes, crests and banking; weather and time of day (clock, air and track temperature, rain, standing water, drying line, rubber); tyre JSON in `data/` | `CarState`, `CarPhysics`, `TyreCompound`, `TyreCatalog`, `SimEnvironment` | core, cars, tracks |
| **race** | 1.3.0 | Race rules: countdown, laps, sectors, positions, finish, contacts, snapshots, settings, entries and crews, building a race from start data | `RaceSim`, `RaceSettings`, `RaceEntry`, `RaceFactory` | core, cars, tracks, physics |
| **ai** | 1.2.0 | Computer drivers with personalities (see docs/AI.md), aware of slopes and crests; 50 named drivers with teams and traits in `data/` | `AIDriver`, `DriverCatalog`, `DriverTraits` | core, cars, tracks, physics, race |
| **graphics** | 2.0.0 | The 3D world: track and terrain, trackside (trees, grandstands, pits), Blender-built car models with liveries, sun, sky, weather and the camera | `WorldView`, `TrackView`, `CarView`, `WeatherView`, `GfxSettings` | core, cars, tracks, physics |
| **audio** | 1.0.0 | Every sound, made in code: engines following revs and throttle, tyre squeal, grass rumble, crashes, start lights, menu clicks | `RaceAudio`, `SoundBank`, autoload `Sound` | core, cars, physics |
| **multiplayer** | 1.1.1 | Online play the Torque Shed way (lobby, ENet, UPnP, streaming cars) and running a race offline / as host / as client | `RaceSession`, `NetTimeline`, autoload `Net` | core, physics, race, ai |
| **ui** | 1.3.0 | Main menu, lobby, race settings, in-race HUD, controller-friendly widgets | `RaceHud`, `Stepper`; scene `main_menu.tscn` | core, cars, tracks, physics, race, multiplayer, audio |
| **business** | 0.1.0 (planned) | Wave 4: championships, seasons, prize money, buying and upgrading cars | none yet | core, cars, race |
| **game** | 1.1.1 | Puts it all together: start-up (loads content, registers controls) and the race scene | autoload `Game`; scene `race.tscn` | everything except business |

Start-up order: `GameData` (core) parses the command line, `Game` (game)
registers controls and loads all content into `GameData`, `Net`
(multiplayer) gets ready, `Sound` (audio) sets up the audio buses, then the main menu (ui) opens.

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
6. **The simulation stays pure.** core, cars, tracks, physics, race and ai
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
