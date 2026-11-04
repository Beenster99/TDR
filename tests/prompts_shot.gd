extends Node
## Screenshots of the main menu's controls list, first as a keyboard player,
## then after touching a controller (needs a GPU or xvfb + mesa vulkan):
##   godot --path . res://tests/prompts_shot.tscn -- <out_prefix>

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://prompts"
	var menu: Node = load("res://modules/ui/main_menu.tscn").instantiate()
	add_child(menu)
	for mode in [false, true]:
		InputPrompt.set_pad(mode)
		for i in 30:
			await get_tree().process_frame
		var path := "%s_%s.png" % [out, "pad" if mode else "keyboard"]
		get_viewport().get_texture().get_image().save_png(path)
		print("saved ", path)
	get_tree().quit()
