#!/usr/bin/env python3
"""Convert a TUMFTM racetrack-database track into this game's track JSON format.

Source data: https://github.com/TUMFTM/racetrack-database (LGPL-3.0).
Centre lines come from OpenStreetMap, widths from satellite imagery.

Usage:
  python3 tools/import_tumftm_track.py <track.csv> <raceline.csv> <out.json> \
      --id spielberg --name "Spielberg GP Circuit" --location "Spielberg, Austria"

Coordinate conversion: source is metres with Y up. Godot 2D is Y down, so we flip Y.
Flipping mirrors left/right, so the source's right/left widths are swapped.
"""
import argparse, csv, json, math


def read_rows(path):
    rows = []
    with open(path) as f:
        for r in csv.reader(f):
            if not r or r[0].lstrip().startswith("#"):
                continue
            rows.append([float(v) for v in r])
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("track_csv")
    ap.add_argument("raceline_csv")
    ap.add_argument("out_json")
    ap.add_argument("--id", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--location", default="")
    ap.add_argument("--ambient", type=float, default=22.0)
    ap.add_argument("--track-temp", type=float, default=32.0)
    args = ap.parse_args()

    track = read_rows(args.track_csv)
    rl = read_rows(args.raceline_csv)
    centre = [[round(x, 2), round(-y, 2), round(wl, 2), round(wr, 2)] for x, y, wr, wl in track]
    raceline = [[round(x, 2), round(-y, 2)] for x, y in rl]
    n = len(centre)
    length = sum(math.dist(centre[i][:2], centre[(i + 1) % n][:2]) for i in range(n))

    out = {
        "format": 1,
        "id": args.id,
        "name": args.name,
        "location": args.location,
        "length_m": round(length, 1),
        "source": "TUMFTM racetrack-database (LGPL-3.0), OpenStreetMap-derived centre line",
        "direction_note": "Points are ordered in race direction. Index 0 is the start/finish line.",
        "centerline_format": ["x_m", "y_m", "width_right_m", "width_left_m"],
        "centerline": centre,
        "raceline": raceline,
        "start_index": 0,
        "sectors": [0.0, 0.333, 0.667],
        "runoff_m": 30.0,
        "kerb_width_m": 1.2,
        "default_environment": {"ambient_c": args.ambient, "track_c": args.track_temp,
                                 "time_of_day_h": 14.0, "weather": "dry"},
        "pit_lane": None,
    }
    with open(args.out_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"wrote {args.out_json}: {n} points, {length:.0f} m")


if __name__ == "__main__":
    main()
