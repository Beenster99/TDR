class_name PitCrewGame
extends Control
## The pit crew mini-game, co-op "Two guns" (docs/PIT_CREW_GAME.md). A player
## is one of the car's two wheel gunners, working in the real 3D pit box
## seen from above: the left gunner does the front left then the rear left,
## the right gunner the right side. The AI crew do everything else (the
## lollipop, the fuel, the air lance, the release), and the car drops once
## both sides are done, so how well the gunners play decides the stop time.
##
##  1. While the car comes down the lane, run your mechanic to your front
##     wheel (stick / WASD).
##  2. In the box, once the fuel is in (tyres wait for the fuel), at a
##     wheel: HOLD the gun (RT / A / Space) to undo the nut. The old wheel
##     comes off and the new one goes on by itself.
##  3. HOLD the gun again and let go in the green: the earlier in the green,
##     the quicker (the bright strip at its start is perfect). Let go too
##     early and the nut isn't tight: do it again. Hold on and the gun
##     finishes it slowly.
##  4. Run to your rear wheel and do it again.
##
## Who plays: the car's driver is the left gunner (the pit guide drives the
## car down the lane and into the box, so their hands are free); a team
## mate on the pit crew or the pit wall is the right gunner (or the left one
## when the AI drives); a strategist doesn't play. Each player turns it on
## for themselves in Settings > Gameplay, and a side nobody plays is the
## AI's. Online, each gunner plays on their own machine: their wheels reach
## the machine that simulates the car through RaceSession.request_pit.

const PREF := "pit_crew_game"

enum Stage { IDLE, READY, BOX, DONE }
enum Job { NONE, NUT, SWAP, GUN, LOOSE }

const RUN_SPEED := 5.0       ## m/s, a gunner sprinting round the car
const REACH := 0.75          ## m from a wheel's spot that counts as at the wheel
const ROAM := 6.5            ## m from the car's centre a gunner can go
const NUT_OFF_S := 0.45      ## hold the gun this long to undo the nut
const GUN_ON_S := 0.7        ## a standard nut on (the gauge's 1.0)
## Wheel gun gauge, in shares of GUN_ON_S.
const GUN_LOOSE := 0.72      ## let go before this: the nut isn't tight, go again
const GUN_PERFECT := 0.82    ## up to here: perfect
const GUN_GOOD := 1.04       ## up to here: good
const GUN_AUTO := 1.4        ## held on: the gun finishes it here (slow)
const GUN_REFIT_S := 0.3     ## a loose nut: time to get the gun back on it
const RESULT_S := 5.0        ## the result stays up this long

const YELLOW := Color(1.0, 0.88, 0.35)
const GREEN := Color(0.4, 1.0, 0.5)
const BRIGHT := Color(0.75, 1.0, 0.85)
const RED := Color(1.0, 0.4, 0.35)
const AMBER := Color(1.0, 0.65, 0.25)
const DIM := Color(1, 1, 1, 0.55)
const PANEL := Color(0.02, 0.04, 0.07, 0.88)
const WHEEL_NAMES := ["FRONT LEFT", "FRONT RIGHT", "REAR LEFT", "REAR RIGHT"]
const SIDE_NAMES := ["LEFT", "RIGHT"]

## The RaceSession (untyped so the headless tests can drive the game with a
## stand-in: it needs sim, local_car, team_car, local_role and request_pit).
var session
## The pit crews in the 3D world (graphics PitCrews; null in tests without
## one: the wheel spots then come from the car itself).
var crews
var font: Font
var stage := Stage.IDLE
var car := -1
var side := -1
var clock := 0.0                 ## seconds since the stage started (in the box: since the car stopped)
var enabled_override = null      ## tests: true / false instead of the player's setting
var autoplay := false            ## testing (--crew-autoplay): runs and guns like a sharp player

# The player's mechanic.
var pos := Vector2.ZERO
var face := 0.0
var job := Job.NONE
var job_wheel := -1
var job_t0 := 0.0
var my_wheels: Array = []        ## this side's wheels this stop, front first
var done: Dictionary = {}        ## wheel -> perfect / good / slow
var loose := 0
var guns_from := 0.0             ## when the tyres can start (the fuel is in)
var _gun_was := false
var _flash := ""
var _flash_t := 0.0

# Result.
var result: Dictionary = {}
var _stops_seen := -1


func setup(p_session, p_crews = null) -> void:
	session = p_session
	crews = p_crews
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
	return gd != null and bool(gd.prefs.get(PREF, false))


## Which wheel gunner this player is: [car, side] (side 0 left, 1 right),
## [-1, -1] for none. The driver is the left gunner; a team mate on the pit
## crew or pit wall the right one (the left when the AI drives).
static func gunner_for(s) -> Array:
	if s == null:
		return [-1, -1]
	var c: int = s.team_car if s.team_car >= 0 else s.local_car
	if c < 0:
		return [-1, -1]
	if s.local_car == c:
		return [c, 0]
	if not RaceEntry.role_covers(str(s.local_role), RaceEntry.ROLE_PIT_CREW):
		return [-1, -1]   # the strategist
	var sim: RaceSim = s.sim
	for m in sim.entries[c].human_crew():
		if str(m.get("role", "")) == RaceEntry.ROLE_DRIVER:
			return [c, 1]
	return [c, 0]


func is_active() -> bool:
	return stage == Stage.READY or stage == Stage.BOX


# --- Every frame -------------------------------------------------------------

func _process(delta: float) -> void:
	size = get_viewport_rect().size
	if session == null:
		return
	var move := Input.get_vector("crew_left", "crew_right", "crew_up", "crew_down")
	step(delta, move, Input.is_action_pressed("crew_gun"))
	visible = stage != Stage.IDLE
	queue_redraw()


## Keeps the gunner's controls to the game while it's on (the crew console
## would take A / Enter as its own button).
func _input(event: InputEvent) -> void:
	if not is_active():
		return
	for a in ["crew_gun", "crew_up", "crew_down", "crew_left", "crew_right"]:
		if event.is_action(a):
			get_viewport().set_input_as_handled()
			return


## Moves the game on by dt seconds. move: the stick (screen x right, y down;
## the view is north up while you play, so that's the ground's x / y).
## gun: the gun is held.
func step(dt: float, move := Vector2.ZERO, gun := false) -> void:
	_flash_t -= dt
	if autoplay and is_active():
		var a := _auto()
		move = a[0]
		gun = a[1]
	var want := gunner_for(session) if enabled() else [-1, -1]
	match stage:
		Stage.IDLE, Stage.DONE:
			if stage == Stage.DONE:
				clock += dt
				if clock >= RESULT_S:
					stage = Stage.IDLE
			if int(want[0]) >= 0 and _coming_in(int(want[0])):
				_start(int(want[0]), int(want[1]))
		Stage.READY:
			clock += dt
			var p := _pit()
			if p["phase"] == PitRules.PHASE_SERVICE:
				if int(p.get("crew_play", 0)) & (1 << side):
					_start_box()
				else:
					_stop(Stage.IDLE)   # the call to play didn't reach the car in time
			elif not _coming_in(car):
				session.request_pit(car, {"crew": {"side": side, "play": false}})
				_stop(Stage.IDLE)
			else:
				_run(dt, move)
		Stage.BOX:
			clock += dt
			if _pit()["phase"] != PitRules.PHASE_SERVICE:
				_finish()
			else:
				_step_box(dt, move, gun)
	_gun_was = gun
	_watch_result()
	_show()


func _sim() -> RaceSim:
	return session.sim


func _pit() -> Dictionary:
	return _sim().entries[car].pit


## The car is on its way to its box: boxing, or guided down the lane.
func _coming_in(i: int) -> bool:
	var p: Dictionary = _sim().entries[i].pit
	var ph: String = p["phase"]
	if ph == PitRules.PHASE_LIMIT:
		return true
	return p["box"] and (ph == PitRules.PHASE_APPROACH or ph == PitRules.PHASE_ENTRY)


func _start(i: int, s: int) -> void:
	car = i
	side = s
	clock = 0.0
	result = {}
	done = {}
	loose = 0
	job = Job.NONE
	job_wheel = -1
	var w := _sim().pits.service_for(i, _pit()["plan"])
	my_wheels = PitRules._side_wheels(w, side)
	if my_wheels.is_empty():
		stage = Stage.IDLE   # nothing for this side to do: the AI crew have it
		return
	stage = Stage.READY
	pos = gunner_wait_spot()
	face = 0.0
	session.request_pit(car, {"crew": {"side": side, "play": true}})


func _start_box() -> void:
	stage = Stage.BOX
	clock = 0.0
	var work: Dictionary = _pit()["work"]
	my_wheels = PitRules._side_wheels(work, side)
	guns_from = float((work.get("crew", {}) as Dictionary).get("guns_from", 0.0))


func _stop(next: Stage) -> void:
	stage = next
	clock = 0.0
	if crews:
		crews.drive_gunner(car, side, null)


func _finish() -> void:
	var gave_up := done.size() < my_wheels.size()
	_stop(Stage.DONE)
	var perfect := 0
	for w in done:
		perfect += 1 if done[w] == "perfect" else 0
	result = {"pending": true, "gave_up": gave_up, "loose": loose, "perfect": perfect}


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


# --- The mechanic ------------------------------------------------------------------

## Where this side's gunner waits for the car.
func gunner_wait_spot() -> Vector2:
	if crews:
		return crews.gunner_wait_spot(car, side)
	var f := _frame()
	var s := 1.0 if side == 1 else -1.0
	return f["pos"] + f["dir"] * 2.7 + f["out"] * s * 1.9


## Where the gunner works on a wheel: [spot, facing].
func wheel_spot(wheel: int) -> Array:
	if crews:
		var ws: Array = crews.wheel_spot(car, wheel)
		if not ws.is_empty():
			return ws
	var f := _frame()
	var def := _sim().defs[car]
	var s := 1.0 if wheel % 2 == 1 else -1.0
	var x := def.cg_to_front if wheel < 2 else -(def.wheelbase - def.cg_to_front)
	var spot: Vector2 = f["pos"] + f["dir"] * x + f["out"] * s * (def.track_width * 0.5 + 0.75)
	var out: Vector2 = f["out"]
	return [spot, (-out).angle() if s > 0.0 else out.angle()]


## The car's box: {pos, dir (along the lane), out (towards the garage)}.
func _frame() -> Dictionary:
	if crews:
		var f: Dictionary = crews.box_frame(car)
		if not f.is_empty():
			return f
	var b := _sim().track.pit_box(_sim().pits.box_index(car))
	var dir := Vector2.from_angle(b["heading"])
	var c: CarState = _sim().cars[car]
	return {"pos": c.pos if stage == Stage.BOX else b["pos"], "dir": dir,
		"out": Vector2(-dir.y, dir.x) * _sim().track.pit_side}


func _run(dt: float, move: Vector2) -> void:
	if move.length() > 1.0:
		move = move.normalized()
	if move.length() < 0.05:
		return
	var centre: Vector2 = _frame()["pos"]
	var to := pos + move * RUN_SPEED * dt
	if to.distance_to(centre) > ROAM:
		to = centre + (to - centre).normalized() * ROAM
	pos = to
	face = move.angle()


## The wheel of this side the gunner is at (and still has to do), or -1.
func wheel_here() -> int:
	var best := -1
	var near := REACH
	for w in my_wheels:
		if done.has(w):
			continue
		var d := pos.distance_to(wheel_spot(w)[0])
		if d <= near:
			near = d
			best = w
	return best


## The wheel to do next (front first), or -1 when this side is done.
func next_wheel() -> int:
	if job_wheel >= 0 and not done.has(job_wheel):
		return job_wheel
	for w in my_wheels:
		if not done.has(w):
			return w
	return -1


## The gun gauge of the nut going on: 1.0 = a standard nut.
func gauge() -> float:
	return (clock - job_t0) / GUN_ON_S if job == Job.GUN else 0.0


func _step_box(dt: float, move: Vector2, gun: bool) -> void:
	var pressed := gun and not _gun_was
	match job:
		Job.NONE:
			_run(dt, move)
			var w := wheel_here()
			if w >= 0 and gun and clock >= guns_from:
				job = Job.NUT
				job_wheel = w
				job_t0 = clock
				var ws := wheel_spot(w)
				pos = ws[0]
				face = ws[1]
			elif w >= 0 and pressed and clock < guns_from:
				_flash_msg("Wait: tyres go on once the fuel is in", 1.2)
		Job.NUT:
			if not gun:
				job = Job.NONE   # let go too soon: the nut's still on
			elif clock - job_t0 >= NUT_OFF_S:
				session.request_pit(car, {"crew": {"side": side, "wheel": job_wheel, "nut": "off"}})
				job = Job.SWAP
				job_t0 = clock
				_sfx("ui_tick", -4.0, 1.3)
		Job.SWAP:
			if clock - job_t0 >= PitRules.GUN_SWAP_S:
				job = Job.LOOSE   # the new wheel is on: now gun it on
				job_t0 = clock - GUN_REFIT_S
		Job.LOOSE:
			if pressed and clock - job_t0 >= GUN_REFIT_S:
				job = Job.GUN
				job_t0 = clock
		Job.GUN:
			var g := gauge()
			if not gun or g >= GUN_AUTO:
				if g < GUN_LOOSE:
					loose += 1
					job = Job.LOOSE
					job_t0 = clock
					_flash_msg("LOOSE NUT! Go again", 1.0)
					_sfx("ui_tick", 0.0, 0.5)
				else:
					var r := "perfect" if g <= GUN_PERFECT else ("good" if g <= GUN_GOOD else "slow")
					done[job_wheel] = r
					session.request_pit(car, {"crew": {"side": side, "wheel": job_wheel, "nut": "on"}})
					_sfx("ui_select", -6.0, 1.4 if r == "perfect" else 1.0)
					job = Job.NONE
					job_wheel = -1


## Tells the 3D crew where the player's mechanic is and what they're doing.
func _show() -> void:
	if crews == null or not is_active():
		return
	var pose: int = PitCrews.Pose.STAND
	match job:
		Job.NUT, Job.GUN, Job.LOOSE:
			pose = PitCrews.Pose.KNEEL
		Job.SWAP:
			pose = PitCrews.Pose.CARRY
	var at := pos
	if job == Job.SWAP and job_wheel >= 0:
		# stepping out with the old wheel and back in with the new one
		var f := _frame()
		var s := 1.0 if side == 1 else -1.0
		var k := sin(clampf((clock - job_t0) / PitRules.GUN_SWAP_S, 0.0, 1.0) * PI)
		var out: Vector2 = f["out"]
		var dir: Vector2 = f["dir"]
		at = pos + out * s * 0.6 * k + dir * 0.5 * k
	crews.drive_gunner(car, side, at, face, pose)


## Testing: a sharp gunner. Returns [move, gun held].
func _auto() -> Array:
	var w := next_wheel()
	if w < 0:
		return [Vector2.ZERO, false]
	if job == Job.NONE:
		var to: Vector2 = wheel_spot(w)[0] - pos
		if to.length() > REACH * 0.5 or stage == Stage.READY:
			return [to.normalized() if to.length() > 0.05 else Vector2.ZERO, false]
		return [Vector2.ZERO, clock >= guns_from]
	if job == Job.NUT or job == Job.SWAP:
		return [Vector2.ZERO, true]
	if job == Job.LOOSE:
		return [Vector2.ZERO, not _gun_was]
	return [Vector2.ZERO, gauge() < GUN_LOOSE + 0.05]


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

const W := 560.0
const H := 120.0


func _text(at: Vector2, s: String, fs := 16, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, at + Vector2(1, 1), s, align, width, fs, Color(0, 0, 0, 0.6))
	draw_string(font, at, s, align, width, fs, col)


func _draw() -> void:
	if session == null or stage == Stage.IDLE or font == null:
		return
	var r := Rect2((size.x - W) * 0.5, size.y - H - 196.0, W, H)
	draw_rect(r, PANEL)
	draw_rect(r, Color(YELLOW, 0.45), false, 2.0)
	if stage == Stage.DONE:
		_draw_result(r)
	else:
		_draw_job(r)
	if _flash_t > 0.0 and _flash != "":
		_text(Vector2(r.position.x, r.position.y - 12), _flash, 20, RED if _flash.begins_with("LOOSE") else YELLOW,
			HORIZONTAL_ALIGNMENT_CENTER, W)


func _draw_job(r: Rect2) -> void:
	var o := r.position
	_text(o + Vector2(16, 26), "PIT CREW: %s WHEEL GUN" % SIDE_NAMES[side], 18, YELLOW)
	if stage == Stage.BOX:
		_text(o + Vector2(16, 26), "%.1f s   standard %.1f s" % [clock, float((_pit()["work"] as Dictionary).get("total_s", 0.0))], 15,
			Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, W - 32)
	# Your wheels, then how the other gunner is getting on.
	var x := o.x + 16
	for w in my_wheels:
		var col := Color(1, 1, 1, 0.5)
		if done.has(w):
			col = {"perfect": BRIGHT, "good": GREEN, "slow": AMBER}.get(done[w], GREEN)
		elif w == next_wheel():
			col = YELLOW
		draw_rect(Rect2(x, o.y + 40, 12, 22), col)
		_text(Vector2(x + 18, o.y + 57), WHEEL_NAMES[w], 13, col)
		x += 140
	var other := _other_side()
	if other != "":
		_text(o + Vector2(16, 57), other, 13, DIM, HORIZONTAL_ALIGNMENT_RIGHT, W - 32)
	# What to do now.
	var gy := o.y + 74
	var gx := o.x + 16
	var gw := W - 32
	var tip := ""
	var tip_col := Color.WHITE
	match job:
		Job.NONE:
			var w := next_wheel()
			if w < 0:
				tip = "Your side's done: the car drops when the other side is"
				tip_col = GREEN
			elif stage == Stage.READY:
				tip = "Car coming in: get to the %s" % WHEEL_NAMES[w]
			elif wheel_here() < 0:
				tip = "Run to the %s" % WHEEL_NAMES[w]
			elif clock < guns_from:
				tip = "Fuel going in: tyres after it"
				tip_col = AMBER
			else:
				tip = "HOLD the gun to undo the nut"
				tip_col = YELLOW
		Job.NUT:
			var f := clampf((clock - job_t0) / NUT_OFF_S, 0.0, 1.0)
			draw_rect(Rect2(gx, gy, gw, 14), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(gx, gy, gw * f, 14), Color(YELLOW, 0.7))
			tip = "Undoing the nut..."
		Job.SWAP:
			tip = "Old wheel off, new wheel on..."
		Job.LOOSE:
			tip = "HOLD the gun on the new nut, let go in the green"
			tip_col = YELLOW
		Job.GUN:
			var full := GUN_AUTO
			draw_rect(Rect2(gx, gy, gw, 14), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(gx, gy, gw * GUN_LOOSE / full, 14), Color(RED, 0.35))
			draw_rect(Rect2(gx + gw * GUN_LOOSE / full, gy, gw * (GUN_PERFECT - GUN_LOOSE) / full, 14), Color(BRIGHT, 0.75))
			draw_rect(Rect2(gx + gw * GUN_PERFECT / full, gy, gw * (GUN_GOOD - GUN_PERFECT) / full, 14), Color(GREEN, 0.45))
			draw_rect(Rect2(gx + gw * GUN_GOOD / full, gy, gw * (full - GUN_GOOD) / full, 14), Color(AMBER, 0.3))
			var mx := gx + gw * clampf(gauge() / full, 0.0, 1.0)
			draw_rect(Rect2(mx - 2, gy - 4, 4, 22), Color.WHITE)
			tip = "Let go in the green"
	if tip != "":
		_text(Vector2(gx, o.y + H - 10), tip, 15, tip_col)


## The other gunner's progress, e.g. "AI (right): 1 / 2".
func _other_side() -> String:
	if stage != Stage.BOX:
		return ""
	var p := _pit()
	var tl: Dictionary = (p["work"] as Dictionary).get("crew", {})
	var guns: Array = tl.get("guns", [])
	var o := 1 - side
	if guns.size() <= o or (guns[o] as Array).is_empty():
		return ""
	var n := 0
	for j in guns[o]:
		n += 1 if float(j["on"]) <= clock else 0
	var who := "Team mate" if int(p.get("crew_play", 0)) & (1 << o) else "AI"
	return "%s (%s): %d / %d" % [who, SIDE_NAMES[o].to_lower(), n, (guns[o] as Array).size()]


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
	_text(o + Vector2(16, 36), g, 22, col)
	_text(o + Vector2(16, 68), "Stationary %.1f s  (standard %.1f s, %s%.1f s)" % [st, std, "+" if st >= std else "-", absf(st - std)], 17)
	var notes := []
	if int(result.get("loose", 0)) > 0:
		notes.append("%d loose nut%s" % [result["loose"], "s" if int(result["loose"]) > 1 else ""])
	if int(result.get("perfect", 0)) > 0:
		notes.append("%d perfect wheel gun%s" % [result["perfect"], "s" if int(result["perfect"]) > 1 else ""])
	_text(o + Vector2(16, 98), ", ".join(notes), 14, DIM, HORIZONTAL_ALIGNMENT_LEFT, W - 32)
