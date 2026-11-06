# Pit stop planner

The strategist plans the whole next stop on one screen, then sends it. Until
Send, nothing reaches the car: the crew keeps its current plan and the driver
hears nothing.

## Opening it

- Co-op pit wall (CrewConsole): the first row, **Plan the stop**, on both tabs.
- Full pit wall (StrategistScreen, P): the **PIT STOP SETTINGS** button on the
  OUR CAR panel, or Enter. It opens as a dialog in the middle of the screen,
  titled PIT STOP SETTINGS.
- A driver can open it from the full pit wall to plan their own stop; then
  the button says **SET MY STOP** and no radio message goes out.

## The screen

Left, **CAR SETUP AT THE STOP**: the car seen from above in its colours,
nose up, with its four tyres, the front splitter and the rear wing. Beside
each tyre a card (with a line to its tyre) shows the tyre now: its compound
badge, a bar for how much tread is left and its temperature (blue cold,
green in the window, red hot); then what will be fitted (click to cycle
Keep / the car's slick / Intermediate / Full wet, mixing allowed; a dot
by the tyre marks the ones being changed) and its cold pressure with − / +,
and under it the standard pressure or what it was. Above the car the front
splitter and below it the rear wing, each on a segmented scale from less to
more downforce: a white tick where it is now, the bar filled to the planned
setting (yellow when it changes) and "5 → 7 (+2)". At the bottom the aero
balance: the front share of the downforce now (white) and after the stop
(yellow dot), with the change in total downforce and drag. Anything that
will change is drawn in yellow.

Right: picked tyres (All, Fronts, Rears, Left, Right, then a compound or a
pressure step for all of them), fuel, repairs, driver change (who takes
over), the box call (box this lap, or keep the plan for later), the work
queue in words with the stationary time and the total time lost, then
**Cancel**, **Start again** and **SEND TO DRIVER**.

Cancel (or Esc, ✕, B on a pad) closes the dialog at any time and drops
whatever wasn't sent: the next open starts from the plan the crew has. Send
gives the crew the plan, radios the driver and closes the dialog; the pit
wall says it was sent.

Pressures and downforce can only change when the host allows car setups
(race settings, Car setups: Free). Road cars have fixed wings.

## Mouse and keyboard

| Do | Mouse | Key |
|---|---|---|
| Pick a tyre | click it (Shift or Ctrl click adds) | 1-4 (Shift adds), A all |
| Compound for picked tyres | click a compound button | Q keep, W slick, E inter, R wet |
| Pressure for picked tyres | − / + buttons | ↑ ↓ |
| One tyre's pressure or compound | its card; wheel over the value | |
| Front / rear downforce | − / + or wheel | Z X / C V |
| Fuel, by the litre | − / + (1 L), −10 / +10, wheel over the value, To end, None; the line under it says how many litres go in, the laps they add and the laps in the tank after against laps to go | F G (Shift: 10 L) |
| Repairs, driver change, box | click | H, D, B |
| Send | SEND TO DRIVER | Enter |
| Start again from the car's plan | Start again | Backspace |
| Close | ✕ | Esc |

Right-click steps any value back. A controller still works: D-pad up/down
pressure, left/right compound for the picked tyres, A sends, B closes.

## What Send does

1. `RaceSession.request_pit` with `wheel_tyres` (per tyre), `psi` (per tyre),
   `setup` (wings), `fuel`, `repair` and `box`. The per-tyre plan is used at
   the next stop and then cleared, so later stops go back to the plain tyre
   call (HUD keys, AI, the pit crew tab).
2. The driver change as a role swap that waits for the car in its box
   (`request_role_swap`), or cancels one that was waiting.
3. A team radio message `{kind: "radio", code: "pit_plan", text, lines, say}`.
   The driver only hears it, nothing goes on the race screen: the radio
   click and squelch, static under the race engineer's voice, then the
   squelch tail (audio `Sound.radio`). `say` is the plan as spoken, with the
   driver change said without the player's name
   (`PitPlanner.spoken_lines`). Every pit wall call to the driver is read
   out the same way.

The race engineer's voice is recorded clips (audio `RadioPhrases`, baked by
`modules/audio/tools/radio_voice_bake.py` with the Kokoro neural voice,
Apache 2.0): whole lines where it has them, and pieces for numbers and wheel
choices. Settings > Sound has **Team radio** (volume) and **Radio voice**:
race engineer male or female, the computer's own voice (Windows SAPI), or
off. Only when the message can't be heard (voice off, or a line the clips
can't say and no computer voice) does the driver get the box on screen
instead, one job per line. A new radio call or plan line needs a re-bake;
`tests/run_tests.gd` (`test_radio_voice`) fails until it's there.

## Mixed tyres in the physics

`RaceSim.wheel_compounds[i]` holds the compound on each wheel; `compounds[i]`
is the one on most wheels (what timing, the AI and the HUD show). Each tyre's
grip, pressure, heat and wear come from its own compound, and each axle's
slip curve is the average of its two tyres. Per-tyre pressures are kept as a
trim on the setup's front/rear pressure (`pit["psi_trim"]`,
`CarState.psi_trim`). Both travel in the pit state, so clients and a driver
change (the car moving to another machine) keep them.

## Damage advice

When our car is damaged (LIGHT or worse), OUR CAR on the Strategist screen
shows a DAMAGE card where the setup normally is (the setup is still in PIT
STOP SETTINGS). `DamageAdvice.assess` (telemetry) works it out:

- **How bad:** SCUFFS (below `PitRules.REPAIR_MIN`, the crew won't touch it),
  LIGHT, MODERATE, HEAVY, or CRITICAL (a flat tyre, a leaking engine, a
  gearbox losing gears).
- **Lap time lost:** an estimate per part from `DamageAdvice.LOSS`, the share
  of a clean lap each part costs, measured with `tests/damage_pace_probe.gd`
  (a GT3 at Brands Hatch, Spa and Monza), times the car's 5-lap average.
- **Repair time:** exactly what the stop would take, from
  `PitRules.service_for` / `repair_parts` (the same rule for every car).
- **The call:** the time lost to the flag staying damaged against the cost
  of fixing it. With a stop due anyway (a mandatory stop, not enough fuel or
  a tyre that won't last) the cost is the repair time: FIX AT YOUR STOP, or
  BOX NOW if it costs 0.8 s a lap or more; STOP, BUT DON'T REPAIR when the
  repair costs more than it saves. With no stop due the cost is a stop just
  for the repairs (tyres kept, no fuel): BOX NOW or STAY OUT, with the laps to
  go from which a stop would pay. Within 2.5 s it is YOUR CALL. A flat tyre
  or a leaking engine is always BOX NOW. The places the repair would give
  away (cars behind within the time it costs) are named.

The pit stop settings show the call in one line under Repairs.

## Tests

- `tests/run_tests.gd` (pit tests) for the rules.
- `godot --headless --path . res://tests/planner_check.tscn`: a real race,
  you on the pit wall with your AI co-driver driving; plans a mixed-tyre stop
  with pressures, downforce, fuel and a driver change, sends it and checks
  the stop fitted it. With xvfb, `-- out.png` saves shots of the planner,
  the console and the driver's screen.
- `tests/damage_advice_shot.tscn`: damages our car five ways and checks the
  advice (with xvfb, `-- <prefix>` saves the Strategist screen for each).
