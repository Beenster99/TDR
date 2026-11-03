# Pit crew: the crew, co-op pit stops and the rejoin band

## The crew

Every stop is played out top-down by the team's crew, the Le Mans way, and
the stop time is whatever that crew's timeline comes to
(`PitRules.crew_timeline`, kept in the stop's `work["crew"]` and drawn by
`PitCrews`): the car controller (lollipop); the refueller, who carries the
hose over from the rig and plugs it in, with the fire extinguisher and
cut-off valve attendants; a mechanic wiping the windscreen while the fuel
goes in; a mechanic on the air lance (the car rises on its air jacks); on
each side a **gun man** and a **wheel man**, front then rear (the gun man
undoes the nut, the wheel man pulls the old wheel, puts it down, picks up
the new one laid out by the corner and puts it on, the gun man does it up);
the cockpit helper for driver changes; mechanics for repairs; then the lance
out, the car down and the release. The fuel goes in first: the tyres only
start once the hose is off (`PitRules.TYRES_AFTER_FUEL`, the user's call,
as in the WEC rules).

Each team's crew is up to 5% quicker or slower than average (`crew_skill`;
a player's team is average), every job varies 4% from stop to stop, and 6%
of stops an AI wheel man fumbles a wheel (+1.5 s). The same race (seed)
gives the same stops. The HUD tells the driver the stop time against a
standard stop, and any fumble.

The crew are jointed figures (hips, knees, shoulders, elbows) in race suits
with helmets, gloves and boots. They carry what they work with: wheels in
both arms, the wheel gun, the hose nozzle, the windscreen cloth, the air
lance, the lollipop, the extinguisher. New tyres are laid out by each corner
with a coloured band for the compound (red dry, green intermediate, blue
wet), old ones are put down beside the car, the guns lie by the car until
their gun man picks them up, and the garage has a stack of each compound and
a trolley with the spare guns.

## Co-op pit stops (on by default)

The user's design (2026-11-03). Settings > Gameplay > **Co-op pit stops:
play your crew job**, per player (off: the AI does that player's jobs).

1. **The call.** The strategist calls the car in. The driver follows the pit
   guide line to the pit entry; once the car is in the lane the guide drives
   it to its box (`crew_auto`) and every player's camera closes in on the
   box, north up. On the pit wall the console steps aside for it.
2. **Fuel and windscreen.** The strategist (or the two-player pit wall) is
   the **fuel man**: grab the hose at the rig, plug it into the filler, and
   take it off when the gauge says the tank has the planned fuel. Off early,
   less fuel goes in (the stop result says how much); late, the flow has
   stopped and it's time lost. The driver is the **windscreen man**: hold
   use at the nose until it's clean.
3. **A third player** (pit crew role) gets to work as soon as the car is
   called in: lay out the right new tyres by each corner being changed
   (from the garage stacks: a wrong compound doesn't count, pick it back up)
   and a wheel gun each side (from the trolley). When the car stops, plug
   the air lance in at the back (the car rises). In a two-player crew the AI
   has the tyres and guns out already and does the lance.
4. **Tyres.** Once the hose is off, the driver and a pit crew player each
   do the tyre job they picked in the lobby: left / right **gun man** (pick
   up the gun with grab or the gun button, hold use at the wheel to undo the nut, wait for the wheel
   man, hold again and let go in the green to do it up, then the rear) or
   left / right **wheel man** (grab the old wheel once the nut is off, put
   it down out of the way, pick up the new one, grab at the hub to put it
   on, then the rear). The driver's tyre job starts once the windscreen is
   clean. Every other job is the AI's.
5. **Driver change.** If the strategist planned one, it happens at the same
   time (the stop lasts at least 5 s); otherwise the driver stays in.
6. **Release.** When the lollipop goes green the cameras pull out, the
   guide drives the car to the end of the pit lane and hands it back to the
   driver there, and the pit wall is back at its screens.

### Who does what

| Crew | Phase 1 | Tyres |
|---|---|---|
| Strategist / pit wall | fuel man | (done) |
| Driver | windscreen | their lobby pick |
| Pit crew (3rd player) | tyres and guns laid out after the call, air lance in at the stop | their lobby pick |
| One player on their own | (the AI crew do the whole stop) | |

The lobby's car share rows have a **Pit stop job** picker for the driver and
a pit crew player (left gun man, left wheel man, right gun man, right wheel
man; no two the same: `RaceEntry.share_pit_jobs`, kept as each crew member's
`pit_job`). The strategist's row says fuel man. After a driver change people
keep their pick; a clash goes to the first free job.

### Controls

| | Keyboard | Pad |
|---|---|---|
| Run | WASD / arrows | left stick |
| Grab (pick up, put down, plug in, take off) | G / X | X |
| Use (wheel gun, windscreen; hold) | Space / Enter | RT or A |

Grab and use are rebindable (Settings > Controller, "Pit crew: ...").

### Rules (race module)

- A stop never lasts longer than the crew's give-up time (`CREW_GIVE_UP` x
  the standard stop, or a driver change's minimum), whatever the players did.
- Single player has no crew game: the AI crew do the whole stop.
- Your crew member has a pulsing ring, an arrow overhead and a "YOU" tag; a
  team mate's is blue. Tips name your real buttons (`PitCrewGame.with_keys`).
  With no fuel to put in, the fuel man stands by at the rig.
- Before the car stops, each player's screen sends `crew: {job, play: true,
  lane_auto}` for each of its jobs (`PitRules.JOBS`: fuel, screen, lance,
  wheel_l, gun_l, wheel_r, gun_r; bits of `crew_play`). The tyres and guns
  laid out can come any time after the call (`{job: "lance", act: "tyre",
  wheel, compound}`, `{act: "gun", side}`). In the box: `{job: "lance", act:
  "in"}`, `{job: "fuel", act: "on" | "off"}`, `{job: "screen", act:
  "done"}`, `{job: "gun_l", act: "nut_off" | "nut_on", wheel}`, `{job:
  "wheel_l", act: "wheel_off" | "wheel_on", wheel}`.
- The machine that simulates the car stamps each step with its own stop
  clock, no earlier than the step before it allows (a player on another
  machine is a ping late), keeps them in `crew_jobs` and rebuilds the crew
  timeline with the players' steps in it (`_replay`). Until a player's step
  is done, everything after it (and the release) is unknown and the car
  waits. If it never comes (the player left), the crew send the car at 1.6x
  standard.
- An AI job next to a player's follows the player's times (an AI wheel man
  pulls the wheel just after a player gun man's nut comes off, and so on).
- Fuel actually put in is in the timeline's `fuel_l` and the stop's
  `last_stop.fuel_l`.
- `last_stop` and the `pit_stop` event carry `standard_s` and `played`.
- Multiplayer: all through `RaceSession.request_pit` like any pit call, and
  the timeline is part of the pit state everyone gets. Each player's crew
  member, and what they've put down where, goes to their team mates through
  the host a dozen times a second (`RaceSession.send_crew_pose`, signal
  `crew_pose`, unreliable); a team mate unheard for a second goes back to
  the AI's moves. Protocol 19.

## The rejoin band

`PitRules.rejoin_estimate(car)`: where the car comes back out after a clean
stop at standard pace, among the cars on track. The band on the circuit
marks the stretch whose traffic will be passing the pit exit as the car
leaves the lane; it slides up to the exit as the stop goes on. Green: clear
air; amber: a car within 1.5 s; red: within 0.6 s.

Shown to the driver while boxing and in the lane (3D band, minimap, and
"Rejoin P7, 1.2 s behind ..." in the pit panel), and always on the co-op
crew console, where the pit wall plans the stop from it.
