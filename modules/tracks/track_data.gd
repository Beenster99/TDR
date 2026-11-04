class_name TrackData
extends RefCounted
## Track layout from modules/tracks/data/*.json. Units are metres, Godot 2D axes
## (Y down). Index 0 of the centre line is the start/finish line and points
## run in race direction.

## What's under a car at a point (on track, kerb, grass run-off, barrier).
## GRAVEL (gravel trap) and RUNOFF (paved run-off) are off the track like
## GRASS; anything >= GRASS counts as off the track.
enum Surface { TRACK, KERB, GRASS, BARRIER, GRAVEL, RUNOFF }
## What the barrier at the edge of the run-off is made of.
enum Barrier { WALL, TYRES, ARMCO, FENCE }
## Barrier severity in a crash: how much of the impact reaches the car
## (1 = armco) and how much it bounces back.
const BARRIER_HARDNESS := {Barrier.WALL: 1.3, Barrier.TYRES: 0.55, Barrier.ARMCO: 1.0, Barrier.FENCE: 0.75}
const BARRIER_REBOUND := {Barrier.WALL: 1.35, Barrier.TYRES: 1.05, Barrier.ARMCO: 1.25, Barrier.FENCE: 1.0}
const BARRIER_NAMES := {Barrier.WALL: "concrete wall", Barrier.TYRES: "tyre wall", Barrier.ARMCO: "armco", Barrier.FENCE: "catch fencing"}
const _BARRIER_CODES := {"W": Barrier.WALL, "T": Barrier.TYRES, "A": Barrier.ARMCO, "F": Barrier.FENCE}
const _RUNOFF_CODES := {"G": Surface.GRASS, "R": Surface.GRAVEL, "P": Surface.RUNOFF}

var id: String = ""
## What kind of racing the track is for: "circuit" (road racing), "rallycross"
## (mixed tarmac and dirt, with a joker lap) or "derby" (demolition derby).
var discipline: String = "circuit"
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
## Per centre-line point: barrier type (Barrier) and run-off surface
## (Surface.GRASS / GRAVEL / RUNOFF) on each side. Empty = armco and grass.
var barrier_left: PackedByteArray = []
var barrier_right: PackedByteArray = []
var runoff_left: PackedByteArray = []
var runoff_right: PackedByteArray = []

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
var _pit_lane_cells := {}   ## pit_path segments near each cell (see _bucket_segments)
## The pit wall: a concrete wall between the track and the pit lane, all
## along the stretch where the lane runs beside the track with room for it
## (never on the track or in the lane). Its centre line, in metres; cars
## can't drive through it (RaceSim.resolve_pit_wall). Empty if no room.
var pit_wall: PackedVector2Array = []
var _pit_wall_bounds := Rect2()
## The wall's segments bucketed into PIT_WALL_CELL m squares (cell key ->
## segment indices, in order), so a car only tests the few segments near it.
var _pit_wall_cells := {}
const PIT_WALL_CELL := 8.0
const PIT_WALL_CELL_MARGIN := 3.0  ## segments are listed in every cell within this of them
const PIT_WALL_NEAR_MARGIN := 9.0  ## the same for pit_wall_near (a whole car's reach)
var _pit_wall_near_cells := {}
const PIT_WALL_HALF := 0.5        ## half the wall's thickness (m, as TrackView draws it)
const PIT_WALL_MIN_GAP := 3.4     ## track edge to lane edge needed for the wall (clear of the kerb band)
const PIT_WALL_MAX_GAP := 25.0    ## the lane's this far off: an access road, no wall
const PIT_WALL_LANE_GAP := 1.5    ## the wall stands at most this far off the lane's edge
const PIT_WALL_STEP := 2.0        ## m along the lane between wall points
## Pit lane surface: how far beside the lane the ground eases into it, and
## how far from the track's edge the lane still follows the track's height.
const PIT_VERGE_M := 10.0
const PIT_JOIN_GAP_M := 30.0

## Elevation (empty / zero when a track has none: everything below then
## returns flat values, so callers can use it unconditionally).
## Heights are metres above the lowest point of the map (base_alt_m above sea).
var base_alt_m: float = 0.0
var height: PackedFloat64Array = []     ## height at each centre-line point
var bank: PackedFloat64Array = []       ## banking at each point, radians, + = right side lower
var pit_height: PackedFloat64Array = [] ## height at each pit_path point
var _grade: PackedFloat64Array = []     ## dh/ds at each point (smoothed)
const CREST_SMOOTH_M := 35.0  ## box radius, applied 3x (~ +-100 m in all)
var _vcurv: PackedFloat64Array = []     ## d2h/ds2 at each point (+ = dip, - = crest)
## Terrain grid around the circuit, for drawing the ground and for cars off
## the track. Point (i, j) is at terrain_origin + Vector2(i, j) * terrain_cell_m
## and its height is terrain_heights[j * terrain_size.x + i] (metres).
var terrain_origin := Vector2.ZERO
var terrain_cell_m: float = 20.0
var terrain_size := Vector2i.ZERO
var terrain_heights: PackedFloat32Array = []

## Table-top jumps baked into the heights: {s (the lip), up_m, top_m,
## down_m, height_m}. Cars can leave the ground on tracks with jumps.
var jumps: Array = []
## Where the centre line crosses itself (flat crossovers):
## Vector2(s of the first pass, s of the second pass).
var crossovers: PackedVector2Array = []


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
	t.discipline = str(d.get("discipline", "circuit"))
	t.jumps = d.get("jumps", []).duplicate(true)
	for c in d.get("crossovers", []):
		t.crossovers.append(Vector2(float(c[0]), float(c[1])))
	t._build()
	t._load_dirt(d.get("dirt", []))
	if d.get("joker") is Dictionary and (d["joker"] as Dictionary).get("path", []).size() >= 2:
		t._build_joker(d["joker"])
	t._load_elevation(d.get("elevation"), start)
	if t.has_joker():
		t._build_joker_profile()
	t._load_barriers(d.get("barriers"), start)
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
	_pit_lane_cells = _bucket_segments(pit_path, PIT_WALL_CELL, pit_width * 0.5 + 0.5)
	_build_pit_wall()


## The pit wall's centre line: wherever the gap between the track's edge and
## the lane's edge is at least PIT_WALL_MIN_GAP, in the stretch round the
## garages (the run of such points that overlaps the speed-limit zone). It
## stands in the middle of the gap, or PIT_WALL_LANE_GAP off the lane where
## the gap is wide.
func _build_pit_wall() -> void:
	pit_wall = PackedVector2Array()
	var h := pit_width * 0.5
	var runs: Array = []      ## [[start d, points], ...]
	var cur := PackedVector2Array()
	var cur_start := 0.0
	var hint := -1
	var d := 0.0
	while d <= pit_length:
		var lane_edge := pit_position_at(d, -pit_side * h)
		var q := project(lane_edge, hint)
		hint = q["idx"]
		var edge: float = q["w_right"] if pit_side > 0.0 else q["w_left"]
		var gap: float = float(q["offset"]) * pit_side - edge
		var ok := gap >= PIT_WALL_MIN_GAP and gap <= PIT_WALL_MAX_GAP
		var wp := pit_position_at(d, -pit_side * (h + minf(gap * 0.5, PIT_WALL_LANE_GAP)))
		if ok:
			# Where the lane bends the offset point can fold back into the
			# lane or out onto the track: no wall there.
			var wq := project(wp, hint)
			var w_edge: float = wq["w_right"] if pit_side > 0.0 else wq["w_left"]
			ok = float(wq["offset"]) * pit_side - w_edge >= kerb_width + PIT_WALL_HALF \
				and project_pit(wp)["dist"] >= h + PIT_WALL_HALF + 0.2
		if ok:
			if cur.is_empty():
				cur_start = d
			cur.append(wp)
		elif not cur.is_empty():
			runs.append([cur_start, cur])
			cur = PackedVector2Array()
		d += PIT_WALL_STEP
	if not cur.is_empty():
		runs.append([cur_start, cur])
	# The longest run beside the garages (the speed-limit zone).
	for r in runs:
		var pts: PackedVector2Array = r[1]
		var a: float = r[0]
		var b: float = a + (pts.size() - 1) * PIT_WALL_STEP
		if pts.size() >= 2 and b >= pit_limit_start and a <= pit_limit_end and pts.size() > pit_wall.size():
			pit_wall = pts
	if pit_wall.size() >= 2:
		var lo := pit_wall[0]
		var hi := pit_wall[0]
		for p in pit_wall:
			lo = lo.min(p)
			hi = hi.max(p)
		_pit_wall_bounds = Rect2(lo, hi - lo)
	_bucket_pit_wall()


func _bucket_pit_wall() -> void:
	_pit_wall_cells = _bucket_segments(pit_wall, PIT_WALL_CELL, PIT_WALL_CELL_MARGIN)
	_pit_wall_near_cells = _bucket_segments(pit_wall, PIT_WALL_CELL, PIT_WALL_NEAR_MARGIN)


## False when nothing of the pit wall is within radius of c (cheap: one
## look-up), so a car far from it can skip pit_wall_contact. True means
## it might be.
func pit_wall_near(c: Vector2, radius: float) -> bool:
	if not has_pit_wall():
		return false
	if radius > PIT_WALL_NEAR_MARGIN:
		return true
	var near: PackedInt32Array = _pit_wall_near_cells.get(Vector2i(floori(c.x / PIT_WALL_CELL), floori(c.y / PIT_WALL_CELL)), PackedInt32Array())
	var r2 := radius * radius
	for i in near:
		var a := pit_wall[i]
		var seg := pit_wall[i + 1] - a
		var l2 := seg.length_squared()
		var foot := a if l2 < 1e-8 else a + seg * clampf((c - a).dot(seg) / l2, 0.0, 1.0)
		if c.distance_squared_to(foot) <= r2:
			return true
	return false


## Segments of a polyline bucketed into cell x cell squares: Vector2i cell ->
## PackedInt32Array of the segments (in order) that come within margin of it.
static func _bucket_segments(pts: PackedVector2Array, cell: float, margin: float) -> Dictionary:
	var cells := {}
	for i in pts.size() - 1:
		var lo := pts[i].min(pts[i + 1]) - Vector2.ONE * margin
		var hi := pts[i].max(pts[i + 1]) + Vector2.ONE * margin
		for cx in range(floori(lo.x / cell), floori(hi.x / cell) + 1):
			for cy in range(floori(lo.y / cell), floori(hi.y / cell) + 1):
				var key := Vector2i(cx, cy)
				var list: PackedInt32Array = cells.get(key, PackedInt32Array())
				list.append(i)
				cells[key] = list
	return cells


func has_pit_wall() -> bool:
	return pit_wall.size() >= 2


## Where a circle (centre c, radius r) is into the pit wall, or {} if it
## isn't: {normal (unit, out of the wall towards keep_side's side), depth (m)}.
## keep_side is a point on the side the circle should end up on (the car's
## centre); a circle that has gone right through is pushed back to that side.
func pit_wall_contact(c: Vector2, r: float, keep_side: Vector2) -> Dictionary:
	if not has_pit_wall() or not _pit_wall_bounds.grow(r + PIT_WALL_HALF + 0.5).has_point(c):
		return {}
	var reach := r + PIT_WALL_HALF
	var best := {}
	# Only segments that can be within reach + 1 m: those listed in c's cell.
	var near: PackedInt32Array
	if reach + 1.0 <= PIT_WALL_CELL_MARGIN and not _pit_wall_cells.is_empty():
		near = _pit_wall_cells.get(Vector2i(floori(c.x / PIT_WALL_CELL), floori(c.y / PIT_WALL_CELL)), PackedInt32Array())
	else:
		near = PackedInt32Array(range(pit_wall.size() - 1))
	for i in near:
		var a := pit_wall[i]
		var b := pit_wall[i + 1]
		var seg := b - a
		var l2 := seg.length_squared()
		if l2 < 1e-6:
			continue
		var t := clampf((c - a).dot(seg) / l2, 0.0, 1.0)
		var foot := a + seg * t
		var v := c - foot
		var dist := v.length()
		if dist >= reach + 1.0:
			continue
		var nrm: Vector2
		var depth: float
		if t > 0.0 and t < 1.0:
			# Along the wall: out on the side the car is on.
			var side_n := Vector2(-seg.y, seg.x) / sqrt(l2)
			if side_n.dot(keep_side - a) < 0.0:
				side_n = -side_n
			var sd := side_n.dot(c - foot)   # + on the car's side
			depth = reach - sd
			nrm = side_n
		else:
			# Round the end of the wall.
			if dist < 0.0001:
				continue
			depth = reach - dist
			nrm = v / dist
		if depth > 0.0 and (best.is_empty() or depth > float(best["depth"])):
			best = {"normal": nrm, "depth": depth}
	return best


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


func _load_elevation(e, start: int) -> void:
	if not (e is Dictionary) or e.get("height_m", []).size() != points.size():
		return
	var n := points.size()
	var hs: Array = e["height_m"]
	var bs: Array = e.get("bank_deg", [])
	base_alt_m = e.get("base_alt_m", 0.0)
	height.resize(n)
	bank.resize(n)
	for k in n:
		height[k] = float(hs[(k + start) % n])
		bank[k] = deg_to_rad(float(bs[(k + start) % n])) if bs.size() == n else 0.0
	for v in e.get("pit_height_m", []):
		pit_height.append(float(v))
	# Slope from the heights as stored; vertical curvature from a version
	# smoothed over ~200 m, because the source map (~30 m cells) has small
	# bumps a real track doesn't, and at racing speed those would throw the
	# car into the air.
	_grade.resize(n)
	_vcurv.resize(n)
	var step := length / n
	var smooth := _box_blur(_box_blur(_box_blur(height, int(CREST_SMOOTH_M / step)), int(CREST_SMOOTH_M / step)), int(CREST_SMOOTH_M / step))
	var kc := maxi(1, int(25.0 / step))
	for i in n:
		var ip := (i - 1 + n) % n
		var inx := (i + 1) % n
		var lb := maxf(seg_len[ip], 0.01)
		var lf := maxf(seg_len[i], 0.01)
		var gb := (height[i] - height[ip]) / lb
		var gf := (height[inx] - height[i]) / lf
		_grade[i] = (gb * lf + gf * lb) / (lb + lf)
		var d := kc * step
		_vcurv[i] = (smooth[(i + kc) % n] - 2.0 * smooth[i] + smooth[(i - kc + n) % n]) / (d * d)
	var tr = e.get("terrain")
	if tr is Dictionary and tr.get("size", []).size() == 2:
		terrain_origin = Vector2(tr["origin"][0], tr["origin"][1])
		terrain_cell_m = tr.get("cell_m", 20.0)
		terrain_size = Vector2i(int(tr["size"][0]), int(tr["size"][1]))
		var hd: Array = tr.get("height_dm", [])
		if hd.size() == terrain_size.x * terrain_size.y:
			terrain_heights.resize(hd.size())
			for k in hd.size():
				terrain_heights[k] = float(hd[k]) * 0.1
		else:
			terrain_size = Vector2i.ZERO


## Moving average over +-r points of a closed-loop signal.
static func _box_blur(v: PackedFloat64Array, r: int) -> PackedFloat64Array:
	var n := v.size()
	r = clampi(r, 1, n / 2 - 1)
	var out := PackedFloat64Array()
	out.resize(n)
	var acc := 0.0
	for j in range(-r, r + 1):
		acc += v[(j + n) % n]
	for i in n:
		out[i] = acc / (2 * r + 1)
		acc += v[(i + r + 1) % n] - v[(i - r + n) % n]
	return out


func _load_barriers(b, start: int) -> void:
	if not (b is Dictionary):
		return
	var n := points.size()
	var sets := [["left", barrier_left, _BARRIER_CODES, Barrier.ARMCO], ["right", barrier_right, _BARRIER_CODES, Barrier.ARMCO],
		["runoff_left", runoff_left, _RUNOFF_CODES, Surface.GRASS], ["runoff_right", runoff_right, _RUNOFF_CODES, Surface.GRASS]]
	for st in sets:
		var codes: String = b.get(st[0], "")
		if codes.length() != n:
			continue
		var arr: PackedByteArray = st[1]
		arr.resize(n)
		for k in n:
			arr[k] = st[2].get(codes[(k + start) % n], st[3])


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
	if a <= edge or (discipline == "derby" and a <= edge + runoff):
		return TrackData.Surface.TRACK   # a derby arena's road runs right up to the walls
	if q.has("pos") and in_pit_lane(q["pos"]):
		return TrackData.Surface.TRACK
	if q.has("pos") and has_joker() and _joker_bounds.grow(JOKER_VERGE_M).has_point(q["pos"]):
		var jd: float = project_joker(q["pos"])["dist"] - joker_width * 0.5
		if jd <= 0.0:
			return TrackData.Surface.TRACK
		if jd <= JOKER_VERGE_M and a > edge + kerb_width:
			return TrackData.Surface.GRASS
	if a <= edge + kerb_width:
		return TrackData.Surface.KERB
	if a <= edge + runoff:
		var ro := runoff_right if off >= 0.0 else runoff_left
		return ro[q["idx"]] if ro.size() == points.size() else TrackData.Surface.GRASS
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


## Grid slot i (0 = pole). Two-wide staggered grid behind the line; in a
## Demolition Derby arena two abreast in tight rows (the arenas are small).
func grid_slot(i: int) -> Dictionary:
	var s := length - 12.0 - i * 8.0
	if discipline == "derby":
		s = length - 10.0 - floorf(i * 0.5) * DERBY_ROW_M
	var side := -1.0 if i % 2 == 0 else 1.0
	var w := minf(width_left[index_at(s)], width_right[index_at(s)])
	var offset := side * minf(4.0 if discipline == "circuit" else 3.0, w * 0.45)
	return {"pos": position_at(s, offset), "heading": heading_at(s), "s": s}


## Metres between rows on a Demolition Derby grid (two cars a row).
const DERBY_ROW_M := 7.5


# --- Loose surface (rallycross dirt sections) --------------------------------

## Stretches of the lap on a loose surface (gravel, dirt): [[s_from, s_to], ...]
## in metres from the start line, race direction. A stretch may run over the
## line (s_from > s_to).
var dirt: Array = []
## Per centre-line point: how loose the surface is there (0 tarmac .. 1 dirt),
## eased over DIRT_BLEND_M where tarmac and dirt meet.
var _dirt_pt: PackedFloat32Array = []
const DIRT_BLEND_M := 4.0


func _load_dirt(ranges) -> void:
	if not (ranges is Array) or (ranges as Array).is_empty():
		return
	for r in ranges:
		if r is Array and r.size() >= 2:
			dirt.append([float(r[0]), float(r[1])])
	_dirt_pt.resize(points.size())
	for i in points.size():
		_dirt_pt[i] = _dirt_range_value(cum_s[i], dirt, length)


static func _dirt_range_value(s: float, ranges: Array, loop_len: float) -> float:
	var best := 0.0
	for r in ranges:
		var a: float = r[0]
		var b: float = r[1]
		var inside: float
		if loop_len > 0.0:
			var span := fposmod(b - a, loop_len)
			var into := fposmod(s - a, loop_len)
			if into > span:
				# outside: distance to the nearer end
				inside = -minf(into - span, loop_len - into)
			else:
				inside = minf(into, span - into)
		else:
			inside = minf(s - a, b - s)
		best = maxf(best, clampf(0.5 + inside / DIRT_BLEND_M, 0.0, 1.0))
	return best


func has_dirt() -> bool:
	return not dirt.is_empty() or not joker_dirt.is_empty()


## How loose the surface of the lap is at distance s: 0 = tarmac, 1 = dirt.
func dirt_at(s: float) -> float:
	if _dirt_pt.is_empty():
		return 0.0
	var a := _seg_at(s)
	return lerpf(_dirt_pt[a[0]], _dirt_pt[a[1]], a[2])


## How loose the surface is under a world position (on the lap or the joker).
func dirt_at_pos(pos: Vector2, q: Dictionary = {}) -> float:
	if has_joker() and in_joker(pos):
		return joker_dirt_at(project_joker(pos)["d"])
	if q.is_empty():
		q = project(pos)
	return dirt_at(q["s"])


# --- Joker lap (rallycross) ----------------------------------------------------
## A second route every car must take once a race (RaceSettings.joker_laps).
## Like the pit lane it is a path from where it leaves the lap (entry) to
## where it rejoins (exit); distances along it are "joker metres" (0 = entry).

var joker_path: PackedVector2Array = []
var joker_cum: PackedFloat64Array = []
var joker_length: float = 0.0
var joker_entry_s: float = 0.0
var joker_exit_s: float = 0.0
var joker_width: float = 10.0
var joker_dirt: Array = []      ## [[d_from, d_to], ...] in joker metres
var _joker_bounds := Rect2()
## Grass verge beside the joker where it runs away from the lap.
const JOKER_VERGE_M := 5.0


func _build_joker(j: Dictionary) -> void:
	for q in j["path"]:
		joker_path.append(Vector2(q[0], q[1]))
	joker_cum.resize(joker_path.size())
	var s := 0.0
	for i in joker_path.size():
		if i > 0:
			s += joker_path[i - 1].distance_to(joker_path[i])
		joker_cum[i] = s
	joker_length = s
	joker_entry_s = float(j.get("entry_s", 0.0))
	joker_exit_s = float(j.get("exit_s", 0.0))
	joker_width = float(j.get("width_m", joker_width))
	for r in j.get("dirt", []):
		joker_dirt.append([float(r[0]), float(r[1])])
	var lo := joker_path[0]
	var hi := joker_path[0]
	for q in joker_path:
		lo = lo.min(q)
		hi = hi.max(q)
	_joker_bounds = Rect2(lo, hi - lo).grow(joker_width)


## Height of the joker lane at each path point. Where it shares the ground
## with the lap (its ends) it is the lap's height; once it runs away from the
## lap it follows the hillside under it (smoothed), so it lies on the ground
## instead of cutting under the grass where the lap beside it is lower.
var joker_heights: PackedFloat64Array = []

func _build_joker_profile() -> void:
	var m := joker_path.size()
	var lap_h := PackedFloat64Array()
	var ground := PackedFloat64Array()
	var w := PackedFloat64Array()
	var h0 := joker_surface_height(project(joker_path[0]))
	var h1 := joker_surface_height(project(joker_path[m - 1]))
	for i in m:
		var q := project(joker_path[i])
		var off: float = q["offset"]
		var edge: float = (q["w_right"] if off >= 0.0 else q["w_left"]) + kerb_width
		lap_h.append(joker_surface_height(q))
		var f := joker_cum[i] / maxf(joker_length, 1.0)
		ground.append(ground_height_at(joker_path[i]) if terrain_size != Vector2i.ZERO else lerpf(h0, h1, f))
		w.append(smoothstep(0.0, 10.0, absf(off) - edge))
	# Smooth the hillside along the lane (about 8 m either way).
	for _pass in 2:
		var sm := ground.duplicate()
		for i in range(1, m - 1):
			var acc := 0.0
			var n := 0
			for k in range(maxi(i - 4, 0), mini(i + 5, m)):
				acc += ground[k]
				n += 1
			sm[i] = acc / n
		ground = sm
	joker_heights.resize(m)
	for i in m:
		joker_heights[i] = lerpf(lap_h[i], ground[i], w[i])


## Height of the joker lane d joker metres along it (0 without elevation).
func joker_height_at(d: float) -> float:
	if joker_heights.size() != joker_path.size():
		return 0.0
	var i := joker_cum.bsearch(d) - 1
	i = clampi(i, 0, joker_path.size() - 2)
	var span := joker_cum[i + 1] - joker_cum[i]
	var f := clampf((d - joker_cum[i]) / span, 0.0, 1.0) if span > 0.0001 else 0.0
	return lerpf(joker_heights[i], joker_heights[i + 1], f)


func has_joker() -> bool:
	return joker_path.size() >= 2


## Nearest point on the joker: {d (joker metres), offset (+ right), dist}.
func project_joker(pos: Vector2) -> Dictionary:
	var best := {"d": 0.0, "offset": 0.0, "dist": INF}
	for i in joker_path.size() - 1:
		var a := joker_path[i]
		var seg := joker_path[i + 1] - a
		var l := seg.length()
		if l < 0.0001:
			continue
		var dir := seg / l
		var t := clampf((pos - a).dot(dir), 0.0, l)
		var foot := a + dir * t
		var dist := pos.distance_to(foot)
		if dist < best["dist"]:
			best = {"d": joker_cum[i] + t, "offset": (pos - foot).dot(Vector2(-dir.y, dir.x)), "dist": dist}
	return best


func in_joker(pos: Vector2) -> bool:
	if not has_joker() or not _joker_bounds.has_point(pos):
		return false
	return project_joker(pos)["dist"] <= joker_width * 0.5


## Whether a car at pos is driving the joker (for lap distance and the joker
## count). Where the joker and the lap overlap (at its ends, or where they
## cross) a car stays on the route it was on: was_in = on the joker last step.
## q = project(pos) for the lap.
func on_joker_route(pos: Vector2, q: Dictionary, was_in: bool) -> bool:
	if not has_joker() or not _joker_bounds.has_point(pos):
		return false
	var jq := project_joker(pos)
	if jq["dist"] > joker_width * 0.5:
		return false
	if was_in:
		return true
	var off: float = q["offset"]
	var edge: float = q["w_right"] if off >= 0.0 else q["w_left"]
	# Getting on to it: off the lap's tarmac, or at the joker's own start.
	return absf(off) > edge or jq["d"] < joker_length * 0.25


func joker_position_at(d: float, offset: float = 0.0) -> Vector2:
	d = clampf(d, 0.0, joker_length)
	var i := _joker_index(d)
	var dir := (joker_path[i + 1] - joker_path[i]).normalized()
	return joker_path[i] + dir * (d - joker_cum[i]) + Vector2(-dir.y, dir.x) * offset


func joker_heading_at(d: float) -> float:
	var i := _joker_index(d)
	return (joker_path[i + 1] - joker_path[i]).angle()


## How loose the joker's surface is d metres along it (0 tarmac .. 1 dirt).
func joker_dirt_at(d: float) -> float:
	return _dirt_range_value(d, joker_dirt, 0.0) if not joker_dirt.is_empty() else 0.0


## The lap distance a car d metres along the joker counts as: the joker's
## length is spread evenly over the stretch of lap it replaces.
func joker_lap_s(d: float) -> float:
	var span := fposmod(joker_exit_s - joker_entry_s, length)
	return fposmod(joker_entry_s + span * clampf(d / maxf(joker_length, 0.001), 0.0, 1.0), length)


## Lap distance the main track skips while a car is on the joker.
func joker_spans(s: float) -> bool:
	s = fposmod(s, length)
	if joker_entry_s <= joker_exit_s:
		return s >= joker_entry_s and s <= joker_exit_s
	return s >= joker_entry_s or s <= joker_exit_s


func _joker_index(d: float) -> int:
	var lo := 0
	var hi := joker_path.size() - 2
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if joker_cum[mid] <= d:
			lo = mid
		else:
			hi = mid - 1
	return lo


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
	# Same answer as project_pit(pos)["dist"] <= half the width, but only
	# testing the few lane segments listed near pos.
	var half := pit_width * 0.5
	var near: PackedInt32Array = _pit_lane_cells.get(Vector2i(floori(pos.x / PIT_WALL_CELL), floori(pos.y / PIT_WALL_CELL)), PackedInt32Array())
	for i in near:
		var a := pit_path[i]
		var seg := pit_path[i + 1] - a
		var l2 := seg.length_squared()
		if l2 < 1e-8:
			continue
		var foot := a + seg * clampf((pos - a).dot(seg) / l2, 0.0, 1.0)
		if pos.distance_squared_to(foot) <= half * half:
			return true
	return false


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


# --- Elevation ----------------------------------------------------------------

func has_elevation() -> bool:
	return height.size() == points.size() and height.size() > 0


## Fraction along segment index_at(s): [i, j, f].
func _seg_at(s: float) -> Array:
	var i := index_at(s)
	var j := (i + 1) % points.size()
	var f := clampf((fposmod(s, length) - cum_s[i]) / maxf(seg_len[i], 0.0001), 0.0, 1.0)
	return [i, j, f]


## Road height at distance s, offset metres to the right of the centre line
## (banking tilts it across).
func height_at(s: float, offset: float = 0.0) -> float:
	if not has_elevation():
		return 0.0
	var a := _seg_at(s)
	var h := lerpf(height[a[0]], height[a[1]], a[2])
	return h - offset * tan(lerpf(bank[a[0]], bank[a[1]], a[2]))


## Gradient along the race direction (rise over run, + = uphill).
func grade_at(s: float) -> float:
	if not has_elevation():
		return 0.0
	var a := _seg_at(s)
	return lerpf(_grade[a[0]], _grade[a[1]], a[2])


## Vertical curvature d2h/ds2 (1/m): + in a dip or compression, - over a crest.
func vertical_curvature_at(s: float) -> float:
	if not has_elevation():
		return 0.0
	var a := _seg_at(s)
	return lerpf(_vcurv[a[0]], _vcurv[a[1]], a[2])


## Banking in radians, + = right side (of the race direction) lower.
func bank_at(s: float) -> float:
	if not has_elevation():
		return 0.0
	var a := _seg_at(s)
	return lerpf(bank[a[0]], bank[a[1]], a[2])


## Uphill direction and steepness of the road surface at a projected point
## (from project()): world 2D vector of dh/dx, dh/dy.
func surface_gradient(q: Dictionary) -> Vector2:
	if not has_elevation():
		return Vector2.ZERO
	var dir: Vector2 = q["dir"]
	var s: float = q["s"]
	return dir * grade_at(s) - Vector2(-dir.y, dir.x) * tan(bank_at(s))


## Unit up-normal of the road at a world position, in 3D axes where
## x = world x, y = up, z = world y (the 2D Y-down axis).
func surface_normal_at(pos: Vector2, hint: int = -1) -> Vector3:
	if not has_elevation():
		return Vector3.UP
	var g := surface_gradient(project(pos, hint))
	return Vector3(-g.x, 1.0, -g.y).normalized()


## Height of whatever is under a world position: the road (with banking) on
## the track and kerbs, the pit lane in the pits, else the terrain grid.
func surface_height_at(pos: Vector2, hint: int = -1) -> float:
	if not has_elevation():
		return 0.0
	var q := project(pos, hint)
	var off: float = q["offset"]
	var edge: float = q["w_right"] if off >= 0.0 else q["w_left"]
	if absf(off) <= edge + kerb_width:
		return height_at(q["s"], off)
	var road := height_at(q["s"], signf(off) * (edge + kerb_width))
	var h := road
	if terrain_size != Vector2i.ZERO:
		# Run-off follows the road's edge, then eases into the hillside.
		var t := clampf((absf(off) - edge - kerb_width) / (runoff + 60.0), 0.0, 1.0)
		h = lerpf(road, ground_height_at(pos), t * t * (3.0 - 2.0 * t))
	# The pit lane and the ground just around it (so it sits in a smooth
	# verge, not on a step).
	if has_pit_lane() and _pit_bounds.grow(PIT_VERGE_M).has_point(pos):
		var pp := project_pit(pos)
		var out: float = pp["dist"] - pit_width * 0.5
		if out < PIT_VERGE_M:
			var lane := pit_surface_height(pos, pp["d"], q)
			h = lerpf(h, lane, 1.0 - smoothstep(1.5, PIT_VERGE_M, out))
	# The joker: the height of the lap's nearest edge, so the two routes meet
	# without a step, in a smooth verge like the pit lane's.
	if has_joker() and _joker_bounds.grow(PIT_VERGE_M).has_point(pos):
		var jp := project_joker(pos)
		var jout: float = jp["dist"] - joker_width * 0.5
		if jout < PIT_VERGE_M:
			h = lerpf(h, joker_height_at(jp["d"]), 1.0 - smoothstep(1.5, PIT_VERGE_M, jout))
	return h


## Height of the joker's surface at a projected point (project(pos)).
func joker_surface_height(q: Dictionary) -> float:
	var off: float = q["offset"]
	var edge: float = q["w_right"] if off >= 0.0 else q["w_left"]
	return height_at(q["s"], clampf(off, -edge, edge))


## Height of the pit lane's surface at a point on (or beside) it, d pit metres
## along. Away from the track it is the lane's own surveyed height; where the
## lane leaves and rejoins the circuit it eases into the height of the
## track's edge, so the two meet without a step. q = project(pos) if known.
func pit_surface_height(pos: Vector2, d: float, q := {}) -> float:
	if not has_elevation():
		return 0.0
	var own := pit_height_at(d)
	var w := pit_join_weight(d)
	if w <= 0.0:
		return own
	if q.is_empty():
		q = project(pos)
	var off: float = q["offset"]
	var edge: float = q["w_right"] if off >= 0.0 else q["w_left"]
	if absf(off) <= edge:
		return height_at(q["s"], off)
	var road := height_at(q["s"], signf(off) * edge)
	var gap := absf(off) - edge
	return lerpf(own, road, w * (1.0 - smoothstep(0.0, PIT_JOIN_GAP_M, gap)))


## How much the lane follows the track's height d pit metres along: 1 at the
## ends, easing to 0 by the speed-limit zone (garages and boxes stay level).
func pit_join_weight(d: float) -> float:
	var a := maxf(pit_limit_start, 30.0)
	var b := minf(pit_limit_end, pit_length - 30.0)
	return maxf(1.0 - smoothstep(0.0, a, d), smoothstep(b, pit_length, d))


## Terrain height (bilinear on the grid); 0 without terrain data.
func ground_height_at(pos: Vector2) -> float:
	if terrain_size == Vector2i.ZERO:
		return 0.0
	var g := (pos - terrain_origin) / terrain_cell_m
	var i := clampi(int(floor(g.x)), 0, terrain_size.x - 2)
	var j := clampi(int(floor(g.y)), 0, terrain_size.y - 2)
	var fx := clampf(g.x - i, 0.0, 1.0)
	var fy := clampf(g.y - j, 0.0, 1.0)
	var w := terrain_size.x
	var a := lerpf(terrain_heights[j * w + i], terrain_heights[j * w + i + 1], fx)
	var b := lerpf(terrain_heights[(j + 1) * w + i], terrain_heights[(j + 1) * w + i + 1], fx)
	return lerpf(a, b, fy)


## Height d metres along the pit lane (0 without data).
func pit_height_at(d: float) -> float:
	if pit_height.size() != pit_path.size() or pit_height.is_empty():
		return height_at(pit_entry_s)
	var i := _pit_index(d)
	var f := clampf((clampf(d, 0.0, pit_length) - pit_cum[i]) / maxf(pit_cum[i + 1] - pit_cum[i], 0.0001), 0.0, 1.0)
	return lerpf(pit_height[i], pit_height[i + 1], f)


## Lowest and highest road height on the lap: Vector2(min, max).
func height_range() -> Vector2:
	if not has_elevation():
		return Vector2.ZERO
	var lo := INF
	var hi := -INF
	for h in height:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return Vector2(lo, hi)


# --- Dirt, jumps and crossovers (Demolition Derby arenas) -------------------

## Cars can fly (jumps, Demolition Derby arenas).
func allows_air() -> bool:
	return not jumps.is_empty()


## The jump whose lip a car going from s0 to s1 (metres along the lap,
## forwards) has just passed, or {} for none.
func jump_lip(s0: float, s1: float) -> Dictionary:
	if s1 <= s0 or s1 - s0 > 20.0:
		return {}
	for j in jumps:
		var lip := float(j.get("s", -1.0))
		if s0 < lip and s1 >= lip:
			return j
	return {}


## Ramp slope of a jump (rise over run of its up ramp).
static func jump_slope(j: Dictionary) -> float:
	return float(j.get("height_m", 0.0)) / maxf(float(j.get("up_m", 1.0)), 0.1)


## Distance (m, along the lap) from s to the nearest crossover, INF if none.
func crossover_distance(s: float) -> float:
	var best := INF
	for c in crossovers:
		for cs in [c.x, c.y]:
			var d := absf(fposmod(s - cs + length * 0.5, length) - length * 0.5)
			best = minf(best, d)
	return best


## True for the second pass over a crossover (within reach metres): that
## branch is drawn on top where the two roads meet.
func crossover_upper(s: float, reach: float) -> bool:
	for c in crossovers:
		if absf(fposmod(s - c.y + length * 0.5, length) - length * 0.5) < reach:
			return true
	return false


# --- Barriers and run-off ------------------------------------------------------

## Barrier type at distance s on one side (side >= 0: right of the race
## direction, < 0: left).
func barrier_at(s: float, side: float) -> int:
	var arr := barrier_right if side >= 0.0 else barrier_left
	return arr[index_at(s)] if arr.size() == points.size() else Barrier.ARMCO


## Barrier type nearest a projected point (from project()).
func barrier_for(q: Dictionary) -> int:
	var arr := barrier_right if q["offset"] >= 0.0 else barrier_left
	return arr[q["idx"]] if arr.size() == points.size() else Barrier.ARMCO


## Run-off surface at distance s on one side: Surface.GRASS, GRAVEL or RUNOFF.
func runoff_at(s: float, side: float) -> int:
	var arr := runoff_right if side >= 0.0 else runoff_left
	return arr[index_at(s)] if arr.size() == points.size() else Surface.GRASS
