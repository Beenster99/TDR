"""Builds the Demolition Derby arenas (made-up tracks, no real places).

Run:  python3 modules/tracks/tools/build_derby_tracks.py
Writes modules/tracks/data/derby_*.json (same format as the circuits, plus
"discipline": "derby", "dirt" and "jumps").

Each arena is a closed centre line that crosses itself (figure-eights and
knots), so cars meet at flat crossovers. On top of that:
  * dirt: stretches of loose dirt, [[s_from, s_to], ...] in metres along the lap
  * jumps: table-top ramps baked into the elevation (height_m) and listed as
    [{"s": lip, "up_m", "top_m", "down_m", "height_m"}], kept clear of the
    crossovers and of the starting grid.
Arenas are flat apart from the jumps, walled in (concrete, with tyre walls on
the outside of the turns) and have no pit lane.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "data")
sys.path.insert(0, HERE)
import widen  # noqa: E402
STEP = 2.0          # metres between centre-line points
GRID_CLEAR = 85.0   # no jumps this far behind the start line (the grid: 16 cars, 2 abreast)
CROSS_CLEAR = 22.0  # no jumps this close to a crossover
RUNOFF = 1.0        # the road runs right up to the walls: just this strip (still road) before them
SCALE = 1.5         # every arena layout is drawn this much bigger than its curve
                    # (the AI got lost in the tight 2026-11-03 arenas)


def lemniscate(a, squash=1.0):
    def f(t):
        s, c = math.sin(t), math.cos(t)
        d = 1.0 + s * s
        return (a * c / d, squash * a * s * c / d)
    return f


def trefoil(a):
    def f(t):
        return (a * (math.sin(t) + 2.0 * math.sin(2.0 * t)), a * (math.cos(t) - 2.0 * math.cos(2.0 * t)))
    return f


def figure8_stadium(a, b):
    """Two round loops joined by an X: the classic county-fair figure eight."""
    def f(t):
        x = a * math.sin(t)
        return (x * (1.0 + 0.18 * math.cos(2.0 * t)), b * math.sin(2.0 * t))
    return f


def bowtie(a, b, k=0.5):
    """Two long straights crossing in an X, joined by tight hairpins (a bow tie)."""
    def f(t):
        st = math.sin(t)
        return (a * math.copysign(abs(st) ** k, st), b * math.sin(2.0 * t))
    return f


def pretzel(a, b):
    """A sideways S looped back on itself: two crossovers (a 1:3 Lissajous)."""
    def f(t):
        return (a * math.sin(t), b * math.cos(3.0 * t))
    return f


def sample(curve, n=4000):
    pts = [tuple(SCALE * v for v in curve(2.0 * math.pi * i / n)) for i in range(n)]
    # resample at STEP metres
    out = [pts[0]]
    acc = 0.0
    for i in range(1, n + 1):
        a, b = pts[i - 1], pts[i % n]
        d = math.dist(a, b)
        while acc + d >= STEP:
            k = (STEP - acc) / d
            p = (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k)
            out.append(p)
            a = p
            d = math.dist(a, b)
            acc = 0.0
        acc += d
    if math.dist(out[-1], out[0]) < STEP * 0.5:
        out.pop()
    return out


def seg_cross(p1, p2, p3, p4):
    d = (p2[0] - p1[0]) * (p4[1] - p3[1]) - (p2[1] - p1[1]) * (p4[0] - p3[0])
    if abs(d) < 1e-9:
        return None
    t = ((p3[0] - p1[0]) * (p4[1] - p3[1]) - (p3[1] - p1[1]) * (p4[0] - p3[0])) / d
    u = ((p3[0] - p1[0]) * (p2[1] - p1[1]) - (p3[1] - p1[1]) * (p2[0] - p1[0])) / d
    if 0 <= t <= 1 and 0 <= u <= 1:
        return t, u
    return None


def crossings(pts):
    n = len(pts)
    out = []
    for i in range(n):
        for j in range(i + 3, n):
            if i == 0 and j == n - 1:
                continue
            r = seg_cross(pts[i], pts[(i + 1) % n], pts[j], pts[(j + 1) % n])
            if r:
                out.append(((i + r[0]) * STEP, (j + r[1]) * STEP))
    return out


def curvature(pts):
    n = len(pts)
    out = []
    for i in range(n):
        a, b, c = pts[i - 3], pts[i], pts[(i + 3) % n]
        h1 = math.atan2(b[1] - a[1], b[0] - a[0])
        h2 = math.atan2(c[1] - b[1], c[0] - b[0])
        dh = (h2 - h1 + math.pi) % (2 * math.pi) - math.pi
        out.append(dh / (6 * STEP))
    return out


def min_radius(pts):
    return 1.0 / max(abs(k) for k in curvature(pts))


def ring_dist(a, b, L):
    d = abs(a - b) % L
    return min(d, L - d)


def build(spec):
    pts = sample(spec["curve"])
    n = len(pts)
    L = n * STEP
    # start line: the straightest point the spec asks for (fraction of lap)
    start = int(spec.get("start", 0.0) * n) % n
    pts = pts[start:] + pts[:start]
    if spec.get("reverse"):
        pts = [pts[0]] + list(reversed(pts[1:]))
    xs = crossings(pts)
    k = curvature(pts)
    half = spec["width"] * SCALE * 0.5
    cl = [[round(p[0], 2), round(p[1], 2), half, half] for p in pts]
    # Jumps: at the given fractions, nudged to the straightest spot nearby
    # that is clear of the crossovers and the grid.
    heights = [0.0] * n
    jumps = []
    for want in spec.get("jumps", []):
        best = None
        for di in range(-60, 61):
            i = (int(want * n) + di) % n
            s = i * STEP
            up, top, down, h = spec.get("jump_shape", (9.0, 5.0, 11.0, 1.9))
            span = up + top + down
            if s - up < 20.0 or s + top + down > L - GRID_CLEAR:
                continue
            clear = all(ring_dist(s - up + x, c, L) > CROSS_CLEAR for c in [c for pair in xs for c in pair]
                        for x in (0.0, span * 0.5, span))
            if not clear:
                continue
            bend = max(abs(k[(i + o) % n]) for o in range(int(-up / STEP), int((top + down) / STEP)))
            if bend > 0.035:
                continue
            if any(abs(s - j["s"]) < span + 40.0 for j in jumps):
                continue
            score = bend + abs(di) * 0.0002
            if best is None or score < best[0]:
                best = (score, s, up, top, down, h)
        if best is None:
            print("  no room for a jump near %.2f" % want)
            continue
        _, s, up, top, down, h = best
        # s is where the ramp ends (the lip): up ramp before, table, landing
        jumps.append({"s": round(s, 1), "up_m": up, "top_m": top, "down_m": down, "height_m": h})
        for i in range(n):
            x = i * STEP - (s - up)
            if 0.0 <= x <= up:
                y = h * x / up
            elif up < x <= up + top:
                y = h
            elif up + top < x <= up + top + down:
                y = h * (1.0 - (x - up - top) / down)
            else:
                continue
            heights[i] = max(heights[i], y)
    # Dirt stretches, cut around the ramps: the ramps are packed hard so a
    # car that stops on one can still drive up it.
    dirt = []
    for a, b in spec.get("dirt", []):
        cuts = [(a * L, b * L)]
        for j in jumps:
            r0, r1 = j["s"] - j["up_m"] - 3.0, j["s"] + j["top_m"] + j["down_m"] + 3.0
            nxt = []
            for c0, c1 in cuts:
                if r1 <= c0 or r0 >= c1:
                    nxt.append((c0, c1))
                    continue
                if r0 - c0 > 4.0:
                    nxt.append((c0, r0))
                if c1 - r1 > 4.0:
                    nxt.append((r1, c1))
            cuts = nxt
        dirt += [[round(c0, 1), round(c1, 1)] for c0, c1 in cuts]
    walls = []
    for side in (1, -1):
        row = ""
        for i in range(n):
            # tyre walls on the outside of the tighter turns
            row += "T" if abs(k[i]) > 0.02 and k[i] * side < 0 else "W"
        walls.append(row)
    d = {
        "format": 1,
        "id": spec["id"],
        "discipline": "derby",
        "name": spec["name"],
        "short_name": spec["short"],
        "location": spec["location"],
        "country": "",
        "description": spec["description"],
        "length_m": round(L, 1),
        "source": "Made-up Demolition Derby arena (modules/tracks/tools/build_derby_tracks.py)",
        "direction_note": "Points are ordered in race direction. Index 0 is the start/finish line.",
        "centerline_format": ["x_m", "y_m", "width_right_m", "width_left_m"],
        "centerline": cl,
        "start_index": 0,
        "sectors": [0.0, 0.333, 0.667],
        "runoff_m": RUNOFF,
        "kerb_width_m": 0.9,
        "default_environment": spec.get("env", {"ambient_c": 17, "track_c": 22, "time_of_day_h": 19.5, "weather": "dry"}),
        "pit_lane": None,
        "climate": spec.get("climate", {"ambient_day_c": 19, "ambient_night_c": 11, "rain_chance": 0.3}),
        "dirt": dirt,
        "jumps": jumps,
        "crossovers": [[round(a, 1), round(b, 1)] for a, b in xs],
        "elevation": {"source": "flat arena with built ramps", "base_alt_m": 0.0,
                      "height_m": [round(h, 3) for h in heights], "bank_deg": [0.0] * n},
        "barriers": {"source": "arena walls", "codes": {"W": "concrete wall", "T": "tyre wall", "G": "grass", "P": "paved run-off"},
                     "right": walls[0], "left": walls[1], "runoff_right": "P" * n, "runoff_left": "P" * n},
    }
    # The road widens 20% on top of the drawn width, like every track (widen.py).
    widen.widen_track(d)
    path = os.path.join(OUT, spec["id"] + ".json")
    with open(path, "w") as f:
        json.dump(d, f, separators=(",", ":"))
    print("%-22s %5.0f m  crossovers %d  jumps %d  dirt %.0f%%  min radius %.0f m" % (
        spec["id"], L, len(xs), len(jumps), 100.0 * sum(b - a for a, b in dirt) / L, min_radius(pts)))


TRACKS = [
    {"id": "derby_rustbelt_eight", "name": "Rustbelt Figure Eight", "short": "Rustbelt", "location": "County fairground",
     "description": "The classic county-fair figure eight: two loops and one crossover in the middle where every lap someone gets T-boned. Dirt on the far loop and a table-top jump on the way back.",
     "curve": figure8_stadium(58.0, 30.0), "width": 12.0, "start": 0.12,
     "dirt": [[0.55, 0.92]], "jumps": [0.7], "jump_shape": (8.0, 5.0, 10.0, 2.2)},
    {"id": "derby_scrapyard_knot", "name": "Scrapyard Knot", "short": "Scrapyard", "location": "Breaker's yard",
     "description": "Three crossovers tied in a knot through a breaker's yard. Mostly loose dirt, two jumps, and nowhere to hide.",
     "curve": trefoil(16.0), "width": 11.0, "start": 0.05,
     "dirt": [[0.0, 0.18], [0.3, 0.62], [0.74, 0.96]], "jumps": [0.33, 0.62]},
    {"id": "derby_harbour_bowtie", "name": "Harbour Bowtie", "short": "Harbour", "location": "Dockside container yard",
     "description": "Two long straights across the docks meet in an X, with tight hairpins at each end. Tarmac straights, dirt in the hairpins and a big jump off the quay.",
     "curve": bowtie(78.0, 34.0), "width": 12.0, "start": 0.08,
     "dirt": [[0.2, 0.31], [0.69, 0.8]], "jumps": [0.42], "jump_shape": (10.0, 6.0, 13.0, 2.1)},
    {"id": "derby_quarry_pretzel", "name": "Quarry Pretzel", "short": "Quarry", "location": "Disused chalk quarry",
     "description": "A pretzel of a track in an old quarry: two crossovers, a gravelly dirt section round the back and jumps over the spoil heaps.",
     "curve": pretzel(62.0, 40.0), "width": 11.0, "start": 0.0,
     "dirt": [[0.38, 0.7]], "jumps": [0.15, 0.48, 0.66]},
    {"id": "derby_mudflat_infinity", "name": "Mudflat Infinity", "short": "Mudflat", "location": "Estuary marshes",
     "description": "A wide, fast infinity loop laid on the mudflats. Dirt all the way round apart from the start, a crossover in the middle and two jumps.",
     "curve": lemniscate(72.0, 1.15), "width": 12.0, "start": 0.0,
     "dirt": [[0.1, 0.95]], "jumps": [0.22, 0.5],
     "climate": {"ambient_day_c": 14, "ambient_night_c": 7, "rain_chance": 0.55},
     "env": {"ambient_c": 13, "track_c": 15, "time_of_day_h": 16.0, "weather": "overcast"}},
]


if __name__ == "__main__":
    for t in TRACKS:
        build(t)
