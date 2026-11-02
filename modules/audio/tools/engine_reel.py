#!/usr/bin/env python3
"""Renders a listening reel: every car in modules/cars/data idles, launches,
pulls through three gears, bangs off the rev limiter, then lifts off.
    python3 modules/audio/tools/engine_reel.py out_dir
Writes one WAV per car plus reel.wav (all cars in a row) and reel.txt (timings).
Uses the same synthesis as the game's baked loops (engine_synth.py)."""
import glob, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine_synth as es

SR = 44100


def family_for(car):
    """Mirror of CarAudio.engine_profile() (GDScript) for the reel."""
    e = car["engine"]
    given = e.get("sound", {})
    text = (car.get("description", "") + " " + car["id"]).lower()
    cyl = int(e.get("cylinders", 8))
    turbo = "turbo" in text
    if cyl >= 12: fam = "v12_na"
    elif cyl >= 10: fam = "v10_na"
    elif cyl >= 8:
        flat = "flat-plane" in text or (text.startswith("mid-engined") and "cross-plane" not in text)
        fam = ("v8_flat_" if flat else "v8_cross_") + ("turbo" if turbo else "na")
    elif cyl >= 5:
        if any(k in text for k in ("flat-six", "flat6", "boxer")): fam = "flat6_na"
        elif any(k in text for k in ("straight-six", "inline", "i6")): fam = "i6_turbo"
        else: fam = "v6_turbo" if turbo else "v6_na"
    else: fam = "i4_turbo"
    fam = given.get("family", fam)
    return fam, bool(given.get("turbo", turbo or fam.endswith("_turbo"))), bool(given.get("supercharged", "supercharg" in text))


def render_car(car):
    e = car["engine"]
    idle, red = float(e["idle_rpm"]), float(e["redline_rpm"])
    up = float(e.get("shift_up_rpm", red * 0.98))
    fam, turbo, sc = family_for(car)
    rng = np.random.default_rng(3)
    segs = []  # (seconds, rpm_from, rpm_to, load, limiter)
    segs.append((1.2, idle, idle, 0.0, False))
    segs.append((0.25, idle, idle * 2.6, 1.0, False))   # clutch drop
    lo = up * 0.68
    segs.append((1.8, idle * 2.6, up, 1.0, False))
    for g in range(2):
        segs.append((0.07, up, lo, 0.0, False))           # upshift cut
        segs.append((1.6 + 0.4 * g, lo, up if g == 0 else red, 1.0, False))
    segs.append((1.3, red, red, 1.0, True))               # limiter
    segs.append((2.2, red, idle * 1.4, 0.0, False))       # lift off
    segs.append((0.6, idle * 1.4, idle, 0.0, False))
    rpm, load = [], []
    lim_hz = 9.0 if turbo else 14.0
    for sec, a, b, l, lim in segs:
        n = int(sec * SR)
        t = np.arange(n) / SR
        r = a + (b - a) * (t / sec) ** (0.8 if b > a else 0.6)
        ld = np.full(n, l)
        if lim:
            ph = (t * lim_hz) % 1.0
            cut = ph < 0.4
            ld[cut] = 0.12
            r = red * (0.985 - 0.03 * (1 - ph))
        rpm.append(r); load.append(ld)
    rpm = np.concatenate(rpm); load = np.concatenate(load)
    load = np.convolve(load, np.ones(120) / 120, mode="same")
    on, _ = es.render_engine(fam, rpm, 1.0, SR, 11, circular=False)
    off, _ = es.render_engine(fam, rpm, 0.0, SR, 12, circular=False)
    rev = np.clip((rpm - idle) / (red - idle), 0, 1)
    x = on * np.sqrt(load) * (0.4 + 0.6 * rev) + off * np.sqrt(1 - load) * (0.3 + 0.25 * rev)
    n = len(x); t = np.arange(n) / SR
    if turbo:
        boost = np.convolve(load * np.clip((rpm - red * 0.35) / (red * 0.4), 0, 1), np.ones(SR // 4) / (SR // 4), mode="same")
        f = 3000 * (0.55 + 0.75 * boost * (0.5 + 0.5 * rev))
        x += 0.10 * boost * np.sin(2 * np.pi * np.cumsum(f) / SR)
    if sc:
        f = 1000 * (0.4 + 2.2 * rpm / red)
        x += 0.06 * (0.3 + 0.7 * load) * rev * np.sin(2 * np.pi * np.cumsum(f) / SR)
    # Overrun pops while lifting off.
    lift = np.where((load < 0.1) & (rev > 0.45))[0]
    es_sr = es.SR
    es.SR = SR
    for k in range(int(len(lift) / SR * 3)):
        i = int(rng.choice(lift))
        p = es.make_pop(int(rng.integers(100))) * rng.uniform(0.3, 0.8)
        m = min(len(p), n - i)
        x[i:i + m] += p[:m]
    es.SR = es_sr
    fade = np.minimum(1, np.minimum(t / 0.05, (t[-1] - t) / 0.2))
    x *= fade
    return x / (np.max(np.abs(x)) + 1e-9) * 0.85, fam


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "reel"
    os.makedirs(out, exist_ok=True)
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "cars")
    files = sorted(glob.glob(os.path.join(root, "data", "*.json")))
    reel, lines, pos = [], [], 0.0
    gap = np.zeros(int(0.8 * SR))
    for f in files:
        car = json.load(open(f))
        x, fam = render_car(car)
        es.write_wav(os.path.join(out, car["id"] + ".wav"), x, SR)
        lines.append("%5.1fs  %-28s %-15s redline %d" % (pos, car.get("name", car["id"]), fam, car["engine"]["redline_rpm"]))
        reel += [x, gap]
        pos += (len(x) + len(gap)) / SR
        print(lines[-1])
    es.write_wav(os.path.join(out, "reel.wav"), np.concatenate(reel), SR)
    open(os.path.join(out, "reel.txt"), "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
