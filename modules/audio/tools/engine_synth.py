#!/usr/bin/env python3
"""Bakes every engine, turbo, tyre and road sound the game uses.

All sounds are synthesised from scratch here (no recordings, so nothing to
license). Run it after changing a family below:

    python3 modules/audio/tools/engine_synth.py            # writes modules/audio/baked/
    python3 modules/audio/tools/engine_synth.py --passby out.wav   # splash-screen pass-by

How an engine is made (see docs/AUDIO.md for the plain version):
  * Every cylinder firing is an exhaust pulse placed at its real crank angle
    (firing order and bank), so a cross-plane V8 burbles, a flat-plane V8
    screams, a V10 shrieks and a flat-six rasps for the same reason the real
    ones do.
  * Each bank has its own header pipe ringing at its own frequency.
  * The exhaust/muffler/turbo "voice" is a fixed EQ in Hz. Because it doesn't
    move with revs, the engine keeps its character across the rev range
    (the thing that makes pitch-shifted single loops sound like a toy).
  * Loops are baked at many rpm bands; the game crossfades the two nearest
    bands and only nudges the pitch a little.
Needs numpy only.
"""
import argparse
import json
import math
import os
import struct
import sys

import numpy as np

SR = 32000  # loops; the pass-by renders at 44.1 kHz
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "baked")
BANDS = [900, 1500, 2200, 3000, 3800, 4600, 5400, 6200, 7000, 7800, 8600, 9400, 10200, 11000]

# Firing events: (crank angle in a 720-degree cycle, cylinder, bank).
def even(n, banks):
    step = 720.0 / n
    return [(i * step, i, banks[i % len(banks)]) for i in range(n)]

CROSS_V8 = [(i * 90.0, c, b) for i, (c, b) in enumerate(
    [(1, 0), (8, 1), (4, 1), (3, 0), (6, 1), (5, 0), (7, 0), (2, 1)])]  # 1-8-4-3-6-5-7-2: L R R L R L L R

# Each family: firing pattern, header pipe Hz per bank, voice EQ peaks
# (Hz, octave width, dB), low-pass corner, how raspy / driven / uneven it is.
FAMILIES = {
    "v8_cross_na": dict(fire=CROSS_V8, pipe=[140, 182], bank_gain=[1.0, 0.5], header_skew=9.0,
                        peaks=[(70, 0.9, 8), (240, 0.9, 4), (520, 1.0, 1), (1400, 1.0, -4)],
                        lp=3200, lp_order=2, rasp=0.22, drive=2.2, jitter=0.10, mech=0.03,
                        label="cross-plane V8, no turbos: deep, lumpy burble (AMG 6.2)"),
    "v8_cross_turbo": dict(fire=CROSS_V8, pipe=[165, 200], bank_gain=[1.0, 0.7], header_skew=5.0,
                           peaks=[(110, 0.8, 6), (300, 0.9, 3), (1100, 1.0, -3)],
                           lp=2000, lp_order=2, rasp=0.14, drive=1.7, jitter=0.07, mech=0.02, turbo=True,
                           label="cross-plane V8 with twin turbos: muffled thunder (AMG 4.0)"),
    "v8_flat_na": dict(fire=even(8, [0, 1]), pipe=[260, 268], bank_gain=[1.0, 0.95], header_skew=1.0,
                       peaks=[(480, 0.8, 3), (1900, 0.7, 6), (3400, 0.6, 3)],
                       lp=6000, lp_order=2, rasp=0.32, drive=2.4, jitter=0.05, mech=0.05,
                       label="flat-plane V8, no turbos: hard, high scream (LMP2 / 458)"),
    "v8_flat_turbo": dict(fire=even(8, [0, 1]), pipe=[240, 252], bank_gain=[1.0, 0.92], header_skew=1.5,
                          peaks=[(380, 0.8, 4), (1400, 0.8, 3), (2600, 0.7, -2)],
                          lp=2800, lp_order=2, rasp=0.24, drive=1.9, jitter=0.05, mech=0.03, turbo=True,
                          label="flat-plane V8 with twin turbos: rough, rising howl (McLaren 720S, Ferrari F8)"),
    "v10_na": dict(fire=even(10, [0, 1]), pipe=[300, 318], bank_gain=[1.0, 0.9], header_skew=1.0,
                   peaks=[(330, 0.8, 2), (1750, 0.6, 7), (3100, 0.6, 4)],
                   lp=7500, lp_order=2, rasp=0.34, drive=2.4, jitter=0.05, mech=0.05,
                   label="V10, no turbos: shrieking wail (Huracan)"),
    "v12_na": dict(fire=even(12, [0, 1]), pipe=[340, 350], bank_gain=[1.0, 0.95], header_skew=0.5,
                   peaks=[(600, 0.8, 3), (2300, 0.6, 6), (4200, 0.6, 3)],
                   lp=8500, lp_order=2, rasp=0.22, drive=1.8, jitter=0.03, mech=0.04,
                   label="V12, no turbos: smooth, silky howl"),
    "flat6_na": dict(fire=even(6, [0, 1]), pipe=[290, 300], bank_gain=[1.0, 0.95], header_skew=1.5,
                     peaks=[(650, 0.7, 3), (1550, 0.5, 5), (2750, 0.35, 7), (4300, 0.5, 2)],
                     lp=7000, lp_order=2, rasp=0.55, drive=2.8, jitter=0.06, mech=0.14,
                     label="flat-six, no turbos: metallic, raspy scream (Porsche 911 GT3)"),
    "v6_turbo": dict(fire=even(6, [0, 1]), pipe=[250, 262], bank_gain=[1.0, 0.92], header_skew=1.0,
                     peaks=[(430, 0.8, 3), (1650, 0.7, 4), (2900, 0.6, 1)],
                     lp=2600, lp_order=2, rasp=0.24, drive=1.8, jitter=0.05, mech=0.03, turbo=True,
                     label="V6 with twin turbos: raspy, busy hum (Ferrari 296, hypercars)"),
    "v6_na": dict(fire=even(6, [0, 1]), pipe=[210, 222], bank_gain=[1.0, 0.9], header_skew=2.0,
                  peaks=[(300, 0.8, 4), (1150, 0.8, 3), (2400, 0.7, 0)],
                  lp=4000, lp_order=2, rasp=0.3, drive=2.0, jitter=0.06, mech=0.05,
                  label="V6, no turbos: throaty growl (Lotus V6)"),
    "i6_turbo": dict(fire=even(6, [0, 1]), pipe=[205, 215], bank_gain=[1.0, 0.97], header_skew=0.5,
                     peaks=[(240, 0.8, 3), (880, 0.8, 4), (1900, 0.7, 2)],
                     lp=2300, lp_order=2, rasp=0.16, drive=1.6, jitter=0.035, mech=0.03, turbo=True,
                     label="straight-six with twin turbos: smooth, deep rasp (BMW M4)"),
    "i4_turbo": dict(fire=even(4, [0]), pipe=[190], bank_gain=[1.0], header_skew=0.0,
                     peaks=[(190, 0.8, 4), (700, 0.8, 3), (1700, 0.7, -1)],
                     lp=2400, lp_order=2, rasp=0.2, drive=1.9, jitter=0.05, mech=0.04, turbo=True,
                     label="four-cylinder with a turbo: buzzy drone"),
}


# --------------------------------------------------------------------------
# Building blocks

def fft_filter(x, H_of_f, sr, circular=True):
    """Filters x by a zero-phase magnitude response. Circular keeps loops seamless."""
    n = len(x) if circular else 1 << int(math.ceil(math.log2(len(x) * 1.25 + 16)))
    X = np.fft.rfft(x, n)
    f = np.fft.rfftfreq(n, 1.0 / sr)
    y = np.fft.irfft(X * H_of_f(f), n)
    return y[: len(x)]


def fft_convolve(x, k, circular=True):
    if circular:
        n = len(x)
        kk = np.zeros(n)
        m = min(len(k), n)
        kk[:m] += k[:m]
        if len(k) > n:  # wrap the tail
            for s in range(n, len(k), n):
                seg = k[s: s + n]
                kk[: len(seg)] += seg
        return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(kk), n)
    n = 1 << int(math.ceil(math.log2(len(x) + len(k))))
    return np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(k, n), n)[: len(x)]


def peak_eq(f, peaks):
    h = np.ones_like(f)
    lf = np.log2(np.maximum(f, 1.0))
    for f0, width, db in peaks:
        g = 10 ** (db / 20.0)
        h *= 1.0 + (g - 1.0) * np.exp(-0.5 * ((lf - math.log2(f0)) / (width * 0.5)) ** 2)
    return h


def lowpass(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def highpass(f, fc, order=2):
    r = (np.maximum(f, 1e-3) / fc) ** (2 * order)
    return np.sqrt(r / (1.0 + r))


def bandnoise(n, sr, lo, hi, rng, circular=True):
    x = rng.standard_normal(n)
    return fft_filter(x, lambda f: highpass(f, lo, 2) * lowpass(f, hi, 2), sr, circular)


def normalise(x, rms=0.2, peak=0.97):
    r = math.sqrt(float(np.mean(x * x))) + 1e-12
    x = x * (rms / r)
    p = float(np.max(np.abs(x)))
    if p > peak:
        x = x * (peak / p)
    return x


def write_wav(path, x, sr, loop=False, stereo=None):
    """16-bit WAV; loops carry a 'smpl' chunk so Godot imports them looping."""
    if stereo is not None:
        data = np.stack([x, stereo], axis=1).reshape(-1)
        ch = 2
    else:
        data = x
        ch = 1
    pcm = (np.clip(data, -1.0, 1.0) * 32000.0).astype("<i2").tobytes()
    chunks = b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, sr, sr * 2 * ch, 2 * ch, 16)
    chunks += b"data" + struct.pack("<I", len(pcm)) + pcm
    if len(pcm) % 2:
        chunks += b"\0"
    if loop:
        frames = len(x)
        smpl = struct.pack("<9I", 0, 0, int(1e9 / sr), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, frames - 1, 0, 0)
        chunks += b"smpl" + struct.pack("<I", len(smpl)) + smpl
    with open(path, "wb") as fh:
        fh.write(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


# --------------------------------------------------------------------------
# Engines

def render_engine(fam, rpm, load, sr, seed, circular, n_samples=None):
    """rpm: scalar (loop) or per-sample array. load 0 (overrun) .. 1 (full throttle)."""
    p = FAMILIES[fam]
    rng = np.random.default_rng(seed)
    if np.isscalar(rpm):
        cyc = int(round(sr * 120.0 / rpm))
        n_cycles = max(3, int(round(0.75 * sr / cyc)))
        n = cyc * n_cycles
        phase = np.arange(n) / cyc  # engine cycles (720 deg)
        rpm_mean = sr * 120.0 / cyc
    else:
        rpm = np.asarray(rpm, float)
        n = len(rpm)
        phase = np.cumsum(rpm / 120.0 / sr)
        n_cycles = int(phase[-1]) + 1
        rpm_mean = float(np.mean(rpm))
    rev = min(max(rpm_mean / 9000.0, 0.0), 1.2)
    n_banks = len(p["pipe"])
    cyl_ids = sorted({c for _, c, _ in p["fire"]})
    # Fixed per-cylinder character: slightly different pulse strength and
    # header length (cross-plane V8s have very unequal headers).
    lope = 0.08 + 0.12 * max(0.0, 1.0 - rpm_mean / 3000.0) * (p["header_skew"] / 7.0)
    cyl_gain = {c: 1.0 + lope * rng.standard_normal() for c in cyl_ids}
    cyl_skew = {c: p["header_skew"] * rng.standard_normal() for c in cyl_ids}
    jit = p["jitter"] * (1.0 + 2.0 * max(0.0, 1.0 - rpm_mean / 2500.0)) * (1.0 if load > 0.5 else 1.8)
    amp_load = 0.18 + 0.82 * load
    imps = [np.zeros(n) for _ in range(n_banks)]
    env = np.zeros(n)
    for c in range(n_cycles if circular else n_cycles + 1):
        for ang, cyl, bank in p["fire"]:
            target = c + (ang + cyl_skew[cyl]) / 720.0 + 0.002 * rng.standard_normal()
            if circular:
                pos = (target * cyc) % n
            else:
                pos = float(np.searchsorted(phase, target))
                if pos >= n - 2:
                    continue
            a = amp_load * cyl_gain[cyl] * max(0.05, 1.0 + jit * rng.standard_normal())
            if load < 0.5 and rng.random() < 0.06:
                a *= rng.uniform(1.5, 2.6)  # uneven overrun pulse
            i0 = int(pos)
            fr = pos - i0
            i1 = (i0 + 1) % n
            imps[bank][i0] += a * (1 - fr) * p["bank_gain"][bank]
            imps[bank][i1] += a * fr * p["bank_gain"][bank]
            env[i0] += a * (1 - fr)
            env[i1] += a * fr
    # Pulse shape per bank: blow-down pressure bump + ringing header + a crack.
    L = int(0.045 * sr)
    t = np.arange(L) / sr
    out = np.zeros(n)
    bright = 0.35 + 0.65 * load
    for b in range(n_banks):
        f1 = p["pipe"][b]
        bump_len = 0.0016
        bump = np.where(t < bump_len, np.sin(np.pi * t / bump_len), 0.0)
        ring = np.zeros(L)
        for m in range(1, 7):
            fm = f1 * m * (1.0 + 0.012 * (m - 1))
            if fm > sr * 0.45:
                break
            tau = 0.010 / math.sqrt(m) * (1.0 if load > 0.5 else 0.6)
            ring += (1.0 / m ** (1.3 - 0.5 * bright)) * np.exp(-t / tau) * np.sin(2 * np.pi * fm * t + 0.3 * m)
        crack = rng.standard_normal(L) * np.exp(-t / 0.0004) * 0.25 * bright
        k = bump * 1.0 + ring * 0.55 + crack
        out += fft_convolve(imps[b], k, circular)
    # Flow / combustion rasp: noise riding on each pulse.
    env_k = np.exp(-t / (0.0025 + 0.002 * (1 - load)))
    renv = fft_convolve(env, env_k, circular)
    rasp = rng.standard_normal(n) * renv
    rasp = fft_filter(rasp, lambda f: highpass(f, 400, 1) * lowpass(f, 4000, 1), sr, circular)
    sig_rms = math.sqrt(float(np.mean(out ** 2))) + 1e-9
    rasp *= sig_rms / (math.sqrt(float(np.mean(rasp ** 2))) + 1e-9) * p["rasp"] * (0.4 + 0.8 * load)
    # Mechanical: valve train and gear chatter, more at high revs.
    mech = bandnoise(n, sr, 2500, 9000, rng, circular) * renv
    mech *= sig_rms / (math.sqrt(float(np.mean(mech ** 2))) + 1e-9) * p["mech"] * (0.3 + rev)
    x = out + rasp + mech
    # Hot gas is loud enough to be non-linear: soft-clip before the silencer,
    # so the clipping's extra harmonics get shaped by the voice too.
    x = normalise(x, 0.25)
    drive = p["drive"] * (0.6 + 0.4 * load)
    x = np.tanh(drive * x) / math.tanh(drive)
    # The voice: exhaust, silencer and turbo as a fixed EQ.
    lp = p["lp"] * (1.0 if load > 0.5 else 0.55)
    if p.get("turbo"):
        lp *= 1.0 + 0.25 * rev  # more gas, a little more bark up top
    def voice(f):
        return highpass(f, 35, 2) * lowpass(f, lp, p["lp_order"]) * peak_eq(f, p["peaks"])
    x = fft_filter(x, voice, sr, circular)
    if not circular:
        return x, rpm_mean
    return normalise(x, 0.2), rpm_mean


# --------------------------------------------------------------------------
# Other loops and one-shots

def loop_noise(seconds, seed):
    return np.random.default_rng(seed), int(seconds * SR)


def tonal_noise_bands(n, freqs, widths, gains, rng, wander=0.0):
    """Narrow bands of random-phase noise: tones that waver like a real squeal."""
    spec = np.zeros(n // 2 + 1, complex)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    for f0, w, g in zip(freqs, widths, gains):
        mag = np.exp(-0.5 * ((f - f0) / w) ** 2) * g
        spec += mag * np.exp(1j * rng.uniform(0, 2 * np.pi, len(f)))
    return np.fft.irfft(spec, n)


def slow_mod(n, rate_hz, rng, depth):
    """Smooth random modulation that loops (built in the frequency domain)."""
    m = tonal_noise_bands(n, [0.0], [rate_hz], [1.0], rng)
    m = m / (np.max(np.abs(m)) + 1e-9)
    return 1.0 + depth * m


def make_turbo():
    rng, n = loop_noise(1.0, 21)
    t = np.arange(n) / SR
    tone = sum(g * np.sin(2 * np.pi * f * t) for f, g in [(3000, 1.0), (6000, 0.25), (4500, 0.12)])
    breath = bandnoise(n, SR, 2000, 7000, rng)
    x = tone * 0.6 * slow_mod(n, 3.0, rng, 0.15) + breath / (np.std(breath) + 1e-9) * 0.35
    return normalise(x, 0.18)


def make_supercharger():
    rng, n = loop_noise(1.0, 22)
    t = np.arange(n) / SR
    x = sum(g * np.sin(2 * np.pi * f * t) for f, g in [(1000, 1.0), (2000, 0.45), (3000, 0.2), (1040, 0.3)])
    x += bandnoise(n, SR, 800, 4000, rng) * 0.08 / 0.05
    return normalise(x, 0.18)


def make_hybrid():
    rng, n = loop_noise(1.0, 23)
    t = np.arange(n) / SR
    x = sum(g * np.sin(2 * np.pi * f * t) for f, g in [(800, 1.0), (1600, 0.3), (2400, 0.55), (4800, 0.15), (9000, 0.08)])
    x *= slow_mod(n, 2.0, rng, 0.05)
    return normalise(x, 0.18)


def make_gear_whine():
    rng, n = loop_noise(1.0, 24)
    t = np.arange(n) / SR
    am = 1.0 + 0.35 * np.sin(2 * np.pi * 37 * t)
    x = (np.sin(2 * np.pi * 1000 * t) + 0.35 * np.sin(2 * np.pi * 2000 * t)) * am
    x += bandnoise(n, SR, 900, 1100, rng) * 2.0
    return normalise(x, 0.18)


def make_squeal():
    rng, n = loop_noise(3.0, 31)
    base = [760, 1130, 1520, 2280]
    x = tonal_noise_bands(n, base, [9, 12, 16, 20], [1.0, 0.7, 0.45, 0.2], rng)
    x = x / (np.std(x) + 1e-9)
    flutter = slow_mod(n, 14.0, rng, 0.45) * slow_mod(n, 2.0, rng, 0.25)
    hiss = bandnoise(n, SR, 1500, 6000, rng)
    x = x * flutter + hiss / (np.std(hiss) + 1e-9) * 0.25
    return normalise(x, 0.2)


def make_scrub():
    rng, n = loop_noise(2.0, 32)
    x = bandnoise(n, SR, 400, 3500, rng)
    x /= np.std(x) + 1e-9
    grain = np.abs(slow_mod(n, 40.0, rng, 1.0) - 1.0) ** 1.5
    chirp = tonal_noise_bands(n, [900, 1300], [30, 40], [1.0, 0.6], rng)
    chirp /= np.std(chirp) + 1e-9
    x = x * (0.4 + grain) + chirp * 0.35 * slow_mod(n, 6.0, rng, 0.8)
    return normalise(x, 0.2)


def make_lock():
    rng, n = loop_noise(2.0, 33)
    x = tonal_noise_bands(n, [520, 790, 1040], [14, 18, 22], [1.0, 0.6, 0.35], rng)
    x /= np.std(x) + 1e-9
    rough = bandnoise(n, SR, 200, 2500, rng)
    rough /= np.std(rough) + 1e-9
    x = x * slow_mod(n, 25.0, rng, 0.5) + rough * 0.6 * slow_mod(n, 9.0, rng, 0.5)
    return normalise(np.tanh(x * 0.6), 0.2)


def make_road():
    rng, n = loop_noise(2.0, 34)
    x = rng.standard_normal(n)
    x = fft_filter(x, lambda f: highpass(f, 60, 2) * lowpass(f, 1600, 2) * peak_eq(f, [(230, 0.6, 8), (800, 1.0, 3)]), SR)
    return normalise(x, 0.2)


def make_kerb():
    # Rumble strip at a base rate of 25 bumps/s; the game pitches it by speed.
    rng, n = loop_noise(1.0, 35)
    imp = np.zeros(n)
    for i in range(25):
        imp[int(i * n / 25)] = 1.0 + 0.1 * rng.standard_normal()
    t = np.arange(int(0.03 * SR)) / SR
    k = np.sin(2 * np.pi * 90 * t) * np.exp(-t / 0.008) + 0.4 * rng.standard_normal(len(t)) * np.exp(-t / 0.002)
    x = fft_convolve(imp, k)
    x += bandnoise(n, SR, 100, 800, rng) * 0.3 / 0.1
    return normalise(x, 0.2)


def make_gravel():
    rng, n = loop_noise(2.0, 36)
    imp = np.zeros(n)
    hits = rng.integers(0, n, 2600)
    imp[hits] = rng.uniform(-1, 1, len(hits)) ** 3
    x = fft_filter(imp, lambda f: highpass(f, 700, 1) * lowpass(f, 7000, 2), SR)
    rumble = bandnoise(n, SR, 30, 250, rng)
    x = x / (np.std(x) + 1e-9) + rumble / (np.std(rumble) + 1e-9) * 0.8
    return normalise(x, 0.2)


def make_grass():
    rng, n = loop_noise(2.0, 37)
    swish = bandnoise(n, SR, 150, 1500, rng)
    thump = bandnoise(n, SR, 25, 120, rng)
    x = swish / (np.std(swish) + 1e-9) * slow_mod(n, 5.0, rng, 0.4) + thump / (np.std(thump) + 1e-9) * 0.9
    return normalise(x, 0.2)


def make_wind():
    rng, n = loop_noise(3.0, 38)
    x = rng.standard_normal(n)
    x = fft_filter(x, lambda f: highpass(f, 80, 1) * lowpass(f, 2500, 1), SR)
    return normalise(x * slow_mod(n, 0.7, rng, 0.25), 0.2)


def make_spray():
    rng, n = loop_noise(2.0, 39)
    x = bandnoise(n, SR, 1200, 9000, rng)
    x = x / (np.std(x) + 1e-9) * slow_mod(n, 3.0, rng, 0.3)
    drops = np.zeros(n)
    drops[rng.integers(0, n, 900)] = rng.uniform(0.5, 1.0, 900)
    drops = fft_filter(drops, lambda f: highpass(f, 2000, 1), SR)
    return normalise(x + drops / (np.std(drops) + 1e-9) * 0.4, 0.2)


def oneshot_env(n, attack, decay):
    t = np.arange(n) / SR
    return np.minimum(t / max(attack, 1e-5), 1.0) * np.exp(-t / decay)


def make_pop(seed):
    rng = np.random.default_rng(seed)
    n = int(SR * rng.uniform(0.08, 0.16))
    t = np.arange(n) / SR
    thump = np.sin(2 * np.pi * rng.uniform(70, 110) * t) * np.exp(-t / 0.02)
    crack = rng.standard_normal(n) * np.exp(-t / rng.uniform(0.004, 0.009))
    crack = fft_filter(crack, lambda f: highpass(f, 300, 1) * lowpass(f, 5000, 1), SR, False)
    x = np.tanh(2.5 * (thump * 0.8 + crack / (np.std(crack[: n // 4]) + 1e-9) * 0.5))
    return normalise(x * oneshot_env(n, 0.0003, 0.05), 0.25)


def make_crackle():
    rng = np.random.default_rng(41)
    n = int(SR * 0.6)
    x = np.zeros(n)
    tpos = 0.0
    while tpos < 0.5:
        p = make_pop(int(rng.integers(1000))) * rng.uniform(0.25, 1.0)
        i = int(tpos * SR)
        m = min(len(p), n - i)
        x[i: i + m] += p[:m]
        tpos += rng.uniform(0.02, 0.09)
    return normalise(x, 0.22)


def make_shift():
    rng = np.random.default_rng(42)
    n = int(SR * 0.12)
    t = np.arange(n) / SR
    clack = rng.standard_normal(n) * np.exp(-t / 0.0015)
    clack = fft_filter(clack, lambda f: highpass(f, 1500, 1), SR, False)
    bap = np.sin(2 * np.pi * 85 * t) * np.exp(-t / 0.03)
    x = np.tanh(2.0 * (clack / (np.std(clack[:200]) + 1e-9) * 0.4 + bap))
    return normalise(x, 0.25)


def make_flutter():
    rng = np.random.default_rng(43)
    n = int(SR * 0.45)
    t = np.arange(n) / SR
    gate = (np.sin(2 * np.pi * 26 * t) > 0.2).astype(float)
    gate = fft_filter(gate, lambda f: lowpass(f, 300, 2), SR, False)
    x = bandnoise(n, SR, 1200, 5000, rng, False) * gate * np.exp(-t / 0.15)
    x += bandnoise(n, SR, 3000, 8000, rng, False) * 0.3 * np.exp(-t / 0.08)
    return normalise(x, 0.2)


def make_blowoff():
    rng = np.random.default_rng(44)
    n = int(SR * 0.5)
    x = bandnoise(n, SR, 2500, 9000, rng, False) * oneshot_env(n, 0.01, 0.12)
    return normalise(x, 0.18)


EXTRAS = {
    "turbo_whistle": (make_turbo, True), "supercharger": (make_supercharger, True),
    "hybrid_whine": (make_hybrid, True), "gear_whine": (make_gear_whine, True),
    "tyre_squeal": (make_squeal, True), "tyre_scrub": (make_scrub, True), "tyre_lock": (make_lock, True),
    "road_roar": (make_road, True), "kerb": (make_kerb, True), "gravel": (make_gravel, True),
    "grass": (make_grass, True), "wind": (make_wind, True), "spray": (make_spray, True),
    "pop_1": (lambda: make_pop(1), False), "pop_2": (lambda: make_pop(2), False),
    "pop_3": (lambda: make_pop(3), False), "pop_4": (lambda: make_pop(4), False),
    "crackle": (make_crackle, False), "shift": (make_shift, False),
    "flutter": (make_flutter, False), "blowoff": (make_blowoff, False),
}


# --------------------------------------------------------------------------
# Splash-screen pass-by (stereo, 44.1 kHz)

def passby(path, fam="v8_cross_na", seconds=4.6, speed=62.0, dist=9.0):
    sr = 44100
    pre = 1.0  # source audio rendered before the clip starts (sound is still travelling)
    n = int(seconds * sr)
    ns = int((seconds + pre) * sr)
    ts = np.arange(ns) / sr - pre        # emission clock
    t = np.arange(n) / sr                # listening clock
    t_pass = seconds * 0.5
    # Revs climb in 3rd, upshift just after the car passes, climb again in 4th.
    shift_t = t_pass + 0.25
    rpm = 5900 + 1450 * np.clip((ts + pre) / (shift_t + pre), 0, 1)
    after = ts >= shift_t
    rpm[after] = 6000 + 900 * ((ts[after] - shift_t) / (seconds - shift_t))
    load = np.ones(ns)
    load[(ts >= shift_t - 0.06) & (ts < shift_t + 0.03)] = 0.0
    load = np.convolve(load, np.ones(200) / 200, mode="same")
    on, _ = render_engine(fam, rpm, 1.0, sr, 5, circular=False)
    off, _ = render_engine(fam, rpm, 0.0, sr, 6, circular=False)
    eng = on * load + off * 0.5 * (1 - load)
    rng = np.random.default_rng(9)
    road = fft_filter(rng.standard_normal(ns), lambda f: highpass(f, 60, 2) * lowpass(f, 1600, 2) * peak_eq(f, [(230, 0.6, 8)]), sr, False)
    wind = fft_filter(rng.standard_normal(ns), lambda f: highpass(f, 100, 1) * lowpass(f, 3000, 1), sr, False)
    src = eng / np.std(eng) + road / np.std(road) * 0.12 + wind / np.std(wind) * 0.05
    # Geometry: the car drives left to right past the listener; sound arrives late (Doppler).
    c = 343.0
    te = t.copy()
    for _ in range(8):
        r = np.sqrt((speed * (te - t_pass)) ** 2 + dist ** 2)
        te = t - r / c
    r = np.sqrt((speed * (te - t_pass)) ** 2 + dist ** 2)
    idx = (te + pre) * sr
    i0 = np.clip(idx.astype(int), 0, ns - 2)
    fr = idx - i0
    rec = src[i0] * (1 - fr) + src[i0 + 1] * fr
    # Distance takes the top off (air and ground absorption), smoothly.
    far = np.clip((r - dist) / 120.0, 0.0, 1.0)
    dull = fft_filter(rec, lambda f: lowpass(f, 1200, 1), sr, False)
    rec = (rec * (1 - far) + dull * far) * (dist / r)
    pan = np.sin(np.arctan2(speed * (te - t_pass), dist))  # -1 left .. 1 right
    left = rec * np.sqrt(0.5 * (1 - pan * 0.85))
    right = rec * np.sqrt(0.5 * (1 + pan * 0.85))
    fade = np.minimum(1.0, np.minimum(t / 0.25, (seconds - t) / 0.4))
    left *= fade
    right *= fade
    m = max(np.max(np.abs(left)), np.max(np.abs(right)))
    write_wav(path, left / m * 0.9, sr, stereo=right / m * 0.9)


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--passby", help="write the splash-screen pass-by to this path and stop")
    ap.add_argument("--family", default="v8_cross_na")
    ap.add_argument("--only", help="comma list of families/extras to rebuild")
    a = ap.parse_args()
    if a.passby:
        passby(a.passby, a.family)
        return
    os.makedirs(OUT, exist_ok=True)
    only = set(a.only.split(",")) if a.only else None
    manifest = {"rate": SR, "families": {}}
    mpath = os.path.join(OUT, "manifest.json")
    if os.path.exists(mpath):
        manifest = json.load(open(mpath))
    for fam, p in FAMILIES.items():
        if only and fam not in only:
            continue
        bands = []
        for bi, band in enumerate(BANDS):
            for load, tag in ((1.0, "on"), (0.0, "off")):
                x, real = render_engine(fam, band, load, SR, 1000 + bi * 7 + (0 if load else 3), True)
                write_wav(os.path.join(OUT, f"{fam}_{tag}_{band}.wav"), x, SR, loop=True)
            bands.append([band, round(real, 3)])
            sys.stdout.write(".")
            sys.stdout.flush()
        manifest["families"][fam] = {"bands": bands, "turbo": bool(p.get("turbo")), "label": p["label"]}
        print(" " + fam)
    for name, (fn, loop) in EXTRAS.items():
        if only and name not in only:
            continue
        write_wav(os.path.join(OUT, name + ".wav"), fn(), SR, loop=loop)
    manifest["rate"] = SR
    with open(mpath, "w") as fh:
        json.dump(manifest, fh, indent=1)
    print("done")


if __name__ == "__main__":
    main()
