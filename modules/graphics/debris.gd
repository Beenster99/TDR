class_name Debris
extends Node3D
## Bits that come off cars in a crash: shards of carbon fibre and painted
## bodywork thrown from where a car was hit, whole parts (a front bumper, a
## rear wing, a mirror) that break away and tumble down the road, and a
## shower of sparks. The pieces bounce, slide to a stop on the ground and
## lie there for a while before they're cleared. Purely visual: the race
## never sees them, so they can't be hit.

const MAX_PIECES := 260
const LIE_S := 50.0            ## how long a piece lies on the ground
## How long pieces lie and how many there can be (WorldView keeps them for
## the whole race in a Demolition Derby: the arena fills with wreckage).
var lie_s := LIE_S
var max_pieces := MAX_PIECES
const CLEAR_S := 3.0           ## then it shrinks away over this long
const GRAVITY := 9.81

## Height of the ground under a point (set by WorldView): (pos, hint) -> y.
var ground: Callable = func(_p: Vector2, _hint: int) -> float: return 0.0

var _pieces: Array = []        ## [node, vel Vector3, spin Vector3, age, at rest, base scale, centre height at rest, is a shard]
var _shard_meshes: Array[Mesh] = []
var _carbon: StandardMaterial3D
var _sparks: Array[GPUParticles3D] = []
var _spark_next := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	name = "Debris"
	_rng.seed = 4242
	_carbon = StandardMaterial3D.new()
	_carbon.albedo_color = Color(0.06, 0.06, 0.07)
	_carbon.roughness = 0.35
	_carbon.metallic = 0.3
	for k in 4:
		_shard_meshes.append(_shard_mesh(k))
	for k in 4:
		_sparks.append(_make_sparks())


## Shards thrown from a hit: at world point p, carried along at the car's
## velocity vel, count pieces, some in paint colour, some carbon.
func burst(p: Vector3, vel: Vector3, count: int, paint: Color, strength := 1.0) -> void:
	count = mini(count, 24)
	for k in count:
		var mi := MeshInstance3D.new()
		mi.mesh = _shard_meshes[_rng.randi() % _shard_meshes.size()]
		if _rng.randf() < 0.55:
			mi.material_override = _carbon
		else:
			var m := StandardMaterial3D.new()
			m.albedo_color = paint
			m.roughness = 0.3
			mi.material_override = m
		var size := _rng.randf_range(0.22, 0.6) * (0.8 + 0.4 * strength)
		mi.scale = Vector3.ONE * size
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		mi.global_position = p + Vector3(_rng.randf_range(-0.4, 0.4), _rng.randf_range(0.2, 0.7), _rng.randf_range(-0.4, 0.4))
		mi.rotation = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
		var throw := Vector3(_rng.randf_range(-1, 1), 0.0, _rng.randf_range(-1, 1)).normalized() * _rng.randf_range(2.0, 7.0) * strength
		throw.y = _rng.randf_range(2.0, 6.0) * strength
		_add(mi, vel * _rng.randf_range(0.55, 0.9) + throw, 0.03 + size * 0.05, true)
	_spark(p, vel, strength)


## A whole part breaking off a car: node is a copy of the part (not in the
## tree yet), xf where the part is in the world, box its mesh bounds. It
## tumbles about its own middle and flies off at the car's velocity plus a
## kick.
func detach(node: Node3D, xf: Transform3D, box: AABB, vel: Vector3, kick: Vector3) -> void:
	var pivot := Node3D.new()
	pivot.name = "Part_" + str(node.name)
	add_child(pivot)
	var c := box.get_center()
	pivot.global_transform = xf * Transform3D(Basis(), c)
	node.transform = Transform3D(Basis(), -c)
	node.visible = true
	pivot.add_child(node)
	_add(pivot, vel * 0.8 + kick + Vector3(0, _rng.randf_range(2.0, 4.5), 0),
		0.04 + minf(box.size.y, box.size.x) * 0.35, false)


## Just sparks (a hard scrape that broke nothing).
func sparks(p: Vector3, vel: Vector3, strength := 1.0) -> void:
	_spark(p, vel, strength)


## Marshals sweeping at p (2D): pieces within radius metres go now.
func clear_near(p: Vector2, radius: float) -> void:
	for pc in _pieces:
		var n: Node3D = pc[0]
		if float(pc[3]) < LIE_S and Vector2(n.global_position.x, n.global_position.z).distance_to(p) < radius:
			pc[3] = LIE_S


func piece_count() -> int:
	return _pieces.size()


func _add(node: Node3D, vel: Vector3, rest_h: float, shard: bool) -> void:
	var spin := 12.0 if shard else 5.0
	_pieces.append([node, vel, Vector3(_rng.randf_range(-spin, spin), _rng.randf_range(-spin, spin), _rng.randf_range(-spin, spin)),
		0.0, false, node.scale, rest_h, shard])
	while _pieces.size() > max_pieces:
		var old: Array = _pieces.pop_front()
		(old[0] as Node).queue_free()


func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	var i := 0
	while i < _pieces.size():
		var pc: Array = _pieces[i]
		var node: Node3D = pc[0]
		pc[3] += delta
		var age: float = pc[3]
		if age > lie_s + CLEAR_S:
			node.queue_free()
			_pieces.remove_at(i)
			continue
		if age > lie_s:
			node.scale = (pc[5] as Vector3) * clampf(1.0 - (age - lie_s) / CLEAR_S, 0.01, 1.0)
		if not pc[4]:
			var v: Vector3 = pc[1]
			v.y -= GRAVITY * delta
			var p := node.global_position + v * delta
			var g: float = ground.call(Vector2(p.x, p.z), -1) + float(pc[6])
			if p.y <= g:
				p.y = g
				if absf(v.y) > 1.5:
					v.y = -v.y * 0.35                  # bounce
					v.x *= 0.7
					v.z *= 0.7
					pc[2] = (pc[2] as Vector3) * 0.6
				else:
					v.y = 0.0
					var f := maxf(1.0 - 6.0 * delta, 0.0)   # slides to a stop
					v.x *= f
					v.z *= f
					pc[2] = (pc[2] as Vector3) * f
					if Vector2(v.x, v.z).length() < 0.15:
						pc[4] = true
						# lie flat-ish on the ground
						var flip := 0.0 if pc[7] or _rng.randf() < 0.7 else PI
						node.rotation = Vector3(flip, node.rotation.y, 0.0)
			pc[1] = v
			node.global_position = p
			var spin: Vector3 = pc[2]
			if not pc[4] and spin.length_squared() > 0.01:
				node.rotate(spin.normalized(), spin.length() * delta)
		i += 1


func _spark(p: Vector3, vel: Vector3, strength: float) -> void:
	var s := _sparks[_spark_next]
	_spark_next = (_spark_next + 1) % _sparks.size()
	s.global_position = p + Vector3(0, 0.3, 0)
	var pm := s.process_material as ParticleProcessMaterial
	var flat := Vector3(vel.x, 0.0, vel.z)
	pm.direction = flat.normalized() + Vector3(0, 0.35, 0) if flat.length() > 1.0 else Vector3.UP
	pm.initial_velocity_min = 3.0 + flat.length() * 0.25
	pm.initial_velocity_max = 8.0 + flat.length() * 0.5
	s.amount_ratio = clampf(0.35 + strength * 0.65, 0.0, 1.0)
	s.restart()


func _make_sparks() -> GPUParticles3D:
	var s := GPUParticles3D.new()
	s.amount = 60
	s.lifetime = 0.55
	s.one_shot = true
	s.explosiveness = 0.9
	s.emitting = false
	s.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 55.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 9.0
	pm.gravity = Vector3(0, -9.8, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var ga := Gradient.new()
	ga.set_color(0, Color(1.0, 0.95, 0.6, 1.0))
	ga.set_color(1, Color(1.0, 0.35, 0.05, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = ga
	pm.color_ramp = gt
	s.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.09, 0.09)
	var m := StandardMaterial3D.new()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.emission_enabled = true
	m.emission = Color(1.0, 0.6, 0.2)
	m.emission_energy_multiplier = 4.0
	q.material = m
	s.draw_pass_1 = q
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.visibility_aabb = AABB(Vector3(-15, -5, -15), Vector3(30, 15, 30))
	add_child(s)
	return s


## A jagged flat chip of bodywork (each k a different shape), about 1 m
## across before scaling.
func _shard_mesh(k: int) -> Mesh:
	var r := RandomNumberGenerator.new()
	r.seed = 100 + k
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 5 + k % 3
	var rim: Array[Vector3] = []
	for j in n:
		var a := TAU * j / n + r.randf_range(-0.3, 0.3)
		var rad := r.randf_range(0.25, 0.6)
		rim.append(Vector3(cos(a) * rad * 1.4, r.randf_range(-0.04, 0.04), sin(a) * rad))
	var top := Vector3(0, 0.05, 0)
	var bot := Vector3(0, -0.05, 0)
	for j in n:
		var a := rim[j]
		var b := rim[(j + 1) % n]
		st.add_vertex(top)
		st.add_vertex(b)
		st.add_vertex(a)
		st.add_vertex(bot)
		st.add_vertex(a)
		st.add_vertex(b)
	st.generate_normals()
	return st.commit()
