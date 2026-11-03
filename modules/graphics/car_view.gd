class_name CarView
extends Node3D
## One car in the 3D world: the Blender-built model for its car id
## (modules/graphics/cars/<id>.glb, made by tools/build_cars.py), painted in
## its livery, with steering and spinning wheels, body roll and pitch, brake
## lights, headlights after dark, a roof number and spray on a wet track.
## Sliding, spinning or locked tyres smoke and lay rubber on the road (dust
## and torn grass off it); in a crash shards of bodywork fly off and parts
## that break away tumble down the road (Debris, SkidMarks).
## It eases toward the simulated position, hiding small snapshot corrections.
##
## Car space: +X forward, +Y up, +Z right. The sim's 2D (x, y) maps to 3D
## (x, height, y), so the top-down picture matches the 2D maths.

const MODEL_PATH := "res://modules/graphics/cars/%s.glb"
const PAINT_SHADER := preload("res://modules/graphics/shaders/car_paint.gdshader")
const PATTERNS := {"solid": 0, "stripes": 1, "split": 2, "sash": 3, "chevron": 4, "bmw": 5, "halves": 6}
const SMALL_PARTS := ["mirror_l", "mirror_r", "interior", "diffuser"]
const DECAL_ATLAS := preload("res://modules/graphics/textures/decals.png")
const DIGITS := preload("res://modules/graphics/textures/digits.png")
## Classes that race in sponsor stickers (road cars and the safety car stay clean).
const STICKER_CLASSES := ["GT3", "Hypercar", "LMP2", "RX1"]

static var _scenes := {}
static var _liveries := {}
static var _sponsors := []

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
## Height of the grass mesh as drawn under a point (set by WorldView). Off the
## road the car is kept on top of it, so it never vanishes into the ground.
var terrain: Callable = func(_p: Vector2, _hint: int) -> float: return -INF
var _lift := 0.0
## How loose the surface under a point is, 0 tarmac .. 1 dirt (set by
## WorldView from the track; rallycross dirt stretches and the joker).
var dirt_at: Callable = func(_p: Vector2) -> float: return 0.0
var _dirt := 0.0
var _dirt_tick := 0.0
## Rallycross: a dust cloud rolling up behind the car on dry dirt, and stones
## or mud thrown back off the tyres (mud and brown spray when it's wet).
var _dust: GPUParticles3D
var _dust_mat: ParticleProcessMaterial
var _roost: GPUParticles3D
var _roost_mat: ParticleProcessMaterial
## Shared effects (set by WorldView; null = none).
var marks: SkidMarks
var debris: Debris
## How hard each tyre is sliding this frame, 0..1 (fl, fr, rl, rr).
var tyre_slide := PackedFloat32Array([0, 0, 0, 0])
var _tyre_smoke: Array[GPUParticles3D] = []   ## front axle, rear axle
var _smoke_mat: Array[ParticleProcessMaterial] = []
var _box := AABB()               ## the whole car in car space
var _body_seen := PackedFloat64Array()   ## body damage already shown as debris
var _part_on := {}               ## part -> attached last time we looked
var _flat := {}                  ## visual damage incl. flat tyres (wheel name -> 0..1)
var _mark_key := 0
## Jacked up in the pits (metres) and wheels off mid-stop (set by WorldView).
var pit_lift := 0.0
## Lifted clear of the ground by a recovery crane (metres, set by the race scene).
var hoist := 0.0
var wheels_hidden := false
var wheels_off_mask := 0         ## pit stop: wheels off the car (bit 1 front left .. 8 rear right)

var _init_done := false
var _sprung: Node3D
var _wheels: Array = []          ## [hub, spin, is_front, radius]
var _paint: ShaderMaterial
var _carbon_decals: ShaderMaterial   ## the rear wing: bare carbon with its stickers
## The sponsors on this car, title sponsor first (names, for the UI).
var sponsors: Array[String] = []
var _tail: StandardMaterial3D
var _head: StandardMaterial3D
var _head_light: SpotLight3D
var _spray: GPUParticles3D
var _pitch := 0.0
var _roll := 0.0
var _parts := {}                 ## part name -> [node, rest transform]
var _smoke: GPUParticles3D
var _damage_tick := 0.0
var _bar_amber: StandardMaterial3D   ## safety car light bar lenses (null on other cars)
var _bar_green: StandardMaterial3D
var _bar_mode := "off"
## Upgraded parts that stand in for a stock part (e.g. "wing_rear" -> "wing_rear_up3").
var _part_alias := {}
## Lowered suspension (upgrade), metres.
var _ride_drop := 0.0
var _bar_t := 0.0

## Every car's bodywork crumples where it's hit (car_deform.gdshaderinc):
## noses and tails crushed in, doors caved in around the hit. Demolition
## Derby cars (CarDefinition.discipline "derby") also get a windscreen that
## cracks then shatters, a bonnet and boot lid that spring open then tear
## off and stay on the track, radiator steam, smoke and fire, and dust and
## mud thrown up on dirt.
const PART_SHADER := preload("res://modules/graphics/shaders/car_part.gdshader")
const GLASS_SHADER := preload("res://modules/graphics/shaders/car_glass.gdshader")
const DERBY_PARTS := ["body", "bumper_front", "bumper_rear", "cabin", "bonnet", "boot", "mirror_l", "mirror_r"]
const LIDS := {"bonnet": "bonnet_lid", "boot": "boot_lid"}
var derby := false
var _crumple_mats: Array[ShaderMaterial] = []
var _glass_ws: ShaderMaterial
var _tail_d: Array[ShaderMaterial] = []
var _head_d: Array[ShaderMaterial] = []
## Where on each zone the hits landed (front/rear: across the car, z; sides:
## along it, x), and a second dent for a hit well away from the first, with
## its share of that zone's crush (0..0.5).
var _dent := Vector4.ZERO
var _dent2 := Vector4.ZERO
var _dent2_w := Vector4.ZERO
var _dent_set := [false, false, false, false]
var _crush_shown := Vector4(-1, -1, -1, -1)
var _roof_shown := -1.0
var _lid_gone := {}
var _ws_broken := false
var _steam: GPUParticles3D
var _fire: GPUParticles3D
var _bay_smoke: GPUParticles3D
var _fire_light: OmniLight3D
var _fire_k := 0.0
var _mud: GPUParticles3D
var _mud_mat: ParticleProcessMaterial
var _grime := 0.0
var _was_air := false
var _air_pitch := 0.0
var _number_y := NAN

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
	_paint.set_shader_parameter("decal_atlas", DECAL_ATLAS)
	_paint.set_shader_parameter("digits", DIGITS)
	_apply_stickers(liv)
	_carbon_decals = _paint.duplicate() as ShaderMaterial
	_carbon_decals.set_shader_parameter("base_mode", 1)
	_carbon_decals.set_shader_parameter("race_number", 0)
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
	_apply_upgrades(def.raw.get("visual", {}))
	_add_number()
	_add_contact_shadow()
	_add_headlight()
	_add_spray()
	_add_smoke()
	_add_tyre_smoke()
	_add_dirt_effects()
	_mark_key = get_instance_id() * 8
	for k in _parts:
		var n: Node3D = _parts[k][0]
		if n is MeshInstance3D and k in ["body", "bumper_front", "bumper_rear", "cabin"]:
			_box = _box.merge((n as MeshInstance3D).get_aabb()) if _box.has_volume() else (n as MeshInstance3D).get_aabb()
	if not _box.has_volume():
		_box = AABB(Vector3(-def.length * 0.5, 0.1, -def.width * 0.5), Vector3(def.length, 1.1, def.width))
	_setup_crumple()
	if def.discipline == "derby":
		_setup_derby()


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
			"carbon":
				if str(n.name).begins_with("wing_rear"):
					mi.set_surface_override_material(s, _carbon_decals)
			"light_tail":
				mi.set_surface_override_material(s, _tail)
			"light_head", "light_drl":
				mi.set_surface_override_material(s, _head)
			"light_bar_amber", "light_bar_green":
				var amber := mname == "light_bar_amber"
				var lm := StandardMaterial3D.new()
				lm.albedo_color = Color(0.55, 0.3, 0.03) if amber else Color(0.05, 0.35, 0.1)
				lm.emission_enabled = true
				lm.emission = Color(1.0, 0.55, 0.05) if amber else Color(0.15, 1.0, 0.3)
				lm.emission_energy_multiplier = 0.0
				lm.roughness = 0.1
				if amber:
					_bar_amber = lm
				else:
					_bar_green = lm
				mi.set_surface_override_material(s, lm)
			"glass":
				var g := StandardMaterial3D.new()
				g.albedo_color = Color(0.03, 0.04, 0.06, 0.62)
				g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
				g.roughness = 0.03
				g.metallic = 0.2
				g.metallic_specular = 0.9
				mi.set_surface_override_material(s, g)


static func _sponsor_list() -> Array:
	if _sponsors.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://modules/graphics/data/sponsors.json"))
		_sponsors = parsed.get("sponsors", []) if parsed is Dictionary else []
	return _sponsors


## The seed that picks a car's sponsors: livery "sponsor_seed", else its
## sponsor package ("sponsor_pack" 1.., chosen in the garage), else the car
## and its race number.
static func sponsor_seed(d: CarDefinition, liv: Dictionary, race_number: int) -> int:
	if liv.has("sponsor_seed"):
		return int(liv["sponsor_seed"])
	var pack := int(liv.get("sponsor_pack", 0))
	if pack > 0:
		return 7919 * pack + 13
	return hash("%s#%d" % [d.id, race_number])


## The title sponsor a sponsor package gives (garage preview).
static func title_sponsor(pack: int) -> String:
	var titles: Array = []
	for sp in _sponsor_list():
		if sp.get("kind", "") == "title":
			titles.append(sp)
	if pack <= 0 or titles.is_empty():
		return ""
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * pack + 13
	return str(titles[rng.randi_range(0, titles.size() - 1)].get("name", ""))


static func _lum(c: Color) -> float:
	return c.r * 0.299 + c.g * 0.587 + c.b * 0.114


## A colour that reads on top of paint c: the livery's own second or accent
## colour when it contrasts enough, else white or near-black.
static func _contrast(c: Color, prefer: Array) -> Color:
	for p in prefer:
		if absf(_lum(p) - _lum(c)) > 0.38:
			return p
	return Color(0.06, 0.06, 0.06) if _lum(c) > 0.55 else Color(0.97, 0.97, 0.97)


## Sponsor stickers and the door number, from the car's slots in
## data/liveries.json ("decal_slots", made by tools/build_cars.py). Which
## sponsors and how they're coloured comes from livery "sponsor_seed" (any
## int; default: from the car and its race number), so each car in a field
## has its own sponsors and the same car always gets the same ones. A
## garage "sponsor_pack" (1..) keeps the player's sponsors the same in every
## race. "sponsors": false or "sponsor_pack": -1 leaves the car clean.
func _apply_stickers(liv: Dictionary) -> void:
	var slots: Array = liv.get("decal_slots", [])
	var pack := int(liv.get("sponsor_pack", 0))
	if slots.is_empty() or not def.class_tag in STICKER_CLASSES or liv.get("sponsors", true) == false or pack < 0:
		_paint.set_shader_parameter("decal_count", 0)
		return
	var all := _sponsor_list()
	var titles: Array = []
	var minors: Array = []
	var conts: Array = []
	for sp in all:
		match str(sp.get("kind", "")):
			"title": titles.append(sp)
			"minor": minors.append(sp)
			"contingency": conts.append(sp)
	if titles.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = sponsor_seed(def, liv, number)
	var primary := Color(liv.get("primary", "#cc2222"))
	var second := Color(liv.get("secondary", "#ffffff"))
	var accent := Color(liv.get("accent", "#111111"))
	var pool := titles.duplicate()
	pool.append_array(minors)
	var pick := func() -> Dictionary:
		var k := rng.randi_range(0, pool.size() - 1)
		var sp: Dictionary = pool[k]
		pool.remove_at(k)
		if pool.is_empty():
			pool = titles.duplicate()
		return sp
	var title: Dictionary = titles[rng.randi_range(0, titles.size() - 1)]
	pool.erase(title)
	var second_sp: Dictionary = pick.call()
	var third_sp: Dictionary = pick.call()
	# Title sponsor: its own brand sticker, or lettering in the team colours.
	var title_brand := rng.randf() < 0.5
	var boxes := PackedVector4Array()
	var infos := PackedVector4Array()
	var fgs := PackedVector3Array()
	var bgs := PackedVector3Array()
	var acs := PackedVector3Array()
	sponsors.clear()
	sponsors.append(str(title.get("name", "")))
	sponsors.append(str(second_sp.get("name", "")))
	sponsors.append(str(third_sp.get("name", "")))
	var number_slot := {}
	for slot in slots:
		var role := str(slot.get("role", ""))
		if role == "number":
			number_slot = slot
			continue
		var sp: Dictionary
		var brand := true
		match role:
			"bonnet", "door", "wing":
				sp = title
				brand = title_brand
			"banner", "endplate":
				sp = second_sp
			"deck":
				sp = second_sp if rng.randf() < 0.5 else third_sp
				brand = rng.randf() < 0.7
			"haunch":
				sp = third_sp
			"sill", "fender":
				sp = conts[rng.randi_range(0, conts.size() - 1)] if not conts.is_empty() else third_sp
			_:
				sp = pick.call()
		if boxes.size() >= 16:
			break
		var cell := float(sp.get("cell", 0))
		var fg: Color
		var bg: Color
		var ac: Color
		if brand:
			fg = Color(sp.get("fg", "#ffffff"))
			bg = Color(sp.get("bg", "#111111"))
			ac = Color(sp.get("accent", "#ffffff"))
		else:
			var paint_here := Color(0.03, 0.03, 0.03) if role == "wing" else primary
			fg = _contrast(paint_here, [second, accent])
			ac = _contrast(paint_here, [accent, second]) if accent != fg else fg
			bg = paint_here
			cell += 100.0
		fg = fg.srgb_to_linear()
		bg = bg.srgb_to_linear()
		ac = ac.srgb_to_linear()
		boxes.append(Vector4(slot["x"], slot["c"], slot["hl"], slot["hh"]))
		infos.append(Vector4(cell, slot["proj"], slot.get("y0", -1.0), slot.get("y1", 9.0)))
		fgs.append(Vector3(fg.r, fg.g, fg.b))
		bgs.append(Vector3(bg.r, bg.g, bg.b))
		acs.append(Vector3(ac.r, ac.g, ac.b))
	while boxes.size() < 16:
		boxes.append(Vector4.ZERO)
		infos.append(Vector4.ZERO)
		fgs.append(Vector3.ZERO)
		bgs.append(Vector3.ZERO)
		acs.append(Vector3.ZERO)
	var n := 0
	for i in infos.size():
		if boxes[i].z > 0.0:
			n = i + 1
	_paint.set_shader_parameter("decal_count", n)
	_paint.set_shader_parameter("decal_box", boxes)
	_paint.set_shader_parameter("decal_info", infos)
	_paint.set_shader_parameter("decal_fg", fgs)
	_paint.set_shader_parameter("decal_bg", bgs)
	_paint.set_shader_parameter("decal_ac", acs)
	if not number_slot.is_empty() and number > 0:
		_paint.set_shader_parameter("race_number", number)
		_paint.set_shader_parameter("number_box", Vector4(number_slot["x"], number_slot["c"], number_slot["hl"], number_slot["hh"]))


## Upgrade parts built into every model by tools/build_cars.py, hidden
## unless the car has the upgrade: level -> part shown instead of a stock part.
const UPGRADE_PARTS := {
	"splitter": {1: ["splitter_up", "splitter"]},
	"wing": {2: ["wing_rear_up2", "wing_rear"], 3: ["wing_rear_up3", "wing_rear"]},
	"canards": {1: ["canards", ""]},
}


## visual (from the car's overrides, see the business module):
## {"splitter": 1, "wing": 2|3, "canards": 1, "calipers": "#rrggbb",
##  "rims": "#rrggbb", "tyre_width": 1.06, "ride_drop_m": 0.02}
func _apply_upgrades(visual: Dictionary) -> void:
	_part_alias.clear()
	for key in UPGRADE_PARTS:
		var want := int(visual.get(key, 0))
		for lvl in UPGRADE_PARTS[key]:
			var pair: Array = UPGRADE_PARTS[key][lvl]
			var on: bool = lvl == want
			if _parts.has(pair[0]):
				(_parts[pair[0]][0] as Node3D).visible = on
				if on and pair[1] != "" and _parts.has(pair[1]):
					(_parts[pair[1]][0] as Node3D).visible = false
					_part_alias[pair[1]] = pair[0]
	if visual.has("calipers"):
		var cm := StandardMaterial3D.new()
		cm.albedo_color = Color(str(visual["calipers"]))
		cm.roughness = 0.35
		cm.metallic = 0.2
		_recolour(self, "caliper", cm)
	if visual.has("rims"):
		var rm := StandardMaterial3D.new()
		rm.albedo_color = Color(str(visual["rims"]))
		rm.metallic = 0.85
		rm.roughness = 0.28
		_recolour(self, "rim", rm)
	var tw := float(visual.get("tyre_width", 1.0))
	for w in _wheels:
		(w[0] as Node3D).scale = Vector3(1.0, 1.0, tw)
	_ride_drop = float(visual.get("ride_drop_m", 0.0))
	_sprung.position.y = -_ride_drop


func _recolour(n: Node, material_name: String, m: Material) -> void:
	for c in n.get_children():
		_recolour(c, material_name, m)
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var base := mi.mesh.surface_get_material(s)
			if base and base.resource_name == material_name:
				mi.set_surface_override_material(s, m)


func _add_number() -> void:
	if number <= 0:
		return
	var at := _find(self, "number_roof") as Node3D
	if at == null:
		return
	var board := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var bs: Array = default_livery(def).get("number_board", [0.62, 0.7])
	pm.size = Vector2(float(bs[0]), float(bs[1]))
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
	l.pixel_size = 0.0042 * float(bs[1]) / 0.7
	l.modulate = Color(0.05, 0.05, 0.05)
	l.double_sided = false
	l.shaded = true
	l.position = Vector3(0, 0.006, 0)
	l.rotation = Vector3(-PI * 0.5, -PI * 0.5, 0)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	at.add_child(l)


## Safety car light bar: "off", "amber" (flashing while out) or "green"
## (coming in this lap).
func set_light_bar(mode: String) -> void:
	_bar_mode = mode


## Words on the roof, read from above (e.g. "SAFETY CAR").
func add_roof_text(text: String) -> void:
	var at := _find(self, "number_roof") as Node3D
	if at == null:
		return
	var l := Label3D.new()
	l.text = text
	l.font_size = 96
	l.outline_size = 0
	l.pixel_size = 0.0028
	l.modulate = Color(0.06, 0.06, 0.06)
	l.double_sided = false
	l.shaded = true
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector3(-0.12, 0.012, 0)
	l.rotation = Vector3(-PI * 0.5, -PI * 0.5, 0)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	at.add_child(l)


func _update_light_bar(delta: float) -> void:
	if _bar_amber == null:
		return
	_bar_t += delta
	var flash := 1.0 if fmod(_bar_t, 0.5) < 0.25 else 0.15
	_bar_amber.emission_energy_multiplier = 6.0 * flash if _bar_mode == "amber" else 0.0
	_bar_green.emission_energy_multiplier = 6.0 * flash if _bar_mode == "green" else 0.0
	_update_beacons()


# --- Safety car beacons ----------------------------------------------------------

## Extra lights that make the safety car stand out from above, close up or
## zoomed right out: a wide roof bar that wig-wags left/right, strobes on all
## four corners, amber glow thrown on the road, and a big pulsing ring on the
## ground that grows as the camera pulls back (set_highlight_zoom).
const BEACON_AMBER := Color(1.0, 0.55, 0.05)
const BEACON_GREEN := Color(0.15, 1.0, 0.3)
var _beacons: Array = []          ## [material, phase (0 or 1), strobe?]
var _beacon_lights: Array = []    ## [OmniLight3D, phase]
var _beacon_tag: Label3D


func add_safety_beacons() -> void:
	if not _beacons.is_empty():
		return
	var top := float(def.raw.get("height_m", 1.3)) + 0.1
	var roof := _find(self, "number_roof") as Node3D
	var bar_x := (roof.position.x + 0.55) if roof else def.body_offset + 0.3
	var half_w := def.width * 0.5
	# Roof bar: six lamps across the roof, left three and right three flash in turn.
	var lamp := Vector3(0.32, 0.12, def.width * 0.86 / 6.0)
	for k in 6:
		var z := -def.width * 0.4 + lamp.z * (k + 0.5)
		_beacon_box(Vector3(bar_x, top, z), lamp * Vector3(1, 1, 0.92), 0 if k < 3 else 1, false)
	# Corner strobes, front and rear, diagonals flash together.
	var fx := def.body_offset + def.length * 0.5 - 0.12
	var rx := def.body_offset - def.length * 0.5 + 0.12
	for c in [[fx, -1.0, 0], [fx, 1.0, 1], [rx, -1.0, 1], [rx, 1.0, 0]]:
		_beacon_box(Vector3(c[0], 0.62, c[1] * (half_w - 0.25)), Vector3(0.12, 0.08, 0.34), c[2], true)
	# Amber light thrown on the road either side.
	for side in [-1.0, 1.0]:
		var o := OmniLight3D.new()
		o.position = Vector3(bar_x, top + 0.6, side * (half_w + 0.4))
		o.omni_range = 9.0
		o.omni_attenuation = 1.2
		o.light_color = BEACON_AMBER
		o.light_energy = 0.0
		o.shadow_enabled = false
		_sprung.add_child(o)
		_beacon_lights.append([o, 0 if side < 0.0 else 1])
	# A tag that stays the same size on screen at any zoom, so the safety
	# car can be found even with the whole track in view.
	_beacon_tag = Label3D.new()
	_beacon_tag.text = "SC"
	_beacon_tag.font_size = 40
	_beacon_tag.outline_size = 12
	_beacon_tag.outline_modulate = Color(0, 0, 0, 0.85)
	_beacon_tag.modulate = BEACON_AMBER
	_beacon_tag.fixed_size = true
	_beacon_tag.pixel_size = 0.0012
	_beacon_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_beacon_tag.no_depth_test = true
	_beacon_tag.render_priority = 10
	_beacon_tag.position = Vector3(def.body_offset, top + 1.5, 0)
	_beacon_tag.offset = Vector2(0, 46)   # drawn above the car, not on it
	add_child(_beacon_tag)
	set_highlight(Highlight.SAFETY)


func _beacon_box(at: Vector3, size: Vector3, phase: int, strobe: bool) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.35, 0.2, 0.03)
	m.emission_enabled = true
	m.emission = BEACON_AMBER
	m.emission_energy_multiplier = 0.0
	m.roughness = 0.15
	bm.material = m
	mi.mesh = bm
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sprung.add_child(mi)
	_beacons.append([m, phase, strobe])


func _update_beacons() -> void:
	if _beacons.is_empty():
		return
	var on := _bar_mode != "off"
	var col := BEACON_GREEN if _bar_mode == "green" else BEACON_AMBER
	# Wig-wag: half a second per side; strobes double-flash each half.
	var half := int(_bar_t / 0.3) % 2
	var t := fmod(_bar_t, 0.3)
	var strobe_on := t < 0.05 or (t > 0.1 and t < 0.15)
	for b in _beacons:
		var m: StandardMaterial3D = b[0]
		m.emission = col
		var lit: bool = on and b[1] == half and (strobe_on if b[2] else true)
		m.emission_energy_multiplier = (9.0 if b[2] else 7.0) if lit else (0.6 if on else 0.0)
	for l in _beacon_lights:
		var o: OmniLight3D = l[0]
		o.light_color = col
		o.light_energy = 3.5 if on and l[1] == half else 0.0
	if _hl and highlight == Highlight.SAFETY:
		_hl.visible = on
		_hl_mat.set_shader_parameter("tint", col)
	if _beacon_tag:
		# Only needed once the car is small on screen.
		_beacon_tag.visible = on and _hl_zoom >= 2.5 and highlight != Highlight.GIVE_BACK
		_beacon_tag.modulate = col if half == 0 else col.lerp(Color.WHITE, 0.5)


# --- Player highlights -----------------------------------------------------------

## set_highlight: no outline, this player's own car, another human player, or
## the car race control says you must give a place back to (let it past),
## or the safety car (always outlined, see add_safety_beacons).
enum Highlight { NONE, SELF, PLAYER, GIVE_BACK, SAFETY }
const HIGHLIGHT_SHADER := preload("res://modules/graphics/shaders/car_highlight.gdshader")
const HIGHLIGHT_SELF := Color(1.0, 0.8, 0.22)
const HIGHLIGHT_PLAYER := Color(0.3, 0.8, 1.0)
const HIGHLIGHT_GIVE_BACK := Color(1.0, 0.3, 0.12)
var highlight: int = Highlight.NONE
var _hl: MeshInstance3D
var _hl_mat: ShaderMaterial
var _hl_zoom := -1.0
var _let_past: Label3D   ## "LET PAST" tag over the car (GIVE_BACK)


## A soft glowing outline on the ground round the car: warm gold for your own
## car (gently breathing), a quieter cyan for other people online. AI cars get
## none. The car you must give a place back to gets a strong pulsing
## orange-red outline and a "LET PAST" tag that stays the same size on screen
## at every zoom. Stays readable when zoomed out (set_highlight_zoom).
func set_highlight(kind: int) -> void:
	highlight = kind
	_show_let_past(kind == Highlight.GIVE_BACK)
	if kind == Highlight.NONE:
		if _hl:
			_hl.visible = false
		return
	if _hl == null:
		_hl = MeshInstance3D.new()
		_hl.name = "Highlight"
		_hl_mat = ShaderMaterial.new()
		_hl_mat.shader = HIGHLIGHT_SHADER
		var pm := PlaneMesh.new()
		pm.material = _hl_mat
		_hl.mesh = pm
		_hl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hl.position = Vector3(def.body_offset, 0.05, 0)
		add_child(_hl)
		set_highlight_zoom(1.0)
	_hl.visible = true
	var mine := kind == Highlight.SELF
	var give := kind == Highlight.GIVE_BACK
	_hl_mat.set_shader_parameter("tint", HIGHLIGHT_GIVE_BACK if give else (HIGHLIGHT_SELF if mine else HIGHLIGHT_PLAYER))
	_hl_mat.set_shader_parameter("strength", 1.0 if give else (0.6 if mine else 0.38))
	_hl_mat.set_shader_parameter("pulse", 1.0 if mine or give else 0.0)
	_hl_mat.set_shader_parameter("pulse_rate", 7.0 if give else 3.0)
	if kind == Highlight.SAFETY:   # the safety car: a strong, fast-flashing amber ring
		_hl_mat.set_shader_parameter("tint", BEACON_AMBER)
		_hl_mat.set_shader_parameter("strength", 0.95)
		_hl_mat.set_shader_parameter("pulse", 2.0)


## The floating "LET PAST" tag: drawn over everything, facing the camera, a
## fixed size on screen and sitting just above the car's outline.
func _show_let_past(show: bool) -> void:
	if _let_past == null:
		if not show:
			return
		_let_past = Label3D.new()
		_let_past.name = "LetPast"
		_let_past.text = "LET PAST"
		_let_past.font_size = 40
		_let_past.outline_size = 14
		_let_past.modulate = Color(1.0, 0.55, 0.3)
		_let_past.outline_modulate = Color(0.2, 0.02, 0.0, 0.9)
		_let_past.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_let_past.fixed_size = true
		_let_past.pixel_size = 0.0006
		_let_past.no_depth_test = true
		_let_past.render_priority = 10
		_let_past.outline_render_priority = 9
		_let_past.offset = Vector2(0, 50)
		_let_past.position = Vector3(def.body_offset, 2.0, 0)
		add_child(_let_past)
	_let_past.visible = show


## Zoomed out (camera far away), the outline gets thicker so a player's car
## can still be picked out of the field. k = 1 close up, grows with distance.
func set_highlight_zoom(k: float) -> void:
	if _hl == null:
		return
	k = clampf(k, 1.0, 40.0 if highlight == Highlight.SAFETY else 12.0)
	if absf(k - _hl_zoom) < 0.03 * k:
		return
	_hl_zoom = k
	var half := Vector2(def.length * 0.5, def.width * 0.5)
	var margin := 0.9 * k + 0.4
	var quad := half + Vector2(margin, margin)
	(_hl.mesh as PlaneMesh).size = quad * 2.0
	_hl_mat.set_shader_parameter("half_size", half)
	_hl_mat.set_shader_parameter("quad_half", quad)
	_hl_mat.set_shader_parameter("width", 0.35 * k)


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


## Tyre smoke: one emitter per axle, left in the world as the car moves on.
## Pale grey on tarmac; brown dust on gravel and grass (colour set each frame).
func _add_tyre_smoke() -> void:
	var b := def.wheelbase - def.cg_to_front
	for axle in 2:
		var p := GPUParticles3D.new()
		p.name = "TyreSmoke" + ("Front" if axle == 0 else "Rear")
		p.amount = 150
		p.lifetime = 2.4
		p.emitting = false
		p.local_coords = false
		p.fixed_fps = 0
		var pm := ParticleProcessMaterial.new()
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(0.25, 0.05, def.track_width * 0.5 + 0.1)
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 70.0
		pm.initial_velocity_min = 0.4
		pm.initial_velocity_max = 1.8
		pm.gravity = Vector3(0, 0.35, 0)
		pm.damping_min = 0.6
		pm.damping_max = 1.2
		pm.scale_min = 1.6
		pm.scale_max = 2.6
		pm.angle_min = -180.0
		pm.angle_max = 180.0
		var curve := CurveTexture.new()
		var cv := Curve.new()
		cv.add_point(Vector2(0, 0.35))
		cv.add_point(Vector2(0.4, 0.8))
		cv.add_point(Vector2(1, 1.0))
		curve.curve = cv
		pm.scale_curve = curve
		var ga := Gradient.new()
		ga.set_color(0, Color(1, 1, 1, 0.0))
		ga.add_point(0.08, Color(1, 1, 1, 0.55))
		ga.set_color(ga.get_point_count() - 1, Color(1, 1, 1, 0.0))
		var gt := GradientTexture1D.new()
		gt.gradient = ga
		pm.color_ramp = gt
		pm.color = Color(0.86, 0.86, 0.88)
		p.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(1.3, 1.3)
		var m := StandardMaterial3D.new()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.billboard_keep_scale = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.vertex_color_use_as_albedo = true
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_texture = _puff_texture()
		q.material = m
		p.draw_pass_1 = q
		p.position = Vector3(def.cg_to_front if axle == 0 else -b, 0.25, 0)
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.visibility_aabb = AABB(Vector3(-40, -4, -40), Vector3(80, 16, 80))
		add_child(p)
		_tyre_smoke.append(p)
		_smoke_mat.append(pm)


## Dust and roost for dirt (rallycross). Built for every car but cost
## nothing until a car drives on dirt.
func _add_dirt_effects() -> void:
	var b := def.wheelbase - def.cg_to_front
	# Dust: big, slow, lingering clouds, left hanging in the air behind.
	_dust = GPUParticles3D.new()
	_dust.name = "DirtDust"
	_dust.amount = 160
	_dust.lifetime = 4.5
	_dust.emitting = false
	_dust.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.4, 0.15, def.track_width * 0.5 + 0.2)
	pm.direction = Vector3(-1, 0.6, 0)
	pm.spread = 55.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.5
	pm.gravity = Vector3(0, 0.25, 0)
	pm.damping_min = 0.8
	pm.damping_max = 1.6
	pm.scale_min = 2.4
	pm.scale_max = 4.2
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	var curve := CurveTexture.new()
	var cv := Curve.new()
	cv.add_point(Vector2(0, 0.3))
	cv.add_point(Vector2(0.3, 0.75))
	cv.add_point(Vector2(1, 1.0))
	curve.curve = cv
	pm.scale_curve = curve
	var ga := Gradient.new()
	ga.set_color(0, Color(1, 1, 1, 0.0))
	ga.add_point(0.06, Color(1, 1, 1, 0.95))
	ga.add_point(0.5, Color(1, 1, 1, 0.6))
	ga.set_color(ga.get_point_count() - 1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = ga
	pm.color_ramp = gt
	pm.color = Color(0.86, 0.79, 0.67)
	_dust.process_material = pm
	_dust_mat = pm
	var q := QuadMesh.new()
	q.size = Vector2(1.6, 1.6)
	var m := StandardMaterial3D.new()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = _puff_texture()
	m.roughness = 1.0
	q.material = m
	_dust.draw_pass_1 = q
	_dust.position = Vector3(-b - 0.4, 0.35, 0)
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dust.visibility_aabb = AABB(Vector3(-60, -4, -60), Vector3(120, 24, 120))
	add_child(_dust)
	# Roost: stones or clods of mud flung back off the tyres, falling fast.
	_roost = GPUParticles3D.new()
	_roost.name = "DirtRoost"
	_roost.amount = 70
	_roost.lifetime = 0.8
	_roost.emitting = false
	_roost.local_coords = false
	var rm := ParticleProcessMaterial.new()
	rm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	rm.emission_box_extents = Vector3(0.15, 0.05, def.track_width * 0.5)
	rm.direction = Vector3(-1, 0.55, 0)
	rm.spread = 22.0
	rm.initial_velocity_min = 4.0
	rm.initial_velocity_max = 10.0
	rm.gravity = Vector3(0, -9.8, 0)
	rm.scale_min = 0.6
	rm.scale_max = 1.6
	rm.angle_min = -180.0
	rm.angle_max = 180.0
	rm.color = Color(0.3, 0.23, 0.16)
	_roost.process_material = rm
	_roost_mat = rm
	var bm := BoxMesh.new()
	bm.size = Vector3(0.09, 0.07, 0.08)
	var mm := StandardMaterial3D.new()
	mm.vertex_color_use_as_albedo = true
	mm.roughness = 0.95
	bm.material = mm
	_roost.draw_pass_1 = bm
	_roost.position = Vector3(-b - 0.3, 0.2, 0)
	_roost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_roost.visibility_aabb = AABB(Vector3(-20, -4, -20), Vector3(40, 10, 40))
	add_child(_roost)


## Dust on dry dirt, mud when it's wet: how much from speed, wheelspin and
## sliding. Called every frame from _process.
func _update_dirt(delta: float, wet: float) -> void:
	_dirt_tick -= delta
	if _dirt_tick <= 0.0:
		_dirt_tick = 0.1
		_dirt = float(dirt_at.call(pos2))
	if _dirt <= 0.02:
		if _dust.emitting:
			_dust.emitting = false
			_roost.emitting = false
		return
	var spd := state.speed()
	var slide := maxf(tyre_slide[2], tyre_slide[0])
	var spin := 1.0 if state.wheelspin else 0.0
	var go := smoothstep(3.0, 30.0, spd)
	var muddy := clampf(wet * 1.5, 0.0, 1.0)
	# Dust needs dry earth; wet dirt throws mud instead.
	var dust := _dirt * (1.0 - muddy) * clampf(go * 0.75 + slide * 0.5 + spin * 0.3, 0.0, 1.0)
	_dust.emitting = dust > 0.04
	_dust.amount_ratio = clampf(dust, 0.0, 1.0)
	_dust_mat.color = Color(0.86, 0.79, 0.67).lerp(Color(0.45, 0.37, 0.28), muddy)
	var roost := _dirt * clampf(smoothstep(5.0, 20.0, spd) * 0.35 + slide * 0.7 + spin * 0.8, 0.0, 1.0) * (0.6 + 0.6 * muddy)
	_roost.emitting = roost > 0.05
	_roost.amount_ratio = clampf(roost, 0.0, 1.0)
	_roost_mat.color = Color(0.4, 0.33, 0.25).lerp(Color(0.2, 0.15, 0.1), muddy)
	_roost_mat.initial_velocity_max = 7.0 + 8.0 * spin + 0.12 * spd


static var _puff: Texture2D


## A soft, lumpy puff (shared by every car).
static func _puff_texture() -> Texture2D:
	if _puff:
		return _puff
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.09
	noise.seed = 11
	for y in n:
		for x in n:
			var d := Vector2(x - n * 0.5 + 0.5, y - n * 0.5 + 0.5).length() / (n * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (0.65 + 0.35 * noise.get_noise_2d(x, y))
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a * 1.4, 0.0, 1.0)))
	_puff = ImageTexture.create_from_image(img)
	return _puff


## How hard each tyre slides (from the car's motion, so it works for cars
## driven on other machines too), then smoke and marks to match.
func _update_tyres(_delta: float) -> void:
	var fwd2 := state.forward()
	var vx := state.vel.dot(fwd2)
	var vy := state.vel.dot(state.right())
	var spd := state.vel.length()
	var a := def.cg_to_front
	var b := def.wheelbase - a
	var alpha_r := atan2(vy - state.yaw_rate * b, maxf(absf(vx), 3.0))
	var vyf := vy + state.yaw_rate * a
	var cs := cos(state.steer_angle)
	var sn := sin(state.steer_angle)
	var alpha_f := atan2(-vx * sn + vyf * cs, maxf(absf(vx * cs + vyf * sn), 3.0))
	var moving := smoothstep(1.5, 7.0, spd)
	var rear := smoothstep(0.14, 0.34, absf(alpha_r)) * moving
	var front := smoothstep(0.17, 0.36, absf(alpha_f)) * moving
	if state.wheelspin:   # burnout or power oversteer
		rear = maxf(rear, 1.0 if spd < 25.0 else 0.6)
	if not state.assist_abs and state.ax < -12.0:   # locking up without ABS
		front = maxf(front, smoothstep(12.0, 19.0, -state.ax) * moving)
	var wet := 0.0
	if env:
		wet = env.wetness_at(state.lateral_offset - env.raceline_offset(state.track_idx))
	var off_road := state.surface == TrackData.Surface.GRASS or state.surface == TrackData.Surface.GRAVEL
	if off_road:   # anything moving on grass or gravel throws up dirt
		var churn := smoothstep(4.0, 30.0, spd) * 0.7
		rear = maxf(rear, churn)
		front = maxf(front, churn * 0.6)
	# Loose dirt: tyre smoke turns to dust, ruts in the earth, and on derby
	# cars mud clods and grime (the dust and roost come from _update_dirt).
	var on_dirt: float = _dirt if state.air_h <= 0.0 and state.surface <= TrackData.Surface.KERB else 0.0
	var churn_dirt := smoothstep(3.0, 22.0, spd) * on_dirt
	if on_dirt > 0.05:
		rear = maxf(rear, churn_dirt * 0.9)
		front = maxf(front, churn_dirt * 0.55)
	tyre_slide = PackedFloat32Array([front, front, rear, rear])
	var dry := 1.0 - clampf(wet * 1.4, 0.0, 1.0)
	var smoke_k := [front, rear]
	var col := Color(0.86, 0.86, 0.88) if not off_road else (Color(0.55, 0.45, 0.32) if state.surface == TrackData.Surface.GRAVEL else Color(0.42, 0.36, 0.24))
	if on_dirt > 0.3:
		col = Color(0.62, 0.5, 0.36).lerp(Color(0.3, 0.23, 0.15), clampf(wet * 1.5, 0.0, 1.0))
		dry = maxf(dry, 0.45)
		off_road = true
	if _mud:
		var clods := churn_dirt * (0.35 + 0.65 * clampf(wet * 2.0, 0.0, 1.0) + maxf(rear - 0.5, 0.0))
		_mud.emitting = clods > 0.06
		_mud.amount_ratio = clampf(clods, 0.0, 1.0)
		_mud_mat.color = Color(0.27, 0.2, 0.13).lerp(Color(0.18, 0.13, 0.08), clampf(wet * 2.0, 0.0, 1.0))
		_grime = minf(_grime + churn_dirt * _delta * (0.01 + 0.03 * wet), 0.8)
	for axle in 2:
		var k: float = smoke_k[axle] * (dry if not off_road else maxf(dry, 0.25))
		_tyre_smoke[axle].emitting = k > 0.05
		_tyre_smoke[axle].amount_ratio = clampf(k, 0.0, 1.0)
		_smoke_mat[axle].color = col
	if marks == null:
		return
	var kind := SkidMarks.Kind.EARTH if state.surface == TrackData.Surface.GRASS or on_dirt > 0.5 else SkidMarks.Kind.RUBBER
	var lays := state.surface != TrackData.Surface.GRAVEL and state.surface != TrackData.Surface.BARRIER
	for w in _wheels:
		var hub: Node3D = w[0]
		var idx := ["wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr"].find(str(hub.name))
		if idx < 0:
			continue
		var k: float = tyre_slide[idx] if lays else 0.0
		if kind == SkidMarks.Kind.RUBBER:
			k *= 1.0 - clampf(wet * 1.6, 0.0, 0.85)
			if off_road:
				k = 0.0
		elif on_dirt > 0.5:
			k = maxf(k, churn_dirt * 0.6)
		if state.air_h > 0.05:
			k = 0.0
		var at := global_transform * Vector3(hub.position.x, 0.0, hub.position.z)
		marks.mark(_mark_key + idx, at, k, 0.34 * hub.scale.z, kind)


## Damage from CarDamage.visual_parts(): scuffed, darkened paint where the
## car was hit; parts sag above 0.6 and fall off above 0.85; a punctured
## wheel rides on its rim; a damaged engine smokes.
func _apply_damage() -> void:
	var d := CarDamage.visual_parts(state)
	var front: float = d.get("front_bumper", 0.0)
	_paint.set_shader_parameter("damage", Vector4(front, d.get("rear_bumper", 0.0), d.get("side_left", 0.0), d.get("side_right", 0.0)))
	for key in DAMAGE_PARTS:
		var part: Array = _parts.get(_part_alias.get(DAMAGE_PARTS[key], DAMAGE_PARTS[key]), [])
		if part.is_empty():
			continue
		var node: Node3D = part[0]
		var rest: Transform3D = part[1]
		var v: float = d.get(key, 0.0)
		var on := v < 0.85
		var name_k: String = DAMAGE_PARTS[key]
		if not on and _part_on.get(name_k, true) and _init_done and debris and node.visible and node is MeshInstance3D:
			_throw_part(node as MeshInstance3D)
		_part_on[name_k] = on
		node.visible = on
		if v > 0.6:
			var k := (v - 0.6) / 0.25
			var sag := Transform3D(Basis(Vector3.FORWARD, 0.08 * k) * Basis(Vector3.UP, 0.05 * k), Vector3(0, -0.04 * k, 0))
			node.transform = sag * rest
		else:
			node.transform = rest
	_flat = d
	var smoke: float = d.get("smoke", 0.0)
	_smoke.emitting = smoke > 0.02
	_smoke.amount_ratio = smoke
	_apply_crumple(d)
	if derby:
		_apply_derby(d)
	_shed_bodywork()


## New dents since we last looked throw shards from that side of the car.
func _shed_bodywork() -> void:
	if _body_seen.size() != 4:
		_body_seen = state.body_damage.duplicate()
		return
	for z in 4:
		var now := state.body_damage[z]
		var was := _body_seen[z]
		_body_seen[z] = now
		if now - was < 0.03 or debris == null or not _init_done:
			continue
		var c := _box.get_center()
		var at: Vector3
		match z:
			0: at = Vector3(_box.end.x, 0.35, c.z)        # front
			1: at = Vector3(_box.position.x, 0.45, c.z)   # rear
			2: at = Vector3(c.x, 0.4, _box.position.z)    # left
			_: at = Vector3(c.x, 0.4, _box.end.z)         # right
		var n := clampi(int((now - was) * 45.0), 2, 18)
		debris.burst(global_transform * at, _vel3(), n, _paint.get_shader_parameter("primary"), clampf((now - was) * 4.0, 0.4, 1.3))


## A part has broken away: a copy of it flies off (the car's own stays,
## hidden, until it's repaired in the pits).
func _throw_part(node: MeshInstance3D) -> void:
	var copy := node.duplicate() as MeshInstance3D
	for sidx in node.get_surface_override_material_count():
		copy.set_surface_override_material(sidx, node.get_surface_override_material(sidx))
	var side := Vector3(0, 0, 1) if node.get_aabb().get_center().z >= 0.0 else Vector3(0, 0, -1)
	var kick_local := (side * 2.5 + Vector3(randf_range(-1.5, 1.5), 0, 0))
	var kick := global_transform.basis * kick_local
	debris.detach(copy, node.global_transform, node.get_aabb(), _vel3(), kick)


## The livery's main colour (pit crews wear it).
func paint_colour() -> Color:
	return _paint.get_shader_parameter("primary")


func _vel3() -> Vector3:
	return Vector3(state.vel.x, 0.0, state.vel.y)


func _find(n: Node, want: String) -> Node:
	if n.name == want:
		return n
	for c in n.get_children():
		var f := _find(c, want)
		if f:
			return f
	return null


func _process(delta: float) -> void:
	if state == null or not visible:
		return
	_update_light_bar(delta)
	if not _init_done or pos2.distance_to(state.pos) > 6.0:
		pos2 = state.pos
		heading = state.heading
		_init_done = true
	else:
		# Glide between physics ticks: carry on at the car's speed and turn
		# rate, then ease onto the simulated pose. (Easing alone drew every car
		# a few metres behind where it really was, more for faster cars, so
		# cars closing under braking touched with a gap still showing.)
		var k := 1.0 - exp(-30.0 * delta)
		pos2 = (pos2 + state.vel * delta).lerp(state.pos, k)
		heading = lerp_angle(heading + state.yaw_rate * delta, state.heading, k)
	# Sit on the ground, following its slope.
	var up: Vector3 = ground_normal.call(pos2, state.track_idx)
	var fwd := Vector3(cos(heading), 0.0, sin(heading))
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up).normalized()
	var gy: float = ground.call(pos2, state.track_idx)
	var lift := 0.0
	if state.surface != TrackData.Surface.TRACK and state.surface != TrackData.Surface.KERB:
		lift = maxf(float(terrain.call(pos2, state.track_idx)) + 0.05 - gy, 0.0)
	_lift = lerpf(_lift, lift, 1.0 - exp(-12.0 * delta)) if lift < _lift else lift
	# Off a jump: up in the air, nose following the flight path.
	var air := state.air_h
	if air > 0.0:
		up = up.lerp(Vector3.UP, 0.7).normalized()
		fwd = Vector3(cos(heading), 0.0, sin(heading))
		fwd = (fwd - up * fwd.dot(up)).normalized()
		right = fwd.cross(up).normalized()
	_air_pitch = lerpf(_air_pitch, clampf(atan2(state.vz, maxf(state.speed(), 5.0)) * 0.7, -0.35, 0.35) if air > 0.0 else 0.0, 1.0 - exp(-6.0 * delta))
	if _was_air and air <= 0.0 and debris and state.speed() > 8.0:
		debris.sparks(global_position + Vector3(0, 0.2, 0), _vel3(), 0.5)
	_was_air = air > 0.0
	transform = Transform3D(Basis(fwd, up, right), Vector3(pos2.x, gy + _lift + hoist + air, pos2.y))
	_sprung.position.y = pit_lift - _ride_drop
	# Body pitch under braking/acceleration and roll in corners.
	var k2 := 1.0 - exp(-8.0 * delta)
	_pitch = lerpf(_pitch, clampf(state.ax * 0.0032, -0.035, 0.03), k2)
	_roll = lerpf(_roll, clampf(-state.ay * 0.0028, -0.04, 0.04), k2)
	_sprung.rotation = Vector3(_roll, 0.0, _pitch + _air_pitch)
	var v := state.vel.dot(state.forward())
	for w in _wheels:
		var hub: Node3D = w[0]
		if w[2]:
			hub.rotation.y = -state.steer_angle
		hub.position.y = def.wheel_radius - 0.09 * float(_flat.get(str(hub.name), 0.0)) + pit_lift
		if w[1]:
			(w[1] as Node3D).rotate_z(-v / w[3] * delta)
			var bit := 1 << maxi(["wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr"].find(str(hub.name)), 0)
			(w[1] as Node3D).visible = not wheels_hidden and (wheels_off_mask & bit) == 0
	var braking := state.ax < -3.0
	var dark := 0.0
	var wet := 0.0
	if env:
		dark = maxf(env.darkness(), clampf((env.rain - 0.5) * 0.8, 0.0, 0.4))
		wet = env.wetness_at(state.lateral_offset - env.raceline_offset(state.track_idx))
	_tail.emission_energy_multiplier = (4.0 if braking else 0.25) + dark * 1.5
	_head.emission_energy_multiplier = dark * 6.0
	for m in _tail_d:
		m.set_shader_parameter("emission_energy", _tail.emission_energy_multiplier)
	for m in _head_d:
		m.set_shader_parameter("emission_energy", _head.emission_energy_multiplier)
	if derby:
		if _fire_light:
			_fire_light.visible = _fire_k > 0.02
			_fire_light.light_energy = _fire_k * (2.2 + 1.4 * sin(Time.get_ticks_msec() * 0.023) * sin(Time.get_ticks_msec() * 0.0071))
	_head_light.visible = dark > 0.08
	_head_light.light_energy = dark * 6.0
	var spray := clampf(wet * 1.3, 0.0, 1.0) * clampf((state.speed() - 8.0) / 50.0, 0.0, 1.0)
	_spray.emitting = spray > 0.03
	_spray.amount_ratio = spray
	_update_tyres(delta)
	_update_dirt(delta, wet)
	_damage_tick -= delta
	if _damage_tick <= 0.0:
		_damage_tick = 0.2
		_apply_damage()


# --- Crumpled bodywork (every car) ------------------------------------------

## Swaps every material on the body parts (not the wheels) for one that
## crumples with the paint, so lights, grilles, glass, wings and splitters
## stay on the bent bodywork. The safety car never takes damage: left as is.
func _setup_crumple() -> void:
	if _bar_amber or _bar_green:
		return
	_crumple_mats.append(_paint)
	_crumple_mats.append(_carbon_decals)
	for name_k in _parts:
		var part: Array = _parts[name_k]
		if not part[0] is MeshInstance3D:
			continue
		var mi := part[0] as MeshInstance3D
		if mi.mesh == null:
			continue
		for sidx in mi.mesh.get_surface_count():
			var cur := mi.get_surface_override_material(sidx)
			var src := mi.mesh.surface_get_material(sidx)
			if cur == null:
				cur = src
			if cur == _paint or cur == _carbon_decals:
				continue
			var src_name := src.resource_name if src else ""
			var sm := ShaderMaterial.new()
			if src_name == "glass" or src_name == "windscreen":
				sm.shader = GLASS_SHADER
				sm.set_shader_parameter("seed", float(get_instance_id() % 997))
				if src_name == "windscreen":
					_glass_ws = sm
			else:
				sm.shader = PART_SHADER
				if cur is StandardMaterial3D:
					var std := cur as StandardMaterial3D
					sm.set_shader_parameter("albedo", std.albedo_color)
					sm.set_shader_parameter("roughness", std.roughness)
					sm.set_shader_parameter("metallic", std.metallic)
					if std.emission_enabled:
						sm.set_shader_parameter("emission", std.emission)
						sm.set_shader_parameter("emission_energy", std.emission_energy_multiplier)
				if cur == _tail:
					_tail_d.append(sm)
				elif cur == _head:
					_head_d.append(sm)
			mi.set_surface_override_material(sidx, sm)
			_crumple_mats.append(sm)
	for m in _crumple_mats:
		m.set_shader_parameter("car_ext", Vector3(_box.end.x, _box.position.x, maxf(-_box.position.z, _box.end.z)))
		m.set_shader_parameter("roof_y", _box.end.y)
		m.set_shader_parameter("crush_depth", crush_depth(def))
	var nr := _find(self, "number_roof") as Node3D
	if nr:
		_number_y = nr.position.y


## How far (m) a fully crushed nose or tail is pushed in: about a sixth of
## the car's length (a supermini loses ~0.6 m, a big saloon ~0.9 m).
static func crush_depth(d: CarDefinition) -> float:
	return clampf(d.length * 0.18, 0.55, 0.95)


## Where a hit landed (world 2D point): the crumple centres on it. A hit well
## away from the zone's first dent starts a second one.
func note_hit(at: Vector2) -> void:
	if _crumple_mats.is_empty() or state == null:
		return
	var local := (at - state.pos).rotated(-state.heading)
	var zone := CarDamage.zone_of(local, def)
	var along := local.y if zone == CarDamage.FRONT or zone == CarDamage.REAR else local.x
	var first: float = _dent[zone]
	if not _dent_set[zone]:
		_dent_set[zone] = true
		_dent[zone] = along
		_dent2[zone] = along
		_dent2_w[zone] = 0.0
	elif absf(along - first) < (0.5 if zone < CarDamage.LEFT else 0.8):
		_dent[zone] = lerpf(first, along, 0.4)
	else:
		# A fresh dent somewhere else on the same panel: it takes a growing
		# share of that zone's crush.
		_dent2[zone] = along if _dent2_w[zone] < 0.02 else lerpf(_dent2[zone], along, 0.5)
		_dent2_w[zone] = minf(_dent2_w[zone] + 0.25, 0.5)
	if _glass_ws and _crush_shown.x < 0.2 and zone == CarDamage.FRONT:
		_glass_ws.set_shader_parameter("crack_at", Vector3(_box.end.x * 0.4, _box.end.y * 0.85, clampf(local.y, -0.5, 0.5)))
	_crush_shown = Vector4(-1, -1, -1, -1)   # push the new dents on the next look


## Bodywork crush from CarDamage.visual_parts()["crush"] into the shaders;
## a car that's taken a pile of hits gets its roof squashed down too.
func _apply_crumple(d: Dictionary) -> void:
	if _crumple_mats.is_empty():
		return
	var c: Array = d.get("crush", [0.0, 0.0, 0.0, 0.0])
	var crush := Vector4(c[0], c[1], c[2], c[3])
	var roof := clampf((CarDamage.body_total(state) - 1.6) * 0.1, 0.0, 0.24)
	if (crush - _crush_shown).length() <= 0.004 and absf(roof - _roof_shown) <= 0.004:
		return
	for z in 4:
		if crush[z] < 0.02:   # undamaged (or repaired): the next hit starts a fresh dent
			_dent_set[z] = false
			_dent2_w[z] = 0.0
	_crush_shown = crush
	_roof_shown = roof
	for m in _crumple_mats:
		m.set_shader_parameter("crush", crush)
		m.set_shader_parameter("dent_at", _dent)
		m.set_shader_parameter("dent_at2", _dent2)
		m.set_shader_parameter("dent2_w", _dent2_w)
		m.set_shader_parameter("roof_crush", roof)
	if not is_nan(_number_y):
		var nr := _find(self, "number_roof") as Node3D
		if nr:
			nr.position.y = _number_y - roof


# --- Demolition Derby ------------------------------------------------------------

## Windscreen cracks, the steam, fire, smoke and mud emitters (the crumpling
## materials are already on from _setup_crumple).
func _setup_derby() -> void:
	derby = true
	if _glass_ws:
		_glass_ws.set_shader_parameter("crack_at", Vector3(_box.end.x * 0.4, _box.end.y * 0.85, 0.2))
	var bay := Vector3(maxf(def.cg_to_front * 0.75, _box.end.x - 1.0), _box.end.y * 0.62, 0.0)
	_steam = _emitter(28, 1.6, Vector3(_box.end.x - 0.25, 0.75, 0.0), Vector3(0.3, 1.0, 0.0), 30.0, [1.5, 3.5], 1.2,
		[0.8, 2.2], Color(0.96, 0.97, 1.0, 0.5), Color(0.96, 0.97, 1.0, 0.0))
	_bay_smoke = _emitter(36, 2.6, bay + Vector3(0, 0.2, 0), Vector3(0, 1, 0), 20.0, [1.0, 2.5], 1.0,
		[1.2, 3.4], Color(0.1, 0.1, 0.1, 0.6), Color(0.3, 0.3, 0.3, 0.0))
	_fire = _emitter(60, 0.55, bay, Vector3(0, 1, 0), 18.0, [1.0, 2.6], 2.5,
		[0.5, 1.3], Color(1.0, 0.85, 0.35, 0.95), Color(0.9, 0.2, 0.02, 0.0), true)
	(_fire.process_material as ParticleProcessMaterial).emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	(_fire.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(0.35, 0.05, def.width * 0.3)
	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Color(1.0, 0.55, 0.18)
	_fire_light.omni_range = 7.0
	_fire_light.position = bay + Vector3(0, 0.6, 0)
	_fire_light.visible = false
	_fire_light.shadow_enabled = false
	add_child(_fire_light)
	# Clods of dirt and mud flung back off the rear tyres.
	_mud = GPUParticles3D.new()
	_mud.amount = 70
	_mud.lifetime = 1.1
	_mud.emitting = false
	_mud.local_coords = false
	_mud_mat = ParticleProcessMaterial.new()
	_mud_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_mud_mat.emission_box_extents = Vector3(0.2, 0.05, def.track_width * 0.5)
	_mud_mat.direction = Vector3(-1, 0.9, 0)
	_mud_mat.spread = 28.0
	_mud_mat.initial_velocity_min = 3.0
	_mud_mat.initial_velocity_max = 8.0
	_mud_mat.gravity = Vector3(0, -9.8, 0)
	_mud_mat.scale_min = 0.5
	_mud_mat.scale_max = 1.4
	_mud_mat.angle_min = -180.0
	_mud_mat.angle_max = 180.0
	_mud.process_material = _mud_mat
	var q := QuadMesh.new()
	q.size = Vector2(0.16, 0.13)
	var m := StandardMaterial3D.new()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	q.material = m
	_mud.draw_pass_1 = q
	_mud.position = Vector3(-(def.wheelbase - def.cg_to_front) - 0.2, 0.25, 0)
	_mud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mud.visibility_aabb = AABB(Vector3(-20, -4, -20), Vector3(40, 10, 40))
	add_child(_mud)


## A soft particle emitter (steam, smoke, flames) on the car.
func _emitter(amount: int, life: float, at: Vector3, dir: Vector3, spread: float, speed: Array, rise: float,
		scale: Array, c0: Color, c1: Color, glow := false) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.emitting = false
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir
	pm.spread = spread
	pm.initial_velocity_min = speed[0]
	pm.initial_velocity_max = speed[1]
	pm.gravity = Vector3(0, rise, 0)
	pm.damping_min = 0.5
	pm.damping_max = 1.5
	pm.scale_min = scale[0]
	pm.scale_max = scale[1]
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	var ga := Gradient.new()
	ga.set_color(0, c0)
	ga.set_color(1, c1)
	var gt := GradientTexture1D.new()
	gt.gradient = ga
	pm.color_ramp = gt
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 1.0)
	var m := StandardMaterial3D.new()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = _puff_texture()
	if glow:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	q.material = m
	p.draw_pass_1 = q
	p.position = at
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-20, -2, -20), Vector3(40, 16, 40))
	add_child(p)
	return p


func _apply_derby(d: Dictionary) -> void:
	_paint.set_shader_parameter("dirt", _grime)
	# Windscreen: cracks spread, then it shatters (a shower of glass).
	var ws: float = d.get("windscreen", 0.0)
	if _glass_ws:
		_glass_ws.set_shader_parameter("crack", ws)
		if ws >= 0.85 and not _ws_broken and _init_done and debris:
			_ws_broken = true
			debris.burst(global_transform * Vector3(_box.end.x * 0.35, _box.end.y * 0.85, 0.0), _vel3(), 14,
				Color(0.78, 0.86, 0.9), 0.7)
	# Bonnet and boot lid: spring open on their hinges, then tear off.
	for lid in LIDS:
		var part: Array = _parts.get(lid, [])
		if part.is_empty():
			continue
		var node: Node3D = part[0]
		var rest: Transform3D = part[1]
		var v: float = d.get(LIDS[lid], 0.0)
		if _lid_gone.get(lid, false):
			node.visible = v < 0.05   # repaired in the pits (never, in a derby)
			if v < 0.05:
				_lid_gone[lid] = false
			continue
		if v >= 0.9 and _init_done and debris and node is MeshInstance3D:
			_lid_gone[lid] = true
			_throw_part(node as MeshInstance3D)
			node.visible = false
			continue
		var box := (node as MeshInstance3D).get_aabb() if node is MeshInstance3D else AABB()
		var open := clampf((v - 0.4) / 0.5, 0.0, 1.0)
		if open <= 0.0:
			node.transform = rest
			continue
		# The bonnet hinges at the windscreen, the boot lid at the rear window.
		var front: bool = lid == "bonnet"
		var hinge := Vector3(box.position.x if front else box.end.x, box.end.y, 0.0)
		var ang := open * (0.75 if front else 0.6) * (1.0 if front else -1.0)
		var xf := Transform3D(Basis(), hinge) * Transform3D(Basis(Vector3(0, 0, 1), ang), Vector3.ZERO) * Transform3D(Basis(), -hinge)
		node.transform = rest * xf
	# Radiator steam, engine-bay smoke, then fire.
	var steam: float = d.get("steam", 0.0)
	_steam.emitting = steam > 0.04
	_steam.amount_ratio = clampf(steam, 0.0, 1.0)
	var fire: float = d.get("fire", 0.0)
	_fire_k = fire
	_fire.emitting = fire > 0.02
	_fire.amount_ratio = clampf(0.3 + fire * 0.7, 0.0, 1.0)
	var bay := maxf(clampf((state.damage_engine - 0.45) / 0.4, 0.0, 1.0), fire)
	_bay_smoke.emitting = bay > 0.03
	_bay_smoke.amount_ratio = clampf(bay, 0.0, 1.0)
	for m in _crumple_mats:
		if m.shader == PART_SHADER:
			m.set_shader_parameter("soot", fire * 0.8)
