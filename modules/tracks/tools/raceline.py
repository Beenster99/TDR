#!/usr/bin/env python3
"""Racing lines: the fastest line round each track for a GT3 car.

The old lines were minimum-curvature lines (TUMFTM) or an elastic band
(OpenStreetMap-only tracks). Those take a geometric apex everywhere. Real
drivers apex late where a straight follows, give up the entry of a corner to
get the exit of the next one, and put two wheels on the kerbs. This tool
finds that line by minimising the lap time of a point-mass car (grip with
downforce, friction ellipse, engine power, rear-wheel traction, braking),
starting from the old line.

The line may go as far as the track edge minus EDGE_M (car fully on the
asphalt, wheels on the white line), or KERB_M where the track has kerbs
(same rule as the kerbs drawn by TrackView: corners), which puts the wheels
on the kerb at apexes and exits like real drivers do.

  python3 modules/tracks/tools/raceline.py [track ids...]   rewrites the
      "raceline" of modules/tracks/data/<id>.json (all tracks if none given)
  python3 modules/tracks/tools/raceline.py --check monza     prints old/new
      model lap times without writing

build_tracks.py calls optimise() for new tracks.
"""
import ctypes
import json
import math
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")

EDGE_M = 1.0        # car centre to track edge on straights / no kerb
KERB_M = 0.3        # where there is a kerb: wheels ride it
KERB_CURV = 0.006   # TrackView draws kerbs where |curvature| is above this
SMOOTH = 1.5e-3      # s per m^2 of second difference: keeps the line flowing
ITERS = 450
SOURCE = "modules/tracks/tools/raceline.py (minimum lap time, GT3 point-mass model)"


class Car(ctypes.Structure):
    _fields_ = [("mu", ctypes.c_double), ("g", ctypes.c_double), ("mass", ctypes.c_double),
                ("aero", ctypes.c_double), ("drag", ctypes.c_double), ("power", ctypes.c_double),
                ("traction", ctypes.c_double), ("brake", ctypes.c_double), ("vmax", ctypes.c_double),
                ("half", ctypes.c_int)]


# A generic GT3 car (Ferrari 296 GT3 numbers, slicks): mu 1.42, 1290 kg with
# driver, ClA 2.5, CdA 0.98, ~435 kW less driveline losses. Traction: a
# rear-drive car puts down roughly two thirds of the grip it can corner on.
GT3 = dict(mu=1.42 * 0.95, g=9.81, mass=1290.0, aero=0.5 * 1.2 * 2.5, drag=0.5 * 1.2 * 0.98,
           power=435e3 * 0.88 * 0.92, traction=0.62, brake=0.9, vmax=95.0, half=2)

_lib = None


def _load():
    global _lib
    if _lib is None:
        out = os.path.join(tempfile.gettempdir(), "tdr_raceline_core.so")
        src = os.path.join(HERE, "raceline_core.c")
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
            subprocess.check_call(["cc", "-O2", "-shared", "-fPIC", "-o", out, src, "-lm"])
        _lib = ctypes.CDLL(out)
        dp = np.ctypeslib.ndpointer(np.float64, flags="C_CONTIGUOUS")
        _lib.profile.restype = ctypes.c_double
        _lib.profile.argtypes = [ctypes.c_int, dp, dp, dp, dp, dp, ctypes.POINTER(Car), dp, dp]
        _lib.gradient.restype = None
        _lib.gradient.argtypes = [ctypes.c_int, dp, dp, dp, dp, dp, ctypes.POINTER(Car), ctypes.c_double, dp, dp, dp]
    return _lib


class Problem:
    """Centre line (Godot axes, race direction), widths and the car."""

    def __init__(self, centre, w_right, w_left, car=GT3):
        self.c = np.ascontiguousarray(centre, dtype=np.float64)
        self.n = len(self.c)
        d = np.roll(self.c, -1, 0) - np.roll(self.c, 1, 0)
        d /= np.linalg.norm(d, axis=1, keepdims=True)
        self.nrm = np.column_stack([-d[:, 1], d[:, 0]])  # right of travel (TrackData.right_normal)
        self.cx, self.cy = self.c[:, 0].copy(), self.c[:, 1].copy()
        self.nx, self.ny = self.nrm[:, 0].copy(), self.nrm[:, 1].copy()
        seg = np.roll(self.c, -1, 0) - self.c
        ang = np.arctan2(seg[:, 1], seg[:, 0])
        curv = np.angle(np.exp(1j * (np.roll(ang, -2) - np.roll(ang, 2)))) / 20.0
        kerb = np.abs(curv) > KERB_CURV
        margin = np.where(kerb, KERB_M, EDGE_M)
        self.hi = np.maximum(np.asarray(w_right, float) - margin, 0.0)
        self.lo = -np.maximum(np.asarray(w_left, float) - margin, 0.0)
        self.car = Car(**car)
        self.v = np.zeros(self.n)
        self.scratch = np.zeros(5 * self.n)

    def lap(self, off):
        off = np.ascontiguousarray(off, dtype=np.float64)
        return _load().profile(self.n, self.cx, self.cy, self.nx, self.ny, off, ctypes.byref(self.car),
                               self.v, self.scratch)

    def grad(self, off, h=0.05):
        g = np.zeros(self.n)
        off = np.ascontiguousarray(off, dtype=np.float64).copy()
        _load().gradient(self.n, self.cx, self.cy, self.nx, self.ny, off, ctypes.byref(self.car), h, g,
                         self.v, self.scratch)
        return g

    def offsets_of(self, line):
        """Offsets (+ right) of a polyline from the centre line, per centre point."""
        line = np.asarray(line, float)
        out = np.zeros(self.n)
        j = 0
        m = len(line)
        # Nearest line point to each centre point, walking forward.
        d0 = np.linalg.norm(line - self.c[0], axis=1)
        j = int(np.argmin(d0))
        for i in range(self.n):
            best, bd = j, 1e18
            for k in range(j - 5, j + 25):
                q = line[k % m]
                dd = ((q - self.c[i]) ** 2).sum()
                if dd < bd:
                    bd, best = dd, k
            j = best
            # Intersect the normal at c[i] with the line segment near best.
            out[i] = self._cross(i, line, best % m)
        return out

    def _cross(self, i, line, k):
        m = len(line)
        c, nr = self.c[i], self.nrm[i]
        t = np.array([nr[1], -nr[0]])
        for a in (k - 1, k):
            p, q = line[a % m], line[(a + 1) % m]
            sp, sq = (p - c) @ t, (q - c) @ t
            if sp == sq:
                continue
            f = sp / (sp - sq)
            if -0.01 <= f <= 1.01:
                return float(((p + (q - p) * f) - c) @ nr)
        return float((line[k] - c) @ nr)


def smooth_pen(off):
    d2 = np.roll(off, -1) - 2 * off + np.roll(off, 1)
    val = SMOOTH * float((d2 ** 2).sum())
    g = SMOOTH * 2 * (np.roll(d2, 1) - 2 * d2 + np.roll(d2, -1))
    return val, g


def optimise(prob, start=None, iters=ITERS, verbose=False):
    off = np.zeros(prob.n) if start is None else np.clip(np.asarray(start, float), prob.lo, prob.hi)
    m = np.zeros(prob.n)
    s = np.zeros(prob.n)
    b1, b2 = 0.8, 0.95
    best = (prob.lap(off) + smooth_pen(off)[0], off.copy())
    for it in range(1, iters + 1):
        lr = 0.15 * (0.05 ** (it / iters))
        g = prob.grad(off) + smooth_pen(off)[1]
        m = b1 * m + (1 - b1) * g
        s = b2 * s + (1 - b2) * g * g
        mh = m / (1 - b1 ** it)
        sh = s / (1 - b2 ** it)
        off = np.clip(off - lr * mh / (np.sqrt(sh) + 2e-3), prob.lo, prob.hi)
        if it % 10 == 0 or it == iters:
            j = prob.lap(off) + smooth_pen(off)[0]
            if j < best[0]:
                best = (j, off.copy())
            if verbose and it % 50 == 0:
                print(f"   iter {it}: lap {prob.lap(off):.3f} s")
    return best[1]


def line_points(prob, off):
    return prob.c + prob.nrm * off[:, None]


def track_problem(d):
    cl = np.array(d["centerline"], float)
    return Problem(cl[:, :2], cl[:, 2], cl[:, 3])


def run(tid, write=True):
    path = os.path.join(DATA, tid + ".json")
    with open(path) as f:
        d = json.load(f)
    prob = track_problem(d)
    old = prob.offsets_of(d["raceline"]) if d.get("raceline") else np.zeros(prob.n)
    t_old_raw = prob.lap(np.clip(old, prob.lo - 5, prob.hi + 5))
    t_old = prob.lap(np.clip(old, prob.lo, prob.hi))
    new = optimise(prob, old)
    t_new = prob.lap(new)
    print(f"{tid}: model lap old line {t_old_raw:.2f} s (in bounds {t_old:.2f}), new line {t_new:.2f} s", flush=True)
    if write:
        pts = line_points(prob, new)
        d["raceline"] = [[round(float(x), 2), round(float(y), 2)] for x, y in pts]
        d["raceline_source"] = SOURCE
        with open(path, "w") as f:
            json.dump(d, f, separators=(",", ":"))
    return t_old, t_new


def main(argv):
    check = "--check" in argv
    ids = [a for a in argv if not a.startswith("--")]
    if not ids:
        ids = sorted(f[:-5] for f in os.listdir(DATA) if f.endswith(".json"))
    for tid in ids:
        run(tid, write=not check)


if __name__ == "__main__":
    main(sys.argv[1:])
