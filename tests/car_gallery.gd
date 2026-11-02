extends Node
## Picture of every car model side by side, in their race liveries with
## sponsor stickers (needs a GPU or xvfb + mesa vulkan):
##   godot --path . res://tests/car_gallery.tscn -- <out.png> [top|three|side] [class or car ids, comma separated] [copies]
## copies > 1 shows each car several times, as different entries of a field.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://cars.png"
	var view: String = args[1] if args.size() > 1 else "top"
	var which: String = args[2] if args.size() > 2 else ""
	var copies: int = int(args[3]) if args.size() > 3 else 1
	await get_tree().process_frame
	var cars: Dictionary = GameData.cars
	var ids: Array[String] = []
	if which == "" or which == "all":
		ids = CarCatalog.ids_in_class(cars, "")
	elif which.contains("_"):
		for id in which.split(","):
			ids.append(id)
	else:
		for cls in which.split(","):
			ids.append_array(CarCatalog.ids_in_class(cars, cls))
	var world := Node3D.new()
	add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.32, 0.33, 0.35)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.85)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	world.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.22, 0.22, 0.23)
	gm.roughness = 0.9
	pm.material = gm
	ground.mesh = pm
	world.add_child(ground)
	var n := ids.size() * copies
	var cols := ceili(sqrt(float(n) * (3.4 if view == "top" else 0.6)))
	if view == "side":
		cols = 1 if n < 5 else 2
	var dx := 3.4 if view == "top" else 6.5
	var dz := 6.6 if view == "top" else 4.0
	var k := 0
	for id in ids:
		for c in copies:
			var def: CarDefinition = cars[id]
			var st := CarState.new()
			var col := k % cols
			var row := k / cols
			st.pos = Vector2(col * dx, row * dz)
			st.heading = -PI * 0.5 if view == "top" else 0.0
			var v := CarView.new()
			v.setup(def, st, "%s %d" % [id, c], false, k + 1, {} if c == 0 else WorldView.livery_variant(c))
			world.add_child(v)
			var l := Label3D.new()
			l.text = def.display_name
			l.font_size = 64
			l.pixel_size = 0.006
			l.rotation = Vector3(-PI * 0.5, 0, 0)
			l.position = Vector3(st.pos.x, 0.02, st.pos.y + (def.length * 0.5 + 0.5 if view == "top" else 1.8))
			world.add_child(l)
			k += 1
	var cam := Camera3D.new()
	var rows := ceili(float(n) / cols)
	var w := (cols - 1) * dx
	var h := (rows - 1) * dz
	var centre := Vector3(w * 0.5, 0, h * 0.5)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(h + 7.0, (w + 7.0) * 9.0 / 16.0)
	if view == "top":
		cam.look_at_from_position(centre + Vector3(0, 60, 0.01), centre, Vector3(0, 0, -1))
	elif view == "side":
		cam.look_at_from_position(centre + Vector3(0, 1.2, 60), centre + Vector3(0, 1.2, 0), Vector3.UP)
	else:
		cam.size *= 1.1
		cam.size *= 0.75
		cam.look_at_from_position(centre + Vector3(30, 32, 40), centre, Vector3.UP)
	world.add_child(cam)
	cam.make_current()
	for i in 30:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("saved ", out)
	get_tree().quit()
