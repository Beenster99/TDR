# Co-op pit wall: pit crew and strategist

Wave 5. When two or three players share a car (co-op), one drives and the
others run the pit wall:

| Players in the car | Roles |
|---|---|
| 3 | driver, pit crew, strategist |
| 2 | driver, pit wall (pit crew + strategist in one) |

Roles, swaps and the network live in the multiplayer module (`RaceSession`:
`team_car`, `local_role`, `request_role_swap`, `send_team_radio`, see its
docs). This page is about the screens (ui module: `CrewConsole`,
`TeamRadio`) and the pit-stop setup changes (race module: `PitRules`).

## The console

A player in a car's crew who is not driving sees the race in full 3D in the
middle of the screen, zoomed out to the whole track with every car (zoom in
and out with the right stick, R3 for the whole track and back), with the
console around it:

- **Left: timing.** Every car's position, gap, last lap (purple = fastest),
  tyre compound and stint age, and stops. Our car is marked yellow, the car
  the strategist is watching blue (also ringed on the 3D view).
- **Right: the role's panel.** With the combined role, Y / C switches
  between the two tabs.
- **Bottom: team radio** with the driver, and the latest race control call.

### Pit crew

Calls the stop and prepares it:

- **Pit call**: box this lap / stay out (the driver hears it on the radio too).
- **Tyres**: auto (suits the weather), the car's dry tyre, intermediates,
  full wets, no change.
- **Fuel**: enough to finish, none, or 5 L steps up to a full tank.
- **Repairs**: fix everything or nothing (when damage is on).
- **Setup changes** (when the host allows car setups): front splitter, rear
  wing and tyre pressures, applied while the car is in the box. Wing changes
  take 2.5 s each and new pressures without new tyres 4 s; both happen while
  the tyres are being changed, so with new tyres they usually cost nothing.
- **The stop**: how long it will take, what it does, the time lost in all,
  and where a stop now would rejoin.
- **The car**: each tyre's temperature (colour), wear left, punctures; fuel
  and laps it lasts against laps to go; damage to aero, suspension, engine
  and gearbox.

### Strategist

Reads the race (built on the pit wall race data, `RaceTelemetry`):

- the cars just ahead and behind: gap and whether we're closing or losing on
  the last-5-lap average;
- the pit window: stop now = time lost, rejoin position, clear air or
  traffic, the gap behind needed for a free stop, mandatory stops left and
  the window, fuel against laps to go;
- the next weather change with its ETA and confidence;
- **pace**: who is fastest on the last lap, over the last 3 laps and over
  the last 5 laps (in our class in a multi-class race), with where we rank
  and how far off we are; the next backmarkers up the road and how far;
- **our rival**, the car we're really racing (`RaceTelemetry.rival_of`: in
  our class and on our lap, the nearer of the cars just ahead and behind):
  orange in the timing, ringed in orange on the 3D view, first in the
  rivals list. Backmarkers (a lap or more down on us) carry a blue "+1L"
  tag in the timing, and the next ones up the road get blue rings;
- rivals (our rival, the watched car, the cars around, the leaders): tyres
  and their age, stops, pace, and their latest strategy call;
- **Full pit wall** (or P) opens the full-screen strategist screen with the
  weather radar and every car's sector times. Its timing panel has a PACE
  view (click the tab or press Tab): one table of every car with its last
  lap, last 3 and last 5 laps (each with its rank and the gap to us), best
  lap and race gap. Click a heading to sort on it, again to turn it round.
  Our rival and the backmarkers are marked. Any car can be made the rival there with **MARK AS
  RIVAL** on the selected car panel (and back to the worked-out one with
  **AUTO RIVAL**).
- **The rejoin band** (green / amber / red on the track where a stop now
  would come out) is drawn only for the strategist (and the combined pit
  wall role), never on the driver's screen.
- **Onboard camera**: a live picture-in-picture window, top right of the 3D
  view, from any car's front camera (on the roof, looking ahead) or rear
  camera (looking back over the wing). Pick the car on the *Onboard camera*
  row (every car, ours included, in running order) and front / rear / off
  on the *Camera view* row. It starts on our car's front camera. In the full
  pit wall, Y / C shows the selected car's onboard camera where the feed
  was (front, rear, off). It works online too: every machine draws it from
  its own copy of the race, so nothing extra goes over the network.

### Radio

X / V (pad / keyboard) opens the calls to the driver: box this lap, stay
out, push, look after the tyres, save fuel, defend, gap for a free stop,
rain coming, driver change at this stop. The driver sees them as a banner on
the HUD (with a chime) and can answer with Back / V: copy, box this lap?,
tyres are gone, I have damage, track getting wet, negative, stuck in
traffic, how's the fuel?

### Role swaps

When there's another player in the crew, the last row swaps roles with them.
A swap that involves the driver waits for the next pit stop (the console
shows it's waiting; press A again to cancel). After a swap the screen
changes over by itself: the new driver gets the HUD and the controls, the
old driver the console.

### Moving the panels

Every panel on the console (timing, the pit crew / strategy panel, team
radio and the onboard camera picture) and on the full pit wall (timing,
weather radar, selected car, feed, onboard picture) can be moved, zoomed and
resized with the mouse:

- drag a panel's title bar (the strip along its top, marked with six dots)
  to move it; drag the onboard picture from anywhere on it;
- drag the grip in a panel's bottom right corner to zoom it: the whole
  panel, text included, gets bigger (up to 200 %) or smaller (down to 60 %),
  so the data is easier to read; the size shows while you drag;
- drag a panel's right or bottom edge to make it wider or taller without
  changing the text size (every panel has a smallest size that still fits
  its contents);
- the onboard picture resizes from its corner and stays 16:9;
- panels snap to the screen edges and line up next to each other;
- a click on a title bar that doesn't move still clicks what's there.

On the console the 3D race frames itself in the biggest space the panels
leave free. The layout is saved (`GameData.prefs["pit_wall_layout"]`, one
for the console and one for the full pit wall) and comes back next race.
**Reset layout** in the header puts everything back. Code: `PanelLayout`
(ui); check: `tests/pit_wall_layout_check.tscn`.

## Controls (console)

| | Keyboard | Pad |
|---|---|---|
| Choose a row | Up / Down | D-pad up / down |
| Change a value | Left / Right | D-pad left / right |
| Act (toggle, open, swap) | Enter / Space | A |
| Switch tab (combined role) | C | Y |
| Radio the driver | V | X or Back |
| Full pit wall | P | from the strategy tab |
| Zoom | E / Q, wheel | right stick, LB / RB |
| Whole track and back | Z / Tab | R3 |

## Testing alone

`--role pit_crew`, `--role strategist` or `--role pit_wall` with `--single`
puts you on the pit wall of your own car with the AI driving it.
