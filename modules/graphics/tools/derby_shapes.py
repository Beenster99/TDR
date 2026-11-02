"""Shape files for the Demolition Derby cars, from each car's body_style.

Run:  python3 modules/graphics/tools/derby_shapes.py
then: blender -b --python modules/graphics/tools/build_cars.py -- <ids...>

Reads modules/cars/data/derby_*.json and writes
modules/graphics/tools/car_shapes/<id>.json. The cars are old road cars
(saloons, estates, pickups, vans, 4x4s ...): no wings or splitters, a
separate windscreen (it cracks and shatters), and the bonnet and boot lid
as their own parts (they spring open and come off).
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CARS = os.path.join(ROOT, "modules", "cars", "data")
OUT = os.path.join(HERE, "car_shapes")

# belt/nose/tail/roof heights (m), cabin start/end (t), windscreen and rear
# glass lengths (t), ground clearance, top width (fraction), front overhang (m)
STYLES = {
    "sedan":     dict(belt=0.92, nose=0.84, tail=0.92, roof=1.40, cab=(0.30, 0.75), ws=0.10, rear=0.10, zb=0.17, wt=0.86, fo=1.05),
    "taxi":      dict(belt=0.92, nose=0.84, tail=0.92, roof=1.42, cab=(0.30, 0.75), ws=0.10, rear=0.10, zb=0.17, wt=0.86, fo=1.0),
    "wagon":     dict(belt=0.92, nose=0.84, tail=0.95, roof=1.45, cab=(0.30, 0.97), ws=0.10, rear=0.02, zb=0.17, wt=0.86, fo=1.05),
    "limo":      dict(belt=0.92, nose=0.84, tail=0.92, roof=1.45, cab=(0.25, 0.80), ws=0.07, rear=0.07, zb=0.16, wt=0.86, fo=1.1),
    "hearse":    dict(belt=0.95, nose=0.86, tail=0.98, roof=1.62, cab=(0.25, 0.97), ws=0.08, rear=0.02, zb=0.17, wt=0.86, fo=1.05),
    "muscle":    dict(belt=0.88, nose=0.80, tail=0.88, roof=1.32, cab=(0.40, 0.76), ws=0.10, rear=0.09, zb=0.15, wt=0.84, fo=1.05),
    "fastback":  dict(belt=0.86, nose=0.78, tail=0.90, roof=1.30, cab=(0.38, 0.90), ws=0.10, rear=0.30, zb=0.15, wt=0.82, fo=0.95),
    "coupe":     dict(belt=0.90, nose=0.82, tail=0.90, roof=1.35, cab=(0.37, 0.78), ws=0.10, rear=0.12, zb=0.15, wt=0.84, fo=1.0),
    "compact":   dict(belt=0.90, nose=0.82, tail=0.90, roof=1.42, cab=(0.28, 0.78), ws=0.10, rear=0.10, zb=0.17, wt=0.86, fo=0.8),
    "hatch":     dict(belt=0.88, nose=0.80, tail=0.92, roof=1.40, cab=(0.28, 0.95), ws=0.12, rear=0.12, zb=0.15, wt=0.85, fo=0.8),
    "minivan":   dict(belt=0.98, nose=0.92, tail=1.0, roof=1.75, cab=(0.16, 0.97), ws=0.17, rear=0.03, zb=0.17, wt=0.86, fo=0.95),
    "kei_van":   dict(belt=0.92, nose=0.95, tail=0.95, roof=1.85, cab=(0.04, 0.97), ws=0.07, rear=0.02, zb=0.16, wt=0.88, fo=0.45),
    "pickup":    dict(belt=1.02, nose=1.0, tail=1.02, roof=1.85, cab=(0.27, 0.53), ws=0.08, rear=0.02, zb=0.28, wt=0.9, fo=0.95),
    "ute":       dict(belt=0.92, nose=0.84, tail=0.94, roof=1.40, cab=(0.34, 0.58), ws=0.10, rear=0.03, zb=0.17, wt=0.86, fo=1.0),
    "van":       dict(belt=1.02, nose=0.98, tail=1.02, roof=2.05, cab=(0.14, 0.98), ws=0.12, rear=0.02, zb=0.2, wt=0.9, fo=0.9),
    "suv":       dict(belt=1.10, nose=1.05, tail=1.10, roof=1.88, cab=(0.27, 0.96), ws=0.10, rear=0.03, zb=0.34, wt=0.88, fo=0.85),
    "suv_small": dict(belt=1.06, nose=1.02, tail=1.06, roof=1.82, cab=(0.26, 0.95), ws=0.10, rear=0.03, zb=0.33, wt=0.88, fo=0.7),
    "microcar":  dict(belt=0.72, nose=0.58, tail=0.70, roof=1.30, cab=(0.10, 0.85), ws=0.25, rear=0.30, zb=0.14, wt=0.72, fo=0.45),
}

LIVERIES = [
    {"pattern": "solid", "secondary": "#e8e4d8", "accent": "#111111"},
    {"pattern": "stripes", "secondary": "#f0f0f0", "accent": "#111111"},
    {"pattern": "halves", "secondary": "#8a8f88", "accent": "#222222"},
    {"pattern": "split", "secondary": "#d22a1e", "accent": "#111111"},
    {"pattern": "chevron", "secondary": "#f2d000", "accent": "#111111"},
    {"pattern": "sash", "secondary": "#1d1d1d", "accent": "#e0e0e0"},
]


def shape(car, k):
    st = STYLES[car["body_style"]]
    belt, nose, tail, roof = st["belt"], st["nose"], st["tail"], st["roof"]
    zb, wt = st["zb"], st["wt"]
    c0, c1 = st["cab"]
    zs = zb + 0.26
    body = [
        {"t": 0.0, "w": 0.86, "zb": zb + 0.08, "zs": zs, "zt": nose - 0.04, "ze": nose - 0.02, "wt": wt * 0.92},
        {"t": 0.03, "w": 0.97, "zb": zb, "zs": zs, "zt": nose, "ze": nose + 0.02, "wt": wt},
        {"t": 0.12, "w": 1.0, "zb": zb, "zs": zs, "zt": (nose + belt) * 0.5, "ze": belt - 0.01, "wt": wt},
        {"t": max(c0 - 0.02, 0.14), "w": 1.0, "zb": zb, "zs": zs, "zt": belt - 0.02, "ze": belt, "wt": wt},
        {"t": min(c1 + 0.02, 0.9), "w": 1.0, "zb": zb, "zs": zs, "zt": belt - 0.01, "ze": belt, "wt": wt},
        {"t": 0.96, "w": 0.98, "zb": zb, "zs": zs, "zt": tail - 0.02, "ze": tail, "wt": wt},
        {"t": 1.0, "w": 0.88, "zb": zb + 0.08, "zs": zs, "zt": tail - 0.05, "ze": tail - 0.03, "wt": wt * 0.92},
    ]
    body.sort(key=lambda b: b["t"])
    ws, rear = st["ws"], st["rear"]
    top = roof
    deck = belt + 0.03
    stations = [
        {"t": c0, "zt": deck + 0.03, "wb": 0.93, "wt": 0.82},
        {"t": c0 + ws * 0.5, "zt": deck + (top - deck) * 0.6, "wb": 0.93, "wt": 0.8},
        {"t": c0 + ws, "zt": top, "wb": 0.93, "wt": 0.78},
        {"t": c1 - max(rear, 0.03), "zt": top - 0.01, "wb": 0.93, "wt": 0.78},
    ]
    if rear > 0.05:
        stations.append({"t": c1 - rear * 0.5, "zt": deck + (top - deck) * 0.55, "wb": 0.9, "wt": 0.72})
        stations.append({"t": c1, "zt": deck + 0.03, "wb": 0.86, "wt": 0.66})
        rg = [c1 - rear + 0.01, c1 - 0.01]
    else:
        stations.append({"t": c1, "zt": top - 0.04, "wb": 0.92, "wt": 0.76})
        rg = None
    cabin = {"stations": stations, "windscreen": [c0 + 0.004, c0 + ws], "ws_half_width": 0.7,
             "side_windows": [c0 + ws * 0.7, c1 - max(rear, 0.03) * 0.6]}
    if rg:
        cabin["rear_glass"] = rg
        cabin["rg_half_width"] = 0.6
    lids = {}
    if c0 - 0.06 > 0.1:
        lids["bonnet"] = [0.05, c0 - 0.012]
    if 0.95 - (c1 + 0.012) > 0.08:
        lids["boot"] = [c1 + 0.012, 0.95]
    hl_z = [nose - 0.22, nose - 0.08]
    liv = dict(LIVERIES[k % len(LIVERIES)])
    return {
        "front_overhang": st["fo"],
        "race_car": False,
        "upgrades": False,
        "windscreen_part": True,
        "lids": lids,
        "tyre_width": [0.215, 0.225],
        "arch_flare": [0.015, 0.015],
        "arch_lift": [0.04, 0.04],
        "spokes": 5,
        "rim_colour": "#8c8f94",
        "caliper_colour": "#3a3a3a",
        "shoulder_crease": 0.9,
        "body": body,
        "cabin": cabin,
        "bumper_cuts": [0.055, 0.955],
        "mirrors": {"z": 0.1, "out": 0.12},
        "number_door": {"t": min(max(c0 + 0.12, 0.35), 0.6), "z": (zs + belt) * 0.5},
        "number_size": 0.22,
        "regions": [
            {"mat": "grille", "t": [-0.01, 0.035], "y": [0.0, 0.55], "facing": "frontish", "z": [zb + 0.18, nose - 0.08]},
            {"mat": "light_head", "t": [-0.01, 0.035], "y": [0.6, 0.88], "facing": "frontish", "z": hl_z},
            {"mat": "light_tail", "t": [0.965, 1.01], "y": [0.62, 0.92], "facing": "rear", "z": [tail - 0.25, tail - 0.06]},
            {"mat": "grille", "t": [0.97, 1.01], "y": [0.0, 0.3], "facing": "rear", "z": [zb + 0.15, zb + 0.32]},
        ],
        "livery": liv,
    }


if __name__ == "__main__":
    ids = sorted(f[:-5] for f in os.listdir(CARS) if f.startswith("derby_") and f.endswith(".json"))
    for k, cid in enumerate(ids):
        with open(os.path.join(CARS, cid + ".json")) as f:
            car = json.load(f)
        with open(os.path.join(OUT, cid + ".json"), "w") as f:
            json.dump(shape(car, k), f, indent=1)
    print(" ".join(ids))
