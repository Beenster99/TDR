class_name TrackData
extends RefCounted
## Track layout from modules/tracks/data/*.json. Units are metres, Godot 2D axes
## (Y down). Index 0 of the centre line is the start/finish line and points
## run in race direction.

## What's under a car at a point (on track, kerb, grass run-off, barrier).
enum Surface { TRACK, KERB, GRASS, BARRIER }

var id: String = ""
var display_name: String = ""
var short_name: String = ""
var location: String = ""
var country: String = ""
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
## Optional weather hints: {ambient_day_c, ambient_night_c, rain_chance}.
var climate: Dictionary = {}
var pit_lane = null  ## raw pit_lane object from the JSON (null = none)

## Pit lane (used from wave 3). The lane is a path from where it leaves the
## track (entry) to where it rejoins (exit), in race direction. Distances
## along it are "pit metres" (0 = entry).
var pit_path: PackedVector2Array = []
var pit_cum: PackedFloat64Array = []
var pit_length: float = 0.0
var pit_side: float = 1.0          ## +1 = right of the track, -1 = left
var pit_entry_s: float = 0.0       ## track distance where the lane leaves
var pit_exit_s: float = 0.0        ## track distance where it rejoins
var pit_width: float = 12.0
var pit_speed_limit: float = 60.0 / 3.6  ## m/s
var pit_limit_start: float = 0.0   ## pit metres where the speed limit starts
var pit_limit_end: float = 0.0     ## and ends
var pit_box_count: int = 30
var _pit_bounds := Rect2()


static func from_dict(d: Dictionary) -> TrackData:
	var t := TrackData.new()
	t.id = d.get("id", "")
	t.display_name = d.get("name", t.id)
	t.short_name = d.get("short_name", t.display_name)
	t.location = d.get("location", "")
	t.country = d.get("country", "")
	t.climate = d.get("climate", {})
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
	if t.pit_lane is Dictionary and t.pit_lane.get("path", []).size() >= 2:
		t._build_pit(t.pit_lane)
	return t


func _build_pit(p: Dictionary) -> void:
	for q in p["path"]:
		pit_path.append(Vector2(q[0], q[1]))
	pit_cum.resize(pit_path.size())
	var s := 0.0
	for i in pit_path.size():
		if i > 0:
			s += pit_path[i - 1].distance_to(pit_path[i])
		pit_cum[i] = s
	pit_length = s
	pit_side = 1.0 if p.get("side", "right") == "right" else -1.0
	pit_entry_s = p.get("entry_s", 0.0)
	pit_exit_s = p.get("exit_s", 0.0)
	pit_width = p.get("width_m", pit_width)
	pit_speed_limit = float(p.get("speed_limit_kph", 60.0)) / 3.6
	pit_limit_start = p.get("limit_start_m", pit_length * 0.15)
	pit_limit_end = p.get("limit_end_m", pit_length * 0.85)
	pit_box_count = p.get("box_count", pit_box_count)
	var lo := pit_path[0]
	var hi := pit_path[0]
	for q in pit_path:
		lo = lo.min(q)
		hi = hi.max(q)
	_pit_bounds = Rect2(lo, hi - lo).grow(pit_width)


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
		"pos": pos,
	}


func surface_for(q: Dictionary) -> int:
	var off: float = q["offset"]
	var edge: float = q["w_right"] if off >= 0.0 else q["w_left"]
	var a := absf(off)
	if a <= edge:
		return TrackData.Surface.TRACK
	if q.has("pos") and in_pit_lane(q["pos"]):
		return TrackData.Surface.TRACK
	if a <= edge + kerb_width:
		return TrackData.Surface.KERB
	if a <= edge + runoff:
		return TrackData.Surface.GRASS
	return TrackData.Surface.BARRIER


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


# --- Pit lane ---------------------------------------------------------------

func has_pit_lane() -> bool:
	return pit_path.size() >= 2


## Nearest point on the pit lane: {d (pit metres), offset (+ right), dist}.
func project_pit(pos: Vector2) -> Dictionary:
	var best := {"d": 0.0, "offset": 0.0, "dist": INF}
	for i in pit_path.size() - 1:
		var a := pit_path[i]
		var seg := pit_path[i + 1] - a
		var l := seg.length()
		if l < 0.0001:
			continue
		var dir := seg / l
		var t := clampf((pos - a).dot(dir), 0.0, l)
		var foot := a + dir * t
		var dist := pos.distance_to(foot)
		if dist < best["dist"]:
			best = {"d": pit_cum[i] + t, "offset": (pos - foot).dot(Vector2(-dir.y, dir.x)), "dist": dist}
	return best


func in_pit_lane(pos: Vector2) -> bool:
	if not has_pit_lane() or not _pit_bounds.has_point(pos):
		return false
	return project_pit(pos)["dist"] <= pit_width * 0.5


## Position d metres along the pit lane, offset metres to the right of it.
func pit_position_at(d: float, offset: float = 0.0) -> Vector2:
	var i := _pit_index(d)
	var dir := _pit_dir(i)
	return pit_path[i] + dir * (clampf(d, 0.0, pit_length) - pit_cum[i]) + Vector2(-dir.y, dir.x) * offset


func pit_heading_at(d: float) -> float:
	return _pit_dir(_pit_index(d)).angle()


## Pit box i (0 = first after the entry): {pos, heading, d}. Boxes sit on the
## garage side of the lane (away from the track), inside the speed-limit zone.
func pit_box(i: int) -> Dictionary:
	var a := pit_limit_start + 20.0
	var b := pit_limit_end - 20.0
	var n := maxi(pit_box_count, 1)
	var d := lerpf(a, b, (float(i) + 0.5) / n)
	return {"pos": pit_position_at(d, pit_side * pit_width * 0.25), "heading": pit_heading_at(d), "d": d}


## True when track distance s is in the part of the lap the pit lane runs beside.
func pit_spans(s: float) -> bool:
	s = fposmod(s, length)
	if pit_entry_s <= pit_exit_s:
		return s >= pit_entry_s and s <= pit_exit_s
	return s >= pit_entry_s or s <= pit_exit_s


func _pit_index(d: float) -> int:
	d = clampf(d, 0.0, pit_length)
	var lo := 0
	var hi := pit_path.size() - 2
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if pit_cum[mid] <= d:
			lo = mid
		else:
			hi = mid - 1
	return lo


func _pit_dir(i: int) -> Vector2:
	return (pit_path[i + 1] - pit_path[i]).normalized()
