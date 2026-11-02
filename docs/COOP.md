# Co-op: sharing a car

Two or three players can race one car together, each with a role:

| Players | Roles |
|---|---|
| 1 | driver |
| 2 | driver, pit wall (pit crew and strategist in one) |
| 3 | driver, pit crew, strategist |

Only the driver's inputs steer the car. Everyone in the crew can make pit
calls (box, tyres, fuel, repairs) with `RaceSession.request_pit`.

## Forming crews in the lobby

Each player in the lobby has a row with two steppers (left/right on the
D-pad or arrow keys): their **car share** ("own car" or car share 1-8) and
their **role**. The host can set anyone's row; players set their own. A car
share holds up to three players and races the car of its first player
(lowest player number). The host keeps the roles valid: one driver, and the
rest shared out by `RaceEntry.share_roles`. Taking a role someone else
holds swaps it with them.

Command line (testing): `--team 1 --role pit_wall` joins car share 1 as pit
crew + strategist.

## Swapping roles in a race

`RaceSession.request_role_swap(car, peer_a, peer_b)` swaps two crew members'
roles. Any crew member may ask.

- Pit crew and strategist swap at once.
- A swap with the driver is a **driver change**. It waits until the car is
  stopped in its pit box, or happens at once on the grid before the start.
  `pending_swap(car)` shows a waiting change; `cancel_role_swap(car)` takes
  it back. The stop lasts at least `PitRules.DRIVER_CHANGE_S` (5 s) from the
  moment of the change.

### How the car moves to the new driver (Torque Shed style)

Each car is simulated on its driver's machine. At a driver change:

1. The old driver's machine sees the car in the box with a change waiting,
   stops simulating it, and sends the host the car's full state
   (`CarState.serialize()`: fuel, tyre temperatures and wear, damage) and
   its pit state (`PitRules.car_handover`).
2. The host swaps the roles, makes the new driver the car's owner and sends
   everyone the crew, the owner and that state (`Net._rpc_crew`).
3. The new driver's machine loads the state and carries on the stop and the
   race from exactly there. Everyone else keeps drawing the car from the
   stream as before.

If the driver leaves mid-race, the next crew member takes the wheel where
the car is; if nobody is left, the host's AI drives it.

## API for the role screens (multiplayer module)

- `RaceSession.team_car`: the car whose crew this player is in (-1 none).
- `RaceSession.local_car`: the car this player drives (-1 when not driving).
- `RaceSession.local_role`: `RaceEntry.ROLE_DRIVER`, `ROLE_PIT_CREW`,
  `ROLE_STRATEGIST` or `ROLE_PIT_WALL`. Use `RaceEntry.role_covers(role,
  duty)` to check a duty (pit wall covers both pit duties).
- Signals: `role_changed(role)` (this player), `crew_changed(car)` (any car),
  `team_radio(car, msg)`.
- `crew_of(car)`, `pending_swap(car)`, `request_role_swap`, `cancel_role_swap`.
- `send_team_radio(car, msg)`: msg `{kind: "ping"|"radio", code, text}`;
  `from` and `role` are filled in. Delivered to every crew member of that car.

Offline testing: `--single --role strategist` (or `pit_crew`, `pit_wall`)
puts you in your car's crew with the AI driving it.

## Tests

`tests/net_coop.sh`: a dedicated server and two clients share one car; the
pit wall player asks for the wheel, the change happens at the mandatory
stop, and the new driver brings the car home. `test_coop_roles` in
`tests/run_tests.gd` checks role sharing and the driver change in the box.
