extends Node
## Frame-time probe in a real race (needs a GPU or xvfb + mesa vulkan).
## Your car is driven by the AI for a lap with a full grid; every frame's
## time, the renderer's CPU and GPU time, draw calls, objects and triangles
## are logged against where you are on the lap. Prints the average, the
## slowest 1 %, every hitch (a frame over 2.5x the median) and the slowest
## 100 m stretches with what was on screen there.
##   godot --path . res://tests/perf_probe.tscn -- [track] [seconds] [cars] --autodrive
## --csv <file> also writes every frame.

var session: RaceSession
var scene: Node
var track := "brands_hatch"
var seconds := 90.0
var cars := 25
var csv := ""
var _rows: Array = []
var _last_us := 0
var _t_start := 0.0
var _vp: RID


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args())
	var pos := a.filter(func(x): return not str(x).begins_with("--"))
	track = pos[0] if pos.size() > 0 else track
	seconds = float(pos[1]) if pos.size() > 1 else seconds
	cars = int(pos[2]) if pos.size() > 2 else cars
	var k := a.find("--csv")
	if k >= 0 and k + 1 < a.size():
		csv = a[k + 1]
	var s := RaceSettings.new()
	s.seed = 3
	s.track_id = track
	s.laps = 3
	s.ai_count = cars - 1
	s.damage_enabled = true
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	session = RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	var t0 := Time.get_ticks_msec()
	scene = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	print("[perf] %s: scene built in %d ms" % [track, Time.get_ticks_msec() - t0])
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	get_tree().create_timer(1800.0).timeout.connect(func(): print("[perf] gave up"); get_tree().quit(1))


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := (now - _last_us) / 1000.0
	_last_us = now
	if session == null or session.sim.phase != RaceSim.Phase.RACING:
		return
	var sim := session.sim
	if _t_start == 0.0:
		_t_start = sim.race_time
		return
	if sim.race_time - _t_start > seconds:
		_report()
		get_tree().quit()
		return
	var me := sim.cars[session.local_car]
	_rows.append([dt, sim.race_time,
		me.track_s,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu(),
		RenderingServer.viewport_get_measured_render_time_gpu(_vp),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])


func _report() -> void:
	var n := _rows.size()
	if n < 10:
		print("[perf] too few frames")
		return
	var dts: Array = _rows.map(func(r): return r[0])
	dts.sort()
	var med: float = dts[n / 2]
	var p99: float = dts[int(n * 0.99)]
	var tot := 0.0
	var sums := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for r in _rows:
		tot += r[0]
		for j in 10:
			sums[j] += r[j]
	print("[perf] %s, %d cars, %d frames: avg %.1f ms (%.1f fps), median %.1f, 1%% low %.1f ms, worst %.1f ms" %
		[track, cars, n, tot / n, 1000.0 * n / tot, med, p99, dts[n - 1]])
	print("[perf] avg script %.2f ms, physics %.2f ms, render cpu %.2f ms, gpu %.2f ms; draw calls %d, objects %d, triangles %dk" %
		[sums[3] / n, sums[4] / n, sums[5] / n, sums[6] / n, sums[7] / n, sums[8] / n, sums[9] / n / 1000.0])
	var hitches := 0
	for r in _rows:
		if r[0] > med * 2.5:
			hitches += 1
			if hitches <= 15:
				print("[perf]   hitch %.1f ms at %.0f m (script %.1f, physics %.1f, render cpu %.1f, gpu %.1f, draws %d)" %
					[r[0], r[2], r[3], r[4], r[5], r[6], r[7]])
	print("[perf] hitches over %.1f ms: %d" % [med * 2.5, hitches])
	# slowest stretches of the lap
	var bins := {}
	for r in _rows:
		var b := int(r[2] / 100.0)
		if not bins.has(b):
			bins[b] = [0, 0.0, 0.0, 0.0, 0.0, 0.0]
		bins[b][0] += 1
		bins[b][1] += r[0]
		bins[b][2] += r[5]
		bins[b][3] += r[6]
		bins[b][4] += r[7]
		bins[b][5] += r[9]
	var keys := bins.keys()
	keys.sort_custom(func(x, y): return bins[x][1] / bins[x][0] > bins[y][1] / bins[y][0])
	for b in keys.slice(0, 5):
		var v: Array = bins[b]
		print("[perf]   %4d-%4d m: avg %.1f ms (render cpu %.1f, gpu %.1f), draws %d, triangles %dk" %
			[b * 100, b * 100 + 100, v[1] / v[0], v[2] / v[0], v[3] / v[0], v[4] / v[0], v[5] / v[0] / 1000.0])
	if csv != "":
		var f := FileAccess.open(csv, FileAccess.WRITE)
		f.store_line("ms,race_time,track_s,script_ms,physics_ms,render_cpu_ms,gpu_ms,draws,objects,triangles")
		for r in _rows:
			f.store_line(",".join(r.map(func(x): return str(snappedf(x, 0.01)))))
