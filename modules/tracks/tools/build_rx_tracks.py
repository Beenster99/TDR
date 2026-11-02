"""Builds the FIA World Rallycross circuits from OpenStreetMap.

Run:  python3 modules/tracks/tools/build_rx_tracks.py [track_id ...]

Reads modules/tracks/tools/rx_tracks.json and writes modules/tracks/data/<id>.json
in the same format as the other circuits (see build_tracks.py), plus:

  "discipline": "rallycross"
  "dirt":  [[s_from, s_to], ...]   loose-surface stretches of the lap (metres
                                    from the start line, race direction)
  "joker": {path, entry_s, exit_s, width_m, length_m, dirt: [[d_from, d_to]]}
           the joker lap: a second route every car must take once a race,
           from where it leaves the lap (entry_s) to where it rejoins (exit_s).
           Distances along it are joker metres (0 = where it leaves).
  no pit lane (rallycross has no pit stops in a race)

How a circuit is found in OpenStreetMap:
  * every highway=raceway way near the circuit that isn't karting, motocross
    or an area; ways named "Joker" (or listed in "joker_ways") are the joker;
  * the longest closed one-way loop through the rest is the lap;
  * each way's surface tag (asphalt / gravel / dirt ...) says where the lap is
    loose; "default_surface" fills untagged ways, "dirt_override" (fractions of
    the lap) fills circuits with no surface tags at all;
  * the start line is on the way tagged raceway=start, or "start_way", else at
    the start of the longest tarmac stretch.

Elevation (AWS Terrarium tiles) and barriers come from the same helpers as the
road circuits. Downloads are cached in ~/.cache/tdr-tracks.
"""
import argparse, json, math, os, sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_tracks as bt  # noqa: E402
from elevation import add_elevation  # noqa: E402
from barriers import add_barriers  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
LOOSE = ("gravel", "fine_gravel", "dirt", "ground", "earth", "unpaved", "compacted", "sand", "mud", "grass")
NOT_RX = ("karting", "motocross", "kart", "cycling")


def is_loose(tags, default):
    return tags.get("surface", default) in LOOSE


def rx_ways(ways, cfg):
    out = []
    keep_r = cfg.get("radius_m", 600.0)
    centre = np.array(cfg.get("osm_offset", [0.0, 0.0]))
    for w in ways:
        t = w["tags"]
        if t.get("highway") != "raceway" or t.get("area") == "yes":
            continue
        if any(x in t.get("sport", "") for x in NOT_RX) or w["id"] in cfg.get("osm_exclude_ways", []):
            continue
        if bt.is_pit(w):
            continue
        if np.linalg.norm(w["xy"].mean(0) - centre) > keep_r:
            continue
        out.append(w)
    # Venues that tag their rallycross ways (sport=rallycross) often share the
    # site with a road circuit: keep just the rallycross ones.
    if any("rallycross" in w["tags"].get("sport", "") for w in out):
        out = [w for w in out if "rallycross" in w["tags"].get("sport", "") or w["id"] in cfg.get("joker_ways", [])]
    return split_at_junctions(out)


def split_at_junctions(ways):
    """OpenStreetMap ways often meet in the middle of another way: cut every
    way at each node it shares with another, so the graph has an edge between
    every two junctions."""
    count = {}
    for w in ways:
        for r in set(w["refs"]):
            count[r] = count.get(r, 0) + 1
        # a closed way joins itself at its first node
    out = []
    for w in ways:
        refs, xy = w["refs"], w["xy"]
        cuts = [0] + [k for k in range(1, len(refs) - 1) if count.get(refs[k], 0) >= 2] + [len(refs) - 1]
        for a, b in zip(cuts[:-1], cuts[1:]):
            if b - a < 1:
                continue
            piece = dict(w)
            piece["refs"] = refs[a:b + 1]
            piece["xy"] = xy[a:b + 1]
            piece["osm_id"] = w["id"]
            piece["id"] = f"{w['id']}.{a}"
            out.append(piece)
    return out


def is_joker(w, cfg):
    if w.get("osm_id", w["id"]) in cfg.get("joker_ways", []):
        return True
    t = w["tags"]
    return "joker" in (t.get("name", "") + " " + t.get("name:en", "")).lower()


def loop_with_tags(ways):
    """Longest closed loop (bt.main_loop), keeping the way behind every point."""
    edges = []
    for w in ways:
        a, b = w["refs"][0], w["refs"][-1]
        length = float(np.linalg.norm(np.diff(w["xy"], axis=0), axis=1).sum())
        edges.append((a, b, w, False, length))
        if w["tags"].get("oneway") not in ("yes", "1", "true"):
            edges.append((b, a, w, True, length))
    out = {}
    for e in edges:
        out.setdefault(e[0], []).append(e)
    best = (0.0, None)

    def dfs(start, node, path, used, length):
        nonlocal best
        for e in out.get(node, []):
            if e[2]["id"] in used:
                continue
            if e[1] == start:
                if length + e[4] > best[0]:
                    best = (length + e[4], path + [e])
                continue
            used.add(e[2]["id"])
            dfs(start, e[1], path + [e], used, length + e[4])
            used.discard(e[2]["id"])

    for e in edges:
        dfs(e[0], e[1], [e], {e[2]["id"]}, e[4])
    if best[1] is None:
        raise RuntimeError("no closed raceway loop found")
    pts, src = [], []
    for e in best[1]:
        xy = e[2]["xy"][::-1] if e[3] else e[2]["xy"]
        pts.extend(xy[:-1].tolist())
        src.extend([e[2]] * (len(xy) - 1))
    return np.array(pts), src, [e[2]["id"] for e in best[1]]


def resample_tagged(pts, src, step):
    """Resample a closed polyline every step metres, carrying each sample's source way."""
    p = np.vstack([pts, pts[:1]])
    seg = np.linalg.norm(np.diff(p, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    n = max(int(round(s[-1] / step)), 8)
    t = np.linspace(0, s[-1], n, endpoint=False)
    xy = np.column_stack([np.interp(t, s, p[:, 0]), np.interp(t, s, p[:, 1])])
    k = np.clip(np.searchsorted(s, t, side="right") - 1, 0, len(src) - 1)
    return xy, [src[i] for i in k]


def runs(mask, cum, total):
    """[[s_from, s_to], ...] for the True stretches of a closed per-point mask."""
    n = len(mask)
    if mask.all():
        return [[0.0, round(total, 1)]]
    out = []
    i0 = int(np.argmin(mask))  # start scanning at a False point
    i = 0
    while i < n:
        k = (i0 + i) % n
        if mask[k]:
            j = i
            while j < n and mask[(i0 + j) % n]:
                j += 1
            a = cum[k]
            b = cum[(i0 + j) % n] if (i0 + j) % n != 0 else total
            out.append([round(float(a), 1), round(float(b), 1)])
            i = j
        else:
            i += 1
    return out


def open_runs(mask, cum, total):
    out = []
    i = 0
    n = len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            out.append([round(float(cum[i]), 1), round(float(cum[j] if j < n else total), 1)])
            i = j
        else:
            i += 1
    return out


def joker_route(rx, loop_ids, cfg):
    """The joker: the shortest way off the lap and back on to it, through the
    ways that aren't part of the lap, that uses at least one joker way."""
    loop_nodes = set()
    for w in rx:
        if w["id"] in loop_ids:
            loop_nodes.update([w["refs"][0], w["refs"][-1]])
    free = [w for w in rx if w["id"] not in loop_ids]
    out = {}
    for w in free:
        L = float(np.linalg.norm(np.diff(w["xy"], axis=0), axis=1).sum())
        out.setdefault(w["refs"][0], []).append((w["refs"][-1], w, False, L))
        if w["tags"].get("oneway") not in ("yes", "1", "true") or is_joker(w, cfg):
            out.setdefault(w["refs"][-1], []).append((w["refs"][0], w, True, L))
    best = (1e18, None)

    def dfs(node, path, used, length, has_j):
        nonlocal best
        if length >= best[0] or len(path) > 12:
            return
        for nxt, w, rev, L in out.get(node, []):
            if w["id"] in used:
                continue
            p2 = path + [(w, rev)]
            j2 = has_j or is_joker(w, cfg)
            if nxt in loop_nodes:
                if j2 and length + L < best[0]:
                    best = (length + L, p2)
                continue
            used.add(w["id"])
            dfs(nxt, p2, used, length + L, j2)
            used.discard(w["id"])

    for n0 in loop_nodes:
        dfs(n0, [], set(), 0.0, False)
    if best[1] is None:
        return []
    return [dict(w, xy=w["xy"][::-1]) if rev else w for w, rev in best[1]]


def build_joker(centre, jw, default_surface, cfg):
    """Joker path from the joker way(s), joined onto the lap at both ends."""
    if cfg.get("joker_reverse"):
        jw = [dict(w, xy=w["xy"][::-1]) for w in jw]
    path = np.vstack([jw[0]["xy"]] + [w["xy"][1:] for w in jw[1:]])
    # Which end is the entry: one-way tags give the direction when the
    # pieces were chained in order; otherwise the shorter forward span wins.
    total = float(np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1).sum())
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    ia = int(bt.nearest(path[:1], centre)[0][0])
    ib = int(bt.nearest(path[-1:], centre)[0][0])
    fwd = (cum[ib] - cum[ia]) % total
    if fwd > total * 0.5:
        path = path[::-1]
        ia, ib = ib, ia
    # Join each end onto the centre line: lead in from a point on the lap a
    # little before the joker's first point, and out to one a little after.
    lead = cfg.get("joker_lead_m", 0.0)
    def lap_point(s):
        return np.array([np.interp(s % total, np.append(cum, total), np.append(centre[:, 0], centre[0, 0])),
                         np.interp(s % total, np.append(cum, total), np.append(centre[:, 1], centre[0, 1]))])
    entry_s = (cum[ia] - lead) % total
    exit_s = (cum[ib] + lead) % total
    p0 = lap_point(entry_s)
    p1 = lap_point(exit_s)
    full = np.vstack([p0, path, p1])
    full = bt.resample(full, 3.0, False)
    full = bt.smooth(full, 3, False)
    full[0], full[-1] = p0, p1
    # Surface along the joker: from the joker ways' tags.
    jxy = np.vstack([bt.resample(w["xy"], 2.0, False) for w in jw])
    jloose = np.concatenate([[is_loose(w["tags"], default_surface)] * len(bt.resample(w["xy"], 2.0, False)) for w in jw])
    k, _ = bt.nearest(full, jxy)
    loose = jloose[k]
    if cfg.get("joker_surface"):
        loose[:] = cfg["joker_surface"] in LOOSE
    return full, float(entry_s), float(exit_s), loose


def pick_start(centre, src, loose, cfg, ways):
    n = len(centre)
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    if cfg.get("start_frac") is not None:
        cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
        return int(np.argmin(np.abs(cum - cfg["start_frac"] * seg.sum())))
    start_way = cfg.get("start_way")
    tagged = [w for w in ways if w.get("osm_id", w["id"]) == start_way or w["tags"].get("raceway") == "start"]
    best = None
    for w in tagged:
        mid = bt.resample(w["xy"], 1.0, False)
        mid = mid[len(mid) // 2:len(mid) // 2 + 1]
        k, d = bt.nearest(mid, centre)
        L = float(np.linalg.norm(np.diff(w["xy"], axis=0), axis=1).sum())
        if d[0] < 10.0 and (best is None or L > best[0]):
            best = (L, int(k[0]))
    if best is not None:
        return best[1]
    # Longest straight-ish tarmac run: the line sits 60 m into it, so the
    # grid behind it stands on tarmac.
    d = np.roll(centre, -1, 0) - centre
    ang = np.arctan2(d[:, 1], d[:, 0])
    turn = np.abs(np.angle(np.exp(1j * (np.roll(ang, -1) - ang))))
    good = (~loose) & (turn < math.radians(4.0))
    best, best_i = 0, 0
    i0 = int(np.argmin(good)) if not good.all() else 0
    run = 0
    for j in range(n):
        k = (i0 + j) % n
        run = run + 1 if good[k] else 0
        if run > best:
            best, best_i = run, k
    start = (best_i - best + 1) % n
    return (start + min(best - 1, int(60.0 / seg.mean()))) % n


def build(cfg, cache):
    tid = cfg["id"]
    print(f"{tid}:")
    default_surface = cfg.get("default_surface", "asphalt")
    ways = bt.load_osm(cfg, cache, cfg.get("osm_half_m", 700.0))
    rx = rx_ways(ways, cfg)
    main = [w for w in rx if not is_joker(w, cfg)]
    loop, src, used = loop_with_tags(main)
    jw = joker_route(rx, set(used), cfg)
    print(f"   lap from OpenStreetMap ways {sorted(set(int(str(u).split('.')[0]) for u in used))}")
    centre, csrc = resample_tagged(loop, src, 3.0)
    centre = bt.smooth(centre, cfg.get("smooth_passes", 3), True)
    loose = np.array([is_loose(w["tags"], default_surface) for w in csrc])
    if cfg.get("reverse"):
        centre, loose, csrc = centre[::-1].copy(), loose[::-1].copy(), csrc[::-1]
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    if cfg.get("dirt_override"):
        cum = np.concatenate([[0], np.cumsum(seg)[:-1]]) / seg.sum()
        loose[:] = False
        for a, b in cfg["dirt_override"]:
            loose |= ((cum >= a) & (cum < b)) if a <= b else ((cum >= a) | (cum < b))
    start = pick_start(centre, csrc, loose, cfg, rx)
    centre, loose = np.roll(centre, -start, 0), np.roll(loose, -start)
    n = len(centre)
    width = cfg.get("width_m", 12.0) / 2.0
    wr = np.full(n, width)
    wl = np.full(n, width)
    for w_from, w_to, w_m in cfg.get("width_ranges", []):
        cum = np.concatenate([[0], np.cumsum(np.roll(seg, -start))[:-1]]) / seg.sum()
        m = (cum >= w_from) & (cum < w_to)
        wr[m] = wl[m] = w_m / 2.0
    raceline = bt.elastic_raceline(centre, wr, wl, margin=1.4)

    joker = None
    if jw:
        jp, entry_s, exit_s, jloose = build_joker(centre, jw, default_surface, cfg)
        joker = (jp, entry_s, exit_s, jloose)

    # Godot axes: flip Y (left and right swap).
    flip = np.array([1.0, -1.0])
    centre_g = centre * flip
    seg = np.linalg.norm(np.roll(centre_g, -1, 0) - centre_g, axis=1)
    length = float(seg.sum())
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    dirt = runs(loose, cum, length)
    dirt_m = sum(b - a for a, b in dirt)
    out = {
        "format": 1,
        "id": tid,
        "discipline": "rallycross",
        "name": cfg["name"],
        "short_name": cfg.get("short_name", cfg["name"]),
        "location": cfg.get("location", ""),
        "country": cfg.get("country", ""),
        "description": cfg.get("description", ""),
        "length_m": round(length, 1),
        "real_length_m": cfg.get("real_length_m", 0),
        "source": "OpenStreetMap (ODbL) centre line and surfaces",
        "direction_note": "Points are ordered in race direction. Index 0 is the start/finish line.",
        "centerline_format": ["x_m", "y_m", "width_right_m", "width_left_m"],
        "centerline": [[round(p[0], 2), round(p[1], 2), round(float(a), 2), round(float(b), 2)]
                       for p, a, b in zip(centre_g, wl, wr)],
        "raceline": [[round(x, 2), round(y, 2)] for x, y in raceline * flip],
        "start_index": 0,
        "sectors": cfg.get("sectors", [0.0, 0.333, 0.667]),
        "runoff_m": cfg.get("runoff_m", 10.0),
        "kerb_width_m": cfg.get("kerb_width_m", 0.8),
        "default_environment": dict({"ambient_c": 18.0, "track_c": 24.0, "time_of_day_h": 14.0, "weather": "dry"},
                                    **cfg.get("environment", {})),
        "pit_lane": None,
        "dirt": dirt,
    }
    if "climate" in cfg:
        out["climate"] = cfg["climate"]
    jtxt = "no joker found"
    if joker:
        jp, entry_s, exit_s, jloose = joker
        jp_g = jp * flip
        # entry/exit are distances on the un-rolled lap: shift by the start.
        cum0 = np.concatenate([[0], np.cumsum(np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1))[:-1]])
        ia = int(bt.nearest(jp_g[:1], centre_g)[0][0])
        ib = int(bt.nearest(jp_g[-1:], centre_g)[0][0])
        jseg = np.linalg.norm(np.diff(jp_g, axis=0), axis=1)
        jcum = np.concatenate([[0], np.cumsum(jseg)])
        jlen = float(jseg.sum())
        out["joker"] = {
            "source": "OpenStreetMap ways " + ",".join(sorted(set(str(w.get("osm_id", w["id"])) for w in jw))),
            "path": [[round(x, 2), round(y, 2)] for x, y in jp_g],
            "length_m": round(jlen, 1),
            "entry_s": round(float(cum[ia]), 1),
            "exit_s": round(float(cum[ib]), 1),
            "width_m": cfg.get("joker_width_m", cfg.get("width_m", 12.0) * 0.85),
            "dirt": open_runs(jloose, jcum, jlen),
        }
        main_span = (cum[ib] - cum[ia]) % length
        jtxt = f"joker {jlen:.0f} m (replaces {main_span:.0f} m of the lap, entry {cum[ia]:.0f} m, exit {cum[ib]:.0f} m)"
    print(f"   {n} points, {length:.0f} m (real {cfg.get('real_length_m', '?')} m), "
          f"{dirt_m / length * 100:.0f}% loose in {len(dirt)} stretches, {jtxt}")
    lat0, lon0 = bt.osm_center(cfg, cache)
    out["geo"] = {"lat0": lat0, "lon0": lon0, "r": np.eye(2).tolist(), "t": [0.0, 0.0]}
    try:
        add_elevation(out, cfg, cache)
    except Exception as e:
        print("   elevation unavailable:", e)
    add_barriers(out, cfg, cache)
    rx_grass_runoff(out)
    with open(os.path.join(DATA, tid + ".json"), "w") as f:
        json.dump(out, f, separators=(",", ":"))


def rx_grass_runoff(out):
    """Rallycross run-off is grass banks: OSM's gravel areas at these venues
    are mostly the dirt sections of the lap itself, not gravel traps."""
    b = out.get("barriers") or {}
    for side in ("runoff_left", "runoff_right"):
        if isinstance(b.get(side), str):
            b[side] = "G" * len(b[side])
    if b:
        b["source"] = b.get("source", "") + "; grass run-off (rallycross)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/tdr-tracks"))
    args = ap.parse_args()
    with open(os.path.join(HERE, "rx_tracks.json")) as f:
        tracks = json.load(f)["tracks"]
    for cfg in tracks:
        if not args.ids or cfg["id"] in args.ids:
            build(cfg, args.cache)


if __name__ == "__main__":
    main()
