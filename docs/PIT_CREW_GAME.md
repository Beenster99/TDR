# Pit crew: the AI crew, the mini-game prototype and the rejoin band

## The AI crew (first pass, on for everyone)

Every stop is played out top-down by the team's AI crew, the Le Mans way,
and the stop time is whatever that crew's timeline comes to
(`PitRules.crew_timeline`, kept in the stop's `work["crew"]` and drawn by
`PitCrews`): the car controller (lollipop), the refueller with the fire
extinguisher and cut-off valve attendants, a mechanic on the air lance (the
car rises on its air jacks), two tyre changers working unaided, one down
each side, front then rear (nut off, wheel swap, nut on), two technicians
checking the old tyres, the cockpit helper for driver changes, mechanics
for repairs, then the lance out, the car down and the release. Tyres and
fuel still go on at the same time.

Each team's crew is up to 5% quicker or slower than average (`crew_skill`;
a player's team is average), every job varies 4% from stop to stop, and 6%
of stops fumble a wheel (+1.5 s). The same race (seed) gives the same stops.
The HUD tells the driver the stop time against a standard stop, and any fumble.

## The player mini-game (prototype, off by default)

The player leads their own pit crew at each stop, and how well they play
decides how long the car sits in the box. Rules in the race module
(`PitRules.crew_input`, `release_clear`, `crew_timeline`), the game itself in the
ui module (`PitCrewGame`), the rejoin band in graphics (`RejoinMarker`, through
`WorldView.set_rejoin`) and the HUD.

Settings > Gameplay > **Pit crew mini-game (prototype)**, off by default.
Off, the AI crew do the stop. The 2-player co-op version is being designed.

## Who plays

Whoever leads the car's pit crew: in a co-op crew the pit crew (or the
combined pit wall); otherwise the driver. While the pit guide brings the car
in, the driver's pedals do nothing, so the game uses them:

| | Keyboard | Pad |
|---|---|---|
| Crew calls, wheel gun, release | Throttle (W / Up) | RT (or A) |
| Cut the fuel | Brake (S / Down) | LT (or X) |

They follow Settings > Controller (Throttle and Brake).

## 1. Crew to stations (in the pit lane)

From the box call (or the limit line, when driving in by hand) a ring closes
on each station the stop needs: jacks, each tyre being changed, the fuel rig,
the wings, repairs. Press as it closes: within 0.07 s is perfect (that crew
member saves 0.05 s), within 0.18 s good. A missed call means that crew
member is late: the car waits 0.35 s for each one when it stops.

## 2. In the box

The jacks go up (1 s), then at the same time:

- **Wheel guns**, one tyre after another. The gauge fills as the nut goes
  on; 1.0 is the standard time for that tyre (the stop's tyre time shared
  out). Before 0.72 the wheel isn't on: it goes again (+0.3 s). 0.72-0.82
  perfect, up to 1.04 good, later slow; nobody presses: done at 1.4.
- **Fuel**: press brake to cut the fuel at the line. Early puts in less
  (that's what the car gets); nobody presses: the rig cuts out 0.6 s late.
- Wing changes and repairs take their time; then the jacks drop (1 s).

## 3. Release

The light turns green when no car is coming down the lane behind the box.
Press throttle to send the car (a standard release is 0.5 s after the jacks
drop; nobody presses: 0.9 s). Pressing on red is an **unsafe release**:
5 s penalty.

## How it changes the stop

- A played stop (the leader's screen sends `crew: {play: true}` when the game
  starts) waits in the box for the release (`crew: {release: true, fuel_l}`)
  and can't be quicker than 60% of the standard time. If no release ever
  comes (the leader left) the crew send the car at 1.6x standard.
- Standard = the stop time in docs/PITS.md. A sharp stop is about 20-25%
  quicker (a two-tyre + fuel stop: 5.1 s instead of 6.25 s in the test); an
  untouched one about 30% slower.
- `last_stop` and the `pit_stop` event carry `standard_s` and `played`.
- Multiplayer: the calls go through `RaceSession.request_pit` like any pit
  call, so a co-op pit crew plays for a car simulated on the driver's
  machine (their release arrives a ping later). Protocol 14.

## The rejoin band

`PitRules.rejoin_estimate(car)`: where the car comes back out after a clean
stop at standard pace, among the cars on track. The band on the circuit
marks the stretch whose traffic will be passing the pit exit as the car
leaves the lane; it slides up to the exit as the stop goes on. Green: clear
air; amber: a car within 1.5 s; red: within 0.6 s.

Shown to the driver while boxing and in the lane (3D band, minimap, and
"Rejoin P7, 1.2 s behind ..." in the pit panel), and always on the co-op
crew console, where the pit wall plans the stop from it.
