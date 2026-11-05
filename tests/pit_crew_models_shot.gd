extends Node3D
## A close look at the pit crew models (graphics PitCrews): crew members in
## their poses holding what they work with, the wheels with their compound
## rings, the wheel gun, the fuel rig with its hose, the tyre stacks and the
## gun trolley. Needs a GPU or xvfb + mesa vulkan.
##   godot --path . res://tests/pit_crew_models_shot.tscn -- <out.png> [top]
## top: straight down, the way the game sees them.

var crews: PitCrews


func _ready() -> void:
	var a := Array(OS.get_cmdline_user_args()).filter(func(x): return not str(x).begins_with("--"))
	var out: String = a[0] if a.size() > 0 else "user://pit_crew_models.png"
	var top: bool = a.size() > 1 and a[1] == "top"
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.34, 0.37)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.57, 0.62)
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-1.0, 0.6, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.3, 0.31, 0.33)
	gm.roughness = 0.9
	ground.material_override = gm
	add_child(ground)
	crews = PitCrews.new()
	add_child(crews)
	var c := PitCrews.Crew.new()
	c.team = Color(0.1, 0.3, 0.85)
	var team := c.team
	var helmet := Color(0.95, 0.95, 0.95)
	var all := [PitCrews.Carry.TYRE, PitCrews.Carry.GUN, PitCrews.Carry.HOSE, PitCrews.Carry.CLOTH, PitCrews.Carry.LANCE, PitCrews.Carry.EXTINGUISHER]
	# people: [x, z, face, pose, carry]
	var line := [[-3.0, 1.2, 0.0, PitCrews.Pose.STAND, PitCrews.Carry.NONE], [-1.8, 1.2, 0.0, PitCrews.Pose.CARRY, PitCrews.Carry.TYRE],
		[-0.6, 1.2, 0.0, PitCrews.Pose.KNEEL, PitCrews.Carry.GUN], [0.6, 1.2, 0.0, PitCrews.Pose.HOSE, PitCrews.Carry.HOSE],
		[1.8, 1.2, 0.0, PitCrews.Pose.WIPE, PitCrews.Carry.CLOTH], [3.0, 1.2, 0.0, PitCrews.Pose.CROUCH, PitCrews.Carry.LANCE]]
	for l in line:
		var p: PitCrews.Person = crews._person(c, team, helmet, all)
		p.pos = Vector2(l[0], l[1])
		p.target = p.pos
		p.face = PI * 0.5 + 0.5
		p.target_face = p.face
		p.pose = l[3]
		p.carry = l[4]
		for k in 20:
			crews._move(p, 0.1)
	# wheels: dry, intermediate, wet, used
	for k in 4:
		var w := crews._wheel_prop(crews, false, k if k < 3 else -1)
		w.position = Vector3(-3.0 + k * 0.9, 0.17, -0.6)
	var gun := crews._gun_prop(crews)
	gun.position = Vector3(0.9, 0.07, -0.6)
	gun.rotation.y = 0.6
	for k in 3:
		crews._part(crews, crews._stack_mesh(k, team), crews._vc("wheel", 0.55, 0.25), Vector3(-3.0 + k * 0.9, 0, -2.2))
	crews._part(crews, crews._trolley_mesh(), crews._vc("metal", 0.4, 0.35), Vector3(0.8, 0, -2.3))
	var rig := crews._part(crews, crews._rig_mesh(team), crews._vc("metal", 0.4, 0.35), Vector3(3.0, 0, -2.2))
	rig.rotation.y = -PI * 0.5
	var cam := Camera3D.new()
	add_child(cam)
	if top:
		cam.position = Vector3(0, 11, -0.4)
		cam.rotation = Vector3(-PI * 0.5, 0, 0)
		cam.fov = 45
	else:
		cam.position = Vector3(0, 4.2, 6.2)
		cam.look_at(Vector3(0, 0.6, -0.4))
		cam.fov = 50
	for k in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("[models] saved ", out)
	get_tree().quit()
