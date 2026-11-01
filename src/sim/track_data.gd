class_name TrackData
extends RefCounted
## Track layout from data/tracks/*.json. Units are metres, Godot 2D axes
## (Y down). Index 0 of the centre line is the start/finish line and points
## run in race direction.

var id: String = ""
var display_name: String = ""
var location: String = ""
var points: PackedVector2Array = []
var width_right: PackedFloat64Array = []
var width_left: PackedFloat64Array = []
var cum_s: PackedFloat64Array = []      ## distance at each point
var seg_dir: PackedVector2Array = []    ## unit tangent of segment i -> i+1
var seg_len: PackedFloat64Array = []
var length: float = 0.0
var raceline: PackedVector2Array = []
var sectors: PackedFloat64Array = [0.0, 0.333, 0.667]
var runoff: float = 30.0
var kerb_width: float = 1.2
var default_environment: Dictionary = {}
var pit_lane = null  ## wave 3


static func from_dict(d: Dictionary) -> TrackData:
	var t := TrackData.new()
	t.id = d.get("id", "")
	t.display_name = d.get("name", t.id)
	t.location = d.get("location", "")
	var start: int = d.get("start_index", 0)
	var cl: Array = d["centerline"]
	var n := cl.size()
	for k in n:
		var p: Array = cl[(k + start) % n]
		t.points.append(Vector2(p[0], p[1]))
		t.width_right.append(float(p[2]))
		t.width_left.append(float(p[3]))
	for p in d.get("raceline", []):
		t.raceline.append(Vector2(p[0], p[1]))
	t.sectors = PackedFloat64Array(d.get("sectors", [0.0, 0.333, 0.667]))
	t.runoff = d.get("runoff_m", t.runoff)
	t.kerb_width = d.get("kerb_width_m", t.kerb_width)
	t.default_environment = d.get("default_environment", {})
	t.pit_lane = d.get("pit_lane")
	t._build()
	return t


func _build() -> void:
	var n := points.size()
	cum_s.resize(n)
	seg_dir.resize(n)
	seg_len.resize(n)
	var s := 0.0
	for i in n:
		var a := points[i]
		var b := points[(i + 1) % n]
		cum_s[i] = s
		seg_len[i] = a.distance_to(b)
		seg_dir[i] = (b - a) / maxf(seg_len[i], 0.0001)
		s += seg_len[i]
	length = s


func point_count() -> int:
	return points.size()


func right_normal(i: int) -> Vector2:
	var d := seg_dir[i]
	return Vector2(-d.y, d.x)


## Smoothed normal at a vertex (average of adjacent segments), for drawing.
func vertex_normal(i: int) -> Vector2:
	var n := points.size()
	var d := seg_dir[i] + seg_dir[(i - 1 + n) % n]
	d = d.normalized()
	return Vector2(-d.y, d.x)


## Project a world position onto the centre line.
## hint: last known segment index (-1 = full search). Returns
## {idx, s, offset (+ right), w_right, w_left, dir}
func project(pos: Vector2, hint: int = -1, window: int = 12) -> Dictionary:
	var n := points.size()
	var best_i := 0
	var best_t := 0.0
	var best_d2 := INF
	var from := 0
	var count := n
	if hint >= 0:
		from = hint - window
		count = window * 2 + 1
	for k in count:
		var i := (from + k + n) % n
		var a := points[i]
		var t := clampf((pos - a).dot(seg_dir[i]), 0.0, seg_len[i])
		var d2 := pos.distance_squared_to(a + seg_dir[i] * t)
		if d2 < best_d2:
			best_d2 = d2
			best_i = i
			best_t = t
	# A big jump (teleport, respawn, or stale hint) falls back to a full search.
	if hint >= 0 and best_d2 > 60.0 * 60.0:
		return project(pos, -1)
	var j := (best_i + 1) % n
	var f := best_t / maxf(seg_len[best_i], 0.0001)
	var foot := points[best_i] + seg_dir[best_i] * best_t
	return {
		"idx": best_i,
		"s": cum_s[best_i] + best_t,
		"offset": (pos - foot).dot(right_normal(best_i)),
		"w_right": lerpf(width_right[best_i], width_right[j], f),
		"w_left": lerpf(width_left[best_i], width_left[j], f),
		"dir": seg_dir[best_i],
	}


func surface_for(q: Dictionary) -> int:
	var off: float = q["offset"]
	var edge: float = q["w_right"] if off >= 0.0 else q["w_left"]
	var a := absf(off)
	if a <= edge:
		return CarState.Surface.TRACK
	if a <= edge + kerb_width:
		return CarState.Surface.KERB
	if a <= edge + runoff:
		return CarState.Surface.GRASS
	return CarState.Surface.BARRIER


## World position at distance s along the centre line, offset metres to the right.
func position_at(s: float, offset: float = 0.0) -> Vector2:
	var i := index_at(s)
	var t := fposmod(s, length) - cum_s[i]
	return points[i] + seg_dir[i] * t + right_normal(i) * offset


func heading_at(s: float) -> float:
	return seg_dir[index_at(s)].angle()


func index_at(s: float) -> int:
	s = fposmod(s, length)
	var lo := 0
	var hi := points.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if cum_s[mid] <= s:
			lo = mid
		else:
			hi = mid - 1
	return lo


## Grid slot i (0 = pole). Two-wide staggered grid behind the line.
func grid_slot(i: int) -> Dictionary:
	var s := length - 12.0 - i * 8.0
	var side := -1.0 if i % 2 == 0 else 1.0
	var w := minf(width_left[index_at(s)], width_right[index_at(s)])
	var offset := side * minf(3.0, w * 0.45)
	return {"pos": position_at(s, offset), "heading": heading_at(s), "s": s}
