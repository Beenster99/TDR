#!/usr/bin/env python3
"""Bakes the pit wall's radio voice: every phrase the pit wall says to the
driver, read by a neural text-to-speech voice and saved as short .ogg clips
in modules/audio/voice/<voice>/ with an index, phrases.json.

The game builds a message from these clips (RadioVoice / RadioPhrases):
whole lines where it has them ("Box, box. Box this lap."), and pieces for
the lines with numbers in ("Pressures" + "front left" + "twenty seven" +
"point five" + "psi"). A message it can't build from the clips falls back
to the computer's own voice.

The voices are Kokoro-82M (Apache 2.0, free for games, no attribution
needed), run with kokoro-onnx (MIT). Nothing from the TTS ships with the game
but the clips. Needs, at bake time only:

    python3 -m venv venv && venv/bin/pip install kokoro-onnx soundfile
    curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
    curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
    venv/bin/python modules/audio/tools/radio_voice_bake.py --model-dir <dir with the two files>

and ffmpeg on the PATH. Rerun it after adding a radio call or pit plan line
(tests/run_tests.gd checks every call and plan line can be built).
"""
import argparse
import glob
import json
import os
import re
import subprocess
import tempfile

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, "modules", "audio", "voice")

## voice folder -> Kokoro voice, speed. British voices: it's a British pit wall.
VOICES = {
    "engineer_male": ("bm_george", 1.08),
    "engineer_female": ("bf_emma", 1.08),
}

## The pit wall's ready-made calls (modules/ui/team_radio.gd CREW_CALLS),
## and what the driver might hear back on a co-driver's machine.
CALLS = [
    "Box, box. Box this lap.",
    "Stay out, stay out.",
    "Push now, we need the pace.",
    "Manage the tyres, they have to last.",
    "Save fuel: lift and coast where you can.",
    "Car behind is closing. Defend.",
    "You have the gap behind for a free stop.",
    "Rain is coming, be ready for a tyre call.",
    "Driver change at this stop.",
]
## Pit plan lines (modules/ui/pit_planner.gd message_lines) that never change.
PLAN_LINES = [
    "Plan for the next stop.",
    "No tyres.",
    "Fuel to the end.",
    "No fuel.",
    "We fix the damage.",
    "No repairs, we leave the damage.",
]
## Pieces for the lines with numbers or a choice of wheels in.
PIECES = [
    "Pressures", "psi", "and", "to", "litres of fuel",
    "Front downforce up", "Front downforce down", "Rear downforce up", "Rear downforce down",
    "front left", "front right", "rear left", "rear right",
]
## PitRules.WHEEL_LABELS except "all four" ("Four new slicks.").
WHEEL_LABELS = ["fronts", "rears", "left side", "right side", "front left", "front right", "rear left", "rear right"]

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def number_words(n: int) -> str:
    """Same as RadioPhrases.number_words (0..999)."""
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    rest = n % 100
    return ONES[n // 100] + " hundred" + ("" if rest == 0 else " and " + number_words(rest))


def key_of(text: str) -> str:
    """Same as RadioPhrases.key_of: lower case words, no punctuation."""
    t = text.lower().replace("-", " ")
    t = re.sub(r"[^a-z0-9' ]+", " ", t)
    return " ".join(t.split())


def compounds() -> list:
    names = []
    for path in sorted(glob.glob(os.path.join(ROOT, "modules", "physics", "data", "*.json"))):
        with open(path) as f:
            names.append(json.load(f)["name"].lower())
    return names


def phrases() -> list:
    out = list(CALLS) + list(PLAN_LINES) + list(PIECES)
    for name in compounds():
        out.append("Four new %ss." % name)
        out.append("New %ss" % name)
        for label in WHEEL_LABELS:
            out.append("New %ss, %s." % (name, label))
    out += [number_words(n) for n in range(0, 201)]
    out += ["point " + ONES[d] for d in range(1, 10)]
    seen, unique = set(), []
    for p in out:
        k = key_of(p)
        if k not in seen:
            seen.add(k)
            unique.append(p)
    return unique


def trim(samples: np.ndarray, rate: int) -> np.ndarray:
    """Cuts the silence either side, keeping 15 ms."""
    level = np.abs(samples)
    loud = np.where(level > 10 ** (-42 / 20))[0]
    if loud.size == 0:
        return samples
    pad = int(rate * 0.015)
    return samples[max(0, loud[0] - pad): min(samples.size, loud[-1] + pad)]


def radio_colour(samples: np.ndarray, rate: int) -> np.ndarray:
    """A light touch of radio: rolls off the deep lows and the very top, a
    little warmth, so it sits with the static without sounding like a phone."""
    spec = np.fft.rfft(samples)
    freqs = np.fft.rfftfreq(samples.size, 1.0 / rate)
    hp = 1.0 / np.sqrt(1.0 + (180.0 / np.maximum(freqs, 1.0)) ** 4)
    lp = 1.0 / np.sqrt(1.0 + (freqs / 6500.0) ** 4)
    presence = 1.0 + 0.25 * np.exp(-((freqs - 2500.0) / 900.0) ** 2)
    out = np.fft.irfft(spec * hp * lp * presence, samples.size)
    out = np.tanh(out * 1.6) / np.tanh(1.6)
    peak = np.max(np.abs(out)) or 1.0
    return (out / peak * 0.89).astype(np.float32)


def slug(text: str) -> str:
    return key_of(text).replace("'", "").replace(" ", "_")[:60]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--voice", choices=list(VOICES), action="append")
    args = ap.parse_args()
    import soundfile as sf
    from kokoro_onnx import Kokoro
    tts = Kokoro(os.path.join(args.model_dir, "kokoro-v1.0.onnx"), os.path.join(args.model_dir, "voices-v1.0.bin"))
    todo = phrases()
    for folder in args.voice or list(VOICES):
        voice, speed = VOICES[folder]
        dest = os.path.join(OUT, folder)
        os.makedirs(dest, exist_ok=True)
        for old in glob.glob(os.path.join(dest, "*.ogg")):
            os.remove(old)
        index = {}
        with tempfile.TemporaryDirectory() as tmp:
            for text in todo:
                samples, rate = tts.create(text, voice=voice, speed=speed, lang="en-gb")
                samples = radio_colour(trim(np.asarray(samples, dtype=np.float32), rate), rate)
                name = slug(text)
                wav = os.path.join(tmp, name + ".wav")
                sf.write(wav, samples, rate)
                subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", wav, "-c:a", "libvorbis",
                                "-q:a", "5", os.path.join(dest, name + ".ogg")], check=True)
                index[key_of(text)] = {"file": name + ".ogg", "s": round(samples.size / rate, 3)}
        with open(os.path.join(dest, "phrases.json"), "w") as f:
            json.dump({"voice": "Kokoro-82M " + voice, "licence": "Apache-2.0", "phrases": index}, f, indent=1,
                      sort_keys=True)
        print(folder, len(index), "phrases")


if __name__ == "__main__":
    main()
