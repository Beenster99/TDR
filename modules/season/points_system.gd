class_name PointsSystem
extends RefCounted
## How a championship scores a race: points by finishing position, plus
## optional bonus points for pole position and the fastest lap.
## Presets copy real series; "custom" takes any list ("25,18,15,...");
## "everyone" gives every classified finisher points (last = 1).

const PRESETS := {
	"f1": {"name": "F1 (25-18-15-12-10-8-6-4-2-1)", "points": [25, 18, 15, 12, 10, 8, 6, 4, 2, 1]},
	"f1_2003": {"name": "F1 2003-09 (10-8-6-5-4-3-2-1)", "points": [10, 8, 6, 5, 4, 3, 2, 1]},
	"f1_1991": {"name": "F1 1991-2002 (10-6-4-3-2-1)", "points": [10, 6, 4, 3, 2, 1]},
	"motogp": {"name": "MotoGP (25-20-16-13-11 ... 1, top 15)", "points": [25, 20, 16, 13, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]},
	"indycar": {"name": "IndyCar (50-40-35-32-30 ... everyone)", "points": [50, 40, 35, 32, 30, 28, 26, 24, 22, 20,
		19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5]},
	"everyone": {"name": "Everyone scores (last place = 1)", "points": []},
	"custom": {"name": "Custom", "points": [25, 18, 15, 12, 10, 8, 6, 4, 2, 1]},
}
## Order shown in the menu.
const PRESET_ORDER := ["f1", "f1_2003", "f1_1991", "motogp", "indycar", "everyone", "custom"]

var preset: String = "f1"
var points: Array = [25, 18, 15, 12, 10, 8, 6, 4, 2, 1]
var pole_points: int = 0
var fastest_lap_points: int = 0
## The fastest lap only scores if that driver also finishes this high (0 = any finisher).
var fastest_lap_top: int = 10


static func from_preset(id: String, custom_points: Array = []) -> PointsSystem:
	var p := PointsSystem.new()
	p.preset = id if PRESETS.has(id) else "f1"
	p.points = PRESETS[p.preset]["points"].duplicate()
	if p.preset == "custom" and not custom_points.is_empty():
		p.points = custom_points.duplicate()
	return p


## "25, 18, 15" -> [25, 18, 15] (anything that isn't a number is skipped).
static func parse_list(text: String) -> Array:
	var out := []
	for part in text.replace(";", ",").replace(" ", ",").split(",", false):
		if part.strip_edges().is_valid_int() and int(part) >= 0:
			out.append(int(part))
	return out


## Points for finishing position pos (1 = winner) in a field of field_size.
func for_position(pos: int, field_size: int) -> int:
	if pos < 1:
		return 0
	if preset == "everyone":
		return maxi(field_size - pos + 1, 0)
	return int(points[pos - 1]) if pos <= points.size() else 0


func display_name() -> String:
	var n: String = PRESETS.get(preset, PRESETS["f1"])["name"]
	if preset == "custom":
		n = "Custom (%s)" % "-".join(points.map(func(x): return str(x)))
	var extras := []
	if pole_points > 0:
		extras.append("pole +%d" % pole_points)
	if fastest_lap_points > 0:
		extras.append("fastest lap +%d" % fastest_lap_points)
	return n + ("" if extras.is_empty() else ", " + ", ".join(extras))


func to_dict() -> Dictionary:
	return {"preset": preset, "points": points.duplicate(), "pole_points": pole_points,
		"fastest_lap_points": fastest_lap_points, "fastest_lap_top": fastest_lap_top}


static func from_dict(d: Dictionary) -> PointsSystem:
	var p := PointsSystem.new()
	p.preset = str(d.get("preset", "f1"))
	p.points = []
	for x in d.get("points", PRESETS["f1"]["points"]):
		p.points.append(int(x))
	p.pole_points = int(d.get("pole_points", 0))
	p.fastest_lap_points = int(d.get("fastest_lap_points", 0))
	p.fastest_lap_top = int(d.get("fastest_lap_top", 10))
	return p
