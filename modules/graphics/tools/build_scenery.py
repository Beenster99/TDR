#!/usr/bin/env python3
"""Real trackside scenery for a circuit, from open data.

Builds modules/graphics/data/scenery/<track>.json: the buildings (with real
heights where known), grandstands, bridges and trees around a circuit, plus
the land cover modelled as meshes (fields, woods, car parks with their bays,
roads with their lines, paths, water, gravel, the circuit's other loops), cut
along the game's terrain triangles so it lies exactly on the hillside.
Trackside (graphics) turns it into 3D objects, so a circuit looks like itself
from above.

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
Needs numpy, Pillow and shapely (2.1+); LIDAR also needs scipy, pyproj and tifffile
(pip install shapely scipy pyproj tifffile imagecodecs).

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

TILE_DEG_M = 800.0         # OSM API download tile size (m)

ROAD_W = {"motorway": 11, "trunk": 10, "primary": 8.5, "secondary": 7.5, "tertiary": 7, "unclassified": 6,
          "residential": 6, "living_street": 5, "service": 4.5, "motorway_link": 6, "trunk_link": 6,
          "primary_link": 6, "secondary_link": 6, "tertiary_link": 6}
PATHS = {"footway": 1.8, "path": 1.4, "cycleway": 2.2, "bridleway": 2.0, "pedestrian": 4.0, "steps": 2.0}

MAJOR = ("motorway", "trunk", "primary", "secondary", "motorway_link", "trunk_link", "primary_link")
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


# --- land cover: real geometry, not a picture --------------------------------

# Ground kinds the game draws (terrain shader, COLOR.g). 0 = the game's own
# grass. Keep in step with KIND_* in shaders/terrain.gdshader.
KINDS = ["grass", "field", "meadow", "scrub", "wood", "residential", "industrial", "farmyard", "water", "sand",
         "dirt", "asphalt", "parking", "parking_grass", "bay_line", "road", "road_line", "path", "track_dirt",
         "raceway", "hedge", "footprint", "pitch", "road_dash"]
KIND = {k: i for i, k in enumerate(KINDS)}
SPLIT = 255                # a terrain triangle shared by several kinds (see "pieces")
CHUNK = 16                 # cells per side cut at a time
MESH_CHUNK = 32            # cells per side of each mesh tile the game draws


class Land:
    """Land cover as polygons, cut along the game's terrain triangles so the
    game can lay it on the hillside exactly: each terrain triangle is either
    wholly one kind (tri_kind) or split into pieces (triangles of their own).
    Painted bottom layer first, like the old ground map: later shapes cover
    earlier ones, kind "grass" rubs out (the game's grass shows)."""

    def __init__(self, origin, size, cell):
        self.o = np.asarray(origin, float)
        self.cell = float(cell)
        self.n = np.ceil(np.asarray(size) / cell).astype(int)
        self.items = []     # (z, seq, kind id, variant, geometry)

    def _add(self, geom, kind, z, key=""):
        import shapely
        if geom is None or geom.is_empty:
            return
        if not geom.is_valid:
            geom = shapely.make_valid(geom)
        geom = shapely.get_parts(geom)
        geom = [g for g in geom if g.geom_type in ("Polygon", "MultiPolygon") and g.area > 0.01]
        if not geom:
            return
        g = shapely.union_all(geom) if len(geom) > 1 else geom[0]
        g = g.simplify(0.04)
        var = zlib.crc32(key.encode()) & 0xFF if key else 0
        self.items.append((z, len(self.items), KIND[kind], var, g))

    def poly(self, outer, kind, z, holes=(), key=""):
        from shapely.geometry import Polygon
        if len(outer) < 3:
            return
        hs = [h for h in holes if len(h) >= 3]
        self._add(Polygon(outer, hs), kind, z, key)

    def line(self, pts, width_m, kind, z, key="", join="round"):
        from shapely.geometry import LineString
        if len(pts) < 2:
            return
        self._add(LineString(pts).buffer(width_m * 0.5, quad_segs=3, join_style=join, mitre_limit=3.0), kind, z, key)

    def dashes(self, pts, width_m, dash, gap, kind, z):
        """A dashed centre line (dash metres on, gap metres off)."""
        from shapely.geometry import LineString
        from shapely.ops import substring
        import shapely
        ls = LineString(pts)
        L = ls.length
        segs = []
        d = gap * 0.5
        while d + dash < L:
            segs.append(substring(ls, d, d + dash))
            d += dash + gap
        if segs:
            self._add(shapely.union_all([s.buffer(width_m * 0.5, cap_style="flat") for s in segs]), kind, z)

    def erase(self, geom, z):
        self._add(geom, "grass", z)

    def encode(self):
        import shapely
        from shapely import STRtree
        nx, ny = int(self.n[0]), int(self.n[1])
        items = sorted(self.items, key=lambda it: (it[0], it[1]))
        geoms = np.array([it[4] for it in items], dtype=object)
        tree = STRtree(geoms)
        tk = np.zeros((ny, nx, 2), np.uint8)
        tv = np.zeros((ny, nx, 2), np.uint8)
        pk, pv, pxy = [], [], []
        c = self.cell
        half = c * c * 0.5
        for cy in range(0, ny, CHUNK):
            for cx in range(0, nx, CHUNK):
                w, h = min(CHUNK, nx - cx), min(CHUNK, ny - cy)
                x0, y0 = self.o + np.array([cx, cy]) * c
                bx = shapely.box(x0, y0, x0 + w * c, y0 + h * c)
                idx = tree.query(bx, predicate="intersects")
                if len(idx) == 0:
                    continue
                # visible part of each shape in this chunk, top layer first
                covered = None
                vis = []
                for i in sorted(idx, reverse=True):
                    g = shapely.intersection(geoms[i], bx)
                    if g.is_empty or g.area < 1e-3:
                        continue
                    v = g if covered is None else shapely.difference(g, covered)
                    covered = g if covered is None else shapely.union(covered, g)
                    if items[i][2] != 0 and not v.is_empty and v.area > 1e-3:
                        vis.append((items[i][2], items[i][3], v))
                if not vis:
                    continue
                # the chunk's terrain triangles: (a, b, c) and (b, d, c), as TrackView builds them
                jj, ii = np.mgrid[0:h, 0:w]
                ax = x0 + ii.ravel() * c
                ay = y0 + jj.ravel() * c
                A = np.stack([ax, ay], -1)
                B, Cc, D = A + [c, 0], A + [0, c], A + [c, c]
                t0 = np.stack([A, B, Cc, A], 1)
                t1 = np.stack([B, D, Cc, B], 1)
                tris = shapely.polygons(np.concatenate([t0, t1]))
                tcell = np.concatenate([np.stack([jj.ravel() + cy, ii.ravel() + cx, np.zeros(w * h, int)], -1),
                                        np.stack([jj.ravel() + cy, ii.ravel() + cx, np.ones(w * h, int)], -1)])
                ttree = STRtree(tris)
                for kind, var, v in vis:
                    ti = ttree.query(v, predicate="intersects")
                    if len(ti) == 0:
                        continue
                    inter = shapely.intersection(v, tris[ti])
                    ar = shapely.area(inter)
                    full = ar > half * 0.9995
                    for t in ti[full]:
                        r, q, s = tcell[t]
                        tk[r, q, s] = kind
                        tv[r, q, s] = var
                    part = (~full) & (ar > 0.01)
                    if not part.any():
                        continue
                    for t in ti[part]:
                        r, q, s = tcell[t]
                        tk[r, q, s] = SPLIT
                    parts = shapely.get_parts(inter[part])
                    parts = parts[shapely.get_type_id(parts) == 3]
                    parts = parts[shapely.area(parts) > 0.01]
                    if len(parts) == 0:
                        continue
                    tri = shapely.get_parts(shapely.constrained_delaunay_triangles(parts))
                    tri = tri[shapely.area(tri) > 1e-4]
                    xy = shapely.get_coordinates(shapely.get_exterior_ring(tri)).reshape(-1, 4, 2)[:, :3]
                    # wind them like the terrain (positive area in game x, y)
                    e1, e2 = xy[:, 1] - xy[:, 0], xy[:, 2] - xy[:, 0]
                    flip = (e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0]) < 0
                    xy[flip] = xy[flip][:, [0, 2, 1]]
                    pxy.append(xy.astype(np.float32))
                    pk.append(np.full(len(xy), kind, np.uint8))
                    pv.append(np.full(len(xy), var, np.uint8))
        pxy = np.concatenate(pxy) if pxy else np.zeros((0, 3, 2), np.float32)
        pk = np.concatenate(pk) if pk else np.zeros(0, np.uint8)
        pv = np.concatenate(pv) if pv else np.zeros(0, np.uint8)
        self.stats = {"full": int(((tk != 0) & (tk != SPLIT)).sum()), "split": int((tk == SPLIT).sum()),
                      "pieces": int(len(pk))}
        return self._mesh(tk, tv, pk, pv, pxy)

    def _mesh(self, tk, tv, pk, pv, pxy):
        """Ready-to-draw meshes in MESH_CHUNK-cell tiles: vertices (x, 0, y)
        (the game's shader lays them on the hillside), a colour per vertex
        (r 0, g kind / 255, b variant / 255) and triangle indices."""
        ny, nx = tk.shape[:2]
        c = self.cell
        o = self.o
        cent = pxy.mean(1)
        pc = np.floor((cent - o) / (c * MESH_CHUNK)).astype(int)
        V, K, I, table = [], [], [], []
        nv = ni = 0
        for cy in range(0, ny, MESH_CHUNK):
            for cx in range(0, nx, MESH_CHUNK):
                vx, vk, ix = [], [], []
                count = 0

                def add(xy, kind, var, tri):
                    nonlocal count
                    vx.append(xy)
                    vk.append(np.repeat([[kind, var]], len(xy), 0))
                    ix.append(tri + count)
                    count += len(xy)

                # whole triangles: runs of cells along a row with one kind become strips
                for r in range(cy, min(cy + MESH_CHUNK, ny)):
                    q = cx
                    qe = min(cx + MESH_CHUNK, nx)
                    while q < qe:
                        k0, k1 = tk[r, q, 0], tk[r, q, 1]
                        same = k0 == k1 and tv[r, q, 0] == tv[r, q, 1] and k0 not in (0, SPLIT)
                        if same:
                            e = q + 1
                            while e < qe and tk[r, e, 0] == k0 and tk[r, e, 1] == k0 and \
                                    tv[r, e, 0] == tv[r, q, 0] and tv[r, e, 1] == tv[r, q, 0]:
                                e += 1
                            L = e - q
                            xs = o[0] + np.arange(q, e + 1) * c
                            top = np.stack([xs, np.full(L + 1, o[1] + r * c)], -1)
                            bot = np.stack([xs, np.full(L + 1, o[1] + (r + 1) * c)], -1)
                            i = np.arange(L)
                            A, B, Cc, D = i, i + 1, L + 1 + i, L + 2 + i
                            tri = np.stack([np.stack([A, B, Cc], -1), np.stack([B, D, Cc], -1)], 1).reshape(-1)
                            add(np.vstack([top, bot]), k0, tv[r, q, 0], tri)
                            q = e
                            continue
                        a = o + np.array([q, r]) * c
                        for s_, kk in ((0, k0), (1, k1)):
                            if kk in (0, SPLIT):
                                continue
                            pts = np.array([a, a + [c, 0], a + [0, c]]) if s_ == 0 else \
                                np.array([a + [c, 0], a + [c, c], a + [0, c]])
                            add(pts, kk, tv[r, q, s_], np.arange(3))
                        q += 1
                # the pieces of split triangles in this tile (shared corners merged)
                sel = (pc[:, 0] == cx // MESH_CHUNK) & (pc[:, 1] == cy // MESH_CHUNK)
                if sel.any():
                    t = pxy[sel].reshape(-1, 2)
                    kv = np.repeat(np.stack([pk[sel], pv[sel]], -1), 3, 0)
                    key = np.concatenate([np.round(t * 1000).astype(np.int64), kv.astype(np.int64)], 1)
                    uniq, inv = np.unique(key, axis=0, return_index=False, return_inverse=True)
                    first = np.zeros(len(uniq), int)
                    first[inv.reshape(-1)] = np.arange(len(inv))
                    vx.append(t[first])
                    vk.append(kv[first])
                    ix.append(inv.reshape(-1) + count)
                    count += len(uniq)
                if count == 0:
                    continue
                vxa = np.concatenate(vx).astype(np.float32)
                V.append(vxa)
                K.append(np.concatenate(vk))
                I.append(np.concatenate(ix).astype(np.int32))
                lo, hi = vxa.min(0), vxa.max(0)
                table.append([nv, count, ni, len(I[-1]), round(float(lo[0]), 2), round(float(lo[1]), 2),
                              round(float(hi[0]), 2), round(float(hi[1]), 2)])
                nv += count
                ni += len(I[-1])
        V = np.concatenate(V) if V else np.zeros((0, 2), np.float32)
        K = np.concatenate(K) if K else np.zeros((0, 2), np.uint8)
        I = np.concatenate(I) if I else np.zeros(0, np.int32)
        xyz = np.zeros((len(V), 3), np.float32)
        xyz[:, 0], xyz[:, 2] = V[:, 0], V[:, 1]
        col = np.zeros((len(V), 4), np.float32)
        col[:, 1] = K[:, 0] / 255.0
        col[:, 2] = K[:, 1] / 255.0
        col[:, 3] = 1.0
        self.stats.update(verts=int(len(V)), tris=int(len(I) // 3))

        def b64(a):
            raw = np.ascontiguousarray(a).tobytes()
            return base64.b64encode(zlib.compress(raw, 9)).decode(), len(raw)

        out = {"format": 1, "origin": np.round(self.o, 3).tolist(), "cell": self.cell, "n": [int(nx), int(ny)],
               "kinds": KINDS,
               "_doc": "Land cover meshes, one per tile: chunks = [first vertex, vertex count, first index, index "
                       "count, x0, y0, x1, y1]. verts float32 (x, 0, y); cols float32 RGBA (g = kind / 255, "
                       "b = variant / 255); idx int32 (per tile, from its first vertex). Each zlib then base64, "
                       "*_bytes = size unpacked.",
               "chunks": table}
        for name, arr in (("verts", xyz), ("cols", col), ("idx", I)):
            out[name], out[name + "_bytes"] = b64(arr)
        self._tk, self._pk, self._pxy = tk, pk, pxy
        return out

    def preview(self, path, land, px_per_m=1.0):
        """Draw the land cover as a PNG (a quick look without the game)."""
        cols = {"field": (150, 130, 80), "meadow": (90, 120, 60), "scrub": (70, 90, 45), "wood": (30, 60, 30),
                "residential": (110, 120, 90), "industrial": (130, 130, 128), "farmyard": (125, 115, 95),
                "water": (40, 70, 110), "sand": (200, 185, 140), "dirt": (130, 110, 80), "asphalt": (80, 80, 84),
                "parking": (90, 90, 95), "parking_grass": (100, 115, 65), "bay_line": (240, 240, 240),
                "road": (60, 60, 64), "road_line": (230, 230, 230), "path": (170, 160, 140),
                "track_dirt": (125, 110, 80), "raceway": (70, 70, 74), "hedge": (35, 55, 25),
                "footprint": (120, 120, 120), "pitch": (80, 130, 55), "road_dash": (230, 230, 230)}
        nx, ny = land["n"]
        k = px_per_m
        im = Image.new("RGB", (int(nx * self.cell * k), int(ny * self.cell * k)), (70, 110, 50))
        d = ImageDraw.Draw(im)
        c = self.cell * k
        for r, q, s_ in zip(*np.nonzero((self._tk != 0) & (self._tk != SPLIT))):
            a = np.array([q, r]) * c
            pts = [a, a + [c, 0], a + [0, c]] if s_ == 0 else [a + [c, 0], a + [c, c], a + [0, c]]
            d.polygon([tuple(p) for p in pts], fill=cols[KINDS[self._tk[r, q, s_]]])
        for kd, t in zip(self._pk, self._pxy):
            d.polygon([tuple(((p - self.o) * k).tolist()) for p in t], fill=cols[KINDS[kd]])
        im.save(path)


# --- build -------------------------------------------------------------------

def has_elevation(track):
    e = track.get("elevation") or {}
    return len(e.get("height_m", [])) == len(track["centerline"]) and len(track["centerline"]) > 0


def circuit_band(track, extra):
    """The road (each side's own width) plus `extra` metres, as polygons:
    one quad per centre-line step, and the pit lane."""
    from shapely.geometry import Polygon, LineString
    cl = np.array(track["centerline"])
    p, wl, wr = cl[:, :2], cl[:, 2], cl[:, 3]
    d = np.roll(p, -1, 0) - np.roll(p, 1, 0)
    d /= np.maximum(np.hypot(d[:, 0], d[:, 1]), 1e-9)[:, None]
    nrm = np.stack([-d[:, 1], d[:, 0]], -1)
    kerb = track.get("kerb_width_m", 1.0)
    left = p - nrm * (wl + kerb + extra)[:, None]
    right = p + nrm * (wr + kerb + extra)[:, None]
    out = []
    n = len(p)
    for i in range(n):
        j = (i + 1) % n
        q = Polygon([left[i], left[j], right[j], right[i]])
        out.append(q if q.is_valid else q.buffer(0))
    if track.get("pit_lane"):
        out.append(LineString(track["pit_lane"]["path"]).buffer(track["pit_lane"].get("width_m", 12.0) * 0.5 + 1.0))
    return out


def build(tid, cfg, cache, use_lidar, land_only=False):
    path = os.path.join(TRACKS, tid + ".json")
    track = json.load(open(path))
    dst = os.path.join(OUT, tid + ".json")
    old = None
    if land_only:
        if not os.path.exists(dst):
            raise RuntimeError(f"{tid}: --land-only needs an existing {os.path.relpath(dst, ROOT)}")
        old = json.load(open(dst))
        use_lidar = False
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
    # the game's terrain grid (TrackView._build_terrain): 10 m cells on hills, 16 m flat
    land = Land(origin, size, 10.0 if has_elevation(track) else 16.0)
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
            land.poly(p, "parking", z)
            land.line(np.vstack([p, p[:1]]), 0.15, "bay_line", z + 0.5, join="mitre")
            continue
        land.poly(p, kind, z, holes, key)

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
                land.line(p, w, "raceway", 14)
        elif hw in ROAD_W:
            p = way_xy(refs, xy)
            if in_area(p):
                w = parse_m(tags.get("width")) or ROAD_W[hw]
                if hw in MAJOR:   # white edge lines on the bigger roads
                    land.line(p, w + 0.5, "road_line", 15)
                land.line(p, w, "road", 16)
                if w >= 5.5 and hw not in ("service", "living_street"):
                    land.dashes(p, 0.12, 3.0, 6.0, "road_dash", 17)
        elif hw == "track":
            p = way_xy(refs, xy)
            if in_area(p):
                paved = tags.get("surface") in ("asphalt", "paved", "concrete")
                land.line(p, 3.2, "road" if paved else "track_dirt", 12, wid)
        elif hw in PATHS:
            p = way_xy(refs, xy)
            if in_area(p):
                land.line(p, PATHS[hw], "path", 13)
        elif br == "hedge":
            p = way_xy(refs, xy)
            if in_area(p):
                land.line(p, 2.0, "hedge", 11)
        elif tags.get("waterway") in ("river", "stream", "canal", "ditch", "drain"):
            p = way_xy(refs, xy)
            if in_area(p):
                land.line(p, 4.0 if tags["waterway"] in ("river", "canal") else 1.6, "water", 10)

    if not land_only:
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
            land.line(p, w, "asphalt", 18)
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
                # an even, jittered canopy: dense near the circuit, bigger trees
                # further spaced out far away (keeps the tree count sane on
                # tracks surrounded by forest, e.g. Spa or Hockenheim)
                kind = 1 if tags.get("leaf_type") == "needleleaved" else 0
                for spacing, near in ((7.5, True), (12.0, False)):
                    gx, gy = np.meshgrid(np.arange(lo2[0], hi2[0], spacing), np.arange(lo2[1], hi2[1], spacing))
                    cand = np.stack([gx.ravel(), gy.ravel()], -1)
                    if len(cand) == 0:
                        continue
                    cand = cand + rng.uniform(-spacing * 0.35, spacing * 0.35, cand.shape)
                    cl = clear.at(cand)
                    cand, cl = cand[cl > keep_out], cl[cl > keep_out]
                    cand = cand[(cl < 250.0) if near else (cl >= 250.0)]
                    if len(cand) == 0:
                        continue
                    cand = cand[inside(p, cand)]
                    lo_h, hi_h = (9, 16) if near else (15, 22)
                    for q in cand:
                        trees.append([round(float(q[0]), 1), round(float(q[1]), 1), round(float(rng.uniform(lo_h, hi_h)), 1), kind])
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
    else:
        # keep the buildings, bridges and trees already built (LIDAR included)
        out_b, out_br, trees = old["buildings"], old["bridges"], old["trees"]
        for br in out_br:
            land.line(np.array(br["p"]), br["w"], "asphalt", 18)
        if any("LIDAR" in x for x in old.get("sources", [])):
            lidar = True

    # The circuit, its kerbs and run-off (and the pit lane) are the game's own:
    # keep that band clear, so no map gravel or tarmac shows beside them.
    # Gravel traps and the circuit's own outline mapped near it are left out
    # altogether (the game draws its own gravel; the map's sits a few metres
    # off and would read as a stray line of gravel round the track).
    import shapely
    band = shapely.union_all(circuit_band(track, track.get("runoff_m", 30.0) + 3.0))
    near = shapely.union_all(circuit_band(track, track.get("runoff_m", 30.0) + 40.0))
    land.items = [it for it in land.items
                  if not (it[2] in (KIND["sand"], KIND["raceway"]) and it[4].intersects(near))]
    land.erase(band, 100)

    t0 = time.time()
    ground = land.encode()
    print(f"   land: {land.stats['full']} whole triangles, {land.stats['split']} split into "
          f"{land.stats['pieces']} pieces; {land.stats['verts']} vertices, {land.stats['tris']} triangles "
          f"({time.time() - t0:.0f} s)")
    out = {
        "format": 2,
        "track": tid,
        "sources": ["Map data © OpenStreetMap contributors (ODbL), openstreetmap.org/copyright"] +
                   (["Heights: Environment Agency LIDAR Composite DSM 1 m, © Environment Agency copyright and/or "
                     "database right, Open Government Licence v3.0"] if lidar is not None else []),
        "land": ground,
        "buildings": out_b,
        "bridges": out_br,
        "trees_format": ["x", "y", "height_m", "kind (0 broadleaf, 1 conifer, 2 bush)"],
        "trees": trees,
    }
    os.makedirs(OUT, exist_ok=True)
    with open(dst, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"   wrote {os.path.relpath(dst, ROOT)} ({os.path.getsize(dst) / 1e6:.1f} MB)")
    return land, ground


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tracks", nargs="*", help="track ids (default: every track in tools/scenery.json)")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/tdr-tracks"))
    ap.add_argument("--no-lidar", action="store_true")
    ap.add_argument("--land-only", action="store_true",
                    help="rebuild only the land cover, keeping the buildings, bridges and trees already built")
    ap.add_argument("--preview", help="also save the land cover as a PNG here (1 px per metre)")
    args = ap.parse_args()
    cfg = json.load(open(os.path.join(HERE, "scenery.json")))
    ids = args.tracks or list(cfg["tracks"])
    for tid in ids:
        land, ground = build(tid, cfg["tracks"].get(tid, {}), args.cache, not args.no_lidar, args.land_only)
        if args.preview:
            land.preview(args.preview if len(ids) == 1 else args.preview.replace(".png", f"_{tid}.png"), ground)


if __name__ == "__main__":
    main()
