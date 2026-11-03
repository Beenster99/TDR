"""Writes the 20 Demolition Derby cars (made-up makes and models) to
modules/cars/data/derby_*.json.

Run:  python3 modules/cars/tools/build_derby_cars.py

Every car is class "Derby" and discipline "derby", so it only races in
Demolition Derby events. Extra fields read by the game:
  body_style  what kind of car it is (sedan, wagon, pickup, van ...); the
              graphics module builds its 3D shape from this
              (modules/graphics/tools/derby_shapes.py)
  toughness   how much of a hit the car shrugs off (CarDamage divides the
              damage by it; 1 = a race car, 3 = an old steel land yacht)
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "data")

# id, name, style, length, width, wheelbase, track, mass, cylinders, peak Nm,
# drive (RWD/FWD/AWD), toughness, colour, description
CARS = [
    ("derby_brannock_sovereign", "Brannock Sovereign", "sedan", 5.6, 2.0, 3.0, 1.62, 1950, 8, 470, "RWD", 3.0, "#3f5e8c",
     "Full-size 1970s four-door with a 6.6 V8 and a steel bumper like a girder. The derby favourite."),
    ("derby_brannock_country_wagon", "Brannock Sovereign Country Wagon", "wagon", 5.75, 2.0, 3.0, 1.62, 2100, 8, 470, "RWD", 3.1, "#7a5a3a",
     "The Sovereign as a nine-seat estate with fake wood panels. Long, heavy and nearly unbreakable."),
    ("derby_kestrel_imperial", "Kestrel Imperial Limousine", "limo", 6.4, 2.0, 3.7, 1.64, 2400, 8, 520, "RWD", 3.2, "#121214",
     "A stretched V8 limousine retired from the wedding trade. Turns like a ship, hits like one too."),
    ("derby_kestrel_requiem", "Kestrel Requiem Hearse", "hearse", 6.1, 2.0, 3.5, 1.64, 2350, 8, 500, "RWD", 3.0, "#1b1b1f",
     "An old V8 hearse with a long glass-sided back. Someone else's funeral."),
    ("derby_halvorsen_240", "Halvorsen 240 Estate", "wagon", 4.8, 1.76, 2.65, 1.47, 1420, 4, 190, "RWD", 2.6, "#9a2a22",
     "Square Scandinavian estate with a 2.3 four. Built like a fridge and twice as hard to kill."),
    ("derby_halvorsen_260", "Halvorsen 260 Saloon", "sedan", 4.8, 1.76, 2.65, 1.47, 1400, 6, 235, "RWD", 2.4, "#c8c4b4",
     "The saloon version with the 2.7 V6. Boxy, rear-drive and happy going sideways."),
    ("derby_pelham_marauder", "Pelham Marauder", "muscle", 5.2, 1.92, 2.85, 1.58, 1650, 8, 540, "RWD", 2.3, "#d8a21a",
     "Big-block two-door muscle car. Plenty of shove, a long bonnet and not much to stop it."),
    ("derby_pelham_stallion", "Pelham Stallion Fastback", "fastback", 4.7, 1.85, 2.7, 1.55, 1450, 8, 450, "RWD", 2.0, "#2c7a3c",
     "Pony-car fastback with a small-block V8. Quick, light and a bit fragile at the back."),
    ("derby_ostrava_1300", "Ostrava 1300", "compact", 4.1, 1.62, 2.42, 1.35, 950, 4, 105, "RWD", 1.6, "#d9d2a8",
     "Eastern-bloc 1.3 saloon. Slow, simple and surprisingly hard to finish off."),
    ("derby_tanaga_comet", "Tanaga Comet Hatch", "hatch", 3.9, 1.68, 2.45, 1.45, 1000, 4, 145, "FWD", 1.6, "#e05a1e",
     "Front-drive 1.6 hot hatch. Nimble enough to dodge the big cars, light enough to be thrown around by them."),
    ("derby_tanaga_voyageur", "Tanaga Voyageur Minivan", "minivan", 4.85, 1.86, 2.88, 1.56, 1750, 6, 300, "FWD", 2.4, "#6c8aa8",
     "Seven-seat people carrier with a 3.0 V6. Tall, front-drive and a moving wall."),
    ("derby_tanaga_kei_box", "Tanaga Kei Box", "kei_van", 3.4, 1.48, 2.35, 1.30, 820, 3, 95, "FWD", 1.4, "#f1efe8",
     "Tiny Japanese box van with a 660 cc three. Tips over if you look at it, but nips through gaps."),
    ("derby_marlow_workhorse", "Marlow Workhorse Pickup", "pickup", 5.45, 2.0, 3.3, 1.66, 2050, 8, 480, "RWD", 3.0, "#5e6a3c",
     "Full-size farm pickup with a 5.8 V8 and an empty load bed to back into people with."),
    ("derby_marlow_rancher", "Marlow Rancher Ute", "ute", 5.1, 1.9, 2.95, 1.56, 1700, 8, 430, "RWD", 2.5, "#8a1f3a",
     "Two-door coupe-utility: a muscle car front with a pickup bed behind."),
    ("derby_dunmore_courier", "Dunmore Courier Van", "van", 5.05, 1.96, 3.05, 1.68, 1900, 4, 300, "RWD", 2.8, "#f2f2ee",
     "Ex-delivery panel van with a 2.5 turbo-diesel four. Slab-sided and slow, but it weighs a ton."),
    ("derby_corrigan_trailmaster", "Corrigan Trailmaster 4x4", "suv", 4.95, 1.98, 2.9, 1.65, 2200, 8, 450, "AWD", 3.0, "#3b4a3a",
     "Body-on-frame off-roader with a 5.0 V8 and four-wheel drive. Loves the dirt."),
    ("derby_corrigan_scout", "Corrigan Scout", "suv_small", 4.2, 1.8, 2.5, 1.52, 1600, 6, 280, "AWD", 2.4, "#b0482a",
     "Short-wheelbase 4x4 with a 3.8 V6. Climbs over anything, rolls over most things."),
    ("derby_vesta_metro_cab", "Vesta Metro Cab", "taxi", 5.3, 1.96, 2.95, 1.6, 1850, 8, 400, "RWD", 2.9, "#f4c20d",
     "A retired city cab: police-spec V8, heavy-duty springs and two million kilometres on the clock."),
    ("derby_rook_bubble_600", "Rook Bubble 600", "microcar", 2.85, 1.42, 1.85, 1.2, 560, 2, 52, "RWD", 1.2, "#59b8c9",
     "A 600 cc two-cylinder bubble car. Brave. Very brave."),
    ("derby_galloway_monarch", "Galloway Monarch Coupe", "coupe", 5.0, 1.88, 2.9, 1.56, 1900, 12, 560, "RWD", 2.3, "#4b2a5c",
     "A faded grand tourer with a thirsty V12. Gentleman's express, now a battering ram."),
]

DISPLACEMENT_NOTE = {2: "two-cylinder", 3: "three-cylinder", 4: "four-cylinder", 6: "V6", 8: "V8", 12: "V12"}


def car(spec):
    (cid, name, style, L, W, wb, track, mass, cyl, nm, drive, tough, colour, desc) = spec
    redline = {2: 6000, 3: 7000, 4: 6200, 6: 5800, 8: 5200, 12: 6000}[cyl]
    if "diesel" in desc:
        redline = 4400
    idle = 800
    curve = [[idle, nm * 0.55], [int(redline * 0.3), nm * 0.85], [int(redline * 0.55), nm],
             [int(redline * 0.8), nm * 0.93], [redline, nm * 0.78]]
    small = mass < 1100
    ratios = [3.3, 2.0, 1.35, 1.0] if small else [2.6, 1.6, 1.0, 0.75]
    tall = style in ("van", "minivan", "suv", "suv_small", "kei_van", "hearse", "pickup")
    front_engine = 0.56 if style not in ("microcar", "kei_van") else 0.45
    return {
        "format": 1,
        "id": cid,
        "name": name,
        "description": desc,
        "class_tag": "Derby",
        "discipline": "derby",
        "body_style": style,
        "toughness": round(1.0 + (tough - 1.0) * 0.5, 2),
        "colour": colour,
        "mass_kg": mass,
        "weight_front": front_engine,
        "wheelbase_m": wb,
        "cg_height_m": 0.72 if tall else 0.56,
        "track_width_m": track,
        "length_m": L,
        "width_m": W,
        "body_offset_m": 0.0,
        "inertia_factor": 1.1,
        "engine": {
            "idle_rpm": idle,
            "redline_rpm": redline,
            "shift_up_rpm": int(redline * 0.95),
            "shift_down_rpm": int(redline * 0.45),
            "torque_curve": [[r, round(t)] for r, t in curve],
            "engine_brake_nm": round(nm * 0.12),
            "cylinders": cyl,
        },
        "gearbox": {"ratios": ratios, "final_drive": 3.55 if not small else 4.1, "efficiency": 0.84},
        "drivetrain": drive,
        "awd_front_split": 0.4 if drive == "AWD" else 0.0,
        "wheel_radius_m": 0.36 if tall else (0.27 if small else 0.33),
        "brakes": {"max_force_n": round(mass * 8.5), "bias_front": 0.64},
        "steering": {"max_angle_deg": 36, "rate_deg_s": 230},
        "aero": {"cda": 1.05 if tall else 0.85, "cla": 0.05, "balance_front": 0.5},
        "tyre_compound": "road_semi_slick",
        "fuel": {"capacity_l": 60, "bsfc_l_per_kwh": 0.36},
        "tuning_ranges": {"brake_bias_front": [0.55, 0.72], "aero_cla": [0.0, 0.1], "final_drive": [3.0, 4.6]},
        # On loose dirt the tail steps out a lot (old road tyres, worn
        # suspension): rear-drive cars most, front-drive least.
        "chassis": {"front_grip": 0.94, "rear_grip": 1.0, "roll_stiffness_front": 0.6,
                    "dirt_rear_grip": {"RWD": 0.6, "AWD": 0.68, "FWD": 0.74}[drive]},
    }


if __name__ == "__main__":
    for spec in CARS:
        d = car(spec)
        with open(os.path.join(OUT, d["id"] + ".json"), "w") as f:
            json.dump(d, f, indent=1)
    print("wrote %d derby cars" % len(CARS))
