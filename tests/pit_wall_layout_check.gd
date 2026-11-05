extends Node
## Moving the pit wall panels in a real race scene (needs the autoloads, so it
## runs as a scene, not with -s). You hand the car to your AI co-driver on the
## grid and run the pit wall, then drag the console's timing panel across the
## screen and the onboard picture into a corner with the mouse, check the 3D
## race reframes into the space left and the layout is saved, then move a panel
## on the full pit wall and put both back with Reset layout.
##   godot --headless --path . res://tests/pit_wall_layout_check.tscn
## With a screen (xvfb): add -- <out.png> to save shots (console and full pit wall).

var session: RaceSession
var scene: Node
var out := ""
var fails := 0
var _handed := false
var _started := false
var _saved_layout


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else ""
	# Don't touch the player's own layout.
	_saved_layout = GameData.prefs.get(PanelLayout.PREF)
	GameData.prefs.erase(PanelLayout.PREF)
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = "spa"
	s.laps = 3
	s.ai_count = 5
	s.drivers_per_car = 2
	s.safety_car_enabled = false
	s.environment = {"time_h": 14.0, "weather": "dry"}
	var humans := [{"name": "You", "car_id": "bmw_m4_gt3", "crew": [{"peer_id": 0, "name": "You", "role": RaceEntry.ROLE_DRIVER}]}]
	var start := RaceFactory.plan(s, humans, GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	get_tree().create_timer(900.0).timeout.connect(func(): print("[layout] gave up"); _end())


func _physics_process(_delta: float) -> void:
	if session == null or _started:
		return
	if not _handed and session.local_car >= 0:
		_handed = true
		session.request_role_swap(session.local_car, 0, RaceEntry.AI_PEER)
	if session.sim.phase == RaceSim.Phase.RACING and session.local_car < 0 and scene.crew.visible:
		_started = true
		_run()


func _frames(n: int) -> void:
	for k in n:
		await get_tree().process_frame


func _mouse(ci: Control, pos: Vector2, pressed: int = -1, held := false) -> void:
	var ev: InputEvent
	if pressed < 0:
		ev = InputEventMouseMotion.new()
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	else:
		ev = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed == 1
	ev.position = ci.get_global_transform_with_canvas() * pos   # the pit wall draws in a smaller canvas
	ci._input(ev)


## Drags from a to b in a few steps, a frame apart.
func _drag(ci: Control, a: Vector2, b: Vector2) -> void:
	_mouse(ci, a, 1)
	for k in range(1, 6):
		_mouse(ci, a.lerp(b, k / 5.0), -1, true)
		await _frames(1)
	_mouse(ci, b, 0)
	await _frames(2)


func _run() -> void:
	print("pit wall layout")
	var crew: CrewConsole = scene.crew
	crew.cam_mode = CrewConsole.CAM_FRONT
	await _frames(4)
	var view0 := crew.view_rect()
	var t0: Rect2 = crew.panel_rects()["timing"]
	check(not crew.layout.customised() and t0.position.x < 20.0, "the console starts as designed, timing on the left")
	# A click on the timing title bar that doesn't move is not a drag.
	await _drag(crew, t0.position + Vector2(200, 12), t0.position + Vector2(201, 12))
	check(not crew.layout.customised(), "a click on a title bar leaves the panel where it is")
	# Timing over to the right, next to the role panel.
	var role0: Rect2 = crew.panel_rects()["role"]
	var goal_x := role0.position.x - 12.0 - t0.size.x
	await _drag(crew, t0.position + Vector2(200, 12), t0.position + Vector2(200 + goal_x - t0.position.x + 4.0, 12))
	var t1: Rect2 = crew.panel_rects()["timing"]
	check(absf(t1.position.x - goal_x) < 1.0, "the timing panel moved right and snapped next to the role panel (x %.0f, wanted %.0f)" % [t1.position.x, goal_x])
	var view1 := crew.view_rect()
	check(view1.end.x <= t1.position.x and view1.position.x < view0.position.x and view1.size.x >= 200.0,
		"the 3D race moves into the space on the left (%s)" % view1)
	var saved = GameData.prefs.get(PanelLayout.PREF, {})
	check(saved is Dictionary and saved.has("console") and (saved["console"] as Dictionary).has("timing"), "the console layout is saved")
	# Clicks inside the moved panel still pick cars.
	var order := session.sim.running_order
	var target := order[order.size() - 1] if order[order.size() - 1] != crew.team_car() else order[0]
	var p := order.find(target)
	var n := order.size()
	var rh := clampf((t1.size.y - 40) / maxf(n, 1), 18.0, 30.0)
	_mouse(crew, Vector2(t1.position.x + 120, t1.position.y + 46 + p * rh + rh * 0.5), 1)
	_mouse(crew, Vector2(t1.position.x + 120, t1.position.y + 46 + p * rh + rh * 0.5), 0)
	check(crew.watch_car == target, "clicking a car in the moved timing panel still watches it")
	# The onboard picture into the bottom left corner.
	if crew.pip_on():
		var pr := crew.pip_rect()
		await _drag(crew, pr.get_center(), pr.get_center() + Vector2(-2000, 2000))
		var pr2 := crew.pip_rect()
		check(pr2.position.x <= 6.0 and pr2.end.y >= crew.get_viewport_rect().size.y - 6.0, "the onboard picture went to the bottom left corner (%s)" % pr2)
	else:
		print("  (no onboard camera headless: picture not checked)")
	# A fresh console (the next race) loads the same layout.
	var again := PanelLayout.new("console")
	again.load_from(GameData.prefs)
	check(again.rect_of("timing", t0, crew._bounds()) == t1, "the next race loads the moved layout")
	if out != "":
		await _frames(20)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.get_basename() + "_console.png")
	# The full pit wall: move the feed to the left of the screen.
	var wall: StrategistScreen = scene.pit_wall
	wall.open()
	await _frames(4)
	if out != "":
		await _frames(30)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.get_basename() + "_wall.png")
	var feed: Rect2
	for pl in wall.layout.placed:
		if pl[0] == "feed":
			feed = pl[1]
	check(feed.has_area(), "the full pit wall places its feed panel")
	await _drag(wall, feed.position + Vector2(feed.size.x * 0.25, 10), Vector2(30 + feed.size.x * 0.25, 70))
	var moved := wall.layout.rect_of("feed", feed)
	check(wall.layout.is_moved("feed") and moved.position.x < 40.0, "the feed moved to the left (%s)" % moved)
	check((GameData.prefs[PanelLayout.PREF] as Dictionary).has("wall") and (GameData.prefs[PanelLayout.PREF] as Dictionary).has("console"),
		"each pit wall screen keeps its own layout")
	# Zoom the timing up with its corner grip so it reads better, then pick a car in it.
	var tim: Rect2
	for pl in wall.layout.placed:
		if pl[0] == "timing":
			tim = pl[1]
	# Shorter first (bottom edge), so there's room below to zoom into.
	var ex := tim.position.x + tim.size.x * 0.8   # clear of the feed moved over its left side
	await _drag(wall, Vector2(ex, tim.end.y - 2), Vector2(ex, tim.end.y - 2 - tim.size.y * 0.4))
	var tim2 := wall.layout.rect_of("timing", tim)
	check(tim2.size.y < tim.size.y * 0.7 and is_equal_approx(tim2.size.x, tim.size.x), "the bottom edge makes the timing shorter (%s -> %s)" % [tim, tim2])
	await _drag(wall, tim2.end - Vector2(4, 4), tim2.end - Vector2(4, 4) + Vector2(tim2.size.x * 0.3, tim2.size.y * 0.3))
	var zs := wall.layout.scale_of("timing")
	check(zs > 1.1, "the corner grip zooms the full pit wall's timing (%d %%)" % roundi(zs * 100.0))
	await _frames(2)
	var tz := wall.layout.rect_of("timing", tim)
	var w_order := session.sim.running_order
	var pick: int = w_order[w_order.size() - 1]
	var pk := w_order.size() - 1
	var lr := wall.layout.content_rect("timing", tz)
	# the rows start under the TIMING / PACE tabs (24 px)
	var wrh := clampf((lr.size.y - 24 - 34) / maxf(w_order.size(), 1), 14.0, 28.0)
	var ly := lr.position.y + 24 + 32 + pk * wrh + wrh * 0.5
	var at := tz.position + (Vector2(lr.position.x + 300, ly) - tz.position) * zs
	_mouse(wall, at, 1)
	_mouse(wall, at, 0)
	check(wall.selected == pick, "clicking a car in the zoomed timing picks that car")
	if scene.pit_wall.onboard:
		var cam: Camera3D = scene.pit_wall.onboard.camera
		check(cam.cull_mask & CarView.HIGHLIGHT_LAYER == 0, "the onboard picture leaves out the player highlight rings")
	if out != "":
		await _frames(20)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.get_basename() + "_full.png")
	# Reset layout, from the button in the header.
	await _frames(1)
	var rb: Rect2
	for h in wall._hits:
		if h[1] == "reset_layout":
			rb = h[0]
	check(rb.has_area(), "the full pit wall shows Reset layout once a panel moved")
	_mouse(wall, rb.get_center(), 1)
	_mouse(wall, rb.get_center(), 0)
	check(not wall.layout.customised(), "Reset layout puts the full pit wall back")
	wall.close()
	await _frames(2)
	for h in crew._hits:
		if h[1] == "reset_layout":
			rb = h[0]
	_mouse(crew, rb.get_center(), 1)
	_mouse(crew, rb.get_center(), 0)
	check(not crew.layout.customised() and crew.view_rect() == view0, "Reset layout puts the console back, race framed as before")
	check(not (GameData.prefs.get(PanelLayout.PREF, {}) as Dictionary).has("console"), "and nothing is left saved for it")
	_end()


func _end() -> void:
	if _saved_layout != null:
		GameData.prefs[PanelLayout.PREF] = _saved_layout
	else:
		GameData.prefs.erase(PanelLayout.PREF)
	GameData.save_prefs()
	print("PASS" if fails == 0 else "FAIL (%d failures)" % fails)
	get_tree().quit(1 if fails > 0 else 0)
