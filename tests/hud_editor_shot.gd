extends Node
## Screenshots of the HUD layout editor (needs a GPU or xvfb + mesa vulkan):
##   edit    - a race with the editor open, the track map picked
##   custom  - a race with a moved and resized layout, editor closed
##   preview - the editor from Settings, over its own preview race
##   godot --path . res://tests/hud_editor_shot.tscn -- <out.png> <mode> [race seconds] --autodrive --zoom 0.3

var out := "user://hud_editor.png"
var mode := "edit"
var wait := 12.0


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	out = a[0] if a.size() > 0 else out
	mode = a[1] if a.size() > 1 else mode
	wait = float(a[2]) if a.size() > 2 else wait
	GameData.persist_prefs = false
	GameData.prefs[HudLayout.PREF] = {}
	GameData.prefs[RaceHud.PREF_TOWER] = true
	if mode == "custom":
		# Tower off (compact standings), map bottom-left above the tyres,
		# speed bigger and centred low, sectors at the top.
		GameData.prefs[RaceHud.PREF_TOWER] = false
		GameData.prefs[HudLayout.PREF] = {
			"speed": {"x": 0.5, "y": 0.80, "s": 1.3},
			"sectors": {"x": 0.5, "y": 0.0, "s": 0.85},
			"map": {"x": 0.0, "y": 0.47, "s": 1.2},
			"timing": {"x": 0.0, "y": 0.0},
			"hint": {"on": false},
		}
	if mode == "preview":
		var bg := ColorRect.new()
		bg.color = Color(0.12, 0.14, 0.16)
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var layer := CanvasLayer.new()
		add_child(layer)
		layer.add_child(bg)
		var root := HudEditor.open_preview(bg)
		await _frames(20)
		var hud: RaceHud = root.get_child(1)
		hud.editor.select("speed")
		await _frames(10)
		_save()
		return
	var s := RaceSettings.new()
	s.seed = 5
	s.track_id = "spa"
	s.laps = 5
	s.ai_count = 11
	s.fuel_enabled = true
	s.tyre_wear_enabled = true
	s.damage_level = "full"
	s.damage_enabled = true
	s.mandatory_pit_stops = 1
	s.environment = {"time_h": 15.0, "weather": "dry"}
	var start := RaceFactory.plan(s, [{"name": "You", "car_id": "bmw_m4_gt3"}], GameData.cars, GameData.drivers)
	var session := RaceSession.create(RaceSession.Mode.OFFLINE, start, 0)
	GameData.active_session = session
	var scene: Node = load("res://modules/game/race.tscn").instantiate()
	add_child(scene)
	while session.sim.race_time < wait:
		await get_tree().process_frame
	if mode == "edit":
		var hud: RaceHud = scene.hud
		hud.open_editor()
		await _frames(2)
		hud.editor.select("map")
		hud.scale_item("map", 1.2, Vector2(1, 0))
	await _frames(6)
	_save()


func _frames(n: int) -> void:
	for _k in n:
		await get_tree().process_frame


func _save() -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[shot] saved ", out)
	get_tree().quit()
