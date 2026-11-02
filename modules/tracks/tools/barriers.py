#!/usr/bin/env python3
"""Barrier types and run-off surfaces along each track, for damage and grip.

For every centre-line point and each side of the track this records:
  barrier at the edge of the run-off: W concrete wall, T tyre wall,
           A armco (steel guard rail), F catch fencing
  run-off surface between the kerb and the barrier: G grass, R gravel trap,
           P paved (asphalt) run-off

Where OpenStreetMap maps it (barrier=wall/guard_rail/tyres/fence/
jersey_barrier, gravel or sand areas next to the track), that is used;
elsewhere sensible defaults by corner and circuit style fill in (tyres on the
outside of slow corners, armco elsewhere, a concrete pit wall, walls all round
a street circuit, gravel or paved run-off on the outside of corners).

build_tracks.py calls add_barriers() for each track; this file can also be
run on its own from the cached OpenStreetMap downloads and the track's "geo"
block:

  python3 modules/tracks/tools/barriers.py              # every track
  python3 modules/tracks/tools/barriers.py spa monza    # just these

tracks.json options: "runoff_style": "gravel" | "paved" | "grass" (default
gravel), "street": true (walls everywhere unless mapped otherwise).
"""
import glob, json, math, os, sys
import xml.etree.ElementTree as ET

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
R_EARTH = 6371000.0

BARRIER_TAGS = {
    "wall": "W", "jersey_barrier": "W",
    "guard_rail": "A", "tyres": "T", "fence": "F",
}
GRAVEL_SURFACES = ("gravel", "sand", "fine_gravel", "pebblestone", "shingle")
GRAVEL_NATURAL = ("sand", "shingle", "scree")
FILL_M = 60.0          # a mapped barrier carries on this far along the lap into unmapped gaps
SLOW_CORNER_CURV = 1.0 / 70.0   # tighter than this radius: tyre walls on the outside
CORNER_CURV = 1.0 / 400.0       # tighter than this: counts as a corner


# --- OpenStreetMap ---------------------------------------------------------

def load_features(tid, geo, cache):
    """Barrier lines and gravel areas from the cached OSM tiles, in game metres."""
    files = sorted(glob.glob(os.path.join(cache, "osm", f"{tid}_[0-9]*_[0-9]*_[0-9]*.osm")))
    if not files or geo is None:
        return [], []
    lat0, lon0 = geo["lat0"], geo["lon0"]
    r = np.array(geo["r"])
    t = np.array(geo["t"])
    nodes, ways = {}, {}
    for f in files:
        try:
            root = ET.parse(f).getroot()
        except ET.ParseError:
            continue
        for n in root.iter("node"):
            lat, lon = float(n.get("lat")), float(n.get("lon"))
            nodes[n.get("id")] = (math.radians(lon - lon0) * R_EARTH * math.cos(math.radians(lat0)),
                                  math.radians(lat - lat0) * R_EARTH)
        for w in root.iter("way"):
            ways[w.get("id")] = ({x.get("k"): x.get("v") for x in w.iter("tag")}, [nd.get("ref") for nd in w.iter("nd")])

    def to_game(refs):
        xy = np.array([nodes[x] for x in refs if x in nodes])
        if len(xy) < 2:
            return None
        return ((xy - t) @ r) * np.array([1.0, -1.0])  # osm -> tum, then flip Y

    lines, areas = [], []
    for tags, refs in ways.values():
        code = BARRIER_TAGS.get(tags.get("barrier", ""))
        gravel = (tags.get("surface") in GRAVEL_SURFACES and "highway" not in tags) or \
            tags.get("natural") in GRAVEL_NATURAL or tags.get("landuse") == "gravel"
        if not code and not gravel:
            continue
        xy = to_game(refs)
        if xy is None:
            continue
        if code:
            lines.append((code, xy))
        if gravel and refs[0] == refs[-1] and len(xy) >= 4:
            areas.append(xy)
    return lines, areas


def densify(xy, step=2.0):
    out = [xy[0]]
    for a, b in zip(xy[:-1], xy[1:]):
        n = max(1, int(np.linalg.norm(b - a) / step))
        for k in range(1, n + 1):
            out.append(a + (b - a) * k / n)
    return np.array(out)


def inside(poly, pts):
    """Even-odd point in polygon for many points."""
    x, y = pts[:, 0], pts[:, 1]
    res = np.zeros(len(pts), dtype=bool)
    px, py = poly[:, 0], poly[:, 1]
    j = len(poly) - 1
    for i in range(len(poly)):
        cond = ((py[i] > y) != (py[j] > y)) & (x < (px[j] - px[i]) * (y - py[i]) / (py[j] - py[i] + 1e-12) + px[i])
        res ^= cond
        j = i
    return res


# --- geometry --------------------------------------------------------------

def frame(pts):
    d = np.roll(pts, -1, 0) - np.roll(pts, 1, 0)
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    return d, np.column_stack([-d[:, 1], d[:, 0]])  # tangent, right normal (game axes)


def curvature(pts):
    d, _ = frame(pts)
    a = np.arctan2(d[:, 1], d[:, 0])
    da = (np.roll(a, -3) - np.roll(a, 3) + math.pi) % (2 * math.pi) - math.pi
    seg = np.linalg.norm(np.roll(pts, -3, 0) - np.roll(pts, 3, 0), axis=1)
    k = da / np.maximum(seg, 1e-6)          # + = turning right (game axes, Y down)
    for _ in range(4):
        k = 0.25 * np.roll(k, 1) + 0.5 * k + 0.25 * np.roll(k, -1)
    return k


def mode_filter(codes, half):
    n = len(codes)
    out = list(codes)
    for i in range(n):
        win = [codes[(i + j) % n] for j in range(-half, half + 1)]
        win = [c for c in win if c]
        if win:
            out[i] = max(set(win), key=win.count) if codes[i] else codes[i]
    return out


def fill_gaps(codes, max_pts):
    """Spread mapped values along the lap into unmapped stretches, up to max_pts."""
    n = len(codes)
    out = list(codes)
    if not any(codes):
        return out
    for direction in (1, -1):
        last, dist = None, 0
        start = next(i for i in range(n) if codes[i])
        for k in range(1, n + 1):
            i = (start + direction * k) % n
            if codes[i]:
                last, dist = codes[i], 0
            else:
                dist += 1
                if last and dist <= max_pts and not out[i]:
                    out[i] = last
    return out


# --- one track -------------------------------------------------------------

def add_barriers(out, cfg, cache):
    cl = np.array(out["centerline"], dtype=np.float64)
    pts, wr, wl = cl[:, :2], cl[:, 2], cl[:, 3]
    n = len(pts)
    step = float(np.linalg.norm(np.roll(pts, -1, 0) - pts, axis=1).mean())
    runoff = out.get("runoff_m", 30.0)
    tang, right = frame(pts)
    lines, areas = load_features(out["id"], out.get("geo"), cache)

    # Barriers: every mapped barrier point is projected onto the nearest
    # centre point; the closest one beyond the kerb on each side wins.
    found = {1: [None] * n, -1: [None] * n}
    best = {1: np.full(n, np.inf), -1: np.full(n, np.inf)}
    for code, xy in lines:
        p = densify(xy)
        pd = np.gradient(p, axis=0)
        pd /= np.maximum(np.linalg.norm(pd, axis=1, keepdims=True), 1e-9)
        lo, hi = pts.min(0) - runoff - 40, pts.max(0) + runoff + 40
        keep = (p[:, 0] > lo[0]) & (p[:, 1] > lo[1]) & (p[:, 0] < hi[0]) & (p[:, 1] < hi[1])
        p, pd = p[keep], pd[keep]
        if len(p) == 0:
            continue
        for k in range(0, len(p), 256):
            q = p[k:k + 256]
            d2 = ((q[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
            idx = d2.argmin(1)
            off = ((q - pts[idx]) * right[idx]).sum(1)
            # Track barriers run alongside the track; buildings and field
            # walls mostly don't.
            par = np.abs((pd[k:k + 256] * tang[idx]).sum(1)) > 0.8
            for i, o, ok in zip(idx, off, par):
                if not ok:
                    continue
                side = 1 if o >= 0 else -1
                edge = wr[i] if side > 0 else wl[i]
                gap = abs(o) - edge
                # Beyond the kerb, no further out than the run-off plus a margin.
                if 2.0 <= gap <= runoff + 5.0 and gap < best[side][i]:
                    best[side][i] = gap
                    found[side][i] = code
    mapped = sum(c is not None for s in (1, -1) for c in found[s])

    # Gravel traps: sample the run-off band and test against gravel areas.
    gravel = {1: np.zeros(n, dtype=bool), -1: np.zeros(n, dtype=bool)}
    if areas:
        for side in (1, -1):
            edge = wr if side > 0 else wl
            hits = np.zeros(n, dtype=int)
            for f in (0.25, 0.5):
                probe = pts + right * (side * (edge + 1.2 + f * runoff))[:, None]
                for poly in areas:
                    lo, hi = poly.min(0), poly.max(0)
                    m = (probe[:, 0] >= lo[0]) & (probe[:, 0] <= hi[0]) & (probe[:, 1] >= lo[1]) & (probe[:, 1] <= hi[1])
                    if m.any():
                        idx = np.nonzero(m)[0]
                        hits[idx[inside(poly, probe[idx])]] += 1
            gravel[side] = hits > 0

    # Defaults.
    curv = curvature(pts)
    style = cfg.get("runoff_style", "gravel")
    street = cfg.get("street", False)
    pit = out.get("pit_lane") or {}
    seg = np.linalg.norm(np.roll(pts, -1, 0) - pts, axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    total = seg.sum()
    pit_side = 1 if pit.get("side", "right") == "right" else -1
    a, z = pit.get("entry_s", 0.0), pit.get("exit_s", 0.0)
    in_pit = ((cum >= a) | (cum <= z)) if a > z else ((cum >= a) & (cum <= z))
    fill = max(1, int(FILL_M / step))
    result = {}
    for side, name in ((1, "right"), (-1, "left")):
        codes = fill_gaps(mode_filter(found[side], max(1, int(10.0 / step))), fill)
        outside = side * curv < 0   # a right-hander (curv > 0) has its outside on the left
        sharp = np.abs(curv) > SLOW_CORNER_CURV
        corner = np.abs(curv) > CORNER_CURV
        # Corners matter a few tens of metres beyond the apex too.
        span = max(1, int(40.0 / step))
        corner_out = np.zeros(n, dtype=bool)
        sharp_out = np.zeros(n, dtype=bool)
        for j in range(0, span + 1):
            corner_out |= np.roll(corner & outside, j)
            sharp_out |= np.roll(sharp & outside, j)
        b, ro = [], []
        for i in range(n):
            c = codes[i]
            if c is None:
                if pit and side == pit_side and in_pit[i]:
                    c = "W"
                elif street:
                    c = "W"
                elif sharp_out[i]:
                    c = "T"
                else:
                    c = "A"
            b.append(c)
            if gravel[side][i]:
                ro.append("R")
            elif corner_out[i] and style == "gravel":
                ro.append("R")
            elif corner_out[i] and style == "paved":
                ro.append("P")
            elif street or (pit and side == pit_side and in_pit[i]):
                ro.append("P")
            else:
                ro.append("G")
        result[name] = "".join(b)
        result["runoff_" + name] = "".join(ro)
    counts = {k: sum(result["left"].count(k) + result["right"].count(k) for _ in [0]) for k in "WTAF"}
    rcounts = {k: result["runoff_left"].count(k) + result["runoff_right"].count(k) for k in "GRP"}
    out["barriers"] = {
        "source": f"OpenStreetMap barriers ({mapped} of {2 * n} edge points mapped) and gravel areas, "
                  "defaults by corner and circuit style elsewhere",
        "codes": {"W": "concrete wall", "T": "tyre wall", "A": "armco", "F": "catch fencing",
                  "G": "grass", "R": "gravel trap", "P": "paved run-off"},
        **result,
    }
    print(f"   barriers: {100.0 * mapped / (2 * n):.0f}% mapped; " +
          " ".join(f"{k}{100.0 * v / (2 * n):.0f}%" for k, v in counts.items()) + "; run-off " +
          " ".join(f"{k}{100.0 * v / (2 * n):.0f}%" for k, v in rcounts.items()))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/tdr-tracks"))
    args = ap.parse_args()
    with open(os.path.join(HERE, "tracks.json")) as f:
        tracks = json.load(f)["tracks"]
    for cfg in tracks:
        if args.ids and cfg["id"] not in args.ids:
            continue
        path = os.path.join(DATA, cfg["id"] + ".json")
        with open(path) as f:
            out = json.load(f)
        print(cfg["id"] + ":")
        add_barriers(out, cfg, args.cache)
        with open(path, "w") as f:
            json.dump(out, f, separators=(",", ":"))


if __name__ == "__main__":
    main()
