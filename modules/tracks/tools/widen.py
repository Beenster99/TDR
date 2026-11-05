#!/usr/bin/env python3
"""Wider road on every track.

Real circuits are 10-15 m wide, but seen from above in the game that felt
too narrow to keep a car on, so every track's road is a set times its
real width: WIDTH_SCALE for circuits, then DISCIPLINE_SCALE for rallycross
and derby (they started out wider, so they got only the 20% passes, two so far).
Where two stretches of road run close side by side (Cadwell Park's hairpin
and the straight below it, Mallory Park's Esses...) the road widens only as
far as keeps them MIN_GAP_M apart, or as far apart as they already were. The centre line stays where it is and both edges move out; the
pit lane moves out with the edge on its side, so the gap between the track
and the pit lane stays what it was. Kerbs, run-off, gravel, barriers and the
AI's room all hang off the edges, so they follow.

build_tracks.py applies this to every new circuit. This script migrates
track files built before it (each file records "width_scale", the scale it
has had so far, so running it twice does nothing):

    python3 modules/tracks/tools/widen.py [track ids...]

Afterwards re-optimise the racing lines (raceline.py) and fit the scenery
(modules/graphics/tools/fit_scenery.py) to the wider road.
"""
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
sys.path.insert(0, HERE)
from pit_limit_zone import limit_zone  # noqa: E402

WIDTH_SCALE = 2.16    # circuits: 1.5x (Nov 2026), then 20% more on top, twice
DISCIPLINE_SCALE = {"circuit": WIDTH_SCALE, "rallycross": 1.44, "derby": 1.44}
MIN_GAP_M = 10.0      # two stretches of road side by side stay at least this far apart
JOKER_END_M = 30.0    # the joker's ends, where it meets the lap, may touch the road
CROSS_M = 60.0        # around a crossing (derby crossovers, Suzuka's bridge) no gap rule
FULL_SHIFT_M = 40.0   # pit lane points up to this far beyond the edge move fully
NO_SHIFT_M = 100.0    # and ones this far out not at all (roads leaving the circuit)
SMOOTH_PTS = 6        # moving average over the shift, so the lane stays smooth
INSIDE_MAX = 0.75     # inside a tight corner the road may widen to this times the radius
CURVE_M = 10.0        # radius measured over this many metres either side


def _normals(centre):
    tang = np.roll(centre, -1, 0) - np.roll(centre, 1, 0)
    tang /= np.maximum(np.linalg.norm(tang, axis=1, keepdims=True), 1e-9)
    return np.column_stack([-tang[:, 1], tang[:, 0]])


def _gap_caps(centre, w_pos, w_neg, nrm):
    """How far each edge (+normal, -normal) may grow before it comes nearer
    than MIN_GAP_M to another stretch of the same road (or nearer than it
    already was). Stretches that cross (bridges, derby crossovers) don't count
    near the crossing."""
    n = len(centre)
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    s = np.concatenate([[0.0], np.cumsum(seg)[:-1]])
    lap = float(seg.sum())
    cap_pos, cap_neg = np.full(n, np.inf), np.full(n, np.inf)
    rel = centre[None, :, :] - centre[:, None, :]          # i -> j
    dist = np.linalg.norm(rel, axis=2)
    ds = np.abs(s[:, None] - s[None, :])
    ds = np.minimum(ds, lap - ds)
    wmax = np.maximum(w_pos, w_neg)
    near = ds < np.maximum(60.0, 4.0 * (wmax[:, None] + wmax[None, :]))
    side_i = np.where((rel * nrm[:, None, :]).sum(-1) >= 0, 1, -1)       # j is on i's +/- side
    side_j = np.where((-rel * nrm[None, :, :]).sum(-1) >= 0, 1, -1)      # i is on j's +/- side
    w_i = np.where(side_i > 0, w_pos[:, None], w_neg[:, None])
    w_j = np.where(side_j > 0, w_pos[None, :], w_neg[None, :])
    gap = dist - w_i - w_j
    # crossings: where the roads overlap, and CROSS_M either way along both
    crossing = (gap < 0) & ~near
    if crossing.any():
        step = max(1, int(round(CROSS_M / max(lap / n, 0.1))))
        ci, cj = np.nonzero(crossing)
        zone = np.zeros(n, bool)
        mask = np.zeros((n, n), bool)
        for i, j in zip(ci, cj):
            ii = np.arange(i - step, i + step + 1) % n
            jj = np.arange(j - step, j + step + 1) % n
            mask[np.ix_(ii, jj)] = True
            mask[np.ix_(jj, ii)] = True
        near = near | mask
    room = np.maximum(0.0, gap - np.minimum(np.maximum(gap, 0.0), MIN_GAP_M)) * 0.5
    room[near] = np.inf
    cap_pos = np.where(side_i > 0, room, np.inf).min(1)
    cap_neg = np.where(side_i < 0, room, np.inf).min(1)
    return cap_pos, cap_neg


def _joker_caps(centre, w_pos, w_neg, joker, grow):
    """Rallycross: how far each edge may grow before it closes on the joker
    lane (whose half width grows by `grow`) by more than the gap rule allows.
    The joker's first and last JOKER_END_M (where it splits off and merges
    back) don't count."""
    n = len(centre)
    cap_pos, cap_neg = np.full(n, np.inf), np.full(n, np.inf)
    path = np.asarray(joker.get("path", []), float)
    if len(path) < 2:
        return cap_pos, cap_neg
    along = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))])
    path = path[(along > JOKER_END_M) & (along < along[-1] - JOKER_END_M)]
    if len(path) == 0:
        return cap_pos, cap_neg
    hw = float(joker.get("width_m", 10.0)) * 0.5
    nrm = _normals(centre)
    rel = path[None, :, :] - centre[:, None, :]
    dist = np.linalg.norm(rel, axis=2)
    side = (rel * nrm[:, None, :]).sum(-1) >= 0
    w = np.where(side, w_pos[:, None], w_neg[:, None])
    gap = dist - w - hw
    room = np.maximum(0.0, gap - grow - np.minimum(np.maximum(gap, 0.0), MIN_GAP_M))
    room[gap > 60.0] = np.inf
    cap_pos = np.where(side, room, np.inf).min(1)
    cap_neg = np.where(~side, room, np.inf).min(1)
    return cap_pos, cap_neg


def widths(centre, w_pos, w_neg, scale=WIDTH_SCALE, joker=None):
    """The widened widths (towards +normal, -normal; normal = (-ty, tx)).

    On the inside of a tight corner the edge would fold over itself if the
    road were wider than the corner's radius, so there it widens only up to
    INSIDE_MAX times the radius (never narrower than the real road)."""
    centre = np.asarray(centre, float)
    w_pos, w_neg = np.asarray(w_pos, float), np.asarray(w_neg, float)
    step = float(np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1).mean())
    k = max(1, int(round(CURVE_M / max(step, 0.1))))
    a = centre - np.roll(centre, k, 0)
    b = np.roll(centre, -k, 0) - centre
    cross = a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]
    ang = np.arctan2(cross, (a * b).sum(1))
    radius = (np.linalg.norm(a, axis=1) + np.linalg.norm(b, axis=1)) * 0.5 / np.maximum(np.abs(ang), 1e-6)
    nrm = _normals(centre)
    gaps = _gap_caps(centre, w_pos, w_neg, nrm)
    if joker:
        jc = _joker_caps(centre, w_pos, w_neg, joker, float(joker.get("width_m", 10.0)) * 0.5 * (scale - 1.0))
        gaps = (np.minimum(gaps[0], jc[0]), np.minimum(gaps[1], jc[1]))
    out = []
    for w, inside, room in ((w_pos, ang > 0, gaps[0]), (w_neg, ang < 0, gaps[1])):
        cap = np.where(inside, np.maximum(w, INSIDE_MAX * radius), np.inf)
        cap = np.minimum(cap, w + room)
        # the tightest cap nearby, so the edge eases in and out of the corner
        near = np.min([np.roll(cap, j) for j in range(-2 * k, 2 * k + 1)], axis=0)
        out.append(np.minimum(w * scale, np.maximum(w, near)))
    return out[0], out[1]


def shift_pit(centre, w_pos, w_neg, pit, new_pos, new_neg, pit_sign):
    """The pit path moved out with the widened edge beside it.

    centre: (n, 2) closed centre line; w_pos / w_neg: widths (before
    widening) towards +normal / -normal, where normal = (-ty, tx);
    pit: (m, 2) path; new_pos / new_neg: the widened widths; pit_sign: +1 if the lane is on the +normal side.
    Works in either axis convention."""
    centre = np.asarray(centre, float)
    pit = np.asarray(pit, float)
    nrm = _normals(centre)
    d2 = ((pit[:, None, :] - centre[None, :, :]) ** 2).sum(-1)
    idx = d2.argmin(1)
    off = ((pit - centre[idx]) * nrm[idx]).sum(1)
    w_side = np.where(off >= 0, np.asarray(w_pos)[idx], np.asarray(w_neg)[idx])
    on_road = np.abs(off) <= w_side
    sign = np.where(on_road, float(pit_sign), np.sign(off))
    w = np.where(sign > 0, np.asarray(w_pos)[idx], np.asarray(w_neg)[idx])
    grow = np.where(sign > 0, np.asarray(new_pos)[idx] - np.asarray(w_pos)[idx],
                    np.asarray(new_neg)[idx] - np.asarray(w_neg)[idx])
    gap = np.abs(off) - w
    weight = np.clip((NO_SHIFT_M - gap) / (NO_SHIFT_M - FULL_SHIFT_M), 0.0, 1.0)
    move = nrm[idx] * (sign * grow * weight)[:, None]
    if len(move) > 2 * SMOOTH_PTS:
        k = np.ones(2 * SMOOTH_PTS + 1) / (2 * SMOOTH_PTS + 1)
        pad = np.vstack([np.repeat(move[:1], SMOOTH_PTS, 0), move, np.repeat(move[-1:], SMOOTH_PTS, 0)])
        move = np.column_stack([np.convolve(pad[:, c], k, "valid") for c in (0, 1)])
    return pit + move


def widen_track(d, target=None):
    """Widen a track dict (Godot axes) in place to its discipline's scale.
    False if nothing to do."""
    if target is None:
        target = DISCIPLINE_SCALE.get(d.get("discipline", "circuit"), 1.0)
    done = float(d.get("width_scale", 1.0))
    if target <= done + 1e-6:
        return False
    scale = target / done
    cl = np.array(d["centerline"], float)
    centre, wr, wl = cl[:, :2], cl[:, 2], cl[:, 3]
    # Godot axes (Y down): normal (-ty, tx) points to the right of the race direction.
    nwr, nwl = widths(centre, wr, wl, scale, d.get("joker"))
    pit = d.get("pit_lane")
    if isinstance(pit, dict) and len(pit.get("path", [])) >= 2:
        start = d.get("start_index", 0)
        c0 = np.roll(centre, -start, 0)
        side = 1.0 if pit.get("side", "right") == "right" else -1.0
        path = shift_pit(c0, np.roll(wr, -start), np.roll(wl, -start), np.array(pit["path"]),
                         np.roll(nwr, -start), np.roll(nwl, -start), side)
        pit["path"] = [[round(float(x), 2), round(float(y), 2)] for x, y in path]
        plen = float(np.linalg.norm(np.diff(path, axis=0), axis=1).sum())
        pit["length_m"] = round(plen, 1)
        lo, hi = limit_zone(pit["path"], c0[0].tolist())
        pit["limit_start_m"], pit["limit_end_m"] = lo, hi
    d["centerline"] = [[p[0], p[1], round(float(a), 2), round(float(b), 2)]
                       for p, a, b in zip(d["centerline"], nwr, nwl)]
    joker = d.get("joker")
    if isinstance(joker, dict) and "width_m" in joker:
        joker["width_m"] = round(float(joker["width_m"]) * scale, 2)
    d["width_scale"] = target
    return True


def main(ids):
    for f in sorted(glob.glob(os.path.join(DATA, "*.json"))):
        tid = os.path.basename(f)[:-5]
        if ids and tid not in ids:
            continue
        with open(f) as fh:
            d = json.load(fh)
        if widen_track(d):
            with open(f, "w") as fh:
                json.dump(d, fh, separators=(",", ":"))
            print(f"{tid}: road x{d['width_scale']}")


if __name__ == "__main__":
    main(sys.argv[1:])
