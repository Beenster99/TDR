extends Node
## What the 3D world costs to draw along a lap (needs a GPU or xvfb + mesa
## vulkan). Builds a real race, freezes it on the grid, then puts the
## camera over the track every <step> metres at the usual close zoom and
## measures draw calls, objects, triangles and the GPU time there. At the
## costliest spot it hides each part of the world in turn to show what it
## costs.
##   godot --path . res://tests/render_probe.tscn -- [track] [step m] [zoom 0..1] [spot m] [--shot out.png]

var session: RaceSession
var scene: Node
var track := "brands_hatch"
var step := 150.0
var zoom := 0.2
var spot := -1.0   ## where to break the cost down (default: the costliest spot)
var _vp: RID


func _ready() -> void:
	var pos := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	track = pos[0] if pos.size() > 0 else track
	step = float(pos[1]) if pos.size() > 1 else step
	zoom = float(pos[2]) if pos.size() > 2 else zoom
	spot = float(pos[3]) if pos.size() > 3 else -1.0
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = track
	s.laps = 3
	s.ai_count = 24
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	_run.call_deferred()


func _frames(n: int) -> Array:
	var gpu := 0.0
	var cpu := 0.0
	var wall := 0.0
	for k in n + 2:
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		if k >= 2:
			wall += (Time.get_ticks_usec() - t0) / 1000.0
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp)
	return [wall / n, cpu / n, gpu / n,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))]


func _run() -> void:
	for k in 30:
		await get_tree().process_frame
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	var world: WorldView = scene.world
	var t := session.sim.track
	var vs := get_viewport().get_visible_rect().size
	var b := world.track_view.bounds
	var fit := minf(vs.x / maxf(b.size.x, 1.0), vs.y / maxf(b.size.y, 1.0))
	var z := exp(lerpf(log(26.0), log(fit), zoom))
	var worst := [-1.0, 0.0]
	var tot := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var n := 0
	var s := 0.0
	print("[render] %s at zoom %.2f (%.1f px/m), %dx%d" % [track, zoom, z, vs.x, vs.y])
	while s < t.length:
		world.set_camera(t.position_at(s), z)
		var r := await _frames(4)
		print("[render] %5.0f m: %6.1f ms gpu, %5.2f ms cpu, %5d draws, %5d objects, %6dk tris" % [s, r[2], r[1], r[3], r[4], r[5] / 1000])
		for j in 6:
			tot[j] += r[j]
		n += 1
		if r[2] > worst[0]:
			worst = [r[2], s]
		s += step
	print("[render] average: %.1f ms gpu, %.2f ms cpu, %d draws, %d objects, %dk tris" % [tot[2] / n, tot[1] / n, tot[3] / n, tot[4] / n, tot[5] / n / 1000])
	if spot >= 0.0:
		worst[1] = spot
	world.set_camera(t.position_at(worst[1]), z)
	var base := await _frames(6)
	var a := Array(OS.get_cmdline_user_args())
	var k := a.find("--shot")
	if k >= 0 and k + 1 < a.size():
		get_viewport().get_texture().get_image().save_png(a[k + 1])
		print("[render] screenshot of %.0f m saved to %s" % [worst[1], a[k + 1]])
	print("[render] costliest spot %.0f m: %.1f ms gpu, %d draws, %d objects, %dk tris" % [worst[1], base[2], base[3], base[4], base[5] / 1000])
	for part in _parts(world):
		var nodes: Array = part[1]
		for nd in nodes:
			nd.visible = false
		var r := await _frames(6)
		for nd in nodes:
			nd.visible = true
		print("[render]   without %-22s %6.1f ms gpu (%+.1f), %5d draws (%+d), %5d objects, %6dk tris (%+dk)" %
			[part[0], r[2], r[2] - base[2], r[3], r[3] - base[3], r[4], r[5] / 1000, (r[5] - base[5]) / 1000])
	var sun: DirectionalLight3D = world.sun
	sun.shadow_enabled = false
	var r2 := await _frames(6)
	sun.shadow_enabled = true
	print("[render]   without sun shadows          %6.1f ms gpu (%+.1f), %5d draws (%+d)" % [r2[2], r2[2] - base[2], r2[3], r2[3] - base[3]])
	get_tree().quit()


## Groups of the world's nodes to switch off one at a time.
func _parts(world: WorldView) -> Array:
	var groups := {}
	var stack: Array = [world]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for c in nd.get_children():
			stack.append(c)
		if not (nd is VisualInstance3D):
			continue
		var key := str(nd.get_parent().name) + "/" + _kind(nd)
		if nd is CarView or nd.get_parent() is CarView:
			key = "cars"
		var p := nd.get_parent()
		while p != null and p != world:
			if p is CarView:
				key = "cars"
			elif p is PitCrews:
				key = "pit crews"
			p = p.get_parent()
		if not groups.has(key):
			groups[key] = []
		groups[key].append(nd)
	var out := []
	for k in groups:
		out.append([k, groups[k]])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out


func _kind(nd: Node) -> String:
	var n := str(nd.name)
	var i := 0
	while i < n.length() and not n[i].is_valid_int():
		i += 1
	n = n.substr(0, i)
	if n.begins_with("@"):
		return nd.get_class()
	return n
