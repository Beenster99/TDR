#!/usr/bin/env python3
"""Real elevation for the track files.

Heights come from the Terrarium elevation tiles on AWS Open Data
(https://registry.opendata.aws/terrain-tiles/, no key needed), which merge
SRTM, NASA/USGS and national lidar data sets. build_tracks.py calls
add_elevation() for each track it builds; this file can also be run on its
own to add or refresh elevation in track files that already have a "geo"
block, without downloading OpenStreetMap again:

  python3 modules/tracks/tools/elevation.py              # every track
  python3 modules/tracks/tools/elevation.py spa mugello  # just these

The raw surface model includes trees and buildings and is only ~30 m sharp in
many countries, so the track line is cleaned up: heights are taken across the
tarmac only (median), smoothed along the lap, and gradients are limited to
what real circuits have. Banking comes from "banking" entries in tracks.json
plus a small camber estimated from the hillside the track runs across.
"""
import io, json, math, os, sys, urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
TILE_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
ZOOM = 15
R_EARTH = 6371000.0
SMOOTH_SIGMA_M = 32.0     # along-lap smoothing of the raw heights
MEDIAN_HALF_M = 75.0      # rolling median half-window along the lap
MAX_GRADE = 0.18          # steepest real circuits are ~17-18% (Eau Rouge)
CAMBER_MAX_DEG = 3.0      # estimated camber from the hillside is kept gentle
TERRAIN_CELL_M = 20.0
TERRAIN_MARGIN_M = 600.0  # matches the grass TrackView draws around the track
BLEND_M = 60.0            # terrain eases from the track's height to the hillside over this


# --- tiles -------------------------------------------------------------------

class Dem:
    """Bilinear lookup into Terrarium tiles at one zoom level, cached on disk."""

    def __init__(self, cache):
        self.cache = os.path.join(cache, "terrarium")
        self.tiles = {}

    def _tile(self, x, y):
        key = (x, y)
        if key not in self.tiles:
            path = os.path.join(self.cache, str(ZOOM), str(x), f"{y}.png")
            if not (os.path.exists(path) and os.path.getsize(path) > 0):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                data = None
                for attempt in range(4):
                    try:
                        data = urllib.request.urlopen(TILE_URL.format(z=ZOOM, x=x, y=y), timeout=60).read()
                        break
                    except Exception as e:
                        print(f"   elevation tile failed ({e}), retrying", file=sys.stderr)
                if data is None:
                    raise RuntimeError(f"could not download elevation tile {x},{y}")
                with open(path, "wb") as f:
                    f.write(data)
            from PIL import Image
            rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
            self.tiles[key] = rgb[:, :, 0] * 256.0 + rgb[:, :, 1] + rgb[:, :, 2] / 256.0 - 32768.0
        return self.tiles[key]

    def sample(self, lat, lon):
        lat = np.asarray(lat, dtype=np.float64)
        lon = np.asarray(lon, dtype=np.float64)
        n = 2.0 ** ZOOM * 256.0
        px = (lon + 180.0) / 360.0 * n - 0.5
        lr = np.radians(lat)
        py = (1.0 - np.log(np.tan(lr) + 1.0 / np.cos(lr)) / math.pi) / 2.0 * n - 0.5
        x0 = np.floor(px).astype(int)
        y0 = np.floor(py).astype(int)
        fx = px - x0
        fy = py - y0
        out = np.zeros(px.shape)
        for dx, dy, w in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                          (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
            gx, gy = x0 + dx, y0 + dy
            vals = np.empty(px.shape)
            tx, ty = gx // 256, gy // 256
            for key in set(zip(tx.ravel().tolist(), ty.ravel().tolist())):
                m = (tx == key[0]) & (ty == key[1])
                t = self._tile(*key)
                vals[m] = t[gy[m] - key[1] * 256, gx[m] - key[0] * 256]
            out += w * vals
        return out


# --- geometry ----------------------------------------------------------------

def game_to_latlon(xy, geo):
    """Game metres (x, y down) -> latitude, longitude."""
    r = np.array(geo["r"])
    t = np.array(geo["t"])
    enu = (np.asarray(xy) * np.array([1.0, -1.0])) @ r.T + t
    lat0, lon0 = geo["lat0"], geo["lon0"]
    lat = lat0 + np.degrees(enu[..., 1] / R_EARTH)
    lon = lon0 + np.degrees(enu[..., 0] / (R_EARTH * math.cos(math.radians(lat0))))
    return lat, lon


def gauss_closed(v, s_step, sigma_m):
    """Gaussian smoothing of a closed-loop signal sampled every s_step metres."""
    k = max(1, int(round(3 * sigma_m / s_step)))
    w = np.exp(-0.5 * (np.arange(-k, k + 1) * s_step / sigma_m) ** 2)
    w /= w.sum()
    out = np.zeros_like(v)
    for j, wj in zip(range(-k, k + 1), w):
        out += wj * np.roll(v, -j)
    return out


def gauss_open(v, s_step, sigma_m):
    k = max(1, int(round(3 * sigma_m / s_step)))
    pad = np.concatenate([np.full(k, v[0]), v, np.full(k, v[-1])])
    w = np.exp(-0.5 * (np.arange(-k, k + 1) * s_step / sigma_m) ** 2)
    return np.convolve(pad, w / w.sum(), mode="valid")


def limit_grade(h, seg, max_grade, closed=True):
    """Pull heights in until no segment is steeper than max_grade."""
    h = h.copy()
    for _ in range(3000):
        dh = (np.roll(h, -1) - h) if closed else np.append(np.diff(h), 0.0)
        excess = np.abs(dh) - max_grade * seg
        bad = excess > 1e-4
        if not bad.any():
            break
        corr = np.where(bad, np.sign(dh) * excess * 0.5, 0.0)
        h += corr
        h -= np.roll(corr, 1) if closed else np.concatenate([[0.0], corr[:-1]])
    return h


def tangents_normals(pts):
    d = np.roll(pts, -1, 0) - np.roll(pts, 1, 0)
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    right = np.column_stack([-d[:, 1], d[:, 0]])  # right of travel, game axes (Y down)
    return d, right


# --- one track ---------------------------------------------------------------

def add_flat_elevation(out):
    """For a track we can't place on the map (no OpenStreetMap match): level
    ground. Only used for genuinely flat circuits (Albert Park)."""
    pts = np.array(out["centerline"], dtype=np.float64)[:, :2]
    lo = pts.min(0) - TERRAIN_MARGIN_M
    hi = pts.max(0) + TERRAIN_MARGIN_M
    nx = int(math.ceil((hi[0] - lo[0]) / TERRAIN_CELL_M)) + 1
    ny = int(math.ceil((hi[1] - lo[1]) / TERRAIN_CELL_M)) + 1
    out["elevation"] = {
        "source": "flat: the circuit could not be placed on the elevation map",
        "base_alt_m": 0.0,
        "height_m": [0.0] * len(pts),
        "bank_deg": [0.0] * len(pts),
        "pit_height_m": [0.0] * len((out.get("pit_lane") or {}).get("path", [])),
        "terrain": {"origin": [round(float(lo[0]), 2), round(float(lo[1]), 2)], "cell_m": TERRAIN_CELL_M,
                    "size": [nx, ny], "height_dm": [0] * (nx * ny)},
    }
    print("   elevation: flat (no georeference)")


def add_elevation(out, cfg, cache):
    geo = out["geo"]
    dem = Dem(cache)
    cl = np.array(out["centerline"], dtype=np.float64)
    pts, wr, wl = cl[:, :2], cl[:, 2], cl[:, 3]
    n = len(pts)
    seg = np.linalg.norm(np.roll(pts, -1, 0) - pts, axis=1)
    step = float(seg.mean())
    _, right = tangents_normals(pts)

    # Raw heights across the tarmac only, median per point (trees and stands
    # at the edge of a 30 m DEM cell lift single samples).
    fr = np.linspace(-0.8, 0.8, 7)
    samples = []
    for f in fr:
        off = np.where(f >= 0, f * wr, f * wl)
        samples.append(dem.sample(*game_to_latlon(pts + right * off[:, None], geo)))
    raw = np.percentile(np.array(samples), 30, axis=0)
    # A rolling median along the lap removes short humps and holes (stands,
    # bridges, buildings, tunnels, gaps in the data) before smoothing.
    k = max(1, int(round(MEDIAN_HALF_M / step)))
    raw = np.median(np.array([np.roll(raw, j) for j in range(-k, k + 1)]), axis=0)
    # Per-track tuning in tracks.json, for noisy data (cities, stadiums):
    # "elevation": {"smooth_m": 80, "max_grade": 0.05}
    tune = cfg.get("elevation", {})
    h = gauss_closed(raw, step, tune.get("smooth_m", SMOOTH_SIGMA_M))
    h = limit_grade(h, seg, tune.get("max_grade", MAX_GRADE))

    # Camber estimated from the hillside across the track (gentle), plus any
    # real banking listed in tracks.json: [{"from_m", "to_m", "deg"}], +deg =
    # inside of a right-hand corner lower... (positive = right side lower).
    side = 25.0
    hr = dem.sample(*game_to_latlon(pts + right * (wr + side)[:, None], geo))
    hl = dem.sample(*game_to_latlon(pts - right * (wl + side)[:, None], geo))
    cross = (hl - hr) / (wr + wl + 2 * side)  # >0: right side lower
    cross = gauss_closed(cross, step, 60.0)
    bank = np.clip(np.degrees(np.arctan(cross)) * 0.5, -CAMBER_MAX_DEG, CAMBER_MAX_DEG)
    cum = np.concatenate([[0], np.cumsum(seg)[:-1]])
    for b in cfg.get("banking", []):
        a, z = b["from_m"], b["to_m"]
        inside = (cum >= a) & (cum <= z) if a <= z else (cum >= a) | (cum <= z)
        ramp = np.clip(np.minimum((cum - a) % out["length_m"], (z - cum) % out["length_m"]) / 40.0, 0, 1)
        bank = np.where(inside, bank * (1 - ramp) + b["deg"] * ramp, bank)
    bank = gauss_closed(bank, step, 15.0)

    # Pit lane: its own heights, eased into the track's at both ends.
    pit = out.get("pit_lane") or {}
    pit_h = None
    if len(pit.get("path", [])) >= 2:
        pp = np.array(pit["path"], dtype=np.float64)
        pseg = np.linalg.norm(np.diff(pp, axis=0), axis=1)
        praw = dem.sample(*game_to_latlon(pp, geo))
        ph = gauss_open(praw, max(float(pseg.mean()), 1.0), SMOOTH_SIGMA_M)
        d2 = ((pp[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
        near = d2.argmin(1)
        track_here = h[near]
        pcum = np.concatenate([[0], np.cumsum(pseg)])
        ease = np.clip(np.minimum(pcum, pcum[-1] - pcum) / 120.0, 0, 1)
        ph = track_here * (1 - ease) + ph * ease
        # the lane sits beside the track: keep it within a few metres of it
        ph = np.clip(ph, track_here - 4.0, track_here + 4.0)
        pit_h = limit_grade(ph, np.append(pseg, 1.0), MAX_GRADE, closed=False)

    # Terrain grid around the circuit, easing into the track near its edges.
    lo = pts.min(0) - TERRAIN_MARGIN_M
    hi = pts.max(0) + TERRAIN_MARGIN_M
    nx = int(math.ceil((hi[0] - lo[0]) / TERRAIN_CELL_M)) + 1
    ny = int(math.ceil((hi[1] - lo[1]) / TERRAIN_CELL_M)) + 1
    gx, gy = np.meshgrid(lo[0] + np.arange(nx) * TERRAIN_CELL_M, lo[1] + np.arange(ny) * TERRAIN_CELL_M)
    grid = np.column_stack([gx.ravel(), gy.ravel()])
    terr = dem.sample(*game_to_latlon(grid, geo))
    dense = pts[::1]
    idx = np.empty(len(grid), dtype=int)
    dist = np.empty(len(grid))
    for k in range(0, len(grid), 512):
        d2 = ((grid[k:k + 512, None, :] - dense[None, :, :]) ** 2).sum(-1)
        idx[k:k + 512] = d2.argmin(1)
        dist[k:k + 512] = np.sqrt(d2.min(1))
    edge = np.maximum(wr, wl)[idx] + out.get("runoff_m", 30.0)
    t = np.clip((dist - edge) / BLEND_M, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    terr = h[idx] * (1 - t) + terr * t
    if pit_h is not None:
        pd2 = ((grid[:, None, :] - pp[None, :, :]) ** 2).sum(-1)
        pidx = pd2.argmin(1)
        pdist = np.sqrt(pd2.min(1))
        pt = np.clip((pdist - pit.get("width_m", 12.0)) / BLEND_M, 0.0, 1.0)
        pt = pt * pt * (3 - 2 * pt)
        terr = np.where(pdist < dist, pit_h[pidx] * (1 - pt) + terr * pt, terr)

    base = float(min(h.min(), terr.min()))
    out["elevation"] = {
        "source": "Terrarium elevation tiles, AWS Open Data (SRTM, USGS 3DEP, national lidar), smoothed",
        "base_alt_m": round(base, 1),
        "height_m": [round(float(v - base), 2) for v in h],
        "bank_deg": [round(float(v), 2) for v in bank],
        "pit_height_m": [round(float(v - base), 2) for v in pit_h] if pit_h is not None else [],
        "terrain": {
            "origin": [round(float(lo[0]), 2), round(float(lo[1]), 2)],
            "cell_m": TERRAIN_CELL_M,
            "size": [nx, ny],
            "height_dm": [int(round((v - base) * 10)) for v in terr],
        },
    }
    grades = np.diff(np.append(h, h[0])) / np.maximum(seg, 1e-6)
    print(f"   elevation: {h.max() - h.min():.1f} m from lowest to highest point, "
          f"steepest {grades.max() * 100:.1f}% up / {-grades.min() * 100:.1f}% down, "
          f"bank {bank.min():.1f}..{bank.max():.1f} deg, terrain {nx}x{ny}")


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
        if "geo" not in out:
            if cfg.get("flat_if_unplaced"):
                print(cfg["id"] + ":")
                add_flat_elevation(out)
                with open(path, "w") as f:
                    json.dump(out, f, separators=(",", ":"))
            else:
                print(f"{cfg['id']}: no geo block, run build_tracks.py first")
            continue
        print(cfg["id"] + ":")
        add_elevation(out, cfg, args.cache)
        with open(path, "w") as f:
            json.dump(out, f, separators=(",", ":"))


if __name__ == "__main__":
    main()
