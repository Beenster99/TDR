#!/usr/bin/env python3
"""Builds the tileable asphalt close-up texture the road shader layers over
the track (modules/graphics/textures/asphalt_detail.png).

One tile is 1 m x 1 m of racing asphalt at ~1 mm per texel: grey and
reddish-brown aggregate stones (4-14 mm) packed into dark bitumen, the tops
of the stones worn flat and polished by tyres.

  R = tone (0 = bitumen, brighter = stone; the stone's own grey)
  G = normal X, B = normal Z (0.5 = flat), from the height field
  A = height (0 = deep pores between stones, 1 = stone tops)

Run: python3 modules/graphics/tools/build_asphalt.py   (numpy + Pillow)
"""
import os
import numpy as np
from PIL import Image

N = 1024            # texels per side
MM = 1000.0 / N     # millimetres per texel
rng = np.random.default_rng(20261105)

height = np.zeros((N, N), np.float32) - 0.15   # bitumen sits below the stones
tone = np.full((N, N), 0.0, np.float32)
# bitumen: fine sand-and-binder mastic, slightly mottled
fine = rng.random((N // 4, N // 4)).astype(np.float32)
fine = np.kron(fine, np.ones((4, 4), np.float32))
fine = (fine + np.roll(fine, 2, 0) + np.roll(fine, 2, 1) + np.roll(fine, (2, 2), (0, 1))) * 0.25
tone += 0.10 + 0.10 * fine
height += 0.08 * fine
grit = rng.random((N, N)).astype(np.float32)
tone += 0.12 * (grit > 0.93)          # sand grains catching the light
height += 0.06 * (grit > 0.9)

def stone(cx, cy, r, h, t):
    """Irregular rounded stone, painted with wrap-around (tileable)."""
    R = int(np.ceil(r * 1.35)) + 1
    ys = (np.arange(cy - R, cy + R + 1) % N)
    xs = (np.arange(cx - R, cx + R + 1) % N)
    dy, dx = np.mgrid[-R:R + 1, -R:R + 1].astype(np.float32)
    ang = np.arctan2(dy, dx)
    # lumpy outline: a few random harmonics on the radius
    k = rng.random(4) * 2 * np.pi
    rr = r * (1.0 + 0.16 * np.sin(2 * ang + k[0]) + 0.1 * np.sin(3 * ang + k[1])
              + 0.06 * np.sin(5 * ang + k[2]))
    e = 0.65 + 0.35 * rng.random()   # flattened
    rot = k[3]
    ex = dx * np.cos(rot) + dy * np.sin(rot)
    ey = (-dx * np.sin(rot) + dy * np.cos(rot)) / e
    d = np.sqrt(ex * ex + ey * ey) / np.maximum(rr, 0.5)
    inside = d < 1.0
    dome = np.sqrt(np.clip(1.0 - d * d, 0.0, 1.0))
    top = np.minimum(dome * h, h * 0.8)          # worn flat on top
    sub = height[np.ix_(ys, xs)]
    newh = np.where(inside, np.maximum(sub, top), sub)
    height[np.ix_(ys, xs)] = newh
    st = tone[np.ix_(ys, xs)]
    tone[np.ix_(ys, xs)] = np.where(inside & (top >= sub), t * (0.85 + 0.15 * dome), st)

# coarse aggregate first, then smaller stones filling the gaps
for count, rmin, rmax in ((2600, 4.0, 7.0), (6000, 2.0, 4.0), (9000, 1.0, 2.0)):
    for _ in range(count):
        r = (rmin + (rmax - rmin) * rng.random() ** 1.5) / MM
        cx, cy = rng.integers(0, N, 2)
        g = rng.random()
        # mostly mid-grey granite; some dark basalt, a few pale quartz bits
        t = 0.42 + 0.22 * rng.random()
        if g < 0.25:
            t = 0.22 + 0.12 * rng.random()
        elif g > 0.95:
            t = 0.75 + 0.2 * rng.random()
        h = 0.6 + 0.4 * rng.random()
        stone(int(cx), int(cy), r, h, t)

height = np.clip(height, -0.2, 1.0)
h01 = (height - height.min()) / (height.max() - height.min())
# normals from the height (wrap-around central differences); strength in mm
s = 2.2
gx = (np.roll(h01, -1, 1) - np.roll(h01, 1, 1)) * s
gz = (np.roll(h01, -1, 0) - np.roll(h01, 1, 0)) * s
nl = np.sqrt(gx * gx + gz * gz + 1.0)
nx = -gx / nl
nz = -gz / nl
img = np.dstack([
    np.clip(tone, 0, 1),
    nx * 0.5 + 0.5,
    nz * 0.5 + 0.5,
    h01,
])
out = os.path.join(os.path.dirname(__file__), "..", "textures", "asphalt_detail.png")
Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGBA").save(out, optimize=True)
print("wrote", os.path.normpath(out))
