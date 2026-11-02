"""Pit lane speed-limit zone: where the limiter is on, in pit metres.

Real speed-limit zones cover the garages, which sit along the start/finish
straight, and are about 400-450 m long (pit-stop time loss ~20-25 s). The
mapped OpenStreetMap lanes also include the long entry and exit roads, so the
zone is placed around the point of the lane level with the start/finish line,
not over the whole lane.

    python3 modules/tracks/tools/pit_limit_zone.py   # re-apply to every track JSON
"""
import glob
import json
import math
import os

BEFORE_LINE_M = 240.0   # zone starts this far before the start/finish line
AFTER_LINE_M = 200.0    # and ends this far after it
END_MARGIN_M = 70.0     # never closer than this to the lane's ends


def limit_zone(pit_path, line_point):
    """(limit_start_m, limit_end_m) for a pit path [[x, y], ...]."""
    cum = [0.0]
    for a, b in zip(pit_path, pit_path[1:]):
        cum.append(cum[-1] + math.dist(a, b))
    plen = cum[-1]
    best_d, best = 0.0, float("inf")
    for i, (a, b) in enumerate(zip(pit_path, pit_path[1:])):
        seg = (b[0] - a[0], b[1] - a[1])
        l2 = seg[0] ** 2 + seg[1] ** 2
        if l2 < 1e-9:
            continue
        t = max(0.0, min(1.0, ((line_point[0] - a[0]) * seg[0] + (line_point[1] - a[1]) * seg[1]) / l2))
        foot = (a[0] + seg[0] * t, a[1] + seg[1] * t)
        dist = math.dist(foot, line_point)
        if dist < best:
            best, best_d = dist, cum[i] + t * math.sqrt(l2)
    lo = min(END_MARGIN_M, plen * 0.15)
    hi = max(plen - END_MARGIN_M, plen * 0.85)
    start = max(lo, best_d - BEFORE_LINE_M)
    end = min(hi, best_d + AFTER_LINE_M)
    if end - start < 200.0:  # odd lane: fall back to the whole lane
        start, end = lo, hi
    return round(start, 1), round(end, 1)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    for f in sorted(glob.glob(os.path.join(here, "..", "data", "*.json"))):
        with open(f) as fh:
            d = json.load(fh)
        pit = d.get("pit_lane")
        if not pit:
            continue
        cl = d["centerline"]
        line = cl[d.get("start_index", 0) % len(cl)]
        s, e = limit_zone(pit["path"], (line[0], line[1]))
        pit["limit_start_m"], pit["limit_end_m"] = s, e
        with open(f, "w") as fh:
            json.dump(d, fh, separators=(",", ":"))
        print(f"{d['id']:14s} lane {pit['length_m']:6.0f} m  limiter {s:6.0f}..{e:6.0f} m ({e - s:.0f} m)")


if __name__ == "__main__":
    main()
