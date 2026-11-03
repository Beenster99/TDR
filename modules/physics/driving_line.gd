class_name DrivingLine
extends RefCounted
## The racing line with reference speeds for one car, for the driving aids:
## the coloured braking line (green / yellow / red, like the Forza line) and
## the brake marker boards beside the track. Pure data, no nodes.
##
## speed[k] is the fastest this car can be going at point k and still make
## every corner ahead (corner limit, then braking back from each corner).
## A player going faster than speed[k] needs to be braking by then.
## zones lists every real braking zone on a full-speed lap.

const SPACING := 4.0          ## metres between line points
const MAX_SPEED := 95.0
## Share of the grip the reference lap uses: a bit short of the limit, so a
## player who brakes where the line turns red makes the corner.
const CORNER_GRIP := 0.92
const BRAKE_GRIP := 0.82
const AERO_TRUST := 0.9
const ZONE_MIN_DROP := 6.0    ## m/s (about 22 km/h): less is a lift, not a braking zone
## "Corners only" line (corner): where a corner starts and ends.
const CORNER_CURV := 0.008     ## 1/m (radius 125 m): a corner even without braking
const CORNER_EXIT_CURV := 0.004  ## 1/m (radius 250 m): still turning, past the apex
const CORNER_LEAD := 30.0      ## m shown before a braking zone or turn-in
const CORNER_TAIL := 20.0      ## m shown after the corner straightens out
const CORNER_MAX_EXIT := 250.0 ## m past the apex at most
const CORNER_FADE := 16.0      ## m the line fades in and out over

var points := PackedVector2Array()
var track_s := PackedFloat64Array()     ## track distance of each point
var offset := PackedFloat64Array()      ## lateral offset from the centre line (+ right)
var dist := PackedFloat64Array()        ## distance along the line from point 0
var curv := PackedFloat64Array()        ## signed curvature (+ = turning right)
var speed := PackedFloat64Array()       ## brake envelope (m/s), see above
var lap_speed := PackedFloat64Array()   ## speed on a full-power lap (m/s)
## Braking zones: {start, end, entry_v, apex_v, side} with start/end point
## indices (braking starts at start, the slowest point is end) and side the
## way the corner turns (+1 right, -1 left).
var zones: Array = []
## 0..1 for each point: 1 from the braking zone (or turn-in) through each
## corner to its exit, 0 on the straights, soft in between. The "Corners
## only" driving line shows only where this is up.
var corner := PackedFloat32Array()
var length := 0.0


static func build(track: TrackData, def: CarDefinition, compound: TyreCompound) -> DrivingLine:
	var dl := DrivingLine.new()
	dl._resample(track)
	dl._profile(track, def, compound)
	dl._find_zones()
	dl._find_corners()
	return dl


func size() -> int:
	return points.size()


## Nearest line point to pos, searching around hint (-1 = search all).
func locate(pos: Vector2, hint := -1) -> int:
	var n := points.size()
	if n == 0:
		return 0
	var best := 0
	var best_d := INF
	if hint < 0:
		for k in n:
			var d := pos.distance_squared_to(points[k])
			if d < best_d:
				best_d = d
				best = k
		return best
	for j in range(-30, 31):
		var k := (hint + j + n) % n
		var d := pos.distance_squared_to(points[k])
		if d < best_d:
			best_d = d
			best = k
	if best_d > 60.0 * 60.0:
		return locate(pos, -1)
	return best


func _resample(track: TrackData) -> void:
	var src := track.raceline if track.raceline.size() > 10 else track.points
	var n := src.size()
	var total := 0.0
	for i in n:
		total += src[i].distance_to(src[(i + 1) % n])
	var count := maxi(int(total / SPACING), 16)
	var step := total / count
	length = total
	var seg := 0
	var seg_start := 0.0
	var seg_len := src[0].distance_to(src[1 % n])
	for k in count:
		var s := k * step
		while s > seg_start + seg_len:
			seg_start += seg_len
			seg = (seg + 1) % n
			seg_len = src[seg].distance_to(src[(seg + 1) % n])
		points.append(src[seg].lerp(src[(seg + 1) % n], (s - seg_start) / maxf(seg_len, 0.001)))
		dist.append(s)
	var hint := -1
	for k in count:
		var q := track.project(points[k], hint)
		hint = q["idx"]
		track_s.append(q["s"])
		offset.append(q["offset"])
	curv.resize(count)
	for k in count:
		var a := points[(k - 3 + count) % count]
		var b := points[k]
		var c := points[(k + 3) % count]
		var cross := (b - a).cross(c - b)
		var den := a.distance_to(b) * b.distance_to(c) * c.distance_to(a)
		curv[k] = 2.0 * cross / maxf(den, 0.001)


func _profile(track: TrackData, def: CarDefinition, tc: TyreCompound) -> void:
	var n := points.size()
	var step := length / n
	var g := CarPhysics.G
	var m := def.mass + 40.0
	var mu := tc.peak_mu * minf(def.front_grip, def.rear_grip)
	var aero := 0.5 * 1.2 * def.cla
	var drag := 0.5 * 1.2 * def.cda
	var power := def.peak_power_kw() * 1000.0 * def.drivetrain_efficiency * 0.92
	var v_lim := PackedFloat64Array()
	v_lim.resize(n)
	var vc := PackedFloat64Array()
	vc.resize(n)
	var grade := PackedFloat64Array()
	grade.resize(n)
	for k in n:
		vc[k] = track.vertical_curvature_at(track_s[k])
		grade[k] = track.grade_at(track_s[k])
		var mu_c := mu * CORNER_GRIP
		var den := m * maxf(absf(curv[k]), 1e-5) - mu_c * aero * AERO_TRUST - mu_c * m * vc[k]
		v_lim[k] = MAX_SPEED if den <= 0.0 else minf(sqrt(mu_c * m * g / den), MAX_SPEED)
	# Brake envelope: back from every corner, twice round so the lap joins up.
	speed = v_lim.duplicate()
	for _pass in 2:
		for j in n:
			var k := n - 1 - j
			var nxt := speed[(k + 1) % n]
			var weight_g := maxf(g + nxt * nxt * vc[k], g * 0.25)
			var dec := mu * BRAKE_GRIP * (weight_g + aero * AERO_TRUST * nxt * nxt / m) + drag * nxt * nxt / m * 0.5 + g * grade[k]
			speed[k] = minf(speed[k], sqrt(nxt * nxt + 2.0 * maxf(dec, 2.0) * step))
	# Full-power lap (for where braking really starts).
	lap_speed = speed.duplicate()
	var start := 0
	for k in n:
		if speed[k] < speed[start]:
			start = k
	for j in 2 * n:
		var k := (start + j) % n
		var nk := (k + 1) % n
		var vk := lap_speed[k]
		var acc := minf(power / (m * maxf(vk, 5.0)), mu * g * 0.9) - drag * vk * vk / m - g * grade[k]
		var vn := sqrt(maxf(vk * vk + 2.0 * acc * step, 0.0))
		if vn < lap_speed[nk]:
			lap_speed[nk] = vn


func _find_zones() -> void:
	zones.clear()
	var n := lap_speed.size()
	# Start the scan at the fastest point so no zone is split by the wrap.
	var top := 0
	for k in n:
		if lap_speed[k] > lap_speed[top]:
			top = k
	var j := 0
	while j < n:
		var k := (top + j) % n
		var nk := (k + 1) % n
		if lap_speed[nk] < lap_speed[k] - 0.01:
			var s0 := k
			var e := nk
			var jj := j + 1
			while jj < j + n and lap_speed[(e + 1) % n] < lap_speed[e] - 0.01:
				e = (e + 1) % n
				jj += 1
			if lap_speed[s0] - lap_speed[e] >= ZONE_MIN_DROP:
				zones.append({"start": s0, "end": e, "entry_v": lap_speed[s0], "apex_v": lap_speed[e],
					"side": 1 if _turn_dir(e) > 0.0 else -1})
			j = jj
		else:
			j += 1


## Which way the corner at point k turns: summed curvature just around it.
func _turn_dir(k: int) -> float:
	var n := curv.size()
	var sum := 0.0
	for j in range(-6, 10):
		sum += curv[(k + j + n) % n]
	return sum


## corner (see above): braking zones from just before the brakes go on to
## where the corner opens out, and any tighter bend taken flat out.
func _find_corners() -> void:
	var n := points.size()
	corner = PackedFloat32Array()
	corner.resize(n)
	if n == 0:
		return
	var step := length / n
	var lead := ceili(CORNER_LEAD / step)
	var tail := ceili(CORNER_TAIL / step)
	var fade := maxf(CORNER_FADE / step, 1.0)
	# Curvature smoothed over about 25 m, so a wobble in the line isn't a corner.
	var bend := PackedFloat32Array()
	bend.resize(n)
	for k in n:
		var sum := 0.0
		for j in range(-3, 4):
			sum += absf(curv[(k + j + n) % n])
		bend[k] = sum / 7.0
	var on := PackedByteArray()
	on.resize(n)
	for z in zones:
		var s0: int = z["start"]
		var e: int = z["end"]
		var last := e
		var steps := 0
		while steps * step < CORNER_MAX_EXIT and bend[(e + steps) % n] > CORNER_EXIT_CURV:
			last = (e + steps) % n
			steps += 1
		var span := (last - s0 + n) % n
		for j in range(-lead, span + tail + 1):
			on[(s0 + j + n) % n] = 1
	for k in n:
		if bend[k] > CORNER_CURV:
			for j in range(-lead, tail + 1):
				on[(k + j + n) % n] = 1
	# Soft edges: distance (in points) to the nearest corner point, both ways round.
	var far := float(n)
	var gap := PackedFloat32Array()
	gap.resize(n)
	gap.fill(far)
	for _pass in 2:
		var d := far
		for k in n:
			d = 0.0 if on[k] else d + 1.0
			gap[k] = minf(gap[k], d)
		d = far
		for j in n:
			var k := n - 1 - j
			d = 0.0 if on[k] else d + 1.0
			gap[k] = minf(gap[k], d)
	for k in n:
		corner[k] = 1.0 - smoothstep(0.0, fade, gap[k])
