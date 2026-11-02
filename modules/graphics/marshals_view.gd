class_name MarshalsView
extends Node3D
## Track marshals in orange overalls running out to clear debris, sweeping
## with big brooms, then running back behind the barrier. Simple 3D figures
## like the pit crews, a touch larger so they read from above.
##
## WorldView.set_marshals passes every marshal each frame (from
## RaceControl.marshal_views(), see TrackMarshals.view): [{pos, heading,
## action ("run"/"sweep"/"wave"), t}].

const SCALE := 1.15
const SHOW_DIST := 900.0

var ground: Callable = func(_p: Vector2, _hint: int) -> float: return 0.0
var terrain: Callable = func(_p: Vector2, _hint: int) -> float: return -INF

var _people: Array = []          ## {root, upper, leg_l, leg_r, arm_l, arm_r, broom, pos2, h2}
var _mats := {}
var _meshes := {}


func set_marshals(views: Array) -> void:
	while _people.size() < views.size():
		_people.append(_build())
	for k in _people.size():
		var p: Dictionary = _people[k]
		var root: Node3D = p["root"]
		root.visible = k < views.size()
		if root.visible:
			p["view"] = views[k]


## Where marshals are sweeping right now (to clear the debris bits there).
func sweeping() -> Array:
	var out := []
	for p in _people:
		if (p["root"] as Node3D).visible and p.has("view") and p["view"]["action"] == "sweep":
			out.append(p["view"]["pos"])
	return out


func _process(delta: float) -> void:
	for p in _people:
		if (p["root"] as Node3D).visible and p.has("view"):
			_pose(p, p["view"], delta)


func _pose(p: Dictionary, v: Dictionary, delta: float) -> void:
	var pos: Vector2 = v["pos"]
	var h: float = v["heading"]
	if not p.has("pos2") or (p["pos2"] as Vector2).distance_to(pos) > 5.0:
		p["pos2"] = pos
		p["h2"] = h
	else:
		var k := 1.0 - exp(-14.0 * delta)
		p["pos2"] = (p["pos2"] as Vector2).lerp(pos, k)
		p["h2"] = lerp_angle(float(p["h2"]), h, k)
	pos = p["pos2"]
	var root: Node3D = p["root"]
	var y := maxf(float(ground.call(pos, -1)), float(terrain.call(pos, -1)) + 0.03)
	root.position = Vector3(pos.x, y, pos.y)
	root.rotation = Vector3(0.0, -float(p["h2"]), 0.0)
	var t: float = v["t"]
	var action: String = v["action"]
	var broom: Node3D = p["broom"]
	var legs := 0.0
	var arm_l := 0.0
	var arm_r := 0.0
	var lean := 0.0
	var arm_side := 0.0
	match action:
		"run":
			var c := sin(t * 11.0)
			legs = c * 0.75
			arm_l = -c * 0.9
			arm_r = c * 0.9
			lean = -0.22
			broom.rotation = Vector3(0.0, 0.0, -1.2)     # carried along
		"sweep":
			var c := sin(t * 4.0)
			legs = sin(t * 2.0) * 0.25
			arm_l = -0.9 + c * 0.35
			arm_r = -0.7 + c * 0.35
			lean = -0.35
			arm_side = c * 0.25
			broom.rotation = Vector3(c * 0.6, 0.0, -0.45)  # pushing side to side
		"wave":
			arm_r = -2.8 + sin(t * 6.0) * 0.3                # flag the cars down
			arm_l = 0.1
			broom.rotation = Vector3(0.0, 0.0, -0.2)
	(p["leg_l"] as Node3D).rotation = Vector3(0, 0, legs)
	(p["leg_r"] as Node3D).rotation = Vector3(0, 0, -legs)
	(p["arm_l"] as Node3D).rotation = Vector3(arm_side, 0, arm_l)
	(p["arm_r"] as Node3D).rotation = Vector3(-arm_side, 0, arm_r)
	(p["upper"] as Node3D).rotation = Vector3(0, 0, lean)


func _mat(key: String, col: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = rough
		m.metallic = metal
		if key == "stripe":
			m.emission_enabled = true
			m.emission = col
			m.emission_energy_multiplier = 0.5
		_mats[key] = m
	return _mats[key]


func _box(size: Vector3) -> BoxMesh:
	var key := str(size)
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


func _part(parent: Node3D, mesh: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	mi.visibility_range_end = SHOW_DIST
	parent.add_child(mi)
	return mi


## One marshal: legs and arms swing from hips and shoulders (local x =
## forward, like the cars), a broom in the right hand.
func _build() -> Dictionary:
	var root := Node3D.new()
	root.scale = Vector3.ONE * SCALE
	add_child(root)
	var suit := _mat("suit", Color(1.0, 0.45, 0.05), 0.8)
	var stripe := _mat("stripe", Color(0.95, 0.95, 0.9), 0.5)
	var p := {"root": root}
	for s in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.position = Vector3(0, 0.9, s * 0.11)
		root.add_child(hip)
		_part(hip, _box(Vector3(0.18, 0.86, 0.18)), suit, Vector3(0, -0.43, 0))
		_part(hip, _box(Vector3(0.2, 0.06, 0.2)), stripe, Vector3(0, -0.62, 0))
		p["leg_l" if s < 0.0 else "leg_r"] = hip
	var upper := Node3D.new()
	upper.position = Vector3(0, 0.9, 0)
	root.add_child(upper)
	p["upper"] = upper
	_part(upper, _box(Vector3(0.3, 0.62, 0.5)), suit, Vector3(0, 0.31, 0))
	_part(upper, _box(Vector3(0.31, 0.08, 0.51)), stripe, Vector3(0, 0.36, 0))
	if not _meshes.has("head"):
		var head := SphereMesh.new()
		head.radius = 0.15
		head.height = 0.3
		head.radial_segments = 10
		head.rings = 6
		_meshes["head"] = head
	_part(upper, _meshes["head"], _mat("cap", Color(0.95, 0.95, 0.95), 0.4), Vector3(0, 0.79, 0))
	for s in [-1.0, 1.0]:
		var sh := Node3D.new()
		sh.position = Vector3(0, 0.56, s * 0.31)
		upper.add_child(sh)
		_part(sh, _box(Vector3(0.13, 0.66, 0.13)), suit, Vector3(0, -0.32, 0))
		p["arm_l" if s < 0.0 else "arm_r"] = sh
	# Broom: long handle and a wide black head, held in the right hand.
	var broom := Node3D.new()
	broom.position = Vector3(0.05, -0.62, 0.0)
	(p["arm_r"] as Node3D).add_child(broom)
	_part(broom, _box(Vector3(0.05, 1.5, 0.05)), _mat("handle", Color(0.55, 0.4, 0.2), 0.8), Vector3(0, -0.55, 0))
	_part(broom, _box(Vector3(0.14, 0.14, 0.75)), _mat("bristles", Color(0.08, 0.08, 0.08), 0.9), Vector3(0, -1.3, 0))
	p["broom"] = broom
	return p
