class_name SetupAdvisor
extends RefCounted
## A good setup for a car on a track (wave 4 per-track tuning). The AI uses
## it for every car it drives, and the setup screen's "Recommended" button
## gives it to players as a starting point.
##
## It drives a quick point-mass lap (cornering, braking and power limits,
## with the car's real aero and gearing) to learn the track: how much of the
## lap is flat out, the top speed reached, how hard the dips and crests load
## the car, how bumpy it is. Then it picks:
##  * the wing level with the best point-mass lap time (drag vs downforce),
##  * gearing that just reaches the limiter at the top speed,
##  * ride heights and springs that keep the floor off the ground in the
##    worst compressions, softer on bumpy tracks, stiffer on smooth ones,
##  * tyre pressures that reach the best hot pressure at the expected
##    tyre temperature (lower on a hot track), and
##  * camber, diff and dampers from the corner mix, the weather and the track
##    temperature, plus a fuel load for the race when fuel is on.

const STEP_M := 8.0
const DRIVER_GRIP := 0.88
const WING_GAIN_S := 0.05  # another click of wing only for at least this much lap time (drag costs top speed in a fight)
const MAX_SPEED := 95.0
## Expected tyre temperature above the compound's best per degree of track
## temperature over 33 C (measured with tests/tyre_probe.gd).
const TYRE_TEMP_PER_TRACK_C := 0.65

static var _cache := {}


## Track and car facts from a point-mass lap. Cached per car and track.
static func analyse(def: CarDefinition, track: TrackData) -> Dictionary:
	var key := "%s|%s|%s" % [track.id, def.id, str(def.tuning.hash())]
	if _cache.has(key):
		return _cache[key]
	var pts := _resample(track)
	var lap := _lap(def, pts)
	_cache[key] = lap
	return lap


## Setup values (CarSetup keys) for this car here. conditions (all optional):
## track_c, ambient_c, wetness (0..1), laps, fuel_enabled, fuel_rate.
static func recommend(def: CarDefinition, track: TrackData, conditions: Dictionary = {}) -> Dictionary:
	var base := def
	if def.raw.has("tuning"):
		var raw := def.raw.duplicate(true)
		raw.erase("tuning")
		base = CarDefinition.from_dict(raw)
	var d := CarSetup.defaults(base)
	var out := d.duplicate()
	var wet := clampf(float(conditions.get("wetness", 0.0)), 0.0, 1.0)
	var track_c := float(conditions.get("track_c", track.default_environment.get("track_c", 32.0)))
	var pts := _resample(track)
	# 1. Wing: best point-mass lap over the wing range (splitter follows).
	if CarSetup.adjustable(base, "wing_rear"):
		var best_t := INF
		var r := CarSetup.range_of(base, "wing_rear")
		var w := int(r[1])
		while w <= int(r[2]):
			var fw := clampf(roundf(d["wing_front"] + (w - d["wing_rear"]) * 0.7), 0.0, 10.0)
			var trial := base.with_overrides({"tuning": {"wing_rear": w, "wing_front": fw}})
			var t: float = _lap(trial, pts)["lap_s"]
			if t < best_t - WING_GAIN_S:
				best_t = t
				out["wing_rear"] = w
				out["wing_front"] = fw
			w += 1
		if wet > 0.2:
			out["wing_rear"] = minf(out["wing_rear"] + 2.0, 10.0)
			out["wing_front"] = minf(out["wing_front"] + 2.0, 10.0)
	var aero_def := base.with_overrides({"tuning": {"wing_rear": out["wing_rear"], "wing_front": out["wing_front"]}})
	var lap := _lap(aero_def, pts)
	# 2. Gearing: hit the limiter just after the end of the longest straight.
	var fd := CarSetup.range_of(base, "final_drive")
	var want := clampf(lap["v_top"] * 1.03, 30.0, 120.0)
	var top_now := CarSetup.top_speed(base, 1.0)
	if top_now > 0.0:
		out["final_drive"] = clampf(snappedf(top_now / want, fd[3]), fd[1], fd[2])
	# 3. Springs and dampers from how bumpy it is, then ride heights that keep
	# the floor off the ground in the worst compressions.
	var rough: float = lap["rough"]
	var spring_k := clampf(1.0 + (0.06 - rough) * 3.0, 0.85, 1.2)
	if wet > 0.2:
		spring_k *= 0.88
	for k in ["spring_front", "spring_rear"]:
		var r := CarSetup.range_of(base, k)
		out[k] = clampf(snappedf(d[k] * spring_k, r[3]), r[1], r[2])
	var damp := clampf(roundf(d["damper_front"] + (0.06 - rough) * 30.0 - (1.0 if wet > 0.2 else 0.0)), 3.0, 8.0)
	out["damper_front"] = damp
	out["damper_rear"] = damp
	var sprung := base.with_overrides({"tuning": out})
	var sink := worst_sink(sprung, lap)
	var margin := 3.0 + (3.0 if wet > 0.2 else 0.0)
	# Raise or lower both ends together (keeps the rake, so the balance),
	# by what the end closest to the ground needs; no lower than 6 mm down.
	var raise := maxf(maxf(sprung.plank_mm + margin + sink[0] - d["ride_front"],
		sprung.plank_mm + margin + sink[1] - d["ride_rear"]), -6.0)
	for k in ["ride_front", "ride_rear"]:
		var r := CarSetup.range_of(base, k)
		out[k] = clampf(ceilf(d[k] + raise), r[1], r[2])
	# 4. Alignment, diff and bias from the corner mix and conditions.
	var corners: float = lap["corner_share"]
	var cam_shift := -0.3 * (corners - 0.45) / 0.15 + (0.25 if track_c > 42.0 else 0.0) + 0.6 * wet
	for k in ["camber_front", "camber_rear"]:
		var r := CarSetup.range_of(base, k)
		out[k] = clampf(snappedf(d[k] + clampf(cam_shift, -0.4, 0.8), r[3]), r[1], r[2])
	var slow: float = lap["slow_share"]
	var dr := CarSetup.range_of(base, "diff_power")
	out["diff_power"] = clampf(snappedf(d["diff_power"] + 0.25 * (slow - 0.25) - 0.1 * wet, dr[3]), dr[1], dr[2])
	if wet > 0.2:
		var br := CarSetup.range_of(base, "brake_bias")
		out["brake_bias"] = clampf(d["brake_bias"] + 0.01, br[1], br[2])
		out["arb_front"] = d["arb_front"] - 1
		out["arb_rear"] = d["arb_rear"] - 2
	# 5. Tyre pressures for the expected tyre temperature.
	var tc: TyreCompound = conditions.get("compound", null)
	if tc != null:
		var t_exp := tc.optimal_temp_c + 2.0 + TYRE_TEMP_PER_TRACK_C * (track_c - 33.0)
		var cold := tc.optimal_hot_psi * TyreCompound.COLD_REF_K / (t_exp + 273.15)
		for k in ["pressure_front", "pressure_rear"]:
			var r := CarSetup.range_of(base, k)
			out[k] = clampf(snappedf(cold - tc.cold_psi, r[3]), r[1], r[2])
	# 6. Fuel for the race distance when fuel is on.
	if conditions.get("fuel_enabled", false):
		# Full power while flat out, about a quarter of it through the corners,
		# plus half a lap spare (the AI tops up at a pit stop if it must).
		var flat_s: float = lap["lap_s"] * (1.0 - float(lap["corner_share"]))
		var power_s: float = flat_s + 0.25 * (float(lap["lap_s"]) - flat_s)
		var fpl: float = base.peak_power_kw() * base.bsfc_l_per_kwh / 3600.0 * power_s * float(conditions.get("fuel_rate", 1.0))
		var laps := int(conditions.get("laps", 3))
		out["fuel_l"] = minf(ceilf(fpl * (laps + 0.5) * 1.05 + 1.0), base.fuel_capacity_l)
	return CarSetup.sanitize(base, out)


## Plain one-line notes about the track for the setup screen.
static func notes(def: CarDefinition, track: TrackData) -> Array[String]:
	var lap := analyse(def, track)
	var out: Array[String] = []
	var flat := 1.0 - float(lap["corner_share"])
	if flat > 0.62:
		out.append("Fast track: %d%% of the lap flat out, so less wing is quicker." % roundi(flat * 100.0))
	elif flat < 0.5:
		out.append("Twisty track: only %d%% of the lap flat out, so more wing pays." % roundi(flat * 100.0))
	else:
		out.append("Balanced track: %d%% of the lap flat out." % roundi(flat * 100.0))
	if float(lap["dip_g"]) > 0.6:
		out.append("Big compressions (up to %.1f g extra): keep the ride height up or the springs stiff." % lap["dip_g"])
	if float(lap["crest_g"]) > 0.35:
		out.append("Crests make the car light (down to %d%% of its weight)." % roundi((1.0 - float(lap["crest_g"])) * 100.0))
	if float(lap["rough"]) > 0.08:
		out.append("Bumpy: softer springs and dampers find grip.")
	elif float(lap["rough"]) < 0.03:
		out.append("Smooth: stiff springs and a low car work well.")
	if float(lap["slow_share"]) > 0.3:
		out.append("Lots of slow corners: more diff locking helps traction.")
	out.append("Top speed about %d km/h." % roundi(float(lap["v_top"]) * 3.6))
	return out


# --- Point-mass lap ---------------------------------------------------------

## The racing line every STEP_M metres: [pos, curvature, track s].
static func _resample(track: TrackData) -> Array:
	var ck := "pts|" + track.id + "|" + str(track.length)
	if _cache.has(ck):
		return _cache[ck]
	var src := track.raceline if track.raceline.size() > 10 else track.points
	var n := src.size()
	var line := PackedVector2Array()
	var total := 0.0
	for i in n:
		total += src[i].distance_to(src[(i + 1) % n])
	var count := maxi(int(total / STEP_M), 16)
	var step := total / count
	var seg := 0
	var seg_start := 0.0
	var seg_len := src[0].distance_to(src[1 % n])
	for k in count:
		var s := k * step
		while s > seg_start + seg_len:
			seg_start += seg_len
			seg = (seg + 1) % n
			seg_len = src[seg].distance_to(src[(seg + 1) % n])
		line.append(src[seg].lerp(src[(seg + 1) % n], (s - seg_start) / maxf(seg_len, 0.001)))
	var curv := PackedFloat64Array()
	var vcurv := PackedFloat64Array()
	var hint := -1
	for k in count:
		var a := line[(k - 2 + count) % count]
		var b := line[k]
		var c := line[(k + 2) % count]
		var cross := (b - a).cross(c - b)
		var den := a.distance_to(b) * b.distance_to(c) * c.distance_to(a)
		curv.append(absf(2.0 * cross / maxf(den, 0.001)))
		var q := track.project(b, hint)
		hint = q["idx"]
		vcurv.append(track.vertical_curvature_at(q["s"]))
	var out := [curv, vcurv, step]
	_cache[ck] = out
	return out


static func _lap(def: CarDefinition, pts: Array) -> Dictionary:
	var curv: PackedFloat64Array = pts[0]
	var vcurv: PackedFloat64Array = pts[1]
	var step: float = pts[2]
	var n := curv.size()
	var m := def.mass + 40.0
	# Drivers (and the AI) use a little less than all the grip, which makes
	# downforce worth a bit more than a perfect lap says.
	var mu := 1.42 * DRIVER_GRIP * minf(def.front_grip, def.rear_grip)
	var aero := 0.5 * 1.2 * def.cla
	var drag := 0.5 * 1.2 * def.cda
	var power := def.peak_power_kw() * 1000.0 * def.drivetrain_efficiency * 0.92
	var g := CarPhysics.G
	var v_lim := PackedFloat64Array()
	v_lim.resize(n)
	for k in n:
		var den := m * curv[k] - mu * aero - mu * m * vcurv[k]
		v_lim[k] = MAX_SPEED if den <= 0.0 else minf(sqrt(mu * m * g / den), MAX_SPEED)
	# Gearing caps the top speed.
	var v_gear := CarSetup.top_speed(def, def.final_drive) * 0.995
	var v := v_lim.duplicate()
	var ax := PackedFloat64Array()
	ax.resize(n)
	# Forward (power), twice round so the start line joins up.
	var start := 0
	for k in n:
		if v_lim[k] < v_lim[start]:
			start = k
	for j in 2 * n:
		var k := (start + j) % n
		var nk := (k + 1) % n
		var vk := v[k]
		var acc := minf(power / (m * maxf(vk, 5.0)), mu * g * 0.9) - drag * vk * vk / m
		var vn := sqrt(maxf(vk * vk + 2.0 * acc * step, 0.0))
		vn = minf(vn, v_gear)
		if vn < v[nk]:
			v[nk] = vn
			ax[nk] = acc
	for j in 2 * n:
		var k := (start - j + 2 * n) % n
		var pk := (k - 1 + n) % n
		var vk := v[k]
		var dec := mu * (g + aero * vk * vk / m) + drag * vk * vk / m
		var vp := sqrt(vk * vk + 2.0 * dec * step)
		if vp < v[pk]:
			v[pk] = vp
			ax[pk] = -dec
	var t := 0.0
	var t_corner := 0.0
	var t_slow := 0.0
	var v_top := 0.0
	var loads := PackedFloat64Array()
	var bump := 0.0
	var crest := 0.0
	for k in n:
		var dt := step / maxf(v[k], 1.0)
		t += dt
		if v[k] < v_lim[k] * 0.995 and ax[k] >= 0.0 and v[k] < v_gear * 0.99:
			pass  # accelerating flat out
		else:
			t_corner += dt
		if v[k] < 28.0:
			t_slow += dt
		v_top = maxf(v_top, v[k])
		var lg := v[k] * v[k] * vcurv[k] / g
		loads.append(lg)
		bump += absf(lg) * step
		crest = maxf(crest, -lg)
	var sorted := loads.duplicate()
	sorted.sort()
	return {"lap_s": t, "v_top": v_top, "corner_share": t_corner / t, "slow_share": t_slow / t,
		"dip_g": sorted[int(n * 0.98)], "crest_g": minf(crest, 0.9), "rough": bump / (step * n),
		"v": v, "ax": ax, "loads": loads}


## Worst ride height loss (mm) [front, rear] round the lap, ignoring the
## worst 2% (single spikes in the height data; a brief touch costs little).
static func worst_sink(def: CarDefinition, lap: Dictionary) -> Array:
	var v: PackedFloat64Array = lap["v"]
	var ax: PackedFloat64Array = lap["ax"]
	var loads: PackedFloat64Array = lap["loads"]
	var m := def.mass + 40.0
	var L := def.wheelbase
	var a := def.cg_to_front
	var b := L - a
	var fs := PackedFloat64Array()
	var rs := PackedFloat64Array()
	for k in v.size():
		var q := 0.5 * 1.2 * def.cla * v[k] * v[k] * 1.04
		var lon := m * ax[k] * def.cg_height / L
		var heave := m * CarPhysics.G * loads[k]
		fs.append((heave * b / L / sqrt(def.damper_front) - lon + q * def.aero_balance_front) / (2.0 * def.spring_front))
		rs.append((heave * a / L / sqrt(def.damper_rear) + lon + q * (1.0 - def.aero_balance_front)) / (2.0 * def.spring_rear))
	fs.sort()
	rs.sort()
	var i := int(v.size() * 0.98)
	return [fs[i], rs[i]]
