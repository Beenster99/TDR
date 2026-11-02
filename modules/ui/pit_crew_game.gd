class_name PitCrewGame
extends Control
## The pit crew mini-game: the player leads the crew through their own car's
## stops, and how well they play decides how long the car sits in the box
## (rules: PitRules.crew_input; docs/PIT_CREW_GAME.md).
##
##  1. CREW TO STATIONS, while the car comes down the pit lane (the pit
##     guide is driving, so the pedals are free): a ring closes on each
##     station the stop needs (jacks, each tyre, the fuel rig, the wings).
##     Press THROTTLE as it closes. A missed call means that crew member
##     isn't ready and the car waits for them when it stops.
##  2. IN THE BOX: the jacks go up, then
##     - WHEEL GUNS, one tyre after another: the gauge fills as the nut
##       goes on. Press THROTTLE in the green; the earlier in the green, the
##       quicker (the bright strip at its start is perfect). Too early and
##       the wheel isn't on: it goes again.
##     - FUEL, at the same time: press BRAKE to cut the fuel at the line. Late
##       wastes time, early puts in less.
##     - wings and repairs take their time; then the jacks drop.
##  3. RELEASE: the light goes green when the lane behind is clear. Press
##     THROTTLE to send the car. Releasing on red into a car coming down the
##     lane is an unsafe release (a 5 s penalty).
## Untouched calls time out slowly, so a stop nobody plays is slower than a
## standard one; a clean, sharp one is quicker.
##
## Who plays: whoever leads the car's pit crew. In a co-op crew that's the
## pit crew (or the combined pit wall); otherwise the driver, whose car is
## driven down the lane, or a solo player on the pit wall while their AI
## co-driver drives. Settings > Gameplay turns it off (then the crew works
## at the standard time). Throttle and brake are the controls because the
## driver's pedals do nothing while the pit guide has the car.

const PREF := "pit_crew_game"

enum Stage { IDLE, PREP, BOX, DONE }

# Crew to stations (in the lane).
const RING_S := 1.1          ## a ring closes on its station in this time
const RING_GAP_S := 0.3      ## pause before the next station's ring
const RING_LATE_S := 0.28    ## after the close, the call is missed
const PERFECT_S := 0.07      ## press within this of the close: perfect
const GOOD_S := 0.18         ## within this: good
const MISS_DELAY_S := 0.35   ## each crew member not ready holds the car this long
const PERFECT_GAIN_S := 0.05 ## each perfect call saves this (primed crew)
# In the box. STOP_BASE_S (2.5 s) = jacks up + jacks down + a standard release.
const JACK_UP_S := 1.0
const JACK_DOWN_S := 1.0
const RELEASE_STD_S := 0.5   ## a standard release, after the jacks are down
const RELEASE_AUTO_S := 0.9  ## nobody presses: the crew send it themselves
## Wheel gun gauge, in shares of the standard time for that tyre.
const GUN_LOOSE := 0.72      ## before this the nut isn't on: the wheel goes again
const GUN_PERFECT := 0.82    ## up to here: perfect
const GUN_GOOD := 1.04       ## up to here: good (the standard is 1.0)
const GUN_AUTO := 1.4        ## nobody presses: done at this
const GUN_REFIT_S := 0.3     ## a loose wheel: time to start that one again
const MIN_FUEL_L := 1.0       ## less than this is a splash the crew just do (no fuel game)
const FUEL_AUTO_LATE_S := 0.6  ## the rig cuts out by itself this long after the target
const RESULT_S := 5.0        ## the result stays up this long

const YELLOW := Color(1.0, 0.88, 0.35)
const GREEN := Color(0.4, 1.0, 0.5)
const BRIGHT := Color(0.75, 1.0, 0.85)
const RED := Color(1.0, 0.4, 0.35)
const AMBER := Color(1.0, 0.65, 0.25)
const DIM := Color(1, 1, 1, 0.55)
const PANEL := Color(0.02, 0.04, 0.07, 0.88)
const WHEEL_NAMES := ["FRONT LEFT", "FRONT RIGHT", "REAR LEFT", "REAR RIGHT"]

## The RaceSession (untyped so the headless tests can drive the game with a
## stand-in: it needs sim, local_car, team_car, local_role, local_peer and
## request_pit).
var session
var font: Font
var stage := Stage.IDLE
var car := -1
var clock := 0.0                 ## seconds since the stage started
var enabled_override = null      ## tests: true / false instead of the player's setting
var autoplay := false            ## testing (--crew-autoplay): presses every call at a good moment

# Crew to stations: [{name, result: "" | perfect | good | miss}]
var stations: Array = []
var station_k := 0
var station_t0 := 0.0            ## when the current ring appeared (stage clock)
var prep_delay := 0.0            ## seconds the car waits for the crew in the box

# In the box (stage clock = seconds since the car stopped).
var work: Dictionary = {}
var wheels: Array = []           ## wheels to change, in order
var wheel_k := 0
var wheel_t0 := 0.0              ## the current wheel's gauge started
var wheel_std := 0.0             ## standard seconds for each wheel
var wheel_results: Array = []    ## per wheel done: perfect / good / slow / loose count
var loose := 0
var tyres_done_at := -1.0
var fuel_target := 0.0
var fuel_done_at := -1.0
var fuel_in := 0.0
var release_ready_at := -1.0
var released_at := -1.0
var unsafe := false
var _sent_release := false
var _flash := ""
var _flash_t := 0.0

# Result.
var result: Dictionary = {}
var _stops_seen := -1
var _prev_gun := 0.0
var _prev_fuel := 0.0


func setup(p_session) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE


## On/off: Settings > Gameplay (GameData.prefs[PREF], registered by core).
func enabled() -> bool:
	if enabled_override != null:
		return bool(enabled_override)
	if not is_inside_tree():
		return false
	var gd := get_node_or_null("/root/GameData")
	return gd == null or bool(gd.prefs.get(PREF, true))


## The car this player leads the crew of (-1 = none): their own car when
## nobody else in its crew is the pit crew, or the car they're pit crew for.
static func led_car(s) -> int:
	if s == null:
		return -1
	var car: int = s.team_car if s.team_car >= 0 else s.local_car
	if car < 0:
		return -1
	var role: String = s.local_role
	if RaceEntry.role_covers(role, RaceEntry.ROLE_PIT_CREW):
		return car
	if s.local_car != car:
		return -1   # the strategist
	var sim: RaceSim = s.sim
	for m in sim.entries[car].human_crew():
		if int(m.get("peer_id", 0)) != s.local_peer and RaceEntry.role_covers(str(m.get("role", "")), RaceEntry.ROLE_PIT_CREW):
			return -1   # a team mate runs the crew
	return car


func is_active() -> bool:
	return stage == Stage.PREP or stage == Stage.BOX


# --- Every frame -------------------------------------------------------------

func _process(delta: float) -> void:
	size = get_viewport_rect().size
	if session == null:
		return
	var gun := Input.get_action_strength("accelerate")
	var fuel := Input.get_action_strength("brake")
	var gun_hit := gun > 0.6 and _prev_gun <= 0.3
	var fuel_hit := fuel > 0.6 and _prev_fuel <= 0.3
	_prev_gun = gun
	_prev_fuel = fuel
	step(delta, gun_hit, fuel_hit)
	visible = stage != Stage.IDLE
	queue_redraw()


## Keeps the throttle and brake to the game while it's on (the crew console
## would take A / Enter as its own button).
func _input(event: InputEvent) -> void:
	if is_active() and (event.is_action("accelerate") or event.is_action("brake")):
		get_viewport().set_input_as_handled()


## Moves the game on by dt seconds; gun / fuel: the throttle / brake was
## pressed this frame.
func step(dt: float, gun := false, fuel := false) -> void:
	_flash_t -= dt
	if autoplay:
		gun = gun or _auto_gun(dt)
		fuel = fuel or _auto_fuel(dt)
	var want := led_car(session) if enabled() else -1
	match stage:
		Stage.IDLE, Stage.DONE:
			if stage == Stage.DONE:
				clock += dt
				if clock >= RESULT_S:
					stage = Stage.IDLE
			if want >= 0 and _coming_in(want):
				_start_prep(want)
		Stage.PREP:
			clock += dt
			var p := _pit()
			if p["phase"] == PitRules.PHASE_SERVICE:
				if bool(p.get("crew_game", false)):
					_start_box()
				else:
					stage = Stage.IDLE   # the call to play didn't reach the car in time
			elif not _coming_in(car):
				session.request_pit(car, {"crew": {"play": false}})
				stage = Stage.IDLE
			else:
				_step_prep(gun)
		Stage.BOX:
			clock += dt
			var p := _pit()
			if p["phase"] != PitRules.PHASE_SERVICE:
				_finish(not _sent_release)
			else:
				_step_box(gun, fuel)
	_watch_result()


func _sim() -> RaceSim:
	return session.sim


## Testing: where a sharp crew leader would press.
## (dt: the clock moves on this much before the press counts.)
func _auto_gun(dt: float) -> bool:
	var t := clock + dt
	if stage == Stage.PREP:
		return station_k < stations.size() and t - station_t0 >= RING_S - 0.02
	if stage != Stage.BOX:
		return false
	if tyres_done_at < 0.0 and t >= wheel_t0:
		return (t - wheel_t0) / maxf(wheel_std, 0.01) >= GUN_LOOSE + 0.04
	return release_ready_at >= 0.0 and t >= release_ready_at + 0.25 and _sim().pits.release_clear(car)


func _auto_fuel(dt: float) -> bool:
	return stage == Stage.BOX and fuel_done_at < 0.0 and fuel_target > 0.0 \
		and clock + dt >= block_start() + fuel_target / PitRules.FUEL_FLOW_LPS


func _pit() -> Dictionary:
	return _sim().entries[car].pit


## The car is on its way to its box: boxing, or guided down the lane.
func _coming_in(i: int) -> bool:
	var p: Dictionary = _sim().entries[i].pit
	var ph: String = p["phase"]
	if ph == PitRules.PHASE_LIMIT:
		return true
	return p["box"] and (ph == PitRules.PHASE_APPROACH or ph == PitRules.PHASE_ENTRY)


# --- Crew to stations ----------------------------------------------------------

func _start_prep(i: int) -> void:
	car = i
	stage = Stage.PREP
	clock = 0.0
	result = {}
	var w := _sim().pits.service_for(i, _sim().entries[i].pit["plan"])
	stations = [{"name": "JACKS", "result": ""}]
	for k in w["wheels"]:
		stations.append({"name": WHEEL_NAMES[int(k)], "result": ""})
	if float(w["fuel_l"]) >= MIN_FUEL_L:
		stations.append({"name": "FUEL RIG", "result": ""})
	if not (w.get("setup", {}) as Dictionary).is_empty():
		stations.append({"name": "WINGS", "result": ""})
	if float(w["repair_s"]) > 0.0:
		stations.append({"name": "REPAIRS", "result": ""})
	station_k = 0
	station_t0 = 0.6
	prep_delay = 0.0
	session.request_pit(i, {"crew": {"play": true}})
	_sfx("chime", -8.0)


func _step_prep(gun: bool) -> void:
	if station_k >= stations.size():
		return
	var since := clock - station_t0
	if since < 0.0:
		return
	var off := since - RING_S   # 0 = the ring closes on the station now
	if gun:
		var r := "miss"
		if absf(off) <= PERFECT_S:
			r = "perfect"
		elif absf(off) <= GOOD_S:
			r = "good"
		_call_station(r)
	elif off > RING_LATE_S:
		_call_station("miss")


func _call_station(r: String) -> void:
	stations[station_k]["result"] = r
	match r:
		"perfect":
			prep_delay -= PERFECT_GAIN_S
			_sfx("ui_select", -4.0, 1.3)
		"good":
			_sfx("ui_select", -6.0)
		_:
			prep_delay += MISS_DELAY_S
			_sfx("ui_tick", -2.0, 0.6)
	station_k += 1
	station_t0 = clock + RING_GAP_S


# --- In the box ----------------------------------------------------------------

func _start_box() -> void:
	# Calls nobody made before the car stopped: those crew members are late.
	while station_k < stations.size():
		stations[station_k]["result"] = "miss"
		prep_delay += MISS_DELAY_S
		station_k += 1
	stage = Stage.BOX
	clock = 0.0
	work = _pit().get("work", {})
	wheels = (work.get("wheels", []) as Array).duplicate() if str(work.get("tyre", "")) != "" else []
	wheel_k = 0
	wheel_results = []
	loose = 0
	wheel_std = PitRules.tyre_time(wheels.size()) / maxf(wheels.size(), 1)
	wheel_t0 = block_start()
	tyres_done_at = block_start() if wheels.is_empty() else -1.0
	fuel_target = float(work.get("fuel_l", 0.0))
	if fuel_target < MIN_FUEL_L:
		fuel_target = 0.0   # a splash: the crew just do it
	fuel_done_at = block_start() if fuel_target <= 0.0 else -1.0
	fuel_in = 0.0
	release_ready_at = -1.0
	released_at = -1.0
	unsafe = false
	_sent_release = false


## When the work starts: the jacks are up and every crew member is there.
func block_start() -> float:
	return maxf(prep_delay, -0.2) + JACK_UP_S


func _step_box(gun: bool, fuel: bool) -> void:
	var t := clock
	var b := block_start()
	# Wheel guns, one tyre after another.
	if tyres_done_at < 0.0 and t >= wheel_t0:
		var g := gauge()
		if gun:
			gun = false   # one press, one job
			if g < GUN_LOOSE:
				loose += 1
				wheel_t0 = t + GUN_REFIT_S
				_flash_msg("LOOSE WHEEL! Go again", 1.0)
				_sfx("ui_tick", 0.0, 0.5)
			else:
				_wheel_done(t, "perfect" if g <= GUN_PERFECT else ("good" if g <= GUN_GOOD else "slow"))
		elif g >= GUN_AUTO:
			_wheel_done(t, "slow")
	# Fuel, alongside.
	if fuel_target > 0.0 and t >= b:
		var flow := minf((t - b) * PitRules.FUEL_FLOW_LPS, fuel_target)
		if fuel_done_at < 0.0:
			fuel_in = flow
			var target_at := b + fuel_target / PitRules.FUEL_FLOW_LPS
			if fuel:
				fuel_done_at = t
				_sfx("ui_select", -5.0, 0.8)
				if t < target_at - 0.15:
					_flash_msg("Fuel cut early: %.0f of %.0f L" % [fuel_in, fuel_target], 1.6)
			elif t >= target_at + FUEL_AUTO_LATE_S:
				fuel_done_at = t
				fuel_in = fuel_target
	# Then the wings, repairs, the jacks down and the release.
	if release_ready_at < 0.0 and tyres_done_at >= 0.0 and fuel_done_at >= 0.0:
		var block_end := maxf(maxf(tyres_done_at, fuel_done_at), b + float(work.get("setup_s", 0.0)))
		release_ready_at = block_end + float(work.get("repair_s", 0.0)) + JACK_DOWN_S
		if int(work.get("driver", -1)) >= 0:
			release_ready_at = maxf(release_ready_at, PitRules.DRIVER_CHANGE_S - RELEASE_STD_S)
	if release_ready_at >= 0.0 and t >= release_ready_at and not _sent_release:
		var clear := _sim().pits.release_clear(car)
		if gun:
			_release(t, not clear)
		elif clear and t >= release_ready_at + RELEASE_AUTO_S:
			_release(t, false)


func _wheel_done(t: float, r: String) -> void:
	wheel_results.append(r)
	wheel_k += 1
	_sfx("ui_select", -6.0, 1.4 if r == "perfect" else 1.0)
	if wheel_k >= wheels.size():
		tyres_done_at = t
	else:
		wheel_t0 = t


## The current wheel's gauge: 1.0 = its standard time.
func gauge() -> float:
	return (clock - wheel_t0) / maxf(wheel_std, 0.01)


func _release(t: float, is_unsafe: bool) -> void:
	_sent_release = true
	released_at = t
	unsafe = is_unsafe
	var msg := {"release": true}
	if fuel_target > 0.0:
		msg["fuel_l"] = fuel_in
	session.request_pit(car, {"crew": msg})
	_sfx("chime", -4.0, 1.2)
	if is_unsafe:
		_flash_msg("UNSAFE RELEASE!", 2.0)


func _finish(crew_gave_up: bool) -> void:
	stage = Stage.DONE
	clock = 0.0
	result = {"pending": true, "gave_up": crew_gave_up, "unsafe": unsafe, "prep_delay": prep_delay,
		"loose": loose, "wheels": wheel_results.duplicate()}


## Fills in the stop's real time once the car's pit state says it's done.
func _watch_result() -> void:
	if car < 0:
		return
	var p := _pit()
	var stops := int(p["stops"])
	if _stops_seen < 0:
		_stops_seen = stops
	if stops > _stops_seen:
		_stops_seen = stops
		if result.get("pending", false):
			var last: Dictionary = p.get("last_stop", {})
			result["pending"] = false
			result["stationary_s"] = float(last.get("stationary_s", 0.0))
			result["standard_s"] = float(last.get("standard_s", 0.0))


## A grade for the stop from its time against the standard.
static func grade(stationary: float, standard: float) -> String:
	if standard <= 0.0:
		return ""
	var r := stationary / standard
	if r <= 0.85:
		return "PERFECT STOP"
	if r <= 0.95:
		return "GREAT STOP"
	if r <= 1.03:
		return "GOOD STOP"
	if r <= 1.15:
		return "SLOW STOP"
	return "SCRAPPY STOP"


func _flash_msg(s: String, secs: float) -> void:
	_flash = s
	_flash_t = secs


func _sfx(n: String, db := 0.0, pitch := 1.0) -> void:
	if not is_inside_tree():
		return
	var s := get_node_or_null("/root/Sound")
	if s != null:
		s.call("ui", n, db, pitch)


# --- Drawing ---------------------------------------------------------------------

const W := 640.0
const H := 200.0


func _text(pos: Vector2, s: String, fs := 16, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, pos + Vector2(1, 1), s, align, width, fs, Color(0, 0, 0, 0.6))
	draw_string(font, pos, s, align, width, fs, col)


func _draw() -> void:
	if session == null or stage == Stage.IDLE or font == null:
		return
	var r := Rect2((size.x - W) * 0.5, size.y - H - 196.0, W, H)
	draw_rect(r, PANEL)
	draw_rect(r, Color(YELLOW, 0.45), false, 2.0)
	match stage:
		Stage.PREP: _draw_prep(r)
		Stage.BOX: _draw_box(r)
		Stage.DONE: _draw_result(r)
	if _flash_t > 0.0 and _flash != "":
		_text(Vector2(r.position.x, r.position.y - 12), _flash, 20, RED if _flash.begins_with("UNSAFE") or _flash.begins_with("LOOSE") else YELLOW,
			HORIZONTAL_ALIGNMENT_CENTER, W)


func _draw_prep(r: Rect2) -> void:
	var o := r.position
	_text(o + Vector2(16, 28), "PIT CREW: CREW TO STATIONS", 18, YELLOW)
	_text(o + Vector2(16, 28), "THROTTLE as the ring closes", 14, DIM, HORIZONTAL_ALIGNMENT_RIGHT, W - 32)
	var n := stations.size()
	var step_x := (W - 40.0) / maxf(n, 1)
	for k in n:
		var c := Vector2(o.x + 20 + step_x * (k + 0.5), o.y + 104)
		var res: String = stations[k]["result"]
		var col := Color(1, 1, 1, 0.35)
		match res:
			"perfect": col = BRIGHT
			"good": col = GREEN
			"miss": col = RED
		draw_circle(c, 22.0, Color(col, 0.25 if res == "" else 0.5))
		draw_arc(c, 22.0, 0, TAU, 32, col, 2.5)
		if k == station_k:
			var since := clock - station_t0
			if since >= 0.0:
				var f := clampf(since / RING_S, 0.0, 1.3)
				var rad := lerpf(70.0, 22.0, f)
				var near := absf(since - RING_S) <= GOOD_S
				draw_arc(c, maxf(rad, 4.0), 0, TAU, 40, GREEN if near else YELLOW, 3.0)
		var mark: String = {"perfect": "PERFECT", "good": "READY", "miss": "LATE"}.get(res, "")
		_text(Vector2(c.x - step_x * 0.5, c.y + 52), stations[k]["name"], 12, Color.WHITE if res == "" else col,
			HORIZONTAL_ALIGNMENT_CENTER, step_x)
		if mark != "":
			_text(Vector2(c.x - step_x * 0.5, c.y + 6), mark, 11, col, HORIZONTAL_ALIGNMENT_CENTER, step_x)
	var late := stations.filter(func(s): return s["result"] == "miss").size()
	if late > 0:
		_text(o + Vector2(16, H - 12), "%d crew not ready: the car waits %.1f s" % [late, maxf(prep_delay, 0.0)], 13, AMBER)


func _draw_box(r: Rect2) -> void:
	var o := r.position
	var t := clock
	var b := block_start()
	_text(o + Vector2(16, 28), "PIT CREW: IN THE BOX", 18, YELLOW)
	_text(o + Vector2(16, 28), "%.1f s   standard %.1f s" % [t, float(work.get("total_s", 0.0))], 16, Color.WHITE,
		HORIZONTAL_ALIGNMENT_RIGHT, W - 32)
	# The car from above with its four tyres.
	var car_c := Vector2(o.x + 70, o.y + 112)
	draw_rect(Rect2(car_c - Vector2(22, 50), Vector2(44, 100)), Color(1, 1, 1, 0.18))
	draw_rect(Rect2(car_c - Vector2(22, 50), Vector2(44, 100)), Color(1, 1, 1, 0.5), false, 1.5)
	var spots := [Vector2(-30, -32), Vector2(30, -32), Vector2(-30, 32), Vector2(30, 32)]
	for w in 4:
		var col := Color(1, 1, 1, 0.25)
		var k := wheels.find(w)
		if k >= 0:
			if k < wheel_results.size():
				col = {"perfect": BRIGHT, "good": GREEN, "slow": AMBER}.get(wheel_results[k], GREEN)
			elif k == wheel_k and t >= b:
				col = YELLOW
			else:
				col = Color(1, 1, 1, 0.6)
		draw_rect(Rect2(car_c + spots[w] - Vector2(7, 13), Vector2(14, 26)), col)
	if t < b:
		var txt := "JACKS UP"
		if prep_delay > 0.0 and t < maxf(prep_delay, 0.0):
			txt = "WAITING FOR THE CREW"
		_text(Vector2(o.x + 140, o.y + 80), txt, 16, AMBER if txt.begins_with("WAITING") else DIM)
	# Wheel gun gauge.
	var gx := o.x + 140
	var gy := o.y + 96
	var gw := 360.0
	if not wheels.is_empty():
		var label := "WHEEL GUN: %s" % (WHEEL_NAMES[int(wheels[wheel_k])] if wheel_k < wheels.size() else "TYRES DONE")
		_text(Vector2(gx, gy - 8), label, 14, Color.WHITE if tyres_done_at < 0.0 else GREEN)
		var full := GUN_AUTO
		draw_rect(Rect2(gx, gy, gw, 22), Color(1, 1, 1, 0.08))
		draw_rect(Rect2(gx, gy, gw * GUN_LOOSE / full, 22), Color(RED, 0.35))
		draw_rect(Rect2(gx + gw * GUN_LOOSE / full, gy, gw * (GUN_PERFECT - GUN_LOOSE) / full, 22), Color(BRIGHT, 0.75))
		draw_rect(Rect2(gx + gw * GUN_PERFECT / full, gy, gw * (GUN_GOOD - GUN_PERFECT) / full, 22), Color(GREEN, 0.45))
		draw_rect(Rect2(gx + gw * GUN_GOOD / full, gy, gw * (full - GUN_GOOD) / full, 22), Color(AMBER, 0.3))
		if tyres_done_at < 0.0 and t >= wheel_t0:
			var x := gx + gw * clampf(gauge() / full, 0.0, 1.0)
			draw_rect(Rect2(x - 2, gy - 4, 4, 30), Color.WHITE)
		_text(Vector2(gx, gy + 40), "THROTTLE in the green", 12, DIM)
	else:
		_text(Vector2(gx, gy + 10), "No tyres this stop", 14, DIM)
	# Fuel gauge (right).
	var fx := o.x + W - 160
	if fuel_target > 0.0:
		var fh := 110.0
		var fy := o.y + 50
		var cap := fuel_target * 1.25
		draw_rect(Rect2(fx, fy, 26, fh), Color(1, 1, 1, 0.08))
		var shown := fuel_in if fuel_done_at >= 0.0 or t < b else minf((t - b) * PitRules.FUEL_FLOW_LPS, fuel_target)
		var fill := clampf(shown / cap, 0.0, 1.0) * fh
		draw_rect(Rect2(fx, fy + fh - fill, 26, fill), Color(0.4, 0.8, 1.0, 0.8))
		var ty := fy + fh - fh * fuel_target / cap
		draw_line(Vector2(fx - 6, ty), Vector2(fx + 32, ty), YELLOW, 2.0)
		_text(Vector2(fx + 38, fy + 14), "FUEL", 14, Color.WHITE if fuel_done_at < 0.0 else GREEN)
		_text(Vector2(fx + 38, fy + 34), "%.0f / %.0f L" % [shown, fuel_target], 13, DIM)
		_text(Vector2(fx + 38, fy + 54), "BRAKE at" if fuel_done_at < 0.0 else "done", 12, DIM)
		_text(Vector2(fx + 38, fy + 70), "the line" if fuel_done_at < 0.0 else "", 12, DIM)
	# Release light.
	var lc := Vector2(o.x + W - 40, o.y + 160)
	if release_ready_at >= 0.0 and t >= release_ready_at:
		var clear := _sim().pits.release_clear(car)
		draw_circle(lc, 20.0, GREEN if clear else RED)
		_text(Vector2(gx, o.y + H - 14), "GO! THROTTLE to release" if clear else "HOLD: car coming down the lane", 16,
			GREEN if clear else RED)
	else:
		draw_circle(lc, 20.0, Color(RED, 0.35))
		var what := "Repairs" if tyres_done_at >= 0.0 and fuel_done_at >= 0.0 and float(work.get("repair_s", 0.0)) > 0.0 else ""
		if what != "":
			_text(Vector2(gx, o.y + H - 14), "Repairs: %.0f s" % float(work.get("repair_s", 0.0)), 14, DIM)


func _draw_result(r: Rect2) -> void:
	var o := r.position
	if result.get("pending", true):
		_text(o + Vector2(16, 40), "PIT CREW: car released", 18, YELLOW)
		return
	var st := float(result.get("stationary_s", 0.0))
	var std := float(result.get("standard_s", 0.0))
	var g := grade(st, std)
	if result.get("gave_up", false):
		g = "THE CREW SENT THE CAR WITHOUT YOU"
	var col := GREEN if st <= std else (AMBER if st <= std * 1.15 else RED)
	_text(o + Vector2(16, 40), g, 22, col)
	_text(o + Vector2(16, 76), "Stationary %.1f s  (standard %.1f s, %s%.1f s)" % [st, std, "+" if st >= std else "-", absf(st - std)], 18)
	var notes := []
	var late := stations.filter(func(s): return s["result"] == "miss").size()
	if late > 0:
		notes.append("%d crew late to stations" % late)
	if int(result.get("loose", 0)) > 0:
		notes.append("%d loose wheel%s" % [result["loose"], "s" if int(result["loose"]) > 1 else ""])
	var perfect := (result.get("wheels", []) as Array).count("perfect")
	if perfect > 0:
		notes.append("%d perfect wheel gun%s" % [perfect, "s" if perfect > 1 else ""])
	if result.get("unsafe", false):
		notes.append("UNSAFE RELEASE: 5 s penalty")
	_text(o + Vector2(16, 108), ", ".join(notes), 14, DIM, HORIZONTAL_ALIGNMENT_LEFT, W - 32)
