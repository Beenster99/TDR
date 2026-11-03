# Audio

Every sound in Top Down Racer is synthesised. There are no recordings, so
there is nothing to license. The audio module (`modules/audio/`) only
listens to the race; it never changes it.

## Engines

Each car has an **engine family**. The family decides the character; the
car's own idle and redline decide where in the rev range it lives.

| Family | Sounds like | Cars now |
|---|---|---|
| `v8_cross_na` | cross-plane V8, no turbos: deep, lumpy burble | Mercedes-AMG GT3 |
| `v8_cross_turbo` | cross-plane V8, twin turbos: muffled thunder | front-engined V8 GT, safety car |
| `v8_flat_turbo` | flat-plane V8, twin turbos: rough rising howl | McLaren 720S GT3, mid-engined V8 berlinetta |
| `v8_flat_na` | flat-plane V8, no turbos: hard scream | (LMP2) |
| `v10_na` | V10 shriek | Lamborghini Huracan GT3 |
| `v12_na` | V12 silky howl | |
| `flat6_na` | flat-six: metallic, raspy scream | Porsche 911 GT3 R, rear-engined flat-six GT |
| `v6_turbo` | twin-turbo V6: raspy, busy hum | Ferrari 296 GT3, (hypercars, with `hybrid`) |
| `v6_na` | V6 growl | lightweight roadster (with its supercharger) |
| `i6_turbo` | twin-turbo straight-six: smooth, deep rasp | BMW M4 GT3 |
| `i4_turbo` | turbo four: buzzy drone | |

How a family is made (`modules/audio/tools/engine_synth.py`):

1. Every cylinder firing is an exhaust pulse placed at its real crank angle,
   in the real firing order and on the right bank. A cross-plane V8's banks
   fire unevenly (L R R L R L L R), which is the burble; a flat-plane V8
   alternates evenly, which is the scream. A V10 fires 5 times per turn, a
   V12 6, a six 3, a four 2.
2. Each bank's header pipe rings at its own pitch, cylinders differ a little,
   and every combustion is slightly different from the last.
3. The exhaust, silencer and turbo are a fixed tone shape in Hz (the
   family's "voice"). Because it doesn't move with the revs, the engine keeps
   its character from idle to the limiter.
4. Loops are baked on throttle and on the overrun at 14 rpm bands
   (900 to 11,000 rpm) into `modules/audio/baked/`.

In the game (`CarAudio`) the two bands either side of the revs are
crossfaded and their pitch nudged to the exact rpm; throttle and overrun are
crossfaded by the pedal. On top:

- **Rev limiter:** at the car's redline with the pedal down the ignition cuts
  in and out (about 14 times a second for engines without turbos, 9 with),
  so a 9,400 rpm Porsche and a 7,500 rpm AMG hit very different walls.
- **Gearshifts:** an upshift cuts the ignition for 85 ms with a paddle-shift
  clack; a downshift blips the throttle and may crackle.
- **Pops and crackles** when you lift off at high revs (most on cross-plane
  V8s).
- **Turbo:** whistle that builds with boost (with lag), wastegate flutter
  when you lift. **Supercharger** whine with revs. **Hybrid** motor whine
  with speed (deploying and harvesting). **Straight-cut gearbox** whine on
  race cars.
- **Clutch slip** off the line and **wheelspin** flare the revs.
- **Doppler:** cars passing you (or the camera) drop in pitch as they go by.

### Choosing a car's engine sound

Add an optional `sound` block to the car's `engine` in its JSON:

```json
"engine": { "cylinders": 6, "redline_rpm": 9000,
            "sound": { "family": "v6_turbo", "hybrid": true } }
```

Keys: `family`, `turbo`, `supercharged`, `hybrid`, `gear_whine` (default on
for race classes), `limiter_hz`, `pops` (0 none .. 1 lots). Without it the
family is worked out from `cylinders` and the description ("twin-turbo",
"flat-six", "straight-six", "Mid-engined ... V8" = flat-plane, etc.).

## Tyres and surfaces

- **Squeal** when cornering past the grip peak: a rough, low howl of
  rubber (racing tyres rasp, they don't whistle). **Scrub** just under it
  (your car), **lock-up / wheelspin / handbrake** rasp, **ABS chatter**
  under heavy braking with ABS on.
- Tyres only squeal on tarmac and kerbs. Sliding on **gravel**, **grass**,
  **dirt** or **mud** makes that surface's own noise: on rallycross and derby
  dirt a rumble that turns into a scrabble of grit and clods when the car
  slides, spins or locks its wheels (lower and duller in the wet: mud).
- **Road roar** rising with speed, **kerb** buzz whose pitch follows your
  speed, **gravel** crunch, **grass** swish, **wind**.
- **Rain:** on a wet track tyres hiss with **spray** instead of squealing.

## Buses

`Engine` (engines, turbos, pops, shifts), `Effects` (tyres, road, crashes,
start lights), `UI` (menus). Settings > Sound sets their volumes.

## Rebuilding the sounds

```
python3 modules/audio/tools/engine_synth.py              # all families and loops
python3 modules/audio/tools/engine_synth.py --only v10_na
python3 modules/audio/tools/engine_synth.py --passby gt3_passby.wav --family v8_cross_na
python3 modules/audio/tools/engine_reel.py reel/         # listen to every car
```

Needs Python 3 with numpy. `tests/audio_probe.gd` checks every baked loop
loads and loops and drives each car's sound through a launch, shifts, the
limiter, kerbs and gravel.
