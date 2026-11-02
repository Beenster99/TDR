# Business: money, upgrades and liveries

Wave 4. Every player has a team on their own machine (`user://profile.json`,
class `TeamProfile`): a budget, the upgrade levels bought for each car, and
each car's livery. Upgrades stay with the car between races and seasons.

## Money

- A new team starts with 150,000 cr.
- Every race pays prize money into the budget when it ends
  (`Economy.race_prize`): the winner of a 40 km race gets 40,000 cr, the last
  finisher 15% of that, retired cars 8%. Shorter races pay less (down to a
  quarter), longer ones more (up to 1.5x).
- Season rounds are paid by the season's own end-of-round hook, which can
  pass a `tier` multiplier for bigger events.
- Selling an upgrade back refunds half its price.

## Upgrades (R&D)

Six categories, each with levels 0 (stock) to 3. GT3 parts cost 1.6x Road car
parts. Numbers live in `modules/business/data/upgrades.json`.

| Category | Level 1 / 2 / 3 | Effect at level 3 | Looks |
|---|---|---|---|
| Engine | Stage 1 remap / Stage 2 intake and exhaust / Stage 3 race engine | torque curve x1.13 | |
| Aero | Front splitter / Sport rear wing / Race aero kit | downforce x1.30, drag x1.08 | deeper splitter, bigger wing (2, 3), canards (3) |
| Brakes | Performance pads / Big brake kit / Carbon-ceramic | brake force x1.20 | red, then gold calipers |
| Suspension | Lowering springs / Coilovers / Race suspension | grip x1.05, centre of gravity 3 cm lower | car sits up to 3 cm lower |
| Weight | Lightweight seats / Carbon panels / Full strip-out | mass x0.93 | |
| Tyres | Sport / Wider semi-slicks / Race tyres on forged wheels | grip x1.08 | wider tyres, gunmetal, gold, black rims |

How it reaches the car: `UpgradeCatalog.overrides_for(def, levels)` turns the
levels into `CarDefinition.with_overrides()` values computed from the car's
own stock spec, plus a `visual` block. The lobby sends them as the player's
`setup` (track tuning is merged into the same dictionary under `tuning`), the
host puts them on the race entry, and `RaceSim` builds the car from them.
`CarView` reads `def.raw.visual` to show the upgrade parts.

The upgrade parts are built into every car model by
`modules/graphics/tools/build_cars.py` (`splitter_up`, `wing_rear_up2`,
`wing_rear_up3`, `canards`) and hidden until a car has them. A car's shape
file can tune them with an `"upgrades"` block (`wing2`, `wing3`, `splitter`).

## Host option: Car upgrades

In race settings (`RaceSettings.upgrades_mode`):

- **On**: everyone races the cars they've upgraded.
- **Balanced (BoP)**: upgrades are for looks only; every car in a class
  (players and AI) gets a power and downforce adjustment so its
  power-to-weight and downforce-to-weight match the middle car of that class.
  The adjustment is written to the entry's `setup.bop`.
- **Off**: stock cars.

Track tuning has its own host switch and isn't touched by this option. AI
cars race stock (or balanced).

## Garage

Main menu (and lobby) > Garage. The car turns on a stand in 3D. Up/down
picks a row, left/right changes it: upgrade levels show as a preview (parts
on the car, stats compared with stock) until you press Buy. The livery
rows set the pattern and three colours, saved straight away; other players
see your livery online.

Testing: `--profile user://other.json` makes the menu use another team save.
`tests/garage_shot.tscn` saves a picture of the garage.
