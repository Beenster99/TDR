class_name CarView
extends Node3D
## One car in the 3D world: the Blender-built model for its car id
## (modules/graphics/cars/<id>.glb, made by tools/build_cars.py), painted in
## its livery, with steering and spinning wheels, body roll and pitch, brake
## lights, headlights after dark, a roof number and spray on a wet track.
## It eases toward the simulated position, hiding small snapshot corrections.
##
## Car space: +X forward, +Y up, +Z right. The sim's 2D (x, y) maps to 3D
## (x, height, y), so the top-down picture matches the 2D maths.

const MODEL_PATH := "res://modules/graphics/cars/%s.glb"
const PAINT_SHADER := preload("res://modules/graphics/shaders/car_paint.gdshader")
const PATTERNS := {"solid": 0, "stripes": 1, "split": 2, "sash": 3, "chevron": 4, "bmw": 5, "halves": 6}
const SMALL_PARTS := ["mirror_l", "mirror_r", "interior", "diffuser"]

static var _scenes := {}
static var _liveries := {}

var def: CarDefinition
var state: CarState
var label: String = ""
var is_local := false
var number := 0
var env: SimEnvironment
## Smoothed position and heading in the sim's 2D space (what cameras follow).
var pos2 := Vector2.ZERO
var heading := 0.0
## Ground height and normal under a point (set by WorldView; flat by default).
## Both take (position, nearby centre-line index).
var ground: Callable = func(_p: Vector2, _hint: int) -> float: return 0.0
var ground_normal: Callable = func(_p: Vector2, _hint: int) -> Vector3: return Vector3.UP

var _init_done := false
var _sprung: Node3D
var _wheels: Array = []          ## [hub, spin, is_front, radius]
var _paint: ShaderMaterial
var _tail: StandardMaterial3D
var _head: StandardMaterial3D
var _head_light: SpotLight3D
var _spray: GPUParticles3D
var _pitch := 0.0
var _roll := 0.0
var _parts := {}                 ## part name -> [node, rest transform]
var _smoke: GPUParticles3D
var _damage_tick := 0.0

## CarDamage.visual_parts() name -> model part name.
const DAMAGE_PARTS := {"splitter": "splitter", "front_bumper": "bumper_front", "rear_wing": "wing_rear",
	"diffuser": "diffuser", "rear_bumper": "bumper_rear", "mirror_left": "mirror_l", "mirror_right": "mirror_r"}


## livery: {"pattern", "primary", "secondary", "accent"} (all optional);
## empty = the car's default livery from data/liveries.json.
func setup(p_def: CarDefinition, p_state: CarState, p_label: String, p_local: bool, p_number := 0, livery := {}) -> void:
	def = p_def
	state = p_state
	label = p_label
	is_local = p_local
	number = p_number
	name = "Car_%s" % p_label.validate_node_name()
	_build(livery)


## Conditions for headlights and spray.
func set_environment(p_env: SimEnvironment) -> void:
	env = p_env


## Default livery for a car id, plus the car colour from its definition.
static func default_livery(d: CarDefinition) -> Dictionary:
	if _liveries.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://modules/graphics/data/liveries.json"))
		_liveries = parsed if parsed is Dictionary else {"_": {}}
	var l: Dictionary = _liveries.get(d.id, {}).duplicate()
	if not l.has("primary"):
		l["primary"] = "#" + d.colour.to_html(false)
	return l


func _build(livery: Dictionary) -> void:
	var liv := default_livery(def)
	liv.merge(livery, true)
	_paint = ShaderMaterial.new()
	_paint.shader = PAINT_SHADER
	_paint.set_shader_parameter("primary", Color(liv.get("primary", "#cc2222")))
	_paint.set_shader_parameter("secondary", Color(liv.get("secondary", "#ffffff")))
	_paint.set_shader_parameter("accent", Color(liv.get("accent", "#111111")))
	_paint.set_shader_parameter("pattern", PATTERNS.get(liv.get("pattern", "solid"), 0))
	_paint.set_shader_parameter("x_front", def.cg_to_front + float(liv.get("front_overhang", def.length * 0.22)))
	_paint.set_shader_parameter("car_length", def.length)
	_paint.set_shader_parameter("half_width", def.width * 0.5)
	_tail = StandardMaterial3D.new()
	_tail.albedo_color = Color(0.5, 0.03, 0.03)
	_tail.emission_enabled = true
	_tail.emission = Color(1.0, 0.06, 0.03)
	_tail.emission_energy_multiplier = 0.4
	_tail.roughness = 0.2
	_head = StandardMaterial3D.new()
	_head.albedo_color = Color(0.85, 0.87, 0.9)
	_head.metallic = 0.6
	_head.roughness = 0.08
	_head.emission_enabled = true
	_head.emission = Color(1.0, 0.96, 0.88)
	_head.emission_energy_multiplier = 0.0

	_sprung = Node3D.new()
	_sprung.name = "Sprung"
	add_child(_sprung)
	var model := _instantiate_model()
	# Wheels stay on the ground; everything else rolls and pitches.
	for c in model.get_children():
		model.remove_child(c)
		c.owner = null
		if c.name.begins_with("wheel_"):
			add_child(c)
			var spin := c.get_node_or_null(NodePath(str(c.name) + "_spin"))
			_wheels.append([c, spin, str(c.name).begins_with("wheel_f"), def.wheel_radius])
		else:
			_sprung.add_child(c)
			if c is Node3D:
				_parts[str(c.name)] = [c, (c as Node3D).transform]
	model.free()
	_style(self)
	_add_number()
	_add_contact_shadow()
	_add_headlight()
	_add_spray()
	_add_smoke()


func _instantiate_model() -> Node3D:
	var path := MODEL_PATH % def.id
	if not _scenes.has(def.id):
		_scenes[def.id] = load(path) if ResourceLoader.exists(path) else null
	var ps: PackedScene = _scenes[def.id]
	if ps:
		return ps.instantiate()
	return _stand_in()


## A plain car shape for a car without a model yet.
func _stand_in() -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	body.name = "body"
	var bm := BoxMesh.new()
	bm.size = Vector3(def.length, 0.75, def.width * 0.95)
	body.mesh = bm
	body.position = Vector3(def.cg_to_front - def.length * 0.5 + def.length * 0.22 - def.length * 0.22, 0.55, 0)
	var m := StandardMaterial3D.new()
	m.resource_name = "paint"
	bm.material = m
	root.add_child(body)
	var cab := MeshInstance3D.new()
	cab.name = "cabin"
	var cm := BoxMesh.new()
	cm.size = Vector3(def.length * 0.35, 0.4, def.width * 0.7)
	var g := StandardMaterial3D.new()
	g.resource_name = "glass"
	g.albedo_color = Color(0.05, 0.07, 0.1)
	cm.material = g
	cab.mesh = cm
	cab.position = Vector3(0, 1.0, 0)
	root.add_child(cab)
	var b := def.wheelbase - def.cg_to_front
	for w in [["wheel_fl", def.cg_to_front, -1.0], ["wheel_fr", def.cg_to_front, 1.0], ["wheel_rl", -b, -1.0], ["wheel_rr", -b, 1.0]]:
		var hub := Node3D.new()
		hub.name = w[0]
		hub.position = Vector3(w[1], def.wheel_radius, w[2] * def.track_width * 0.5)
		var t := MeshInstance3D.new()
		t.name = w[0] + "_spin"
		var cy := CylinderMesh.new()
		cy.top_radius = def.wheel_radius
		cy.bottom_radius = def.wheel_radius
		cy.height = 0.3
		var tm := StandardMaterial3D.new()
		tm.resource_name = "tyre"
		tm.albedo_color = Color(0.04, 0.04, 0.04)
		cy.material = tm
		t.mesh = cy
		t.rotation.x = PI * 0.5
		hub.add_child(t)
		root.add_child(hub)
	return root


## Swap the model's materials by name: livery paint, lights we can switch,
## glass tuned for the top-down view; hide small parts when far away.
func _style(n: Node) -> void:
	for c in n.get_children():
		_style(c)
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		var base := str(n.name)
		if base in SMALL_PARTS or base.ends_with("_caliper"):
			gi.visibility_range_end = GfxSettings.car_detail_distance
			gi.visibility_range_end_margin = 50.0
			gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if not n is MeshInstance3D:
		return
	var mi := n as MeshInstance3D
	if mi.mesh == null:
		return
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s)
		var mname := m.resource_name if m else ""
		match mname:
			"paint":
				mi.set_surface_override_material(s, _paint)
			"light_tail":
				mi.set_surface_override_material(s, _tail)
			"light_head", "light_drl":
				mi.set_surface_override_material(s, _head)
			"glass":
				var g := StandardMaterial3D.new()
				g.albedo_color = Color(0.03, 0.04, 0.06, 0.62)
				g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
				g.roughness = 0.03
				g.metallic = 0.2
				g.metallic_specular = 0.9
				mi.set_surface_override_material(s, g)


func _add_number() -> void:
	if number <= 0:
		return
	var at := _find(self, "number_roof") as Node3D
	if at == null:
		return
	var board := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.62, 0.7)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.95, 0.95, 0.93)
	bmat.roughness = 0.4
	pm.material = bmat
	board.mesh = pm
	board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	at.add_child(board)
	var l := Label3D.new()
	l.text = str(number)
	l.font_size = 128
	l.outline_size = 0
	l.pixel_size = 0.0042
	l.modulate = Color(0.05, 0.05, 0.05)
	l.double_sided = false
	l.shaded = true
	l.position = Vector3(0, 0.006, 0)
	l.rotation = Vector3(-PI * 0.5, -PI * 0.5, 0)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	at.add_child(l)


## Soft dark patch on the ground under the car, so it sits on the road even
## where the sun's shadow falls to one side.
func _add_contact_shadow() -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(def.length * 1.08, def.width * 1.15)
	var m := StandardMaterial3D.new()
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0.55))
	g.set_color(1, Color(0, 0, 0, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	pm.material = m
	mi.mesh = pm
	mi.position = Vector3((def.cg_to_front - (def.wheelbase - def.cg_to_front)) * 0.5, 0.03, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _add_headlight() -> void:
	_head_light = SpotLight3D.new()
	_head_light.position = Vector3(def.cg_to_front + 0.9, 0.6, 0)
	_head_light.rotation = Vector3(0, -PI * 0.5, 0)
	_head_light.rotate_object_local(Vector3.RIGHT, -0.12)
	_head_light.spot_range = 55.0
	_head_light.spot_angle = 32.0
	_head_light.spot_attenuation = 0.6
	_head_light.light_energy = 0.0
	_head_light.light_color = Color(1.0, 0.95, 0.85)
	_head_light.shadow_enabled = false
	_head_light.visible = false
	_sprung.add_child(_head_light)


func _add_spray() -> void:
	_spray = GPUParticles3D.new()
	_spray.amount = 48
	_spray.lifetime = 0.9
	_spray.emitting = false
	_spray.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.2, 0.1, def.width * 0.4)
	pm.direction = Vector3(-1, 0.35, 0)
	pm.spread = 18.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 7.0
	pm.gravity = Vector3(0, -1.0, 0)
	pm.damping_min = 2.0
	pm.damping_max = 4.0
	pm.scale_min = 0.8
	pm.scale_max = 2.2
	var curve := CurveTexture.new()
	var cv := Curve.new()
	cv.add_point(Vector2(0, 0.4))
	cv.add_point(Vector2(1, 1.0))
	curve.curve = cv
	pm.scale_curve = curve
	var ga := Gradient.new()
	ga.set_color(0, Color(0.9, 0.92, 0.95, 0.35))
	ga.set_color(1, Color(0.9, 0.92, 0.95, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = ga
	pm.color_ramp = gt
	_spray.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(1.2, 1.2)
	var m := StandardMaterial3D.new()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	m.albedo_texture = tex
	q.material = m
	_spray.draw_pass_1 = q
	_spray.position = Vector3(-(def.wheelbase - def.cg_to_front) - 0.5, 0.25, 0)
	_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_spray)


func _add_smoke() -> void:
	_smoke = GPUParticles3D.new()
	_smoke.amount = 40
	_smoke.lifetime = 2.2
	_smoke.emitting = false
	_smoke.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(-1, 0.6, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.0
	pm.gravity = Vector3(0, 0.8, 0)
	pm.scale_min = 1.0
	pm.scale_max = 3.0
	var ga := Gradient.new()
	ga.set_color(0, Color(0.25, 0.25, 0.26, 0.55))
	ga.set_color(1, Color(0.5, 0.5, 0.52, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = ga
	pm.color_ramp = gt
	_smoke.process_material = pm
	_smoke.draw_pass_1 = _spray.draw_pass_1
	_smoke.position = Vector3(-(def.wheelbase - def.cg_to_front) - 0.3, 0.7, 0)
	_smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_smoke)


## Damage from CarDamage.visual_parts(): scuffed, darkened paint where the
## car was hit; parts sag above 0.6 and fall off above 0.85; a punctured
## wheel rides on its rim; a damaged engine smokes.
func _apply_damage() -> void:
	var d := CarDamage.visual_parts(state)
	var front: float = d.get("front_bumper", 0.0)
	_paint.set_shader_parameter("damage", Vector4(front, d.get("rear_bumper", 0.0), d.get("side_left", 0.0), d.get("side_right", 0.0)))
	for key in DAMAGE_PARTS:
		var part: Array = _parts.get(DAMAGE_PARTS[key], [])
		if part.is_empty():
			continue
		var node: Node3D = part[0]
		var rest: Transform3D = part[1]
		var v: float = d.get(key, 0.0)
		node.visible = v < 0.85
		if v > 0.6:
			var k := (v - 0.6) / 0.25
			var sag := Transform3D(Basis(Vector3.FORWARD, 0.08 * k) * Basis(Vector3.UP, 0.05 * k), Vector3(0, -0.04 * k, 0))
			node.transform = sag * rest
		else:
			node.transform = rest
	for w in _wheels:
		var hub: Node3D = w[0]
		var flat: float = d.get(str(hub.name), 0.0)
		hub.position.y = def.wheel_radius - 0.09 * flat
	var smoke: float = d.get("smoke", 0.0)
	_smoke.emitting = smoke > 0.02
	_smoke.amount_ratio = smoke


func _find(n: Node, want: String) -> Node:
	if n.name == want:
		return n
	for c in n.get_children():
		var f := _find(c, want)
		if f:
			return f
	return null


func _process(delta: float) -> void:
	if state == null:
		return
	if not _init_done or pos2.distance_to(state.pos) > 6.0:
		pos2 = state.pos
		heading = state.heading
		_init_done = true
	else:
		var k := 1.0 - exp(-30.0 * delta)
		pos2 = pos2.lerp(state.pos, k)
		heading = lerp_angle(heading, state.heading, k)
	# Sit on the ground, following its slope.
	var up: Vector3 = ground_normal.call(pos2, state.track_idx)
	var fwd := Vector3(cos(heading), 0.0, sin(heading))
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up).normalized()
	transform = Transform3D(Basis(fwd, up, right), Vector3(pos2.x, ground.call(pos2, state.track_idx), pos2.y))
	# Body pitch under braking/acceleration and roll in corners.
	var k2 := 1.0 - exp(-8.0 * delta)
	_pitch = lerpf(_pitch, clampf(state.ax * 0.0032, -0.035, 0.03), k2)
	_roll = lerpf(_roll, clampf(-state.ay * 0.0028, -0.04, 0.04), k2)
	_sprung.rotation = Vector3(_roll, 0.0, _pitch)
	var v := state.vel.dot(state.forward())
	for w in _wheels:
		var hub: Node3D = w[0]
		if w[2]:
			hub.rotation.y = -state.steer_angle
		if w[1]:
			(w[1] as Node3D).rotate_z(-v / w[3] * delta)
	var braking := state.ax < -3.0
	var dark := 0.0
	var wet := 0.0
	if env:
		dark = maxf(env.darkness(), clampf((env.rain - 0.5) * 0.8, 0.0, 0.4))
		wet = env.wetness_at(state.lateral_offset - env.raceline_offset(state.track_idx))
	_tail.emission_energy_multiplier = (4.0 if braking else 0.25) + dark * 1.5
	_head.emission_energy_multiplier = dark * 6.0
	_head_light.visible = dark > 0.08
	_head_light.light_energy = dark * 6.0
	var spray := clampf(wet * 1.3, 0.0, 1.0) * clampf((state.speed() - 8.0) / 50.0, 0.0, 1.0)
	_spray.emitting = spray > 0.03
	_spray.amount_ratio = spray
	_damage_tick -= delta
	if _damage_tick <= 0.0:
		_damage_tick = 0.2
		_apply_damage()
