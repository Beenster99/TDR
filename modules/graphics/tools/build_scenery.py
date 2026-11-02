#!/usr/bin/env python3
"""Real trackside scenery for a circuit, from open data.

Builds modules/graphics/data/scenery/<track>.json: the buildings (with real
heights where known), grandstands, bridges and trees around a circuit, plus a
painted ground map (fields, woods, car parks with their bays, roads, paths,
water, gravel, the circuit's other loops). Trackside (graphics) turns it into
3D objects, so a circuit looks like itself from above.

Sources (all openly licensed, credited in the output's "sources"):
  - OpenStreetMap (ODbL): footprints, names, landuse, roads, trees, hedges.
  - Environment Agency LIDAR Composite DSM 1 m (Open Government Licence),
    England only, opt in per track with "lidar": "ea_england" in
    tools/scenery.json: real building and bridge heights, and every tree
    and hedge where it actually stands.
Satellite imagery from Google and the like is NOT used (their terms forbid
copying it); it is fine as a visual reference when checking a result.

Usage:
  python3 modules/graphics/tools/build_scenery.py silverstone [more ids]
  options: --cache DIR (downloads are kept there, default ~/.cache/tdr-tracks)
           --no-lidar  (OSM only, even where LIDAR is configured)
Needs numpy and Pillow; LIDAR also needs scipy, pyproj and tifffile
(pip install scipy pyproj tifffile imagecodecs).

To add a track: run the tracks module's build_tracks.py first (the track JSON
must have "geo"), add an entry to tools/scenery.json, then run this.
"""

import argparse
import base64
import glob
import io
import json
import math
import os
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
import zlib

import numpy as np
import logging
logging.getLogger('tifffile').setLevel(logging.ERROR)
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
TRACKS = os.path.join(ROOT, "modules", "tracks", "data")
OUT = os.path.join(ROOT, "modules", "graphics", "data", "scenery")
R_EARTH = 6378137.0
UA = {"User-Agent": "TDR-scenery-builder/1.0 (top-down racer, open data)"}

GROUND_CELL = 1.5          # metres per ground-map pixel
SUPERSAMPLE = 3            # drawn bigger, then shrunk: smooth edges
TILE_DEG_M = 800.0         # OSM API download tile size (m)

# --- ground map colours (RGBA 0..255); alpha 0 keeps the game's own grass ----

C = {
    "field": [(124, 118, 66, 255), (104, 112, 58, 255), (138, 116, 80, 255), (96, 108, 54, 255), (150, 136, 84, 255)],
    "grass": [(70, 104, 46, 150), (78, 112, 50, 150), (64, 96, 42, 150)],
    "scrub": (66, 82, 40, 230),
    "wood": (34, 52, 24, 255),
    "residential": (92, 100, 72, 170),
    "industrial": (112, 112, 108, 230),
    "farmyard": (122, 114, 96, 230),
    "water": (40, 62, 74, 255),
    "sand": (196, 182, 140, 255),
    "dirt": (128, 108, 78, 255),
    "asphalt": (78, 78, 82, 255),
    "parking": (88, 88, 92, 255),
    "parking_grass": (98, 110, 62, 220),
    "bay_line": (196, 196, 190, 255),
    "road": (62, 62, 66, 255),
    "road_line": (200, 200, 190, 255),
    "path": (150, 144, 128, 230),
    "track_dirt": (126, 110, 82, 220),
    "raceway": (70, 70, 74, 255),
    "hedge": (40, 58, 28, 255),
    "footprint": (70, 70, 70, 255),
    "pitch": (74, 124, 50, 200),
}

ROAD_W = {"motorway": 11, "trunk": 10, "primary": 8.5, "secondary": 7.5, "tertiary": 7, "unclassified": 6,
          "residential": 6, "living_street": 5, "service": 4.5, "motorway_link": 6, "trunk_link": 6,
          "primary_link": 6, "secondary_link": 6, "tertiary_link": 6}
PATHS = {"footway": 1.8, "path": 1.4, "cycleway": 2.2, "bridleway": 2.0, "pedestrian": 4.0, "steps": 2.0}

HOUSE = ("house", "detached", "semidetached_house", "terrace", "bungalow", "residential", "apartments", "cottage")
SHED = ("garage", "garages", "shed", "carport", "hut")


# --- downloads -------------------------------------------------------------

def fetch(url, cache_path, timeout=180):
    if os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
        with open(cache_path, "rb") as f:
            return f.read()
    for attempt in range(4):
        try:
            data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout).read()
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            with open(cache_path, "wb") as f:
                f.write(data)
            time.sleep(1.0)  # be polite
            return data
        except Exception as e:
            print(f"   download failed ({e}), retrying", file=sys.stderr)
            time.sleep(2 ** (attempt + 1))
    raise RuntimeError("could not download " + url)


# --- the track's place on Earth ---------------------------------------------

class Geo:
    """Game metres (x, y) <-> OSM east/north metres around (lat0, lon0) <-> lat/lon.
    Same transform as the tracks module: east/north = (x, -y) @ r.T + t."""

    def __init__(self, g):
        self.lat0, self.lon0 = g["lat0"], g["lon0"]
        self.r = np.array(g["r"])
        self.t = np.array(g["t"])
        self.kx = R_EARTH * math.cos(math.radians(self.lat0))

    def ll_to_en(self, lat, lon):
        return np.stack([np.radians(np.asarray(lon) - self.lon0) * self.kx,
                         np.radians(np.asarray(lat) - self.lat0) * R_EARTH], -1)

    def en_to_game(self, en):
        return ((np.asarray(en) - self.t) @ self.r) * np.array([1.0, -1.0])

    def game_to_ll(self, xy):
        xy = np.asarray(xy, dtype=float)
        en = (xy * np.array([1.0, -1.0])) @ self.r.T + self.t
        return (self.lat0 + np.degrees(en[..., 1] / R_EARTH),
                self.lon0 + np.degrees(en[..., 0] / self.kx))


def terrain_bounds(track):
    """The square the game's terrain covers (TrackView._bounds)."""
    pts = np.array([p[:2] for p in track["centerline"]])
    if track.get("pit_lane"):
        pts = np.vstack([pts, np.array(track["pit_lane"]["path"])])
    lo, hi = pts.min(0), pts.max(0)
    m = track.get("runoff_m", 30.0) + 420.0
    lo, hi = lo - m, hi + m
    side = max(hi - lo) * 1.5
    c = (lo + hi) * 0.5
    return c - side * 0.5, np.array([side, side])


class Clearance:
    """Distance from the nearest road (track or pit lane) edge, on a 4 m grid."""

    def __init__(self, track, origin, size, cell=4.0):
        self.o, self.cell = origin, cell
        n = (size / cell).astype(int) + 1
        gx, gy = np.meshgrid(origin[0] + (np.arange(n[0]) + 0.5) * cell, origin[1] + (np.arange(n[1]) + 0.5) * cell)
        P = np.stack([gx.ravel(), gy.ravel()], -1)
        cl = np.array(track["centerline"])
        segs = [(cl[:, :2], np.maximum(cl[:, 2], cl[:, 3]), True)]
        if track.get("pit_lane"):
            pp = np.array(track["pit_lane"]["path"])
            segs.append((pp, np.full(len(pp), track["pit_lane"].get("width_m", 12.0) * 0.5), False))
        best = np.full(len(P), 1e9)
        for pts, hw, _closed in segs:
            for k in range(0, len(pts), 2):
                d = np.hypot(P[:, 0] - pts[k, 0], P[:, 1] - pts[k, 1]) - hw[k]
                np.minimum(best, d, out=best)
        self.f = best.reshape(n[1], n[0])

    def at(self, xy):
        xy = np.atleast_2d(xy)
        i = np.clip(((xy - self.o) / self.cell).astype(int), 0, [self.f.shape[1] - 1, self.f.shape[0] - 1])
        return self.f[i[:, 1], i[:, 0]]


# --- OpenStreetMap ---------------------------------------------------------

def load_osm(tid, geo, origin, size, cache):
    corners = np.array([origin, origin + [size[0], 0], origin + size, origin + [0, size[1]]])
    lat, lon = geo.game_to_ll(corners)
    S, N, W, E = lat.min(), lat.max(), lon.min(), lon.max()
    n = max(1, int(math.ceil(size.max() / TILE_DEG_M)))
    nodes, ways, rels, tagged_nodes = {}, {}, {}, {}
    for i in range(n):
        for j in range(n):
            w, s = W + (E - W) * i / n, S + (N - S) * j / n
            bbox = f"{w:.5f},{s:.5f},{w + (E - W) / n:.5f},{s + (N - S) / n:.5f}"
            try:
                raw = fetch("https://api.openstreetmap.org/api/0.6/map?bbox=" + bbox,
                            os.path.join(cache, "scenery", f"{tid}_{n}_{i}_{j}.osm"))
            except RuntimeError as e:
                print("   skipped a map tile:", e)
                continue
            root = ET.fromstring(raw)
            for nd in root.iter("node"):
                nodes[nd.get("id")] = (float(nd.get("lat")), float(nd.get("lon")))
                tg = {t.get("k"): t.get("v") for t in nd.iter("tag")}
                if tg:
                    tagged_nodes[nd.get("id")] = tg
            for wy in root.iter("way"):
                ways[wy.get("id")] = ({t.get("k"): t.get("v") for t in wy.iter("tag")},
                                      [x.get("ref") for x in wy.iter("nd")])
            for rl in root.iter("relation"):
                rels[rl.get("id")] = ({t.get("k"): t.get("v") for t in rl.iter("tag")},
                                      [(m.get("type"), m.get("ref"), m.get("role")) for m in rl.iter("member")])
    ids = list(nodes)
    ll = np.array([nodes[k] for k in ids])
    g = geo.en_to_game(geo.ll_to_en(ll[:, 0], ll[:, 1]))
    xy = {k: g[i] for i, k in enumerate(ids)}
    return xy, ways, rels, tagged_nodes


def way_xy(refs, xy):
    pts = [xy[r] for r in refs if r in xy]
    return np.array(pts) if len(pts) >= 2 else None


def join_rings(parts):
    """Chain multipolygon member ways into closed rings."""
    parts = [list(p) for p in parts if len(p) >= 2]
    rings = []
    while parts:
        ring = parts.pop(0)
        changed = True
        while ring[0] != ring[-1] and changed:
            changed = False
            for k, p in enumerate(parts):
                if p[0] == ring[-1]:
                    ring += p[1:]
                elif p[-1] == ring[-1]:
                    ring += p[::-1][1:]
                elif p[-1] == ring[0]:
                    ring = p[:-1] + ring
                elif p[0] == ring[0]:
                    ring = p[::-1][:-1] + ring
                else:
                    continue
                parts.pop(k)
                changed = True
                break
        if ring[0] == ring[-1] and len(ring) >= 4:
            rings.append(ring)
    return rings


def areas(ways, rels):
    """Every closed area: (tags, outer rings [refs], inner rings [refs])."""
    out = []
    for tags, refs in ways.values():
        if len(refs) >= 4 and refs[0] == refs[-1]:
            out.append((tags, [refs], []))
    for tags, members in rels.values():
        if tags.get("type") != "multipolygon":
            continue
        outer = [ways[r][1] for t, r, role in members if t == "way" and role != "inner" and r in ways]
        inner = [ways[r][1] for t, r, role in members if t == "way" and role == "inner" and r in ways]
        if outer:
            out.append((tags, join_rings(outer), join_rings(inner)))
    return out


def poly_area(p):
    return 0.5 * abs(np.dot(p[:, 0], np.roll(p[:, 1], 1)) - np.dot(p[:, 1], np.roll(p[:, 0], 1)))


def simplify(p, tol):
    """Douglas-Peucker on an open or closed polyline."""
    if len(p) < 4:
        return p
    keep = np.zeros(len(p), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(p) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        d = p[b] - p[a]
        L = np.hypot(*d)
        seg = p[a + 1:b] - p[a]
        dist = np.abs(seg[:, 0] * d[1] - seg[:, 1] * d[0]) / L if L > 1e-9 else np.hypot(seg[:, 0], seg[:, 1])
        k = int(np.argmax(dist))
        if dist[k] > tol:
            keep[a + 1 + k] = True
            stack += [(a, a + 1 + k), (a + 1 + k, b)]
    return p[keep]


def inside(poly, pts):
    x, y = pts[:, 0], pts[:, 1]
    res = np.zeros(len(pts), dtype=bool)
    px, py = poly[:, 0], poly[:, 1]
    j = len(poly) - 1
    for i in range(len(poly)):
        cond = ((py[i] > y) != (py[j] > y)) & (x < (px[j] - px[i]) * (y - py[i]) / (py[j] - py[i] + 1e-12) + px[i])
        res ^= cond
        j = i
    return res


def parse_m(v):
    try:
        return float(str(v).replace("m", "").strip().split(";")[0])
    except (TypeError, ValueError):
        return None


# --- LIDAR (England) --------------------------------------------------------

EA_DSM = ("https://environment.data.gov.uk/geoservices/datasets/9ba4d5ac-d596-445a-9056-dae3ddec0178/wcs"
          "?service=WCS&version=2.0.1&request=GetCoverage"
          "&coverageId=9ba4d5ac-d596-445a-9056-dae3ddec0178__Lidar_Composite_Elevation_LZ_DSM_1m"
          "&format=image/tiff&subset=E({e0},{e1})&subset=N({n0},{n1})")


class Lidar:
    """The EA 1 m surface model resampled onto a game-aligned 1 m grid, plus an
    estimate of the bare ground under it, so surface - ground = how tall a
    building or tree is."""

    def __init__(self, tid, geo, origin, size, cache):
        import tifffile
        from pyproj import Transformer
        from scipy import ndimage
        self.o = origin
        n = np.ceil(size).astype(int)
        gx, gy = np.meshgrid(origin[0] + np.arange(n[0]) + 0.5, origin[1] + np.arange(n[1]) + 0.5)
        lat, lon = geo.game_to_ll(np.stack([gx, gy], -1))
        tr = Transformer.from_crs(4326, 27700, always_xy=True)
        E, N = tr.transform(lon, lat)
        e0, e1 = int(np.floor(E.min())) - 2, int(np.ceil(E.max())) + 2
        n0, n1 = int(np.floor(N.min())) - 2, int(np.ceil(N.max())) + 2
        dsm = np.full((n1 - n0, e1 - e0), np.nan, np.float32)  # row 0 = north edge n1
        step = 1000
        for ea in range(e0, e1, step):
            for no in range(n0, n1, step):
                ea1, no1 = min(ea + step, e1), min(no + step, n1)
                raw = fetch(EA_DSM.format(e0=ea, e1=ea1, n0=no, n1=no1),
                            os.path.join(cache, "lidar", f"ea_dsm_{ea}_{no}_{ea1}_{no1}.tif"), timeout=300)
                try:
                    a = tifffile.imread(io.BytesIO(raw)).astype(np.float32)
                except Exception as e:
                    print("   LIDAR tile unreadable:", e)
                    continue
                a[(a < -100) | (a > 2000)] = np.nan
                r0, c0 = n1 - no1, ea - e0
                a = a[:dsm.shape[0] - r0, :dsm.shape[1] - c0]
                dsm[r0:r0 + a.shape[0], c0:c0 + a.shape[1]] = a
        # fill holes (water, no data) with the neighbourhood
        mask = np.isnan(dsm)
        if mask.any():
            idx = ndimage.distance_transform_edt(mask, return_distances=False, return_indices=True)
            dsm = dsm[tuple(idx)]
        rows = np.clip((n1 - N).astype(int), 0, dsm.shape[0] - 1)
        cols = np.clip((E - e0).astype(int), 0, dsm.shape[1] - 1)
        self.surface = dsm[rows, cols]
        # Bare ground: open (min then max) with a window bigger than most
        # objects; where a big object (a wood, the pit building) survives,
        # fall back to a much wider window. Then smooth.
        g1 = ndimage.grey_opening(self.surface, size=(61, 61))
        g2 = ndimage.grey_opening(self.surface, size=(181, 181))
        g = np.where(g1 - g2 > 3.0, g2, g1)
        self.ground = ndimage.gaussian_filter(g, 6)
        self.chm = np.clip(self.surface - self.ground, 0, 80)   # height above ground

    def ij(self, xy):
        xy = np.atleast_2d(xy)
        c = np.clip((xy - self.o).astype(int), 0, [self.chm.shape[1] - 1, self.chm.shape[0] - 1])
        return c[:, 1], c[:, 0]

    def height_in(self, poly, q=90):
        """Height of whatever stands on a footprint (a high percentile, so
        roof plant and parapets count but stray points don't)."""
        lo, hi = poly.min(0), poly.max(0)
        gx, gy = np.meshgrid(np.arange(lo[0] + 0.5, hi[0], 1.0), np.arange(lo[1] + 0.5, hi[1], 1.0))
        pts = np.stack([gx.ravel(), gy.ravel()], -1)
        if len(pts) == 0:
            return None
        pts = pts[inside(poly, pts)]
        if len(pts) < 3:
            return None
        i, j = self.ij(pts)
        return float(np.percentile(self.chm[i, j], q))


# --- build -------------------------------------------------------------------

class Ground:
    def __init__(self, origin, size):
        self.o = origin
        self.k = SUPERSAMPLE / GROUND_CELL
        self.n = (np.ceil(size / GROUND_CELL)).astype(int)
        self.img = Image.new("RGBA", (int(self.n[0] * SUPERSAMPLE), int(self.n[1] * SUPERSAMPLE)), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img)

    def px(self, p):
        q = (np.asarray(p) - self.o) * self.k
        return [tuple(v) for v in q.tolist()]

    def poly(self, outer, col, holes=()):
        if len(outer) < 3:
            return
        if not holes:
            self.d.polygon(self.px(outer), fill=col)
            return
        m = Image.new("L", self.img.size, 0)
        md = ImageDraw.Draw(m)
        md.polygon(self.px(outer), fill=255)
        for h in holes:
            if len(h) >= 3:
                md.polygon(self.px(h), fill=0)
        self.img.paste(Image.new("RGBA", self.img.size, col), (0, 0), m)

    def rows(self, outer, col, key):
        """Crop rows / tramlines across a field: faint parallel lines at the
        field's own angle, clipped to it."""
        q = np.array(self.px(outer))
        lo = np.floor(q.min(0)).astype(int)
        hi = np.ceil(q.max(0)).astype(int) + 1
        size = tuple((hi - lo).tolist())
        if min(size) < 4:
            return
        m = Image.new("L", size, 0)
        ImageDraw.Draw(m).polygon([tuple(v) for v in (q - lo).tolist()], fill=255)
        stripes = Image.new("RGBA", size, (0, 0, 0, 0))
        sd = ImageDraw.Draw(stripes)
        ang = (zlib.crc32(key.encode()) % 180) * math.pi / 180.0
        d = np.array([math.cos(ang), math.sin(ang)])
        nrm = np.array([-d[1], d[0]])
        c = np.array(size) * 0.5
        L = float(np.hypot(*size))
        gap = 12.0 * self.k     # tramlines every 12 m
        k = -L
        while k < L:
            a = c + nrm * k - d * L
            b = c + nrm * k + d * L
            sd.line([tuple(a), tuple(b)], fill=col, width=max(1, int(0.9 * self.k)))
            k += gap
        self.img.paste(stripes, tuple(lo.tolist()), Image.composite(stripes, Image.new("RGBA", size, (0, 0, 0, 0)), m))

    def line(self, pts, width_m, col):
        w = max(1, int(round(width_m * self.k)))
        self.d.line(self.px(pts), fill=col, width=w, joint="curve")
        r = w / 2
        for p in self.px([pts[0], pts[-1]]):
            self.d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=col)

    def webp(self):
        im = self.img.resize((int(self.n[0]), int(self.n[1])), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "WEBP", lossless=True, quality=100, method=6)
        return buf.getvalue()


def pick(cols, key):
    return cols[zlib.crc32(key.encode()) % len(cols)] if isinstance(cols, list) else cols


def build(tid, cfg, cache, use_lidar):
    path = os.path.join(TRACKS, tid + ".json")
    track = json.load(open(path))
    if "geo" not in track:
        raise RuntimeError(f"{tid} has no 'geo' block (it isn't placed on the map)")
    geo = Geo(track["geo"])
    origin, size = terrain_bounds(track)
    print(f"[{tid}] area {size[0]:.0f} m square")
    xy, ways, rels, tnodes = load_osm(tid, geo, origin, size, cache)
    print(f"   OSM: {len(ways)} ways, {len(rels)} relations")
    clear = Clearance(track, origin, size)
    runoff = track.get("runoff_m", 30.0)
    lidar = None
    if use_lidar and cfg.get("lidar") == "ea_england":
        try:
            lidar = Lidar(tid, geo, origin, size, cache)
            print("   LIDAR: Environment Agency DSM 1 m")
        except Exception as e:
            print("   LIDAR unavailable, OSM only:", e)
    ground = Ground(origin, size)
    lo, hi = origin, origin + size

    def in_area(p):
        return p is not None and (p.max(0) > lo).all() and (p.min(0) < hi).all()

    # ---- ground map: painted from the bottom layer up ----
    layers = []   # (z, kind, outer xy, holes xy, key)
    buildings_fp = []
    for tags, outers, inners in areas(ways, rels):
        lu, nat, am, le = tags.get("landuse"), tags.get("natural"), tags.get("amenity"), tags.get("leisure")
        kind, z = None, 0
        if lu in ("farmland", "orchard", "vineyard", "allotments"):
            kind, z = "field", 1
        elif lu in ("grass", "meadow", "village_green", "recreation_ground", "cemetery") or nat in ("grassland", "heath") \
                or le in ("park", "golf_course", "common"):
            kind, z = "grass", 1
        elif lu in ("residential",):
            kind, z = "residential", 0
        elif lu in ("industrial", "commercial", "retail", "construction", "railway", "garages", "brownfield"):
            kind, z = "industrial", 0
        elif lu == "farmyard":
            kind, z = "farmyard", 1
        elif nat == "scrub":
            kind, z = "scrub", 2
        elif lu == "forest" or nat == "wood":
            kind, z = "wood", 3
        elif le in ("pitch", "track") and tags.get("surface") not in ("asphalt", "paved", "concrete"):
            kind, z = "pitch", 4
        elif nat == "water" or lu in ("reservoir", "basin") or tags.get("water") or le == "swimming_pool":
            kind, z = "water", 5
        elif nat in ("sand", "shingle", "bare_rock") or lu == "gravel" or \
                (tags.get("surface") in ("sand", "gravel", "fine_gravel", "pebblestone") and "highway" not in tags):
            kind, z = "sand", 6
        elif am == "parking" or tags.get("parking"):
            kind = "parking_grass" if tags.get("surface") in ("grass", "unpaved", "ground", "dirt") else "parking"
            z = 7
        elif am == "parking_space":
            kind, z = "bay", 8
        elif tags.get("area:highway") or (tags.get("highway") and tags.get("area") == "yes") or \
                (tags.get("surface") in ("asphalt", "paved", "concrete") and "building" not in tags):
            kind, z = "asphalt", 7
        elif tags.get("highway") == "raceway" or tags.get("area:highway") == "raceway":
            kind, z = "asphalt", 7
        if "building" in tags or "building:part" in tags:
            for ring in outers:
                p = way_xy(ring, xy)
                if p is not None and len(p) >= 4:
                    buildings_fp.append((tags, p))
            continue
        if kind is None:
            continue
        for ring in outers:
            p = way_xy(ring, xy)
            if not in_area(p):
                continue
            holes = [h for h in (way_xy(r, xy) for r in inners) if h is not None]
            layers.append((z, kind, p, holes, str(tags.get("name", "")) + str(len(p)) + f"{p[0][0]:.0f}"))
    layers.sort(key=lambda L: L[0])
    for z, kind, p, holes, key in layers:
        if kind == "bay":
            ground.poly(p, C["parking"])
            ground.line(np.vstack([p, p[:1]]), 0.15, C["bay_line"])
            continue
        col = pick(C[kind], key)
        ground.poly(p, col, holes)
        if kind == "field":
            ground.rows(p, tuple(int(v * 0.86) for v in col[:3]) + (255,), key)

    # lines: other race loops, roads, paths, hedges
    for wid, (tags, refs) in ways.items():
        hw, br = tags.get("highway"), tags.get("barrier")
        if refs and refs[0] == refs[-1] and tags.get("area") == "yes":
            continue
        p = None
        if hw == "raceway":
            p = way_xy(refs, xy)
            if in_area(p):
                w = parse_m(tags.get("width")) or (10.0 if tags.get("sport") != "karting" else 7.0)
                ground.line(p, w, C["raceway"])
        elif hw in ROAD_W:
            p = way_xy(refs, xy)
            if in_area(p):
                w = parse_m(tags.get("width")) or ROAD_W[hw]
                ground.line(p, w + 0.6, C["road_line"])
                ground.line(p, w, C["road"])
        elif hw == "track":
            p = way_xy(refs, xy)
            if in_area(p):
                paved = tags.get("surface") in ("asphalt", "paved", "concrete")
                ground.line(p, 3.2, C["road"] if paved else C["track_dirt"])
        elif hw in PATHS:
            p = way_xy(refs, xy)
            if in_area(p):
                ground.line(p, PATHS[hw], C["path"])
        elif br == "hedge":
            p = way_xy(refs, xy)
            if in_area(p):
                ground.line(p, 2.0, C["hedge"])
        elif tags.get("waterway") in ("river", "stream", "canal", "ditch", "drain"):
            p = way_xy(refs, xy)
            if in_area(p):
                ground.line(p, 4.0 if tags["waterway"] in ("river", "canal") else 1.6, C["water"])

    # ---- buildings and grandstands ----
    out_b = []
    mask_pts = []
    for tags, p in buildings_fp:
        b = tags.get("building") or tags.get("building:part")
        if b == "bridge":
            continue
        if not in_area(p):
            continue
        p = p[:-1] if np.allclose(p[0], p[-1]) else p
        p = simplify(np.vstack([p, p[:1]]), 0.4)[:-1]
        if len(p) < 3 or poly_area(p) < 6.0:
            continue
        cl = clear.at(p)
        if cl.min() < 2.0:      # it would stand on the road: OSM and the track disagree
            continue
        grand = b == "grandstand" or tags.get("leisure") == "bleachers" or tags.get("building") == "stadium"
        kind = "grandstand" if grand else "house" if b in HOUSE else "shed" if b in SHED else \
            "roof" if b in ("roof", "canopy") else "building"
        h = parse_m(tags.get("height"))
        if h is None and tags.get("building:levels"):
            h = (parse_m(tags.get("building:levels")) or 1) * 3.2 + (2.0 if kind == "house" else 0.0)
        src = "osm" if h is not None else "default"
        if lidar is not None:
            lh = lidar.height_in(p)
            if lh is not None and lh > 1.8:
                h, src = lh, "lidar"
        if h is None:
            h = {"grandstand": 12.0, "house": 7.5, "shed": 3.0, "roof": 5.0}.get(kind, 7.0)
        h = float(np.clip(h, 2.4, 45.0))
        ground.poly(p, C["footprint"])
        mask_pts.append(p)
        # which edge faces the circuit (grandstand seats look that way)
        front = int(np.argmin([clear.at(((p[k] + p[(k + 1) % len(p)]) * 0.5)[None])[0] for k in range(len(p))]))
        rec = {"k": kind, "h": round(h, 1), "p": np.round(p, 2).tolist()}
        if src != "lidar":
            rec["est"] = 1
        if tags.get("name"):
            rec["name"] = tags["name"]
        if kind == "grandstand":
            rec["front"] = front
        out_b.append(rec)
    print(f"   {len(out_b)} buildings ({sum(1 for b in out_b if b['k'] == 'grandstand')} grandstands, "
          f"{sum(1 for b in out_b if 'est' not in b)} with measured heights)")

    # ---- bridges (decks over roads, the circuit, water) ----
    out_br = []
    for wid, (tags, refs) in ways.items():
        if tags.get("bridge") in (None, "no") or not (tags.get("highway") or tags.get("railway")):
            continue
        p = way_xy(refs, xy)
        if not in_area(p):
            continue
        hw = tags.get("highway")
        w = parse_m(tags.get("width")) or (PATHS.get(hw, 0) + 1.2 if hw in PATHS else ROAD_W.get(hw, 6.0))
        h = 6.0
        if lidar is not None:
            i, j = lidar.ij(p)
            mid = lidar.chm[i[1:-1], j[1:-1]] if len(p) > 2 else lidar.chm[i, j]
            if len(mid) and np.median(mid) > 2.5:
                h = float(np.clip(np.max(mid), 4.5, 12.0))
        # only bridges that cross something drivable or near the circuit matter
        if clear.at(p).min() > 300:
            continue
        out_br.append({"w": round(w, 1), "h": round(h, 1), "p": np.round(p, 2).tolist(),
                       "kind": "foot" if hw in PATHS else "road"})
        ground.line(p, w, C["asphalt"])
    print(f"   {len(out_br)} bridges")

    # ---- trees ----
    trees = []
    keep_out = runoff + 4.0
    woods = [(tags, way_xy(o[0], xy)) for tags, o, _ in areas(ways, rels)
             if (tags.get("landuse") == "forest" or tags.get("natural") == "wood") and o]
    woods = [(t, p) for t, p in woods if p is not None and len(p) >= 4]
    rng = np.random.default_rng(zlib.crc32(tid.encode()))
    if lidar is not None:
        from scipy import ndimage
        chm = ndimage.gaussian_filter(lidar.chm, 1.2)
        peak = (chm == ndimage.maximum_filter(chm, size=5)) & (chm > 2.6)
        # no trees on roofs
        bm = Image.new("L", (chm.shape[1], chm.shape[0]), 0)
        bd = ImageDraw.Draw(bm)
        for p in mask_pts:
            bd.polygon([tuple(v) for v in (p - lidar.o).tolist()], fill=255)
        bm = np.array(bm) > 0
        bm = ndimage.binary_dilation(bm, iterations=3)
        peak &= ~bm
        ii, jj = np.nonzero(peak)
        pts = np.stack([jj + 0.5, ii + 0.5], -1) + lidar.o
        hs = chm[ii, jj]
        ok = clear.at(pts) > keep_out
        pts, hs = pts[ok], hs[ok]
        conifer_w = [p for t, p in woods if t.get("leaf_type") == "needleleaved"]
        con = np.zeros(len(pts), bool)
        for p in conifer_w:
            con |= inside(p, pts)
        for q, h, c in zip(pts, hs, con):
            kind = 2 if h < 4.5 else (1 if c else 0)
            trees.append([round(float(q[0]), 1), round(float(q[1]), 1), round(float(h), 1), kind])
        # Deep inside big woods the ground estimate rides on the canopy, so
        # the surface model shows no trees there: fill the gaps.
        occ = set((int(t[0] // 5), int(t[1] // 5)) for t in trees)
        filled = 0
        for tags, p in woods:
            if not in_area(p):
                continue
            lo2, hi2 = p.min(0), p.max(0)
            gx, gy = np.meshgrid(np.arange(lo2[0], hi2[0], 6.5), np.arange(lo2[1], hi2[1], 6.5))
            cand = np.stack([gx.ravel(), gy.ravel()], -1) + rng.uniform(-2.2, 2.2, (gx.size, 2))
            cand = cand[inside(p, cand)]
            cand = cand[clear.at(cand) > keep_out]
            for q in cand:
                c = (int(q[0] // 5), int(q[1] // 5))
                if any((c[0] + a, c[1] + b) in occ for a in (-1, 0, 1) for b in (-1, 0, 1)):
                    continue
                occ.add(c)
                kind = 1 if tags.get("leaf_type") == "needleleaved" else 0
                trees.append([round(float(q[0]), 1), round(float(q[1]), 1), round(float(rng.uniform(12, 20)), 1), kind])
                filled += 1
        print(f"   {filled} trees filled in deep woods")
    else:
        for tags, p in woods:
            if not in_area(p):
                continue
            lo2, hi2 = p.min(0), p.max(0)
            n = int(poly_area(p) / 45.0)
            if n <= 0:
                continue
            cand = rng.uniform(lo2, hi2, size=(n * 2, 2))
            cand = cand[inside(p, cand)][:n]
            cand = cand[clear.at(cand) > keep_out]
            kind = 1 if tags.get("leaf_type") == "needleleaved" else 0
            for q in cand:
                trees.append([round(float(q[0]), 1), round(float(q[1]), 1), round(float(rng.uniform(9, 16)), 1), kind])
        for wid, (tags, refs) in ways.items():
            if tags.get("natural") == "tree_row" or tags.get("barrier") == "hedge":
                p = way_xy(refs, xy)
                if not in_area(p):
                    continue
                step = 8.0 if tags.get("natural") == "tree_row" else 3.5
                for a, b in zip(p[:-1], p[1:]):
                    L = np.hypot(*(b - a))
                    for k in range(int(L / step) + 1):
                        q = a + (b - a) * (k * step / max(L, 1e-6))
                        if clear.at(q[None])[0] > keep_out:
                            if tags.get("natural") == "tree_row":
                                trees.append([round(float(q[0]), 1), round(float(q[1]), 1), round(float(rng.uniform(8, 14)), 1), 0])
                            else:
                                trees.append([round(float(q[0]), 1), round(float(q[1]), 1), round(float(rng.uniform(2.2, 3.4)), 1), 2])
        for nid, tags in tnodes.items():
            if tags.get("natural") == "tree" and nid in xy:
                q = xy[nid]
                if clear.at(q[None])[0] > keep_out:
                    trees.append([round(float(q[0]), 1), round(float(q[1]), 1), parse_m(tags.get("height")) or 11.0, 0])
    print(f"   {len(trees)} trees and bushes")

    data = ground.webp()
    out = {
        "format": 1,
        "track": tid,
        "sources": ["Map data © OpenStreetMap contributors (ODbL), openstreetmap.org/copyright"] +
                   (["Heights: Environment Agency LIDAR Composite DSM 1 m, © Environment Agency copyright and/or "
                     "database right, Open Government Licence v3.0"] if lidar is not None else []),
        "ground": {"origin": np.round(origin, 2).tolist(), "size": np.round(size, 2).tolist(),
                   "webp": base64.b64encode(data).decode()},
        "buildings": out_b,
        "bridges": out_br,
        "trees_format": ["x", "y", "height_m", "kind (0 broadleaf, 1 conifer, 2 bush)"],
        "trees": trees,
    }
    os.makedirs(OUT, exist_ok=True)
    dst = os.path.join(OUT, tid + ".json")
    with open(dst, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"   wrote {os.path.relpath(dst, ROOT)} ({os.path.getsize(dst) / 1e6:.1f} MB, ground map {len(data) / 1e6:.1f} MB)")
    return ground


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tracks", nargs="*", help="track ids (default: every track in tools/scenery.json)")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/tdr-tracks"))
    ap.add_argument("--no-lidar", action="store_true")
    ap.add_argument("--preview", help="also save the ground map as a PNG here")
    args = ap.parse_args()
    cfg = json.load(open(os.path.join(HERE, "scenery.json")))
    ids = args.tracks or list(cfg["tracks"])
    for tid in ids:
        g = build(tid, cfg["tracks"].get(tid, {}), args.cache, not args.no_lidar)
        if args.preview:
            g.img.resize((int(g.n[0]), int(g.n[1])), Image.LANCZOS).save(args.preview)


if __name__ == "__main__":
    main()
