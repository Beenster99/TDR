extends Node
## Screenshot of the garage with an upgraded, repainted car (needs a GPU or
## xvfb + mesa vulkan):
##   godot --path . res://tests/garage_shot.tscn -- <out.png> [car_id] [level 0-3] [pattern]

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://garage.png"
	var car: String = args[1] if args.size() > 1 else "bmw_m4_gt3"
	var lvl: int = int(args[2]) if args.size() > 2 else 3
	var pattern: String = args[3] if args.size() > 3 else "stripes"
	var game_data = GameData
	await get_tree().process_frame
	var p := TeamProfile.load_or_new("user://shot_profile.json")
	p.money = 2000000
	for c in UpgradeCatalog.category_ids():
		p.set_level(game_data.cars[car], c, lvl)
	if pattern != "default":
		p.set_livery(car, {"pattern": pattern, "primary": "#0b3d91", "secondary": "#f2f2f2", "accent": "#e10600"})
	var g := GarageScreen.new()
	add_child(g)
	g.open(car, p)
	for i in 40:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("saved ", out)
	get_tree().quit()
