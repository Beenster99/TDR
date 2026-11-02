#!/usr/bin/env python3
"""Build the game's track files (modules/tracks/data/<id>.json) from real-world data.

Every track is listed in tools/tracks.json. For each one this script:

1. Takes the centre line, track widths and racing line from the TUMFTM
   racetrack-database (https://github.com/TUMFTM/racetrack-database, LGPL-3.0)
   when the track is in it ("tumftm": "<name>").
2. Downloads the circuit from OpenStreetMap (ODbL) and lines it up with the
   TUMFTM centre line, to find the real pit lane (and to check the race
   direction). Tracks that TUMFTM doesn't have ("tumftm": null) take their
   centre line straight from OpenStreetMap, with a set width and a racing line
   worked out here.
3. Writes the track JSON: Godot axes (metres, Y down), index 0 = start/finish
   line, points in race direction, plus a "pit_lane" object for wave 3.

Usage:
  python3 modules/tracks/tools/build_tracks.py               # every track
  python3 modules/tracks/tools/build_tracks.py monza spa     # just these
  options: --cache DIR (downloads are kept there, default ~/.cache/tdr-tracks)

Needs Python 3.9+ and numpy, and internet access to raw.githubusercontent.com,
nominatim.openstreetmap.org and api.openstreetmap.org.
"""
import argparse, json, math, os, re, sys, time, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

import numpy as np

from elevation import add_elevation, add_flat_elevation
from barriers import add_barriers
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pit_limit_zone import limit_zone  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
TUM_URL = "https://raw.githubusercontent.com/TUMFTM/racetrack-database/master/{kind}/{name}.csv"
UA = {"User-Agent": "TDR-track-builder/1.0 (https://github.com/Beenster99/TDR)"}
R_EARTH = 6371000.0
PIT_RE = re.compile(r"\b(pit|pits|pitlane|boxengasse|corsia (dei )?box|voie des stands|stands)\b")
NOT_PIT_WORDS = ("support", "old ", "former", "kart", "historic", "paddock", "motogp", "bike")
BAD_SURFACES = ("ground", "dirt", "gravel", "grass", "unpaved", "sand")


# --- downloads -------------------------------------------------------------

def fetch(url, cache_path):
    if os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
        with open(cache_path, "rb") as f:
            return f.read()
    for attempt in range(4):
        try:
            data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=180).read()
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            with open(cache_path, "wb") as f:
                f.write(data)
            time.sleep(1.0)  # be polite to the OSM servers
            return data
        except Exception as e:  # network hiccup: back off and retry
            print(f"   download failed ({e}), retrying", file=sys.stderr)
            time.sleep(2 ** (attempt + 1))
    raise RuntimeError("could not download " + url)


def read_csv(text):
    rows = []
    for line in text.decode().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            rows.append([float(v) for v in line.split(",")])
    return np.array(rows)


def osm_center(cfg, cache):
    if "osm_center" in cfg:
        return cfg["osm_center"]
    q = urllib.parse.urlencode({"q": cfg["osm_query"], "format": "json", "limit": 1})
    r = json.loads(fetch("https://nominatim.openstreetmap.org/search?" + q,
                         os.path.join(cache, "nominatim", cfg["id"] + ".json")))
    if not r:
        raise RuntimeError("OpenStreetMap search found nothing for " + cfg["osm_query"])
    return [float(r[0]["lat"]), float(r[0]["lon"])]


def load_osm(cfg, cache, half_size_m):
    """Every OpenStreetMap way in a square around the circuit, fetched in tiles
    (the API refuses big areas). Coordinates in metres, X east, Y north."""
    lat0, lon0 = osm_center(cfg, cache)
    dlat = half_size_m / R_EARTH * 180 / math.pi
    dlon = dlat / math.cos(math.radians(lat0))
    tiles = max(1, int(math.ceil(half_size_m * 2 / 1500.0)))
    nodes, ways = {}, {}
    for i in range(tiles):
        for j in range(tiles):
            w = lon0 - dlon + 2 * dlon * i / tiles
            s = lat0 - dlat + 2 * dlat * j / tiles
            bbox = f"{w:.5f},{s:.5f},{w + 2 * dlon / tiles:.5f},{s + 2 * dlat / tiles:.5f}"
            try:
                raw = fetch("https://api.openstreetmap.org/api/0.6/map?bbox=" + bbox,
                            os.path.join(cache, "osm", f"{cfg['id']}_{tiles}_{i}_{j}.osm"))
            except RuntimeError as e:
                print("   skipped a map tile:", e)
                continue
            root = ET.fromstring(raw)
            for n in root.iter("node"):
                lat, lon = float(n.get("lat")), float(n.get("lon"))
                nodes[n.get("id")] = (math.radians(lon - lon0) * R_EARTH * math.cos(math.radians(lat0)),
                                      math.radians(lat - lat0) * R_EARTH)
            for wy in root.iter("way"):
                tags = {t.get("k"): t.get("v") for t in wy.iter("tag")}
                if tags.get("highway") not in ("raceway", "service"):
                    continue
                ways[wy.get("id")] = (tags, [nd.get("ref") for nd in wy.iter("nd")])
    out = []
    for wid, (tags, refs) in ways.items():
        refs = [r for r in refs if r in nodes]
        if len(refs) >= 2:
            out.append({"id": int(wid), "tags": tags, "refs": refs, "xy": np.array([nodes[r] for r in refs])})
    return out


def is_pit(w):
    t = w["tags"]
    text = " ".join([t.get("name", ""), t.get("name:en", ""), t.get("service", ""), t.get("raceway", ""),
                     t.get("description", "")]).lower()
    if any(k in text for k in NOT_PIT_WORDS):
        return False
    return t.get("pitlane") == "yes" or t.get("service") == "pit_lane" or bool(PIT_RE.search(text))


def is_main(w, cfg):
    t = w["tags"]
    if t.get("highway") != "raceway" or t.get("area") == "yes" or is_pit(w):
        return False
    if t.get("surface", "asphalt") in BAD_SURFACES:
        return False
    if w["id"] in cfg.get("osm_exclude_ways", []):
        return False
    name = t.get("name", "").lower()
    return not any(x.lower() in name for x in cfg.get("osm_exclude_names", []))


# --- geometry helpers -----------------------------------------------------

def resample(pts, step, closed):
    p = np.vstack([pts, pts[:1]]) if closed else pts
    seg = np.linalg.norm(np.diff(p, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    n = max(int(round(s[-1] / step)), 2)
    t = np.linspace(0, s[-1], n, endpoint=not closed)
    return np.column_stack([np.interp(t, s, p[:, 0]), np.interp(t, s, p[:, 1])])


def smooth(pts, passes, closed):
    p = pts.copy()
    for _ in range(passes):
        if closed:
            p = (np.roll(p, 1, 0) + 2 * p + np.roll(p, -1, 0)) / 4
        else:
            q = p.copy()
            q[1:-1] = (p[:-2] + 2 * p[1:-1] + p[2:]) / 4
            p = q
    return p


def normals(pts):
    d = np.roll(pts, -1, 0) - np.roll(pts, 1, 0)
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    return np.column_stack([-d[:, 1], d[:, 0]])  # left normal in Y-up axes


def nearest(a, b):
    """For each point of a, index of and distance to the nearest point of b."""
    idx = np.empty(len(a), dtype=int)
    dist = np.empty(len(a))
    for k in range(0, len(a), 256):
        d2 = ((a[k:k + 256, None, :] - b[None, :, :]) ** 2).sum(-1)
        idx[k:k + 256] = d2.argmin(1)
        dist[k:k + 256] = np.sqrt(d2.min(1))
    return idx, dist


def project_s(centre, pts):
    """Arc length along the closed centre line of each point's nearest centre point."""
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    idx, _ = nearest(pts, centre)
    return cum[idx], cum, seg.sum(), idx


def rigid_fit(src, dst):
    """Rotation + translation that best maps src points onto dst (Kabsch)."""
    cs, cd = src.mean(0), dst.mean(0)
    u, _, vt = np.linalg.svd((src - cs).T @ (dst - cd))
    r = (u @ vt).T
    if np.linalg.det(r) < 0:
        vt[-1] *= -1
        r = (u @ vt).T
    return r, cd - cs @ r.T


def densify_ways(ways, step=2.0):
    out = []
    for w in ways:
        out.append(resample(w["xy"], step, False))
    return np.vstack(out) if out else np.zeros((0, 2))


# --- OSM main loop (for tracks TUMFTM doesn't have) ------------------------

def main_loop(ways):
    """Longest closed loop through the main raceway ways, following one-way tags."""
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
        raise RuntimeError("no closed raceway loop found in OpenStreetMap data")
    pts = []
    for e in best[1]:
        xy = e[2]["xy"][::-1] if e[3] else e[2]["xy"]
        pts.extend(xy[:-1].tolist())
    return np.array(pts)


def elastic_raceline(centre, wr, wl, margin=1.6, iters=1500):
    """A smooth line that cuts corners within the track: repeatedly pull each
    point towards its neighbours, then keep it inside the track edges."""
    nl = normals(centre)
    off = np.zeros(len(centre))
    for _ in range(iters):
        p = centre + nl * off[:, None]
        target = (np.roll(p, 1, 0) + np.roll(p, -1, 0)) / 2
        off += 0.5 * ((target - p) * nl).sum(1)
        off = np.clip(off, -(wr - margin), wl - margin)
    return smooth(centre + nl * off[:, None], 3, True)


# --- pit lane ---------------------------------------------------------------

def chain_ways(ways, join_m=4.0):
    """Join ways whose ends meet (shared node, or within join_m metres) into
    the longest single polyline."""
    pieces = [w["xy"].copy() for w in ways]
    close = lambda a, b: np.linalg.norm(a - b) <= join_m
    merged = True
    while merged and len(pieces) > 1:
        merged = False
        for i in range(len(pieces)):
            for j in range(len(pieces)):
                if i == j:
                    continue
                a, b = pieces[i], pieces[j]
                if close(a[-1], b[0]):
                    pass
                elif close(a[-1], b[-1]):
                    b = b[::-1]
                elif close(a[0], b[0]):
                    a = a[::-1]
                elif close(a[0], b[-1]):
                    a, b = b, a
                else:
                    continue
                pieces[i] = np.vstack([a, b[1:]])
                pieces.pop(j)
                merged = True
                break
            if merged:
                break
    lengths = [np.linalg.norm(np.diff(p, axis=0), axis=1).sum() for p in pieces]
    return pieces[int(np.argmax(lengths))]


def build_pit(centre, wr, wl, pit_xy, cfg):
    s, cum, total, idx = project_s(centre, pit_xy)
    ds = np.diff(np.unwrap(s / total * 2 * math.pi)) * total / (2 * math.pi)
    if ds.sum() < 0:  # pit lane runs the other way to the race
        pit_xy = pit_xy[::-1]
    pit_xy = resample(pit_xy, 4.0, False)
    pit_xy = smooth(pit_xy, 2, False)
    # Join the lane's ends to the edge of the track if they stop short of it.
    nl = normals(centre)
    ends = []
    for k in (0, -1):
        _, d = nearest(pit_xy[k:k + 1] if k == 0 else pit_xy[-1:], centre)
        i = nearest(pit_xy[k:k + 1] if k == 0 else pit_xy[-1:], centre)[0][0]
        side = np.sign(((pit_xy[k] - centre[i]) * nl[i]).sum()) or 1.0
        edge = centre[i] + nl[i] * (wl[i] if side > 0 else -wr[i]) * 0.8
        ends.append(edge if np.linalg.norm(pit_xy[k] - edge) > 3.0 else None)
    if ends[0] is not None:
        pit_xy = np.vstack([ends[0], pit_xy])
    if ends[1] is not None:
        pit_xy = np.vstack([pit_xy, ends[1]])
    return resample(pit_xy, 4.0, False)


def untagged_pit_ways(ways, centre, wr, wl, to_track):
    """Pit lanes are often mapped as plain unnamed raceways. Find the ways that
    run beside the track near the start/finish line, off the track itself."""
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    total = seg.sum()
    out = []
    for w in ways:
        t = w["tags"]
        if t.get("highway") != "raceway" or t.get("area") == "yes" or t.get("surface", "asphalt") in BAD_SURFACES:
            continue
        xy = resample(to_track(w["xy"]), 3.0, False)
        if np.linalg.norm(np.diff(xy, axis=0), axis=1).sum() < 25.0:
            continue
        idx, d = nearest(xy, centre)
        edge = np.minimum(wr[idx], wl[idx])
        s = cum[idx]
        near_line = np.minimum(s, total - s) < 900.0
        off = d - edge
        if near_line.all() and np.median(off) > 4.0 and np.median(off) < 60.0 and off.max() < 90.0:
            out.append(w)
    if not out:
        return []
    best = chain_ways(out)
    if np.linalg.norm(np.diff(best, axis=0), axis=1).sum() < 200.0:
        return []
    keep = []
    for w in out:  # the ways that make up the longest chain
        if nearest(to_track(w["xy"][:1]), to_track(best))[1][0] < 0.5 or \
                nearest(w["xy"][:1], best)[1][0] < 0.5:
            keep.append(w)
    return keep or out


def synthetic_pit(centre, wr, wl, cfg):
    """A pit lane alongside the main straight, for tracks with no mapped one."""
    side = cfg.get("pit_side_yup", -1)  # -1 right of the track, +1 left (Y-up)
    seg = np.linalg.norm(np.roll(centre, -1, 0) - centre, axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    total = seg.sum()
    nl = normals(centre)
    out = []
    for s in np.arange(-260.0, 200.0, 4.0):
        i = int(np.searchsorted(cum, s % total, side="right") - 1)
        w = wl[i] if side > 0 else wr[i]
        ramp = min(1.0, min(s + 260.0, 200.0 - s) / 70.0)
        out.append(centre[i] + nl[i] * side * (w * 0.8 + ramp * 16.0))
    return np.array(out)


# --- one track ----------------------------------------------------------------

def build(cfg, cache):
    tid = cfg["id"]
    print(f"{tid}:")
    if cfg.get("tumftm"):
        c = read_csv(fetch(TUM_URL.format(kind="tracks", name=cfg["tumftm"]),
                           os.path.join(cache, "tum", cfg["tumftm"] + ".csv")))
        rl = read_csv(fetch(TUM_URL.format(kind="racelines", name=cfg["tumftm"]),
                            os.path.join(cache, "tum", cfg["tumftm"] + "_raceline.csv")))
        centre, wr, wl = c[:, :2], c[:, 2], c[:, 3]
        raceline = rl[:, :2]
        source = "TUMFTM racetrack-database (LGPL-3.0, OpenStreetMap-derived centre line)"
    else:
        centre = wr = wl = raceline = None
        source = "OpenStreetMap (ODbL) centre line"

    pit = None
    pit_source = "none"
    ways = []
    if cfg.get("osm_query") or cfg.get("osm_center"):
        half = 2500.0 if centre is None else float(np.abs(centre).max()) + 1500.0
        try:
            ways = load_osm(cfg, cache, min(half, 4000.0))
        except Exception as e:
            print("   OpenStreetMap unavailable:", e)
    main = [w for w in ways if is_main(w, cfg)]
    pits = [w for w in ways if w["id"] in cfg["pit_ways"]] if cfg.get("pit_ways") else \
        [w for w in ways if is_pit(w) and w["tags"].get("highway") in ("raceway", "service", None)
         and w["tags"].get("area") != "yes" and w["tags"].get("building") is None]

    if centre is None:
        loop = main_loop(main)
        centre = smooth(resample(loop, 5.0, True), 4, True)
        width = cfg.get("width_m", 13.0) / 2.0
        wr = np.full(len(centre), width)
        wl = np.full(len(centre), width)
        to_track = lambda xy: xy
        geo_r, geo_t = np.eye(2), np.zeros(2)
        if pits:
            pit_xy = chain_ways(pits)
            mid = pit_xy[len(pit_xy) // 2:len(pit_xy) // 2 + 1]
            start = int(nearest(mid, centre)[0][0])
            centre, wr, wl = np.roll(centre, -start, 0), np.roll(wr, -start), np.roll(wl, -start)
        if cfg.get("reverse"):
            centre = np.vstack([centre[:1], centre[:0:-1]])
        raceline = elastic_raceline(centre, wr, wl)
        print(f"   centre line from {len(main)} OpenStreetMap ways, {len(centre)} points")
    elif main:
        # Line up OpenStreetMap with the TUMFTM centre line: try every OSM node
        # as the start/finish point, keep the best, then refine (rotation too).
        osm_pts = densify_ways(main)
        probe = centre[::max(1, len(centre) // 120)]
        cand = osm_pts[::max(1, len(osm_pts) // 600)]
        best = (1e18, None)
        for c0 in cand:
            t = c0 - centre[0]
            _, d = nearest(probe + t, osm_pts)
            score = np.median(d)
            if score < best[0]:
                best = (score, t)
        r, t = np.eye(2), best[1]
        for _ in range(30):
            moved = centre @ r.T + t
            idx, d = nearest(moved, osm_pts)
            keep = d < max(4.0 * np.median(d), 8.0)
            r, t = rigid_fit(centre[keep], osm_pts[idx[keep]])
        moved = centre @ r.T + t
        _, d = nearest(moved, osm_pts)
        rot = math.degrees(math.atan2(r[1, 0], r[0, 0]))
        print(f"   lined up with OpenStreetMap: median error {np.median(d):.1f} m, rotation {rot:.2f} deg")
        if np.median(d) > 12.0:
            print("   WARNING: poor match, pit lane skipped")
            pits = []
        geo_r, geo_t = r, t  # tum -> osm: p @ r.T + t
        to_track = lambda xy: (xy - t) @ r
        # Race direction check against one-way tags.
        dots = []
        oneway = [w for w in main if w["tags"].get("oneway") in ("yes", "1")]
        if oneway:
            seg_mid, seg_dir = [], []
            for w in oneway:
                p = to_track(w["xy"])
                for a, b in zip(p[:-1], p[1:]):
                    seg_mid.append((a + b) / 2)
                    seg_dir.append((b - a) / (np.linalg.norm(b - a) + 1e-9))
            seg_mid, seg_dir = np.array(seg_mid), np.array(seg_dir)
            tang = np.roll(centre, -1, 0) - centre
            tang /= np.linalg.norm(tang, axis=1, keepdims=True)
            idx, d = nearest(centre[::5], seg_mid)
            ok = d < 15
            dots = (tang[::5][ok] * seg_dir[idx[ok]]).sum(1)
            agree = float((dots > 0).mean()) if len(dots) else 1.0
            print(f"   race direction agrees with OpenStreetMap one-way tags on {agree * 100:.0f}% of the lap")
            if agree < 0.3:
                print("   WARNING: TUMFTM order looks reversed against OpenStreetMap")
    else:
        to_track = None
        geo_r = geo_t = None

    if not pits and to_track is not None and centre is not None and ways:
        pits = untagged_pit_ways(ways, centre, wr, wl, to_track)
        if pits:
            print(f"   no tagged pit lane, using {len(pits)} untagged way(s) beside the start/finish straight")
    if pits and to_track is not None:
        pit = build_pit(centre, wr, wl, to_track(chain_ways(pits)), cfg)
        pit_source = "OpenStreetMap ways " + ",".join(str(w["id"]) for w in pits)
    if pit is None or len(pit) < 10:
        pit = synthetic_pit(centre, wr, wl, cfg)
        pit_source = "estimated alongside the main straight (no mapped pit lane found)"
    print(f"   pit lane: {pit_source}")

    # Godot axes: flip Y. That mirrors left/right, so the widths swap.
    flip = np.array([1.0, -1.0])
    centre_g = centre * flip
    raceline_g = raceline * flip
    pit_g = pit * flip
    n = len(centre_g)
    seg = np.linalg.norm(np.roll(centre_g, -1, 0) - centre_g, axis=1)
    length = float(seg.sum())
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])

    # Pit lane facts, in Godot axes ("right" = right of the race direction).
    idx, _ = nearest(pit_g, centre_g)
    tang = np.roll(centre_g, -1, 0) - centre_g
    tang /= np.linalg.norm(tang, axis=1, keepdims=True)
    right = np.column_stack([-tang[:, 1], tang[:, 0]])
    mid = len(pit_g) // 2
    side = "right" if ((pit_g[mid] - centre_g[idx[mid]]) * right[idx[mid]]).sum() > 0 else "left"
    plen = float(np.linalg.norm(np.diff(pit_g, axis=0), axis=1).sum())
    pit_lane = {
        "source": pit_source,
        "side": side,
        "path": [[round(x, 2), round(y, 2)] for x, y in pit_g],
        "length_m": round(plen, 1),
        "entry_s": round(float(cum[idx[0]]), 1),
        "exit_s": round(float(cum[idx[-1]]), 1),
        "width_m": cfg.get("pit_width_m", 12.0),
        "speed_limit_kph": cfg.get("pit_speed_kph", 60),
        # Speed limit around the garages by the start/finish line (see pit_limit_zone.py).
        "limit_start_m": limit_zone(pit_g.tolist(), centre_g[0].tolist())[0],
        "limit_end_m": limit_zone(pit_g.tolist(), centre_g[0].tolist())[1],
        "box_count": cfg.get("pit_boxes", 30),
    }
    straddles = pit_lane["entry_s"] > pit_lane["exit_s"]
    print(f"   {n} points, {length:.0f} m (real {cfg.get('real_length_m', '?')} m), pit lane {plen:.0f} m on the {side},"
          f" entry {pit_lane['entry_s']:.0f} m, exit {pit_lane['exit_s']:.0f} m{'' if straddles else '  (does not cross the line)'}")

    env = {"ambient_c": 22.0, "track_c": 32.0, "time_of_day_h": 14.0, "weather": "dry"}
    env.update(cfg.get("environment", {}))
    out = {
        "format": 1,
        "id": tid,
        "name": cfg["name"],
        "short_name": cfg.get("short_name", cfg["name"]),
        "location": cfg.get("location", ""),
        "country": cfg.get("country", ""),
        "description": cfg.get("description", ""),
        "length_m": round(length, 1),
        "real_length_m": cfg.get("real_length_m", 0),
        "source": source,
        "direction_note": "Points are ordered in race direction. Index 0 is the start/finish line.",
        "centerline_format": ["x_m", "y_m", "width_right_m", "width_left_m"],
        "centerline": [[round(p[0], 2), round(p[1], 2), round(float(a), 2), round(float(b), 2)]
                       for p, a, b in zip(centre_g, wl, wr)],
        "raceline": [[round(x, 2), round(y, 2)] for x, y in raceline_g],
        "start_index": 0,
        "sectors": cfg.get("sectors", [0.0, 0.333, 0.667]),
        "runoff_m": cfg.get("runoff_m", 30.0),
        "kerb_width_m": 1.2,
        "default_environment": env,
        "pit_lane": pit_lane,
    }
    if "climate" in cfg:
        out["climate"] = cfg["climate"]
    if geo_r is not None:
        # Where the track is on Earth: game (x, y) -> east/north metres from
        # (lat0, lon0) is ((x, -y) @ r.T + t). Used for elevation.
        lat0, lon0 = osm_center(cfg, cache)
        out["geo"] = {"lat0": lat0, "lon0": lon0, "r": np.round(geo_r, 8).tolist(),
                      "t": np.round(geo_t, 3).tolist()}
        try:
            add_elevation(out, cfg, cache)
        except Exception as e:
            print("   elevation unavailable:", e)
    elif cfg.get("flat_if_unplaced"):
        add_flat_elevation(out)
    add_barriers(out, cfg, cache)
    with open(os.path.join(DATA, tid + ".json"), "w") as f:
        json.dump(out, f, separators=(",", ":"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/tdr-tracks"))
    args = ap.parse_args()
    with open(os.path.join(HERE, "tracks.json")) as f:
        tracks = json.load(f)["tracks"]
    for cfg in tracks:
        if not args.ids or cfg["id"] in args.ids:
            build(cfg, args.cache)


if __name__ == "__main__":
    main()
