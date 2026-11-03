#!/usr/bin/env python3
"""Fit built scenery to the current track widths, without rebuilding it.

build_scenery.py keeps buildings at least BUILDING_CLEAR_M off the road and
trees outside the run-off (run-off + TREE_CLEAR_M) when it builds a track.
When a track's road changes width afterwards (tracks widen.py), this drops
whatever now stands too close, by the same rules:

    python3 modules/graphics/tools/fit_scenery.py [track ids...]

A fresh build_scenery.py run gives the same result (it reads the widths from
the track file).
"""
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SCENERY = os.path.join(HERE, "..", "data", "scenery")
TRACKS = os.path.join(HERE, "..", "..", "tracks", "data")
BUILDING_CLEAR_M = 2.0
TREE_CLEAR_M = 4.0


def clearance(track, pts):
    """Distance from each point to the nearest road edge (track or pit lane),
    measured as build_scenery.py's Clearance does."""
    cl = np.array(track["centerline"], float)
    segs = [(cl[:, :2], np.maximum(cl[:, 2], cl[:, 3]))]
    pit = track.get("pit_lane")
    if pit:
        pp = np.array(pit["path"], float)
        segs.append((pp, np.full(len(pp), pit.get("width_m", 12.0) * 0.5)))
    best = np.full(len(pts), 1e9)
    for c, hw in segs:
        for k in range(0, len(pts), 2048):
            q = pts[k:k + 2048]
            d = np.sqrt(((q[:, None, :] - c[None, :, :]) ** 2).sum(-1)) - hw[None, :]
            np.minimum(best[k:k + 2048], d.min(1), out=best[k:k + 2048])
    return best


def fit(tid):
    sp = os.path.join(SCENERY, tid + ".json")
    with open(sp) as f:
        sc = json.load(f)
    with open(os.path.join(TRACKS, tid + ".json")) as f:
        track = json.load(f)
    runoff = track.get("runoff_m", 30.0)
    keep_b = []
    for b in sc.get("buildings", []):
        if clearance(track, np.array(b["p"], float)).min() >= BUILDING_CLEAR_M:
            keep_b.append(b)
    trees = sc.get("trees", [])
    if trees:
        ok = clearance(track, np.array([t[:2] for t in trees], float)) > runoff + TREE_CLEAR_M
        keep_t = [t for t, k in zip(trees, ok) if k]
    else:
        keep_t = trees
    gone_b = len(sc.get("buildings", [])) - len(keep_b)
    gone_t = len(trees) - len(keep_t)
    if gone_b or gone_t:
        sc["buildings"], sc["trees"] = keep_b, keep_t
        with open(sp, "w") as f:
            json.dump(sc, f, separators=(",", ":"))
    print(f"{tid}: dropped {gone_b} buildings, {gone_t} trees")


def main(ids):
    for f in sorted(glob.glob(os.path.join(SCENERY, "*.json"))):
        tid = os.path.basename(f)[:-5]
        if not ids or tid in ids:
            fit(tid)


if __name__ == "__main__":
    main(sys.argv[1:])
