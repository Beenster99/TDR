# Pit crew: the AI crew, the wheel gunner mini-game and the rejoin band

## The AI crew (first pass, on for everyone)

Every stop is played out top-down by the team's AI crew, the Le Mans way,
and the stop time is whatever that crew's timeline comes to
(`PitRules.crew_timeline`, kept in the stop's `work["crew"]` and drawn by
`PitCrews`): the car controller (lollipop), the refueller with the fire
extinguisher and cut-off valve attendants, a mechanic on the air lance (the
car rises on its air jacks), two tyre changers working unaided, one down
each side, front then rear (nut off, wheel swap, nut on), two technicians
checking the old tyres, the cockpit helper for driver changes, mechanics
for repairs, then the lance out, the car down and the release. The fuel goes
in first: the wheel guns only start once the hose is off
(`PitRules.TYRES_AFTER_FUEL`, the user's call, as in the WEC rules).

Each team's crew is up to 5% quicker or slower than average (`crew_skill`;
a player's team is average), every job varies 4% from stop to stop, and 6%
of stops fumble a wheel (+1.5 s). The same race (seed) gives the same stops.
The HUD tells the driver the stop time against a standard stop, and any fumble.

## The mini-game: "Two guns" (co-op, off by default)

The co-op concept the user picked (2026-11-02; the other ideas are in the
co-op ideas doc). Each player **is** one of the two wheel gunners, working
in the real 3D pit box seen from above. The AI crew do everything else
(lollipop, fuel, air lance, release), and the car drops once both sides are
done, so how well the gunners play decides the stop time. Rules in the race
module (`PitRules.crew_input`, `crew_timeline`), the game in the ui module
(`PitCrewGame`), the player's mechanic drawn by graphics
(`PitCrews.drive_gunner`, `wheel_spot`), the close camera in the race scene.

Settings > Gameplay > **Pit crew mini-game: be a wheel gunner**, off by
default, per player. A side nobody plays is the AI's.

### Who guns which side

| Crew | Left gunner (front left, rear left) | Right gunner |
|---|---|---|
| One player driving | the driver | AI |
| Driver + pit wall / pit crew | the driver | the team mate |
| Pit wall player, AI co-driver driving | the pit wall player | AI |
| Strategist (3-player crew) | doesn't gun | |

The pit guide drives the car down the lane and into the box, so the
driver's hands are free.

### Controls

| | Keyboard | Pad |
|---|---|---|
| Run | WASD / arrows | left stick |
| Wheel gun (hold) | Space / Enter | RT or A |

The wheel gun is rebindable (Settings > Controller, "Pit crew: wheel gun").
While a player is gunning, the camera closes in on the box (15 m across,
north up) and goes back when the car leaves.

### A stop

1. **In the lane:** run your mechanic to your front wheel.
2. **Fuel first:** the tyres wait until the fuel is in
   (`PitRules.TYRES_AFTER_FUEL`); the gun does nothing before then.
3. **Nut off:** at a wheel, hold the gun for 0.45 s. The old wheel comes off
   and the new one goes on by itself (`PitRules.GUN_SWAP_S`, 1.1 s).
4. **Nut on:** hold the gun again and let go in the green. The gauge's 1.0
   is a standard 0.7 s: let go before 0.72 and the nut is loose (go again),
   0.72-0.82 perfect, up to 1.04 good, later slow; held on, the gun finishes
   it at 1.4.
5. Run to your rear wheel and do it again. When both sides are done the
   lance comes out, the car drops and the lollipop sends it.

### How it changes the stop

- Before the car stops, each gunner's screen sends `crew: {side, play: true}`.
  In the box they send `crew: {side, wheel, nut: "off" | "on"}` as they do
  each wheel. The machine that simulates the car stamps them with its own
  stop clock (a gunner on another machine is a ping late) and rebuilds the
  crew timeline with the players' wheels in it (`PitRules._replay`): until a
  player's last wheel is on, the release is unknown and the car waits. If it
  never comes (the player left), the crew send the car at 1.6x standard.
- Standard = the stop time in docs/PITS.md. With one player, the AI's side
  sets the pace and a slow player holds the car; two sharp gunners beat the
  standard (in the test: 10.7 s against 11.7 s with four tyres and 9 L).
- `last_stop` and the `pit_stop` event carry `standard_s` and `played`.
- Multiplayer: all through `RaceSession.request_pit` like any pit call, and
  the timeline is part of the pit state everyone gets. Another machine draws
  a remote gunner from their reported wheels (kneeling until a nut is done,
  carrying the wheel during the swap). Protocol 14.

Next, from the co-op ideas doc: the driver brakes onto the marks themselves,
both gunners on one screen, then a player as the refueller.

## The rejoin band

`PitRules.rejoin_estimate(car)`: where the car comes back out after a clean
stop at standard pace, among the cars on track. The band on the circuit
marks the stretch whose traffic will be passing the pit exit as the car
leaves the lane; it slides up to the exit as the stop goes on. Green: clear
air; amber: a car within 1.5 s; red: within 0.6 s.

Shown to the driver while boxing and in the lane (3D band, minimap, and
"Rejoin P7, 1.2 s behind ..." in the pit panel), and always on the co-op
crew console, where the pit wall plans the stop from it.
