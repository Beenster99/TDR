# AI drivers

Code: `modules/ai/`. Drivers: `modules/ai/data/drivers.json`.

## Traits

Every driver has eight traits from 0 to 1 (`DriverTraits`):

| Trait | What it does |
|---|---|
| pace | How much of the grip limit they use in corners and how late they brake. Slower drivers are also more patient with the throttle out of corners. |
| consistency | Lap-to-lap variation (only ever slower than their best) and how often they make mistakes. |
| aggression | A style, not a skill: shorter following gap, later braking, more kerb use, bolder passes and blocks, slightly more mistakes. |
| overtaking | How often they commit to a pass, and how long they keep at it. |
| defending | How often they cover the inside of the next corner when a car is right behind (one steady move, never under braking, never across a car that has already pulled alongside). |
| tyre_management | Backing off when tyres run hot, to bring them back into the window. |
| wet_skill | How much of the wet grip loss they cope with; low wet skill means extra margin and more mistakes in the wet. |
| composure | How well they avoid mistakes with a car right behind or alongside. |

Older files using `skill` and `racecraft` still load (skill = pace, racecraft = overtaking and defending).

## How the AI drives

- **Racing line:** the track's racing line (the fastest line for a GT3 car, see docs/ARCHITECTURE.md, Track data), squeezed a little towards the centre so it keeps its shape (wide entry, late apex, out to the edge) with room to spare at the edges.
- **Braking:** the plan allows less braking while the car is still turning (friction circle), so it slows before the second part of a chicane instead of running wide.
- **Speed:** a grip-based plan of corner speeds and braking points for its own car. The AI learns that plan during the race in 32 m sections: a section where it slid or ran wide is taken a little slower next time, a clean one a little faster, up to the driver's limit. New cars, tracks, physics changes and weather need no hand tuning.
- **Live grip:** tyre temperature, wet track (`SimEnvironment.grip_factor`) and darkness change what it dares.
- **Starts:** off the line each car holds its grid lane (its spot across the track) until the braking zone of the first corner, so the field goes two wide into turn 1 instead of filing onto the racing line, and follows the car ahead nose to tail rather than leaving a braking gap. Aggressive starters (chance 0.15 + 0.8 x aggression squared) floor it and spin the tyres, losing a little; the others feather the throttle when the rears spin.
- **Racing room (fair racing):** a car counts as alongside from the first bit of overlap (its nose level with our rear wheels), and the AI keeps 1.1 m clear of it. It holds that gap at its steering aim point too, so it never follows the racing line across the track into a car on the inside (turn-in) or the outside (exit). Demolition Derby is exempt: contact is the point there. `tests/racecraft_corners.gd` puts a car that ignores traffic on the AI's inside at every corner and counts contacts; `test_ai_racing_room` checks there are none.
- **Racecraft:** follows at a gap, picks a side (usually the inside of the next corner) and commits to a pass, leaves racing room alongside (the car further back lifts if there is no room), covers the inside when attacked, moves over for leaders lapping it, rejoins carefully after going off, and reverses out when stuck. The opening lap is calmer.
- **Mistakes:** now and then it brakes too late or runs wide. More often under pressure, at night, in the wet and for aggressive drivers.
- **Team radio:** rare messages (tyres, traffic, mistakes, weather, opening plan) through `RaceSim.post_event` when the race module has it.

`AIDriver.mood` says what a driver is doing right now: RACING, ATTACKING, DEFENDING, YIELDING, MISTAKE or RECOVERING.

## Difficulty

The host's **AI difficulty** (`RaceSettings.ai_difficulty`, 0 to 1) shifts every skill trait while keeping each driver's character: Rookie 0.25, Amateur 0.5, Pro 0.75 (drivers as written), Expert 0.9, Alien 1.0.

## Adding a driver

Add an entry to `drivers.json` with a unique `id`, a `name`, `number`, `nationality`, `age`, `team`, `style` (a label), `potential` (for future careers) and `traits`. No code needed.

## Tuning tools

- `tests/debug_ai.gd`: solo laps per car (`-- [laps] [pace] [car filter] [track]`).
- `tests/ai_race_report.gd`: an AI-only race with passes, contacts, offs and mistakes per driver (`-- [cars] [laps] [seed] [difficulty] [wetness] [trace driver] [trace from s] [class] [track]`).
