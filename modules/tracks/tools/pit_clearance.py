#!/usr/bin/env python3
"""Room for a pit wall between the track and the pit lane.

The mapped pit lanes (OpenStreetMap ways, drawn 12 m wide in the game) often
sit too close to the track's centre line from another source, so along the
garages the lane overlapped the racing surface and the pit wall stood on the
main straight. This moves the pit path out, away from the track, until the
lane's track-side edge is CLEAR_M beyond the track's edge, all along the part
of the lane level with the garages (the speed-limit zone). Towards the entry
and exit the move eases off (1 m out per SLOPE_M along), so the lane still
splits off and merges back where it did.

build_tracks.py applies this to every new circuit. To fix track files built
before it (running it twice does nothing more):

    python3 modules/tracks/tools/pit_clearance.py [track ids...]

Afterwards fit the scenery to the moved lane
(modules/graphics/tools/fit_scenery.py).
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

CLEAR_M = 3.5      # track edge to the lane's edge, room for the wall between
SLOPE_M = 8.0      # the move eases off by 1 m every this many metres along
END_KEEP_M = 15.0  # the lane's last metres (where it meets the track) stay put
SMOOTH_PTS = 4     # moving average over the move
SPAN_MARGIN_M = 40.0  # track looked at: the lane's span plus this either end


def project(pts, centre, wr, wl, mask=None):
    """Signed offset (+ = right, Godot axes) and the track edge on each side
    for points against a closed centre line (only the segments in mask)."""
    a = centre
    b = np.roll(centre, -1, 0)
    seg = b - a
    l2 = np.maximum((seg ** 2).sum(1), 1e-9)
    t = np.clip((((pts[:, None, :] - a[None]) * seg[None]).sum(-1)) / l2[None], 0.0, 1.0)
    foot = a[None] + seg[None] * t[..., None]
    d2 = ((pts[:, None, :] - foot) ** 2).sum(-1)
    if mask is not None:
        d2[:, ~mask] = np.inf
    i = d2.argmin(1)
    k = np.arange(len(pts))
    tt = t[k, i]
    j = (i + 1) % len(centre)
    dirv = seg[i] / np.sqrt(l2[i])[:, None]
    right = np.column_stack([-dirv[:, 1], dirv[:, 0]])
    off = ((pts - foot[k, i]) * right).sum(1)
    w_r = wr[i] * (1 - tt) + wr[j] * tt
    w_l = wl[i] * (1 - tt) + wl[j] * tt
    return off, w_r, w_l


def _cum(path):
    return np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))])


def _normals(path):
    nxt = np.vstack([path[1:], path[-1:]])
    prv = np.vstack([path[:1], path[:-1]])
    tang = nxt - prv
    tang /= np.maximum(np.linalg.norm(tang, axis=1, keepdims=True), 1e-9)
    return np.column_stack([-tang[:, 1], tang[:, 0]])


def lane_gaps(d):
    """Gap from the track edge to the pit lane's track-side edge at each pit
    path point (negative = the lane is on the track there)."""
    cl = np.roll(np.array(d["centerline"], float), -int(d.get("start_index", 0)), 0)
    pit = d["pit_lane"]
    side = 1.0 if pit.get("side", "right") == "right" else -1.0
    path = np.array(pit["path"], float)
    # Only the stretch of track the lane runs beside: another bit of the
    # circuit behind the garages is not this lane's business.
    s = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(cl[:, :2], axis=0), axis=1))])
    length = s[-1] + float(np.linalg.norm(cl[0, :2] - cl[-1, :2]))
    a = float(pit.get("entry_s", 0.0)) - SPAN_MARGIN_M
    b = float(pit.get("exit_s", 0.0)) + SPAN_MARGIN_M
    if b - a >= length:
        mask = None
    else:
        mask = ((s - a) % length) <= ((b - a) % length)
    off, w_r, w_l = project(path, cl[:, :2], cl[:, 2], cl[:, 3], mask)
    edge = w_r if side > 0 else w_l
    return off * side - edge - float(pit.get("width_m", 12.0)) * 0.5


def clear_track(d):
    """Move a track dict's pit lane (Godot axes) out where it is too close to
    the track. Returns the biggest move in metres (0 if nothing moved)."""
    pit = d.get("pit_lane")
    if not isinstance(pit, dict) or len(pit.get("path", [])) < 4:
        return 0.0
    side = 1.0 if pit.get("side", "right") == "right" else -1.0
    path = np.array(pit["path"], float)
    moved = 0.0
    for _ in range(3):   # moving the lane changes which bit of track is nearest
        cum = _cum(path)
        plen = cum[-1]
        lo = float(pit.get("limit_start_m", plen * 0.15))
        hi = float(pit.get("limit_end_m", plen * 0.85))
        need = np.maximum(CLEAR_M - lane_gaps({**d, "pit_lane": {**pit, "path": path.tolist()}}), 0.0)
        need[(cum < lo) | (cum > hi)] = 0.0
        if need.max() < 0.05:
            break
        # The furthest any garage-side point needs it, easing off along the lane...
        env = (need[None, :] - np.abs(cum[:, None] - cum[None, :]) / SLOPE_M).max(1)
        # ...and to nothing by the lane's ends.
        ends = np.maximum(np.minimum(cum, plen - cum) - END_KEEP_M, 0.0) / SLOPE_M
        shift = np.clip(np.minimum(env, ends), 0.0, None)
        if len(shift) > 2 * SMOOTH_PTS:
            k = np.ones(2 * SMOOTH_PTS + 1) / (2 * SMOOTH_PTS + 1)
            pad = np.concatenate([np.repeat(shift[:1], SMOOTH_PTS), shift, np.repeat(shift[-1:], SMOOTH_PTS)])
            shift = np.maximum(np.convolve(pad, k, "valid"), np.minimum(shift, ends))
        path = path + _normals(path) * side * shift[:, None]
        moved += float(shift.max())
    if moved < 0.05:
        return 0.0
    pit["path"] = [[round(float(x), 2), round(float(y), 2)] for x, y in path]
    pit["length_m"] = round(float(_cum(path)[-1]), 1)
    cl = d["centerline"]
    line = cl[d.get("start_index", 0) % len(cl)]
    pit["limit_start_m"], pit["limit_end_m"] = limit_zone(pit["path"], (line[0], line[1]))
    return moved


def main(ids):
    for f in sorted(glob.glob(os.path.join(DATA, "*.json"))):
        tid = os.path.basename(f)[:-5]
        if ids and tid not in ids:
            continue
        with open(f) as fh:
            d = json.load(fh)
        if not isinstance(d, dict) or "centerline" not in d:
            continue
        m = clear_track(d)
        if m > 0.0:
            with open(f, "w") as fh:
                json.dump(d, fh, separators=(",", ":"))
            print(f"{tid}: pit lane moved out up to {m:.1f} m")


if __name__ == "__main__":
    main(sys.argv[1:])
