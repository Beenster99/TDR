class_name PitCrewGame
extends Control
## The pit crew game (docs/PIT_CREW_GAME.md): players do crew jobs at their
## car's stops, in the real 3D pit box seen from above, and the AI crew do
## the rest. How well they play decides the stop time.
##
## Co-op (two or three players sharing a car; Settings > Gameplay > Co-op
## pit stops, on by default): the strategist calls the car in, the driver
## follows the pit guide line to the pit entry and the guide takes the car
## down the lane while both cameras close in on the box.
##  * The strategist (or the two-player pit wall) is the fuel man: take the
##    hose from the rig, plug it into the car, take it off when the tank has
##    the planned fuel (off early: less fuel; late: time lost).
##  * The driver is the windscreen man while the fuel goes in.
##  * A third player (pit crew) lays out the right new tyres and the wheel
##    guns as soon as the car is called in, and plugs the air lance in when
##    it stops (the car rises on its jacks).
##  * Once the fuel is in (tyres only after the fuel), the driver and a pit
##    crew player each do the tyre job they picked in the lobby: a gun man
##    (pick up the gun, undo the nut, do the new one up, put the gun down)
##    or a wheel man (pull the old wheel, put it down, pick up the new one,
##    put it on), left or right side, front then rear.
## When the lollipop goes green the cameras pull out, the guide drives the
## car to the end of the lane and gives it back to the driver there, and the
## pit wall is back at its screens.
##
## On your own there's no crew game: the AI crew do the whole stop.
##
## Controls: run (stick / WASD), grab (pad X / G key: pick up, put down, plug in,
## take off), use (RT or A / Space, held: the wheel gun, the windscreen).
## Online, each player plays on their own machine: their steps reach the
## machine that simulates the car through RaceSession.request_pit, and team
## mates see each other's crew members (RaceSession.send_crew_pose).

const PREF_COOP := "pit_crew_coop"

enum Stage { IDLE, READY, BOX, DONE }
## What the player's hands are doing on a tyre (gun man) step.
enum Job { NONE, NUT, SWAP, GUN, LOOSE }
## What the player is carrying.
enum Hold { NONE, NEW_TYRE, OLD_TYRE, GUN, HOSE }

const RUN_SPEED := 5.0       ## m/s, a mechanic sprinting round the car
const REACH := 0.75          ## m from a spot that counts as at it
const ROAM := 9.0            ## m from the car's centre a mechanic can go (garage included)
const NUT_OFF_S := 0.45      ## hold the gun this long to undo the nut
const GUN_ON_S := 0.7        ## a standard nut on (the gauge's 1.0)
## Wheel gun gauge, in shares of GUN_ON_S.
const GUN_LOOSE := 0.72      ## let go before this: the nut isn't tight, go again
const GUN_PERFECT := 0.82    ## up to here: perfect
const GUN_GOOD := 1.04       ## up to here: good
const GUN_AUTO := 1.4        ## held on: the gun finishes it here (slow)
const GUN_REFIT_S := 0.3     ## a loose nut: time to get the gun back on it
const SCREEN_WIPE_S := 1.6   ## held use at the windscreen this long: clean
const RESULT_S := 5.0        ## the result stays up this long
const POSE_EVERY := 0.07     ## s between crew poses sent to team mates
const POSE_STALE := 1.0      ## a team mate's crew member goes back to the AI after this long unheard

const YELLOW := Color(1.0, 0.88, 0.35)
const GREEN := Color(0.4, 1.0, 0.5)
const BRIGHT := Color(0.75, 1.0, 0.85)
const RED := Color(1.0, 0.4, 0.35)
const AMBER := Color(1.0, 0.65, 0.25)
const BLUE := Color(0.45, 0.75, 1.0)
const DIM := Color(1, 1, 1, 0.55)
const PANEL := Color(0.02, 0.04, 0.07, 0.88)
const WHEEL_NAMES := ["FRONT LEFT", "FRONT RIGHT", "REAR LEFT", "REAR RIGHT"]
const JOB_TITLES := {"fuel": "FUEL MAN", "screen": "WINDSCREEN", "lance": "TYRES, GUNS AND AIR JACKS",
	"gun_l": "LEFT GUN MAN", "gun_r": "RIGHT GUN MAN", "wheel_l": "LEFT WHEEL MAN", "wheel_r": "RIGHT WHEEL MAN"}
const KIND_NAMES := ["dry", "intermediate", "wet"]
const KIND_CHOICES := [PitRules.TYRE_DRY, PitRules.TYRE_INTER, PitRules.TYRE_WET]

## The RaceSession (untyped so the headless tests can drive the game with a
## stand-in: it needs sim, local_car, team_car, local_role, local_peer and
## request_pit).
var session
## The pit crews in the 3D world (graphics PitCrews; null in tests without
## one: spots then come from the car itself).
var crews
var font: Font
var stage := Stage.IDLE
var car := -1
var coop := false
var jobs: Array = []             ## this player's jobs this stop, in order (e.g. ["screen", "gun_l"])
var cur := 0                     ## the one being done now
var clock := 0.0                 ## seconds since the stage started (in the box: the stop's clock)
var enabled_override = null      ## tests: true / false instead of the player's setting
var autoplay := false            ## testing (--crew-autoplay): plays like a sharp player
var ring_colour := YELLOW        ## the ring under this player's crew member (team mates' are blue)
var guide := true                ## draws where to go next in the 3D box (off for stand-in team mates in tests)

# The player's crew member.
var pos := Vector2.ZERO
var face := 0.0
var hold := Hold.NONE
var hold_kind := 0               ## a new tyre in hand: 0 dry, 1 inter, 2 wet
var hold_wheel := -1             ## a tyre in hand: whose wheel it was / is for
var job := Job.NONE
var job_wheel := -1
var job_t0 := 0.0
var wipe := 0.0                  ## windscreen cleaned, seconds of SCREEN_WIPE_S
var done: Dictionary = {}        ## tyre jobs: wheel -> perfect / good / slow / done
var loose := 0
var sent: Dictionary = {}        ## steps sent this stop ("gun_l:0:nut_off" -> true)
var laid: Dictionary = {}        ## lance: wheel -> compound id laid out at its spot
var guns_laid: Dictionary = {}   ## lance: side -> true
var new_at: Dictionary = {}      ## wheel man: wheel -> where its new tyre lies (moved by hand)
var old_at: Dictionary = {}      ## wheel man: wheel -> where its old tyre was put down
var gun_at: Dictionary = {}      ## gun man: side -> where the gun lies (absent = in hand or not out)
var _use_was := false
var _flash := ""
var _flash_t := 0.0
var _pose_t := 0.0
var _remote := {}                ## job -> last time (ticks ms) a team mate's pose came in
var _signal_hooked := false

# Result.
var result: Dictionary = {}
var _stops_seen := -1


func setup(p_session, p_crews = null) -> void:
	session = p_session
	crews = p_crews
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_hook_poses()


func _hook_poses() -> void:
	if _signal_hooked or session == null or not session is Object:
		return
	if (session as Object).has_signal("crew_pose"):
		session.crew_pose.connect(_on_crew_pose)
		_signal_hooked = true


## On/off: Settings > Gameplay (registered by core), co-op pit stops for a
## shared car only.
func enabled(p_coop := false) -> bool:
	if enabled_override != null:
		return bool(enabled_override)
	if not is_inside_tree():
		return false
	if DisplayServer.get_name() == "headless" and not autoplay:
		return false   # nobody at a headless machine to play (tests use --crew-autoplay)
	var gd := get_node_or_null("/root/GameData")
	if gd == null:
		return false
	return p_coop and bool(gd.prefs.get(PREF_COOP, true))


## The jobs this player does at their car's stops: {car, jobs: [...], coop}.
## Co-op (two or more players in the car's crew): the strategist / pit wall
## refuels, the driver cleans the windscreen then does their tyre job, a pit
## crew player lays out the tyres and guns and plugs the air lance in, then
## does theirs. On your own: nothing (the AI crew do it all).
static func jobs_for(s) -> Dictionary:
	var none := {"car": -1, "jobs": [], "coop": false}
	if s == null:
		return none
	var c: int = s.team_car if s.team_car >= 0 else s.local_car
	if c < 0:
		return none
	var sim: RaceSim = s.sim
	var e := sim.entries[c]
	var humans := e.human_crew()
	var role := RaceEntry.ROLE_DRIVER if s.local_car == c else str(s.local_role)
	if humans.size() < 2:
		return none   # on your own the AI crew do the whole stop
	var me := int(s.local_peer) if "local_peer" in s else 0
	var tyre := tyre_job_for(e, me, role)
	match role:
		RaceEntry.ROLE_DRIVER:
			return {"car": c, "jobs": [PitRules.JOB_SCREEN, tyre], "coop": true}
		RaceEntry.ROLE_PIT_CREW:
			return {"car": c, "jobs": [PitRules.JOB_LANCE, tyre], "coop": true}
		RaceEntry.ROLE_STRATEGIST, RaceEntry.ROLE_PIT_WALL:
			return {"car": c, "jobs": [PitRules.JOB_FUEL], "coop": true}
	return none


## The tyre job a co-op crew member does: the one they picked in the lobby
## if nobody else in the crew who picks one has it (a driver change can move
## people about), else the first free one (driver left gun, pit crew right gun).
static func tyre_job_for(e: RaceEntry, peer: int, role: String) -> String:
	var taken := []
	var mine := ""
	for m in e.human_crew():
		if not RaceEntry.picks_pit_job(str(m.get("role", ""))):
			continue
		var j := str(m.get("pit_job", ""))
		if int(m.get("peer_id", -99)) == peer:
			mine = j
		elif j in RaceEntry.PIT_JOBS:
			taken.append(j)
	if mine in RaceEntry.PIT_JOBS and not mine in taken:
		return mine
	var want := PitRules.JOB_GUN_L if role == RaceEntry.ROLE_DRIVER else PitRules.JOB_GUN_R
	if not want in taken:
		return want
	for j in RaceEntry.PIT_JOBS:
		if not j in taken:
			return j
	return PitRules.JOB_GUN_L


func is_active() -> bool:
	return stage == Stage.READY or stage == Stage.BOX


## The job being done now ("" none).
func current_job() -> String:
	return str(jobs[cur]) if cur < jobs.size() else ""


## The player's hands are on their crew member: in the box; while the car
## comes in, once it's in the pit lane (a pit crew player laying out tyres:
## from the call, they're in the garage already). The driver's hands are on
## the wheel until the guide has the car in the lane.
func hands_free() -> bool:
	if stage == Stage.BOX:
		return true
	if stage != Stage.READY:
		return false
	var in_lane: bool = _pit()["phase"] in PitRules.IN_LANE
	if session.local_car == car:
		return _sim().pits.controls(car) and in_lane
	return current_job() == PitRules.JOB_LANCE or in_lane or not coop


## The job's panel and guide are up: only once you're in the pits (the
## camera's on the box), never while you're still driving in.
func in_pits() -> bool:
	return stage == Stage.DONE or wants_close_view()


## The race scene closes the camera in on the box while this is true: from
## when the car is in the lane (a pit crew player laying out tyres: from the
## call) until the lollipop goes green.
func wants_close_view() -> bool:
	if stage == Stage.BOX:
		var tl := _tl()
		var down: Array = tl.get("down", [INF, INF])
		return clock < float(down[-1])
	return stage == Stage.READY and hands_free()


## Where the close camera looks: the car in its box, or the empty box.
func view_centre() -> Vector2:
	return _frame()["pos"]


# --- Every frame -------------------------------------------------------------

func _process(delta: float) -> void:
	size = get_viewport_rect().size
	if session == null:
		return
	var move := Input.get_vector("crew_left", "crew_right", "crew_up", "crew_down")
	var grab := InputMap.has_action("crew_grab") and Input.is_action_just_pressed("crew_grab")
	step(delta, move, Input.is_action_pressed("crew_gun"), grab)
	visible = stage != Stage.IDLE
	queue_redraw()


## Keeps the crew controls to the game while it's on (the crew console
## would take A / Enter as its own button).
func _input(event: InputEvent) -> void:
	if not hands_free():
		return
	for a in ["crew_gun", "crew_grab", "crew_up", "crew_down", "crew_left", "crew_right"]:
		if InputMap.has_action(a) and event.is_action(a):
			get_viewport().set_input_as_handled()
			return


## Moves the game on by dt seconds. move: the stick (screen x right, y down;
## the view is north up while you play, so that's the ground's x / y).
## use: the use button is held (wheel gun, windscreen). grab: the grab button
## was just pressed.
func step(dt: float, move := Vector2.ZERO, use := false, grab := false) -> void:
	_flash_t -= dt
	_hook_poses()
	if autoplay and hands_free():
		var a := _auto()
		move = a[0]
		use = a[1]
		grab = a[2]
	match stage:
		Stage.IDLE, Stage.DONE:
			if stage == Stage.DONE:
				clock += dt
				if clock >= RESULT_S:
					stage = Stage.IDLE
			var want := jobs_for(session)
			if int(want["car"]) >= 0 and not (want["jobs"] as Array).is_empty() and enabled(bool(want["coop"])) \
					and _coming_in(int(want["car"])):
				_start(want)
		Stage.READY:
			clock += dt
			var p := _pit()
			if p["phase"] == PitRules.PHASE_SERVICE:
				if _claimed():
					_start_box()
				else:
					_stop(Stage.IDLE)   # the call to play didn't reach the car in time
			elif not _coming_in(car):
				for j in jobs:
					session.request_pit(car, {"crew": {"job": j, "play": false}})
				_stop(Stage.IDLE)
			elif hands_free():
				_run(dt, move)
				if current_job() == PitRules.JOB_LANCE:
					_step_prep(grab)
		Stage.BOX:
			# The stop's clock: kept here, pulled back into line with the car's
			# pit state (which reaches other machines in steps).
			clock += dt
			var stop_t := float(_pit()["service_total"]) - float(_pit()["service_left"])
			if absf(stop_t - clock) > 0.6:
				clock = stop_t
			if _pit()["phase"] != PitRules.PHASE_SERVICE:
				_finish()
			else:
				_step_box(dt, move, use, grab)
	_use_was = use
	_watch_result()
	_show(dt)
	_expire_remote()


func _sim() -> RaceSim:
	return session.sim


func _pit() -> Dictionary:
	return _sim().entries[car].pit


func _work() -> Dictionary:
	return _pit().get("work", {})


func _tl() -> Dictionary:
	var tl = _work().get("crew", {})
	return tl if tl is Dictionary else {}


## The car is on its way to its box: called in, boxing, or guided down the lane.
func _coming_in(i: int) -> bool:
	var p: Dictionary = _sim().entries[i].pit
	var ph: String = p["phase"]
	if ph == PitRules.PHASE_LIMIT:
		return true
	return p["box"] and (ph == PitRules.PHASE_APPROACH or ph == PitRules.PHASE_ENTRY or ph == PitRules.PHASE_NONE)


## All this player's jobs reached the car before it stopped.
func _claimed() -> bool:
	var play := int(_pit().get("crew_play", 0))
	for j in jobs:
		if play & PitRules.job_bit(j) == 0:
			return false
	return true


func _start(want: Dictionary) -> void:
	car = int(want["car"])
	coop = bool(want["coop"])
	jobs = (want["jobs"] as Array).duplicate()
	cur = 0
	clock = 0.0
	result = {}
	done = {}
	loose = 0
	sent = {}
	laid = {}
	guns_laid = {}
	new_at = {}
	old_at = {}
	gun_at = {}
	hold = Hold.NONE
	hold_wheel = -1
	job = Job.NONE
	job_wheel = -1
	wipe = 0.0
	stage = Stage.READY
	pos = _start_spot()
	face = 0.0
	for j in jobs:
		session.request_pit(car, {"crew": {"job": j, "play": true, "lane_auto": coop}})


## Where this player's crew member waits for the car.
func _start_spot() -> Vector2:
	match current_job():
		PitRules.JOB_FUEL:
			return _spot("rig")[0]
		PitRules.JOB_SCREEN:
			return _spot("screen")[0] + _frame()["dir"] * 1.2
		PitRules.JOB_LANCE:
			return _spot("stack", 1)[0]
	return _spot("wait", _side())[0]


var _no_fuel_stop := false   ## this stop puts no fuel in (the fuel man stands by)


func _start_box() -> void:
	stage = Stage.BOX
	_no_fuel_stop = float(_work().get("fuel_s", 0.0)) <= 0.0
	clock = float(_pit()["service_total"]) - float(_pit()["service_left"])
	_skip_empty_jobs()


## Jobs with nothing to do this stop (no fuel, no tyres on this side) are done at once.
func _skip_empty_jobs() -> void:
	while cur < jobs.size():
		var j := current_job()
		var work := _work()
		var empty := false
		match j:
			PitRules.JOB_FUEL:
				empty = false   # no fuel this stop: the fuel man stays out and says so (_step_fuel)
			PitRules.JOB_LANCE:
				empty = false
			PitRules.JOB_SCREEN:
				empty = false
			_:
				empty = PitRules._side_wheels(work, _side()).is_empty()
		if not empty:
			return
		_next_job()


func _next_job() -> void:
	if crews:
		crews.drive_member(car, current_job(), null)
	cur += 1
	job = Job.NONE
	job_wheel = -1
	if cur < jobs.size() and current_job() in PitRules.TYRE_JOBS:
		# The tyre job's crew member steps in where the last one finished.
		_flash_msg("Now: %s" % JOB_TITLES[current_job()].to_lower(), 2.0)
	if stage == Stage.BOX:
		_skip_empty_jobs()


func _stop(next: Stage) -> void:
	stage = next
	clock = 0.0
	if crews:
		for j in jobs:
			crews.drive_member(car, j, null)


func _finish() -> void:
	# Standing by as fuel man with no fuel to put in counts as done.
	var gave_up := cur < jobs.size() and not (current_job() == PitRules.JOB_FUEL and _no_fuel_stop and cur == jobs.size() - 1)
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
			result["fuel_l"] = float(last.get("fuel_l", 0.0))
			if is_inside_tree() and DisplayServer.get_name() == "headless":
				print("[pit crew] %s played %s: stationary %.2f s, standard %.2f s, %.1f L, gave up %s" % [
					str(session.local_peer) if "local_peer" in session else "?", "+".join(jobs), result["stationary_s"],
					result["standard_s"], result["fuel_l"], result.get("gave_up", false)])


# --- Where things are ---------------------------------------------------------------

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


## A spot in the box (PitCrews.crew_spot): [pos, facing].
func _spot(kind: String, idx := 0) -> Array:
	if crews:
		var s: Array = crews.spot(car, kind, idx)
		if not s.is_empty():
			return s
	return PitCrews.crew_spot(_frame(), PitCrews.crew_dims(_sim().defs[car], _sim().track), kind, idx)


## Where a gun / wheel man works on a wheel: [spot, facing].
func wheel_spot(wheel: int) -> Array:
	return _spot("wheel", wheel)


## The side of the car the current tyre job works (0 left, 1 right; the
## refueller and the windscreen are on the garage side).
func _side() -> int:
	var s := PitRules.job_side(current_job())
	return s if s >= 0 else 1


func _near(spot: Vector2, r := REACH) -> bool:
	return pos.distance_to(spot) <= r


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


## The wheels the current tyre job does this stop, front first.
func my_wheels() -> Array:
	var work := _work() if stage == Stage.BOX else _sim().pits.service_for(car, _pit()["plan"])
	return PitRules._side_wheels(work, _side())


## The wheel to do next (front first), or -1 when this side is done.
func next_wheel() -> int:
	if job_wheel >= 0 and not done.has(job_wheel):
		return job_wheel
	for w in my_wheels():
		if not done.has(w):
			return w
	return -1


## The gun gauge of the nut going on: 1.0 = a standard nut.
func gauge() -> float:
	return (clock - job_t0) / GUN_ON_S if job == Job.GUN else 0.0


func _send(act: Dictionary) -> void:
	var key := "%s:%s:%s:%s" % [act.get("job", ""), act.get("act", ""), act.get("wheel", act.get("side", "")), act.get("compound", "")]
	sent[key] = true
	session.request_pit(car, {"crew": act})


# --- The jobs -----------------------------------------------------------------------

func _step_box(dt: float, move: Vector2, use: bool, grab: bool) -> void:
	match current_job():
		"":
			_run(dt, move)
		PitRules.JOB_FUEL:
			_step_fuel(dt, move, grab)
		PitRules.JOB_SCREEN:
			_step_screen(dt, move, use)
		PitRules.JOB_LANCE:
			_run(dt, move)
			_step_prep(grab)
			_step_lance(grab)
		PitRules.JOB_GUN_L, PitRules.JOB_GUN_R:
			_step_gun(dt, move, use, grab)
		PitRules.JOB_WHEEL_L, PitRules.JOB_WHEEL_R:
			_run(dt, move)
			_step_wheel(grab)


## Fuel litres in so far (the hose on), of the plan's fuel_l.
func fuel_in() -> float:
	var f: Array = _tl().get("fuel", [])
	var rec: Dictionary = (_pit().get("crew_jobs", {}) as Dictionary).get("fuel", {}) if _pit().get("crew_jobs") is Dictionary else {}
	if not rec.has("on"):
		return 0.0
	var on := float(rec["on"])
	var off := float(rec.get("off", clock))
	var want := float(_work().get("fuel_l", 0.0))
	return clampf((minf(off, clock) - on) * PitRules.FUEL_FLOW_LPS, 0.0, want)


func _hose_on() -> bool:
	return sent.has("fuel:on::") and not sent.has("fuel:off::")


## No fuel goes in this stop (none planned, or the tank's full).
func _no_fuel() -> bool:
	return stage == Stage.BOX and float(_work().get("fuel_s", 0.0)) <= 0.0


func _step_fuel(dt: float, move: Vector2, grab: bool) -> void:
	if _no_fuel():
		_run(dt, move)   # nothing to plug in: the fuel man stands by
		return
	var filler := _spot("filler")
	if _hose_on():
		pos = filler[0]
		face = filler[1]
		if grab:
			_send({"job": PitRules.JOB_FUEL, "act": "off"})
			var want := float(_work().get("fuel_l", 0.0))
			var got := fuel_in()
			if got < want - 0.5:
				_flash_msg("Hose off early: %.0f L of %.0f L in" % [got, want], 2.0)
			_next_job()
		return
	_run(dt, move)
	if not grab:
		return
	if hold == Hold.NONE and _near(_spot("rig")[0], 1.2):
		hold = Hold.HOSE
	elif hold == Hold.HOSE and _near(filler[0]):
		_send({"job": PitRules.JOB_FUEL, "act": "on"})
	elif hold == Hold.NONE:
		_flash_msg("Get the hose from the fuel rig first ({crew_grab})", 1.4)
	else:
		_flash_msg("Take the hose to the car's filler ({crew_grab} there)", 1.4)


func _step_screen(dt: float, move: Vector2, use: bool) -> void:
	var sc := _spot("screen")
	if use and _near(sc[0]):
		pos = sc[0]
		face = sc[1]
		wipe += dt
		if wipe >= SCREEN_WIPE_S:
			_send({"job": PitRules.JOB_SCREEN, "act": "done"})
			_next_job()
		return
	_run(dt, move)


## Prep (pit crew player): the right new tyres and the guns laid out.
func _prep_needs() -> Dictionary:
	var work := _work() if stage == Stage.BOX else _sim().pits.service_for(car, _pit()["plan"])
	var per: Array = work.get("wheel_tyres", [])
	var tyres := {}
	for w in work.get("wheels", []) if str(work.get("tyre", "")) != "" else []:
		tyres[int(w)] = str(per[int(w)]) if per.size() == 4 else str(work.get("tyre", ""))
	var guns := {}
	for g in 2:
		if not PitRules._side_wheels(work, g).is_empty():
			guns[g] = true
	return {"tyres": tyres, "guns": guns}


func prep_done() -> bool:
	var n := _prep_needs()
	for w in n["tyres"]:
		if str(laid.get(w, "")) != str(n["tyres"][w]):
			return false
	for g in n["guns"]:
		if not guns_laid.has(g):
			return false
	return true


func _kind_compound(k: int) -> String:
	return _sim().pits.choice_compound(car, KIND_CHOICES[k])


func _step_prep(grab: bool) -> void:
	if not grab:
		return
	var n := _prep_needs()
	if hold == Hold.NONE:
		for k in 3:
			if _near(_spot("stack", k)[0], 0.9):
				hold = Hold.NEW_TYRE
				hold_kind = k
				return
		if _near(_spot("trolley")[0], 1.0):
			hold = Hold.GUN
			return
		for w in laid:
			if _near(_spot("new_tyre", w)[0]):
				# pick a tyre laid out back up (e.g. the wrong one)
				hold = Hold.NEW_TYRE
				hold_kind = PitCrews._kind_of(str(laid[w]))
				laid.erase(w)
				_send({"job": PitRules.JOB_LANCE, "act": "tyre", "wheel": w, "compound": ""})
				return
	elif hold == Hold.NEW_TYRE:
		for w in n["tyres"]:
			if not laid.has(w) and _near(_spot("new_tyre", w)[0]):
				var c := _kind_compound(hold_kind)
				laid[w] = c
				hold = Hold.NONE
				_send({"job": PitRules.JOB_LANCE, "act": "tyre", "wheel": w, "compound": c})
				if c != str(n["tyres"][w]):
					_flash_msg("Wrong tyre! The %s needs %s" % [WHEEL_NAMES[w].to_lower(), _compound_name(str(n["tyres"][w]))], 2.5)
				return
		_flash_msg("Lay it out by a wheel that's being changed", 1.2)
	elif hold == Hold.GUN:
		for g in n["guns"]:
			if not guns_laid.has(g) and _near(_spot("gun", g)[0]):
				guns_laid[g] = true
				hold = Hold.NONE
				_send({"job": PitRules.JOB_LANCE, "act": "gun", "side": g})
				return
		_flash_msg("Lay the gun out by the car, on a side that's changing tyres", 1.2)


func _compound_name(id: String) -> String:
	return KIND_NAMES[PitCrews._kind_of(id)] + "s"


func _step_lance(grab: bool) -> void:
	var lifts := float(_work().get("tyre_s", 0.0)) > 0.0 or float(_work().get("repair_s", 0.0)) > 0.0
	var lance_done: bool = sent.has("lance:in::") or not lifts
	if not lance_done and grab and hold == Hold.NONE and _near(_spot("lance")[0]):
		# The car only goes up once the fuel is in and the hose is off.
		var fuel: Array = _tl().get("fuel", [])
		if fuel.size() == 4 and (is_inf(float(fuel[3])) or float(fuel[3]) > clock):
			_flash_msg("Wait: the car goes up once the fuel is in", 1.2)
			return
		_send({"job": PitRules.JOB_LANCE, "act": "in"})
		lance_done = true
	if lance_done and prep_done():
		_next_job()


func _step_gun(dt: float, move: Vector2, use: bool, grab: bool) -> void:
	var side := _side()
	var me := current_job()
	var pressed := use and not _use_was
	var tl := _tl()
	var g_spot: Vector2 = _spot("gun", side)[0]
	if not gun_at.has(side) and hold != Hold.GUN and not sent.has("gun_taken:%d" % side):
		gun_at[side] = g_spot
	match job:
		Job.NONE:
			_run(dt, move)
			# Grab picks the gun up or puts it down; the gun button next to
			# the gun on the ground picks it up too.
			var by_use := pressed and hold == Hold.NONE and gun_at.has(side) and _near(gun_at[side])
			if grab or by_use:
				if hold == Hold.NONE and gun_at.has(side) and _near(gun_at[side]):
					if not _gun_out(side):
						_flash_msg("No gun laid out yet", 1.2)
					else:
						hold = Hold.GUN
						gun_at.erase(side)
						sent["gun_taken:%d" % side] = true
				elif hold == Hold.GUN:
					gun_at[side] = pos   # put the gun down
					hold = Hold.NONE
					if next_wheel() < 0:
						_next_job()
				return
			var w := next_wheel()
			if w < 0:
				return
			var at_wheel := _near(wheel_spot(w)[0])
			var tj := PitRules.tyre_job(tl, side, w)
			if at_wheel and use and hold == Hold.GUN:
				var off_done := sent.has("%s:nut_off:%d:" % [me, w])
				if not off_done:
					if tj.is_empty() or float(tj.get("start", INF)) > clock:
						if pressed:
							_flash_msg(_why_wait(tj), 1.2)
					else:
						job = Job.NUT
						job_wheel = w
						job_t0 = clock
						var ws := wheel_spot(w)
						pos = ws[0]
						face = ws[1]
			elif at_wheel and pressed and hold != Hold.GUN:
				_flash_msg("Pick up your wheel gun first ({crew_grab})", 1.4)
			# the nut's off: wait for the wheel man, then gun it on
			if sent.has("%s:nut_off:%d:" % [me, w]) and job == Job.NONE:
				job = Job.SWAP
				job_wheel = w
		Job.NUT:
			if not use:
				job = Job.NONE   # let go too soon: the nut's still on
			elif clock - job_t0 >= NUT_OFF_S:
				_send({"job": me, "act": "nut_off", "wheel": job_wheel})
				job = Job.SWAP
				job_t0 = clock
				_sfx("ui_tick", -4.0, 1.3)
		Job.SWAP:
			_run(dt, move * 0.4)
			var tj := PitRules.tyre_job(tl, side, job_wheel)
			if not tj.is_empty() and float(tj.get("wheel_on", INF)) <= clock:
				job = Job.LOOSE
				job_t0 = clock - GUN_REFIT_S
				var ws := wheel_spot(job_wheel)
				pos = ws[0]
				face = ws[1]
		Job.LOOSE:
			if pressed and clock - job_t0 >= GUN_REFIT_S:
				job = Job.GUN
				job_t0 = clock
		Job.GUN:
			var g := gauge()
			if not use or g >= GUN_AUTO:
				if g < GUN_LOOSE:
					loose += 1
					job = Job.LOOSE
					job_t0 = clock
					_flash_msg("LOOSE NUT! Go again", 1.0)
					_sfx("ui_tick", 0.0, 0.5)
				else:
					var r := "perfect" if g <= GUN_PERFECT else ("good" if g <= GUN_GOOD else "slow")
					done[job_wheel] = r
					_send({"job": me, "act": "nut_on", "wheel": job_wheel})
					_sfx("ui_select", -6.0, 1.4 if r == "perfect" else 1.0)
					job = Job.NONE
					job_wheel = -1
					if next_wheel() < 0:
						hold = Hold.NONE   # your side's done: the crew member puts the gun down
						_next_job()


func _gun_out(side: int) -> bool:
	if not coop or not (PitRules.JOB_LANCE in jobs_played()):
		return true
	var prep: Dictionary = (_pit().get("crew_jobs", {}) as Dictionary).get(PitRules.JOB_LANCE, {})
	return prep.has("gun%d" % side)


## The jobs players do this stop (from the car's pit state).
func jobs_played() -> Array:
	var out := []
	var play := int(_pit().get("crew_play", 0))
	for j in PitRules.JOBS:
		if play & PitRules.job_bit(j):
			out.append(j)
	return out


## Why a wheel can't be started yet.
func _why_wait(tj: Dictionary) -> String:
	var tl := _tl()
	var up: Array = tl.get("up", [0.0, 0.0])
	if float(up[1]) > clock:
		return "Wait: the car isn't up on its jacks yet"
	if float(tl.get("guns_from", 0.0)) > clock:
		return "Wait: tyres go on once the fuel is in"
	return "Wait: no gun laid out" if not tj.is_empty() and is_inf(float(tj.get("start", 0.0))) else "Wait..."


func _step_wheel(grab: bool) -> void:
	var side := _side()
	var me := current_job()
	var tl := _tl()
	var w := next_wheel()
	if not grab:
		return
	var tj := PitRules.tyre_job(tl, side, w) if w >= 0 else {}
	var hub: Vector2 = wheel_spot(w)[0] if w >= 0 else pos
	var off_sent := w >= 0 and sent.has("%s:wheel_off:%d:" % [me, w])
	match hold:
		Hold.NONE:
			if w < 0:
				return
			if not off_sent and _near(hub):
				if tj.is_empty() or float(tj.get("nut_off", INF)) > clock:
					_flash_msg("Wait for the gun man to undo the nut", 1.2)
					return
				_send({"job": me, "act": "wheel_off", "wheel": w})
				hold = Hold.OLD_TYRE
				hold_wheel = w
				return
			# pick up a new tyre (laid out by the corner, or wherever it was put)
			var nw := _new_tyre_here()
			if nw >= 0:
				var ready := float(PitRules.tyre_job(tl, side, nw).get("tyre_ready", 0.0))
				if ready > clock:
					_flash_msg("That's not the right tyre for this stop", 1.5)
					return
				hold = Hold.NEW_TYRE
				hold_wheel = nw
				new_at[nw] = null
				return
			if _old_tyre_here() >= 0:
				_flash_msg("That's an old one: the new tyre is by the corner", 1.2)
		Hold.OLD_TYRE:
			if _near(wheel_spot(hold_wheel)[0], 0.45):
				_flash_msg("Step away from the hub to put the old wheel down", 1.2)
				return
			old_at[hold_wheel] = pos + Vector2.from_angle(face) * 0.4
			hold = Hold.NONE
			hold_wheel = -1
		Hold.NEW_TYRE:
			if w >= 0 and hold_wheel == w and off_sent and _near(hub):
				_send({"job": me, "act": "wheel_on", "wheel": w})
				done[w] = "done"
				hold = Hold.NONE
				hold_wheel = -1
				if next_wheel() < 0:
					_next_job()
			elif w >= 0 and hold_wheel == w and _near(hub):
				_flash_msg("Get the old wheel off first", 1.2)
			else:
				new_at[hold_wheel] = pos + Vector2.from_angle(face) * 0.4   # put it down here
				hold = Hold.NONE
				hold_wheel = -1


## The new tyre (wheel) lying within reach, -1 none.
func _new_tyre_here() -> int:
	for w in my_wheels():
		if done.has(w) or (hold == Hold.NEW_TYRE and hold_wheel == w):
			continue
		var at = new_at.get(w, _spot("new_tyre", w)[0])
		if at != null and _near(at):
			return w
	return -1


func _old_tyre_here() -> int:
	for w in old_at:
		if _near(old_at[w]):
			return w
	return -1


# --- The 3D crew member, and team mates' ----------------------------------------------

## Tells the 3D crew where the player's crew member is and what they're doing,
## and team mates on other machines (a few times a second).
func _show(dt: float) -> void:
	_show_guide()
	if not is_active():
		return
	var j := current_job()
	if j == "":
		return
	var pose: int = PitCrews.Pose.STAND
	var carry: int = PitCrews.Carry.NONE
	match hold:
		Hold.NEW_TYRE, Hold.OLD_TYRE:
			pose = PitCrews.Pose.CARRY
			carry = PitCrews.Carry.TYRE
		Hold.GUN:
			pose = PitCrews.Pose.GUN
			carry = PitCrews.Carry.GUN
		Hold.HOSE:
			pose = PitCrews.Pose.HOSE
			carry = PitCrews.Carry.HOSE
	match job:
		Job.NUT, Job.GUN, Job.LOOSE:
			pose = PitCrews.Pose.KNEEL
	if j == PitRules.JOB_FUEL and _hose_on():
		pose = PitCrews.Pose.LEAN
	if j == PitRules.JOB_SCREEN:
		carry = PitCrews.Carry.CLOTH
		if _near(_spot("screen")[0], 0.1) and wipe > 0.0:
			pose = PitCrews.Pose.WIPE
	var props := _props()
	if crews:
		crews.drive_member(car, j, pos, face, pose, carry, ring_colour)
		crews.set_props(car, props)
	_pose_t -= dt
	if _pose_t <= 0.0 and session is Object and (session as Object).has_method("send_crew_pose"):
		_pose_t = POSE_EVERY
		session.send_crew_pose(car, {"job": j, "x": pos.x, "y": pos.y, "f": face, "pose": pose, "carry": carry, "props": props})


## Where this player has put things (for PitCrews.set_props).
func _props() -> Dictionary:
	var out := {}
	var j := current_job()
	if j == PitRules.JOB_FUEL:
		out["hose"] = "car" if _hose_on() else ("hand" if hold == Hold.HOSE else "rig")
	if j == PitRules.JOB_LANCE or laid.size() > 0:
		var nt := {}
		var kinds := {}
		for w in 4:
			nt[w] = _spot("new_tyre", w)[0] if laid.has(w) else null
			if laid.has(w):
				kinds[w] = PitCrews._kind_of(str(laid[w]))
		out["new_tyres"] = nt
		out["new_kinds"] = kinds
		var gs := {}
		for g in 2:
			gs[g] = _spot("gun", g)[0] if guns_laid.has(g) else null
		out["guns"] = gs
	if j in [PitRules.JOB_WHEEL_L, PitRules.JOB_WHEEL_R]:
		var nt := {}
		for w in new_at:
			nt[w] = new_at[w]
		if not nt.is_empty():
			out["new_tyres"] = nt
		if not old_at.is_empty():
			out["old_tyres"] = old_at.duplicate()
	if j in [PitRules.JOB_GUN_L, PitRules.JOB_GUN_R]:
		out["guns"] = {_side(): gun_at.get(_side())}
	return out


## A team mate's crew member (from their machine): draw it, a blue ring under them.
func _on_crew_pose(p_car: int, _peer: int, d: Dictionary) -> void:
	if crews == null or p_car < 0:
		return
	var j := str(d.get("job", ""))
	if not PitCrews.JOB_MEMBER.has(j) or (is_active() and p_car == car and j == current_job()):
		return
	crews.drive_member(p_car, j, Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0))), float(d.get("f", 0.0)),
		int(d.get("pose", 0)), int(d.get("carry", 0)), BLUE)
	if d.get("props") is Dictionary:
		crews.set_props(p_car, d["props"])
	_remote[[p_car, j]] = Time.get_ticks_msec()


func _expire_remote() -> void:
	if _remote.is_empty() or crews == null:
		return
	var now := Time.get_ticks_msec()
	for k in _remote.keys():
		if now - int(_remote[k]) > int(POSE_STALE * 1000.0):
			crews.drive_member(int(k[0]), str(k[1]), null)
			_remote.erase(k)


# --- Testing: a sharp player. Returns [move, use held, grab pressed]. ----------

func _auto() -> Array:
	var j := current_job()
	var go := func(to: Vector2, r := REACH * 0.5) -> Array:
		var d := to - pos
		if d.length() > r:
			return [d.normalized() * minf(1.0, d.length() / 0.8), false, false]   # eases in: no overshooting at low frame rates
		return []
	match j:
		PitRules.JOB_FUEL:
			if stage != Stage.BOX or _no_fuel():
				return [Vector2.ZERO, false, false]
			if _hose_on():
				return [Vector2.ZERO, false, fuel_in() >= float(_work().get("fuel_l", 0.0)) - 0.05]
			if hold == Hold.NONE:
				var m: Array = go.call(_spot("rig")[0], 0.8)
				return m if not m.is_empty() else [Vector2.ZERO, false, true]
			var m: Array = go.call(_spot("filler")[0])
			return m if not m.is_empty() else [Vector2.ZERO, false, true]
		PitRules.JOB_SCREEN:
			if stage != Stage.BOX:
				var m0: Array = go.call(_spot("screen")[0])
				return m0 if not m0.is_empty() else [Vector2.ZERO, false, false]
			var m: Array = go.call(_spot("screen")[0], 0.05)
			return m if not m.is_empty() else [Vector2.ZERO, true, false]
		PitRules.JOB_LANCE:
			var n := _prep_needs()
			if hold == Hold.NEW_TYRE:
				for w in n["tyres"]:
					if not laid.has(w):
						var m: Array = go.call(_spot("new_tyre", w)[0])
						return m if not m.is_empty() else [Vector2.ZERO, false, true]
			if hold == Hold.GUN:
				for g in n["guns"]:
					if not guns_laid.has(g):
						var m: Array = go.call(_spot("gun", g)[0])
						return m if not m.is_empty() else [Vector2.ZERO, false, true]
			for w in n["tyres"]:
				if not laid.has(w):
					var k := PitCrews._kind_of(str(n["tyres"][w]))
					var m: Array = go.call(_spot("stack", k)[0])
					return m if not m.is_empty() else [Vector2.ZERO, false, true]
			for g in n["guns"]:
				if not guns_laid.has(g):
					var m: Array = go.call(_spot("trolley")[0])
					return m if not m.is_empty() else [Vector2.ZERO, false, true]
			if stage == Stage.BOX:
				var m: Array = go.call(_spot("lance")[0])
				return m if not m.is_empty() else [Vector2.ZERO, false, true]
			var m2: Array = go.call(_spot("lance")[0])
			return m2 if not m2.is_empty() else [Vector2.ZERO, false, false]
		PitRules.JOB_GUN_L, PitRules.JOB_GUN_R:
			var side := _side()
			if hold != Hold.GUN and job == Job.NONE and next_wheel() >= 0:
				var at: Vector2 = gun_at.get(side, _spot("gun", side)[0])
				var m: Array = go.call(at)
				if not m.is_empty():
					return m
				return [Vector2.ZERO, false, stage == Stage.BOX and _gun_out(side)]
			var w := next_wheel()
			if w < 0:
				return [Vector2.ZERO, false, hold == Hold.GUN]
			match job:
				Job.NONE:
					var m: Array = go.call(wheel_spot(w)[0])
					if not m.is_empty() or stage != Stage.BOX:
						return m if not m.is_empty() else [Vector2.ZERO, false, false]
					var tj := PitRules.tyre_job(_tl(), side, w)
					return [Vector2.ZERO, not tj.is_empty() and float(tj.get("start", INF)) <= clock, false]
				Job.NUT:
					return [Vector2.ZERO, true, false]
				Job.SWAP:
					return [Vector2.ZERO, false, false]
				Job.LOOSE:
					return [Vector2.ZERO, not _use_was, false]
			return [Vector2.ZERO, gauge() < GUN_LOOSE + 0.05, false]
		PitRules.JOB_WHEEL_L, PitRules.JOB_WHEEL_R:
			var side := _side()
			var w := next_wheel()
			if w < 0:
				return [Vector2.ZERO, false, false]
			var hub: Vector2 = wheel_spot(w)[0]
			var me := current_job()
			if stage != Stage.BOX:
				var m0: Array = go.call(hub + _frame()["dir"] * (0.55 if w < 2 else -0.55))
				return m0 if not m0.is_empty() else [Vector2.ZERO, false, false]
			var tj := PitRules.tyre_job(_tl(), side, w)
			match hold:
				Hold.NONE:
					if not sent.has("%s:wheel_off:%d:" % [me, w]):
						var m: Array = go.call(hub)
						return m if not m.is_empty() else [Vector2.ZERO, false, not tj.is_empty() and float(tj.get("nut_off", INF)) <= clock]
					var at = new_at.get(w, _spot("new_tyre", w)[0])
					var m2: Array = go.call(at)
					return m2 if not m2.is_empty() else [Vector2.ZERO, false, float(tj.get("tyre_ready", 0.0)) <= clock]
				Hold.OLD_TYRE:
					var drop: Vector2 = _spot("old_tyre", w)[0]
					var m3: Array = go.call(drop)
					return m3 if not m3.is_empty() else [Vector2.ZERO, false, true]
				Hold.NEW_TYRE:
					var m4: Array = go.call(hub)
					return m4 if not m4.is_empty() else [Vector2.ZERO, false, true]
	return [Vector2.ZERO, false, false]


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


# --- What to do, and where to go ------------------------------------------------------

## The work this stop (the car's stop once it's in the box, the plan before).
func _svc() -> Dictionary:
	return _work() if stage == Stage.BOX else _sim().pits.service_for(car, _pit()["plan"])


## The car goes up on its jacks this stop (tyres or repairs).
func _lifts() -> bool:
	var w := _svc()
	return float(w.get("tyre_s", 0.0)) > 0.0 or float(w.get("repair_s", 0.0)) > 0.0 or not (w.get("wheels", []) as Array).is_empty()


static func _wheel_name(w: int) -> String:
	return WHEEL_NAMES[w].capitalize()


## The steps of the job being done now, in order: [[text, done], ...]. The
## first one not done is the one to do now. Text can name buttons ({crew_grab}).
func job_steps() -> Array:
	var j := current_job()
	var out := []
	match j:
		PitRules.JOB_FUEL:
			if _no_fuel():
				return [["No fuel this stop: stand by at the rig", false]]
			var on := sent.has("fuel:on::")
			out = [["Grab the hose at the fuel rig", hold == Hold.HOSE or on],
				["Plug it into the filler on the car", on],
				["Take it off when the tank is full", sent.has("fuel:off::")]]
		PitRules.JOB_SCREEN:
			out = [["Run to the nose of the car", wipe > 0.0 or _near(_spot("screen")[0])],
				["Wipe the windscreen clean", wipe >= SCREEN_WIPE_S]]
		PitRules.JOB_LANCE:
			var n := _prep_needs()
			var ok := 0
			for w in n["tyres"]:
				ok += 1 if str(laid.get(w, "")) == str(n["tyres"][w]) else 0
			if not (n["tyres"] as Dictionary).is_empty():
				out.append(["Lay out the new tyres from the stacks  %d / %d" % [ok, n["tyres"].size()], ok == n["tyres"].size()])
			if not (n["guns"] as Dictionary).is_empty():
				out.append(["Lay out the wheel guns from the trolley  %d / %d" % [guns_laid.size(), n["guns"].size()],
					guns_laid.size() >= n["guns"].size()])
			if _lifts():
				out.append(["Air lance in at the back of the car once the fuel is in", sent.has("lance:in::")])
		PitRules.JOB_GUN_L, PitRules.JOB_GUN_R:
			var side := _side()
			out.append(["Pick up your wheel gun", hold == Hold.GUN or sent.has("gun_taken:%d" % side) or not done.is_empty()])
			for w in my_wheels():
				out.append(["%s: undo the nut" % _wheel_name(w), done.has(w) or sent.has("%s:nut_off:%d:" % [j, w])])
				out.append(["%s: do the new nut up" % _wheel_name(w), done.has(w)])
			out.append(["Put the gun down", false])
		PitRules.JOB_WHEEL_L, PitRules.JOB_WHEEL_R:
			for w in my_wheels():
				var off := sent.has("%s:wheel_off:%d:" % [j, w])
				out.append(["%s: pull the old wheel off" % _wheel_name(w), off or done.has(w)])
				out.append(["%s: put the old wheel down" % _wheel_name(w), (off and not (hold == Hold.OLD_TYRE and hold_wheel == w)) or done.has(w)])
				out.append(["%s: fit the new wheel" % _wheel_name(w), done.has(w)])
	return out


## Where the player should go next: [ground spot, radius of the thing
## there], or [] (nowhere new: working where they are).
func guide_target() -> Array:
	if not hands_free() or not in_pits():
		return []
	var j := current_job()
	match j:
		PitRules.JOB_FUEL:
			if _no_fuel() or _hose_on():
				return []
			if hold == Hold.HOSE:
				return [_spot("filler")[0], 0.5] if stage == Stage.BOX else []
			return [_spot("rig")[0], 0.75]
		PitRules.JOB_SCREEN:
			return [_spot("screen")[0], 0.5]
		PitRules.JOB_LANCE:
			var n := _prep_needs()
			if hold == Hold.NEW_TYRE:
				var any = null
				for w in n["tyres"]:
					if laid.has(w):
						continue
					if PitCrews._kind_of(str(n["tyres"][w])) == hold_kind:
						return [_spot("new_tyre", w)[0], 0.5]
					any = w if any == null else any
				return [_spot("new_tyre", int(any))[0], 0.5] if any != null else []
			if hold == Hold.GUN:
				for g in n["guns"]:
					if not guns_laid.has(g):
						return [_spot("gun", g)[0], 0.45]
				return []
			for w in laid:
				if n["tyres"].has(w) and str(laid[w]) != str(n["tyres"][w]):
					return [_spot("new_tyre", w)[0], 0.5]   # the wrong tyre: pick it back up
			for w in n["tyres"]:
				if not laid.has(w):
					return [_spot("stack", PitCrews._kind_of(str(n["tyres"][w])))[0], 0.55]
			for g in n["guns"]:
				if not guns_laid.has(g):
					return [_spot("trolley")[0], 0.7]
			if _lifts() and not sent.has("lance:in::"):
				return [_spot("lance")[0], 0.5]
		PitRules.JOB_GUN_L, PitRules.JOB_GUN_R:
			var w := next_wheel()
			if w < 0:
				return []
			if hold != Hold.GUN and job == Job.NONE:
				return [gun_at.get(_side(), _spot("gun", _side())[0]), 0.45]
			if job == Job.NONE:
				return [wheel_spot(w)[0], 0.5]
		PitRules.JOB_WHEEL_L, PitRules.JOB_WHEEL_R:
			var w := next_wheel()
			if w < 0:
				return []
			match hold:
				Hold.OLD_TYRE:
					return [_spot("old_tyre", w)[0], 0.5]
				Hold.NEW_TYRE:
					return [wheel_spot(w)[0], 0.5]
			if not sent.has("%s:wheel_off:%d:" % [j, w]):
				return [wheel_spot(w)[0], 0.5]
			var at = new_at.get(w, _spot("new_tyre", w)[0])
			return [at, 0.5] if at != null else []
	return []


## The guide in the 3D box (PitCrews.set_guide) to where guide_target says.
func _show_guide() -> void:
	if crews == null or not guide or not crews.has_method("set_guide"):
		return
	var t := guide_target() if is_active() else []
	if t.is_empty():
		crews.set_guide(null, null)
	else:
		crews.set_guide(pos, t[0], float(t[1]), ring_colour, crews.ground_y(car))


# --- Drawing ---------------------------------------------------------------------

const W := 640.0
const ROW := 26.0                ## a step's line
const TOP := 48.0                ## the title bar
const MARGIN := 24.0             ## from the screen's edge
const KEY_BG := Color(0.95, 0.95, 0.92)
const KEY_FG := Color(0.05, 0.06, 0.08)


func _text(at: Vector2, s: String, fs := 16, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, at + Vector2(1, 1), s, align, width, fs, Color(0, 0, 0, 0.6))
	draw_string(font, at, s, align, width, fs, col)


## A tip with the player's own buttons in: {crew_grab} and {crew_gun}
## become what they mapped those actions to, on the device they touched
## last (keyboard and mouse, or the controller), e.g. "G" / "X".
static func with_keys(tip: String) -> String:
	return InputPrompt.fill(tip)


## The buttons that run the crew member about, for the device in use:
## "WASD" on the keyboard, "Left stick" on a pad.
static func move_keys() -> String:
	var kb := InputPrompt.keys(["crew_up", "crew_left", "crew_down", "crew_right"], "")
	if InputPrompt.pad:
		var p := InputPrompt.pair("crew_left", "crew_right")
		return p if p.ends_with("stick") else InputPrompt.keys(["crew_up", "crew_left", "crew_down", "crew_right"], " ")
	return kb if kb.length() <= 4 else InputPrompt.keys(["crew_up", "crew_left", "crew_down", "crew_right"], " ")


## Splits text into plain runs and buttons: [[text, is_button], ...];
## {crew_grab} etc. become the button's name, {move} the run keys.
static func _runs(text: String) -> Array:
	var out := []
	var i := 0
	while i < text.length():
		var open := text.find("{", i)
		var close := text.find("}", open) if open >= 0 else -1
		if open < 0 or close < 0:
			out.append([text.substr(i), false])
			break
		if open > i:
			out.append([text.substr(i, open - i), false])
		var name := text.substr(open + 1, close - open - 1)
		if name == "move":
			out.append([move_keys(), true])
		elif InputMap.has_action(name) or InputSetup.is_ours(name):
			out.append([InputPrompt.key(name), true])
		else:
			out.append([text.substr(open, close - open + 1), false])
		i = close + 1
	return out


func _rich_width(text: String, fs: int) -> float:
	var w := 0.0
	for r in _runs(text):
		w += font.get_string_size(str(r[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + (14.0 if r[1] else 0.0)
	return w


## Draws text with its buttons as key caps (a light box with the key's name
## in): the button for the device the player touched last.
func _rich(at: Vector2, text: String, fs := 16, col := Color.WHITE) -> void:
	var x := at.x
	for r in _runs(text):
		var s := str(r[0])
		var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if r[1]:
			var box := Rect2(x + 2, at.y - fs * 0.92, w + 10, fs * 1.24)
			draw_rect(box, KEY_BG)
			draw_rect(Rect2(box.position + Vector2(0, box.size.y - 3), Vector2(box.size.x, 3)), Color(0.55, 0.56, 0.6))
			draw_string(font, Vector2(x + 7, at.y - 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, KEY_FG)
			x += w + 14
		else:
			draw_string(font, Vector2(x, at.y) + Vector2(1, 1), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6))
			draw_string(font, Vector2(x, at.y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
			x += w


func _bar(x: float, y: float, w: float, f: float, col: Color) -> void:
	draw_rect(Rect2(x, y, w, 14), Color(1, 1, 1, 0.08))
	draw_rect(Rect2(x, y, w * clampf(f, 0.0, 1.0), 14), col)


## The panel's height for steps step lines (and a bar).
func _panel_h(steps: int, bar: bool) -> float:
	return TOP + steps * ROW + (24.0 if bar else 0.0) + 74.0


func _draw() -> void:
	if session == null or stage == Stage.IDLE or font == null:
		return
	if not in_pits():
		return   # still driving in: nothing on screen until you're in the pits
	var steps := job_steps() if stage != Stage.DONE else []
	var bar := stage != Stage.DONE and _bar_kind() != ""
	var h := 132.0 if stage == Stage.DONE else _panel_h(steps.size(), bar)
	# bottom left, clear of the box in the middle of the screen and the HUD's dials
	var r := Rect2(MARGIN, size.y - h - MARGIN, W, h)
	draw_rect(r, PANEL)
	draw_rect(Rect2(r.position, Vector2(W, 4)), YELLOW)
	draw_rect(r, Color(YELLOW, 0.45), false, 2.0)
	if stage == Stage.DONE:
		_draw_result(r)
	else:
		_draw_job(r, steps)
	if _flash_t > 0.0 and _flash != "":
		var fs := 22
		var col := RED if _flash.begins_with("LOOSE") or _flash.begins_with("Wrong") else YELLOW
		var fw := _rich_width(_flash, fs)
		var fb := Rect2(r.position.x + (W - fw) * 0.5 - 14, r.position.y - 46, fw + 28, 36)
		draw_rect(fb, Color(PANEL, 0.92))
		draw_rect(fb, Color(col, 0.8), false, 2.0)
		_rich(Vector2(fb.position.x + 14, fb.position.y + 26), _flash, fs, col)


## A step's mark: a green tick (done), a yellow arrow (now), a dim ring (to come).
func _mark(c: Vector2, state: int) -> void:
	match state:
		0:
			draw_circle(c, 8.0, Color(GREEN, 0.9))
			draw_polyline(PackedVector2Array([c + Vector2(-4, 0), c + Vector2(-1, 3.5), c + Vector2(4.5, -3.5)]), Color(0.02, 0.1, 0.03), 2.2)
		1:
			draw_colored_polygon(PackedVector2Array([c + Vector2(-5, -7), c + Vector2(7, 0), c + Vector2(-5, 7)]), YELLOW)
		_:
			draw_arc(c, 6.5, 0.0, TAU, 16, Color(1, 1, 1, 0.4), 1.5)


func _draw_job(r: Rect2, steps: Array) -> void:
	var o := r.position
	var j := current_job()
	_text(o + Vector2(16, 32), "YOUR JOB:  %s" % JOB_TITLES.get(j, "DONE"), 21, YELLOW)
	var status := ""
	if stage == Stage.BOX:
		status = "%.1f s   (standard %.1f s)" % [clock, float(_work().get("total_s", 0.0))]
	else:
		status = "CAR COMING IN"
	_text(o + Vector2(16, 32), status, 15, Color.WHITE if stage == Stage.BOX else AMBER, HORIZONTAL_ALIGNMENT_RIGHT, W - 32)
	# the steps
	var now := -1
	for k in steps.size():
		if not bool(steps[k][1]):
			now = k
			break
	var y := o.y + TOP
	for k in steps.size():
		var state := 0 if bool(steps[k][1]) else (1 if k == now else 2)
		if state == 1:
			draw_rect(Rect2(o.x + 8, y + 1, W - 16, ROW - 2), Color(YELLOW, 0.13))
		_mark(Vector2(o.x + 26, y + ROW * 0.5), state)
		var col := DIM if state == 0 else (Color.WHITE if state == 1 else Color(1, 1, 1, 0.5))
		_rich(Vector2(o.x + 44, y + ROW * 0.5 + 6), str(steps[k][0]), 16, col)
		y += ROW
	# a gauge for the step being done
	var gx := o.x + 16
	var gw := W - 32
	if _bar_kind() != "":
		_draw_bar(gx, y + 6, gw)
		y += 24
	# now: what to press
	var tip_col := [Color.WHITE]
	var tip := _now_tip(j, tip_col)
	draw_line(Vector2(o.x + 12, y + 6), Vector2(o.x + W - 12, y + 6), Color(1, 1, 1, 0.15))
	if tip != "":
		_rich(Vector2(gx, y + 34), tip, 19, tip_col[0])
	# the controls, for the device in use
	var then := ""
	if jobs.size() > 1 and cur + 1 < jobs.size():
		then = "Then: %s" % JOB_TITLES[jobs[cur + 1]].to_lower()
	_rich(Vector2(gx, o.y + r.size.y - 12), "Run {move}   Grab / put down {crew_grab}   Use {crew_gun}", 13, DIM)
	if then != "":
		_text(Vector2(gx, o.y + r.size.y - 12), then, 13, DIM, HORIZONTAL_ALIGNMENT_RIGHT, gw)


## The gauge shown under the steps: "fuel", "wipe", "nut" (undoing it),
## "gun" (doing it up), or "".
func _bar_kind() -> String:
	match current_job():
		PitRules.JOB_FUEL:
			return "" if _no_fuel() else "fuel"
		PitRules.JOB_SCREEN:
			return "wipe"
		PitRules.JOB_GUN_L, PitRules.JOB_GUN_R:
			if job == Job.NUT:
				return "nut"
			if job == Job.GUN or job == Job.LOOSE:
				return "gun"
	return ""


func _draw_bar(gx: float, gy: float, gw: float) -> void:
	match _bar_kind():
		"fuel":
			var want := float(_svc().get("fuel_l", 0.0))
			var got := fuel_in()
			_bar(gx, gy, gw - 130, got / maxf(want, 0.1), Color(GREEN if got >= want - 0.05 else YELLOW, 0.75))
			_text(Vector2(gx + gw - 120, gy + 13), "%.1f / %.0f L" % [got, want], 15)
		"wipe":
			_bar(gx, gy, gw, wipe / SCREEN_WIPE_S, Color(BLUE, 0.75))
		"nut":
			_bar(gx, gy, gw, (clock - job_t0) / NUT_OFF_S, Color(YELLOW, 0.75))
		"gun":
			var full := GUN_AUTO
			draw_rect(Rect2(gx, gy, gw, 14), Color(1, 1, 1, 0.08))
			draw_rect(Rect2(gx, gy, gw * GUN_LOOSE / full, 14), Color(RED, 0.35))
			draw_rect(Rect2(gx + gw * GUN_LOOSE / full, gy, gw * (GUN_PERFECT - GUN_LOOSE) / full, 14), Color(BRIGHT, 0.75))
			draw_rect(Rect2(gx + gw * GUN_PERFECT / full, gy, gw * (GUN_GOOD - GUN_PERFECT) / full, 14), Color(GREEN, 0.45))
			draw_rect(Rect2(gx + gw * GUN_GOOD / full, gy, gw * (full - GUN_GOOD) / full, 14), Color(AMBER, 0.3))
			if job == Job.GUN:
				var mx := gx + gw * clampf(gauge() / full, 0.0, 1.0)
				draw_rect(Rect2(mx - 2, gy - 4, 4, 22), Color.WHITE)


## What to do right now, with its buttons: the tip, and its colour in col[0].
func _now_tip(j: String, col: Array) -> String:
	match j:
		"":
			col[0] = GREEN
			return "Your jobs are done: the car goes when the crew are"
		PitRules.JOB_FUEL:
			var want := float(_svc().get("fuel_l", 0.0))
			var got := fuel_in()
			if stage != Stage.BOX:
				return "Wait at the fuel rig: the car's on its way"
			if _no_fuel():
				col[0] = GREEN
				return "No fuel this stop (none planned, or the tank's full)"
			if _hose_on():
				col[0] = YELLOW if got < want - 0.05 else GREEN
				return "Filling...  {crew_grab} to take the hose off when full" if got < want - 0.05 else "FULL!  {crew_grab}: take the hose off now"
			if hold == Hold.HOSE:
				col[0] = YELLOW
				return "Run to the filler on the car, then {crew_grab} to plug in"
			col[0] = YELLOW
			return "{crew_grab} at the fuel rig to pick up the hose"
		PitRules.JOB_SCREEN:
			if stage != Stage.BOX:
				return "Get to the nose: the car's on its way"
			col[0] = YELLOW
			return "Hold {crew_gun} at the nose to wipe the windscreen"
		PitRules.JOB_LANCE:
			if not prep_done():
				col[0] = YELLOW
				if hold == Hold.NEW_TYRE:
					return "Carrying a %s tyre: {crew_grab} by its wheel to lay it out" % KIND_NAMES[hold_kind]
				if hold == Hold.GUN:
					return "Carrying a wheel gun: {crew_grab} beside the car to lay it down"
				for w in laid:
					if str(laid[w]) != str(_prep_needs()["tyres"].get(w, laid[w])):
						return "Wrong tyre by the %s: {crew_grab} to pick it back up" % WHEEL_NAMES[w].to_lower()
				return "{crew_grab} at the glowing ring to pick it up"
			if stage == Stage.BOX:
				col[0] = YELLOW
				return "{crew_grab} at the socket, back of the car: air lance in"
			col[0] = GREEN
			return "All laid out: wait by the air lance socket"
	var res := _tyre_tip(j)
	col[0] = res[1]
	return res[0]


## What to do now on a tyre job: [tip, colour].
func _tyre_tip(j: String) -> Array:
	var w := next_wheel()
	if stage != Stage.BOX:
		return ["Get to the %s: the car's on its way" % WHEEL_NAMES[w].to_lower() if w >= 0 else "No tyres on your side this stop", Color.WHITE]
	if w < 0:
		return ["Your side's done%s" % (": {crew_grab} to put the gun down" if hold == Hold.GUN else ""), GREEN]
	var tj := PitRules.tyre_job(_tl(), _side(), w)
	if j.begins_with("gun"):
		match job:
			Job.NUT:
				return ["Keep holding {crew_gun}: undoing the nut...", Color.WHITE]
			Job.SWAP:
				return ["Nut off: the wheel man swaps the wheel...", Color.WHITE]
			Job.LOOSE:
				return ["Hold {crew_gun} on the new nut, let go in the green", YELLOW]
			Job.GUN:
				return ["Let go of {crew_gun} in the green", YELLOW]
		if hold != Hold.GUN:
			return ["{crew_grab} at the glowing ring to pick up your wheel gun", YELLOW]
		if not _near(wheel_spot(w)[0]):
			return ["Run to the %s (the glowing ring)" % WHEEL_NAMES[w].to_lower(), Color.WHITE]
		if tj.is_empty() or float(tj.get("start", INF)) > clock:
			return [_why_wait(tj), AMBER]
		return ["Hold {crew_gun} to undo the nut", YELLOW]
	# wheel man
	var me := current_job()
	match hold:
		Hold.OLD_TYRE:
			return ["Step back and {crew_grab} to put the old wheel down", YELLOW]
		Hold.NEW_TYRE:
			return ["{crew_grab} at the %s hub to fit the new wheel" % WHEEL_NAMES[w].to_lower(), YELLOW]
	if not sent.has("%s:wheel_off:%d:" % [me, w]):
		if not _near(wheel_spot(w)[0]):
			return ["Run to the %s (the glowing ring)" % WHEEL_NAMES[w].to_lower(), Color.WHITE]
		if tj.is_empty() or float(tj.get("nut_off", INF)) > clock:
			return ["Wait for the gun man to undo the nut", AMBER]
		return ["{crew_grab}: pull the old wheel off", YELLOW]
	return ["{crew_grab} at the glowing ring to pick up the new wheel", YELLOW]


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
	_text(o + Vector2(16, 72), "Stationary %.1f s  (standard %.1f s, %s%.1f s)" % [st, std, "+" if st >= std else "-", absf(st - std)], 17)
	var notes := []
	if int(result.get("loose", 0)) > 0:
		notes.append("%d loose nut%s" % [result["loose"], "s" if int(result["loose"]) > 1 else ""])
	if int(result.get("perfect", 0)) > 0:
		notes.append("%d perfect wheel gun%s" % [result["perfect"], "s" if int(result["perfect"]) > 1 else ""])
	if PitRules.JOB_FUEL in jobs:
		notes.append("%.1f L in" % float(result.get("fuel_l", 0.0)))
	_text(o + Vector2(16, 104), ", ".join(notes), 14, DIM, HORIZONTAL_ALIGNMENT_LEFT, W - 32)
