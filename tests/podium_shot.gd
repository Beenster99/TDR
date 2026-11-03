extends Node
## Screenshots of the podium ceremony (PodiumCeremony) without a race:
##   godot --path . res://tests/podium_shot.tscn -- <out_dir> [slot]
## The player's bottle plays itself (autoplay). Saves the trophies, the cork
## popping and the champagne going, then quits.

func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var dir: String = a[0] if a.size() > 0 else "user://podium"
	var slot := int(a[1]) if a.size() > 1 else 0
	DirAccess.make_dir_recursive_absolute(dir)
	var layer := CanvasLayer.new()
	add_child(layer)
	var c := PodiumCeremony.new()
	c.autoplay = true
	layer.add_child(c)
	var drivers := [
		{"name": "beenster", "car": "BMW M4 GT3", "colour": Color(0.1, 0.35, 0.85)},
		{"name": "Lena Hartmann", "car": "Porsche 911 GT3 R", "colour": Color(0.9, 0.9, 0.92)},
		{"name": "Marco Bellini", "car": "Ferrari 296 GT3", "colour": Color(0.85, 0.08, 0.08)},
	]
	if slot != 0 and slot < 3:
		var me: Dictionary = drivers[0]
		drivers[0] = drivers[slot]
		drivers[slot] = me
	for p in 3:
		drivers[p]["is_me"] = p == slot
	c.start(drivers, slot, {"track": "Silverstone", "title": "PODIUM"})
	var t0 := PodiumCeremony.INTRO_S
	var t1 := t0 + PodiumCeremony.TROPHY_S
	for shot in [["intro", 1.6], ["trophy", t0 + 2.0], ["pop", t1 + 1.35], ["spray", t1 + 3.5], ["spray2", t1 + 6.5], ["spray3", t1 + 10.0]]:
		while c.elapsed() < float(shot[1]):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/podium_%s.png" % [dir, shot[0]])
		print("[screenshot] %s  soaked %d  drops %d" % [shot[0], c.view.player_soaked, c.view._d_n])
	get_tree().quit()
