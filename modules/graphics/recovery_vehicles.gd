class_name RecoveryVehicles
extends Node3D
## The marshals' recovery vehicles, in 3D: a crane truck that lifts a crashed
## car over the barrier onto its flatbed, and a tractor that tows a stopped
## car away on a strap. Built from simple shapes, chunky enough to read from
## high above, with flashing amber beacons.
##
## WorldView.set_recovery_vehicles passes one Dictionary per vehicle every
## frame (from RaceControl.recovery_vehicles(), see CarRecovery.view):
## {car, kind ("crane"/"tractor"), pos, heading, speed, reach (0 stowed ..
## 1 boom over the car), hook (2D point the hook hangs over), hoist (m the
## car is lifted), phase, towing, car_pos}.

const CRANE_LENGTH := 9.5
const CRANE_PIVOT := 1.8
const TRACTOR_LENGTH := 4.2
const CAR_ROOF := 1.25            ## top of a race car above its wheels' contact
const SLING := 1.6                ## hook above the car's roof

var ground: Callable = func(_p: Vector2, _hint: int) -> float: return 0.0
var ground_normal: Callable = func(_p: Vector2, _hint: int) -> Vector3: return Vector3.UP
var terrain: Callable = func(_p: Vector2, _hint: int) -> float: return -INF

var _vehicles := {}               ## car index -> {node, kind, parts...}
var _mats := {}
var _clock := 0.0


func set_vehicles(views: Array) -> void:
	var seen := {}
	for v in views:
		var key := int(v["car"])
		seen[key] = true
		if not _vehicles.has(key) or _vehicles[key]["kind"] != v["kind"]:
			if _vehicles.has(key):
				(_vehicles[key]["node"] as Node3D).queue_free()
			_vehicles[key] = _build_crane() if v["kind"] == "crane" else _build_tractor()
			add_child(_vehicles[key]["node"])
		_vehicles[key]["view"] = v
	for key in _vehicles.keys():
		if not seen.has(key):
			(_vehicles[key]["node"] as Node3D).queue_free()
			_vehicles.erase(key)


func _process(delta: float) -> void:
	_clock += delta
	for key in _vehicles:
		var veh: Dictionary = _vehicles[key]
		if not veh.has("view"):
			continue
		_pose(veh, veh["view"], delta)


# --- Placing -------------------------------------------------------------------

func _height(p: Vector2) -> float:
	var gy: float = ground.call(p, -1)
	return maxf(gy, float(terrain.call(p, -1)) + 0.05)


func _pose(veh: Dictionary, v: Dictionary, delta: float) -> void:
	var node: Node3D = veh["node"]
	var pos: Vector2 = v["pos"]
	var h: float = v["heading"]
	# Smooth like the cars, so updates from the host don't jump.
	if not veh.has("pos2") or (veh["pos2"] as Vector2).distance_to(pos) > 8.0:
		veh["pos2"] = pos
		veh["h2"] = h
	else:
		var k := 1.0 - exp(-20.0 * delta)
		veh["pos2"] = (veh["pos2"] as Vector2).lerp(pos, k)
		veh["h2"] = lerp_angle(float(veh["h2"]), h, k)
	pos = veh["pos2"]
	h = veh["h2"]
	var up: Vector3 = ground_normal.call(pos, -1)
	var fwd := Vector3(cos(h), 0.0, sin(h))
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up).normalized()
	node.transform = Transform3D(Basis(fwd, up, right), Vector3(pos.x, _height(pos), pos.y))
	# Wheels roll with the speed.
	var spin := float(v["speed"]) * delta
	for w in veh["wheels"]:
		(w[0] as Node3D).rotate_z(-spin / float(w[1]))
	# Amber beacons flash (two lamps out of phase, like a rotating light).
	var on := fmod(_clock * 2.6, 1.0) < 0.5
	for k in veh["beacons"].size():
		var b: MeshInstance3D = veh["beacons"][k]
		b.material_override = _mat("beacon_on" if on == (k % 2 == 0) else "beacon_off", Color(1.0, 0.55, 0.05), 0.4)
	if veh["kind"] == "crane":
		_pose_crane(veh, v, node)
	else:
		_pose_tractor(veh, v, node)


func _pose_crane(veh: Dictionary, v: Dictionary, node: Node3D) -> void:
	var reach := float(v["reach"])
	var working: bool = v["phase"] in ["reach", "lift", "swing", "lower"]
	# Outriggers out while lifting.
	var legs := 1.0 if working else 0.0
	veh["legs_out"] = move_toward(float(veh.get("legs_out", 0.0)), legs, 0.02)
	for leg in veh["legs"]:
		var l: Node3D = leg[0]
		l.position.z = float(leg[1]) * (1.25 + 1.0 * float(veh["legs_out"]))
	# Boom: from the turret to a tip above the hook. Stowed it lies back over the bed.
	var turret: Node3D = veh["turret"]
	var pivot := turret.global_position + Vector3(0, 0.9, 0)
	var hook2: Vector2 = v["hook"]
	var hook_y := _height(hook2) + float(v["hoist"]) + CAR_ROOF + SLING
	var tip_work := Vector3(hook2.x, maxf(hook_y + 2.2, pivot.y + 3.5), hook2.y)
	var tip_stow := node.global_transform * Vector3(-4.6, 2.9, 0.0)
	var tip := tip_stow.lerp(tip_work, smoothstep(0.0, 1.0, reach))
	var boom: MeshInstance3D = veh["boom"]
	var span := tip - pivot
	var blen := maxf(span.length(), 1.0)
	boom.global_transform = _beam(pivot, tip, Vector3(0.55, 0.55, blen))
	# Turret turns with the boom.
	var flat := Vector3(span.x, 0.0, span.z)
	if flat.length() > 0.2:
		var local := node.global_transform.basis.inverse() * flat
		turret.rotation = Vector3(0.0, -atan2(local.z, local.x), 0.0)
	# Cable and hook block, hanging straight down from the tip.
	var cable: MeshInstance3D = veh["cable"]
	var block: MeshInstance3D = veh["block"]
	var show := reach > 0.05
	cable.visible = show
	block.visible = show
	if show:
		var hang := Vector3(tip.x, minf(hook_y, tip.y - 0.5), tip.z)
		cable.global_transform = _beam(tip, hang, Vector3(0.07, 0.07, maxf(tip.y - hang.y, 0.1)))
		block.global_position = hang
		# Slings from the hook to the car's corners.
		var slings: Array = veh["slings"]
		var car_top := Vector3(hook2.x, _height(hook2) + float(v["hoist"]) + CAR_ROOF * 0.8, hook2.y)
		var carrying: bool = v["phase"] != "reach"
		for k in slings.size():
			var sl: MeshInstance3D = slings[k]
			sl.visible = carrying
			if carrying:
				var ch := float(v.get("car_heading", 0.0))
				var lx := 1.5 if k < 2 else -1.5
				var lz := 0.8 if k % 2 == 0 else -0.8
				var corner := car_top + Vector3(cos(ch) * lx - sin(ch) * lz, 0.0, sin(ch) * lx + cos(ch) * lz)
				sl.global_transform = _beam(hang, corner, Vector3(0.05, 0.05, hang.distance_to(corner)))


func _pose_tractor(veh: Dictionary, v: Dictionary, node: Node3D) -> void:
	var strap: MeshInstance3D = veh["strap"]
	strap.visible = v["towing"] or v["phase"] == "hook"
	if strap.visible:
		var hitch := node.global_transform * Vector3(-TRACTOR_LENGTH * 0.5 - 0.1, 0.55, 0.0)
		var car2: Vector2 = v["car_pos"]
		var to2 := Vector2(hitch.x, hitch.z) - car2
		var nose2 := car2 + to2.normalized() * 2.3
		var nose := Vector3(nose2.x, _height(nose2) + 0.35, nose2.y)
		strap.global_transform = _beam(hitch, nose, Vector3(0.12, 0.04, maxf(hitch.distance_to(nose), 0.1)))


## A box mesh (unit size along z) stretched from a to b.
func _beam(a: Vector3, b: Vector3, size: Vector3) -> Transform3D:
	var d := b - a
	var z := d.normalized() if d.length() > 0.001 else Vector3.FORWARD
	var upv := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := upv.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Transform3D(Basis(x * size.x, y * size.y, z * size.z), (a + b) * 0.5)


# --- Building ------------------------------------------------------------------

func _mat(key: String, col: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	if key == "beacon_on":
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 6.0
	elif key == "glass":
		m.metallic_specular = 0.9
	elif key == "stripe":
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 0.6
	_mats[key] = m
	return m


func _box(parent: Node3D, size: Vector3, at: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


func _unit_box(parent: Node3D, mat: StandardMaterial3D) -> MeshInstance3D:
	return _box(parent, Vector3.ONE, Vector3.ZERO, mat)


func _cyl(parent: Node3D, r: float, h: float, at: Vector3, mat: StandardMaterial3D, axis_z := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = 16
	mi.mesh = cm
	mi.material_override = mat
	mi.position = at
	if axis_z:
		mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	parent.add_child(mi)
	return mi


## A wheel: hub node (spins about local z = the axle) with a tyre and rim.
func _wheel(parent: Node3D, r: float, w: float, at: Vector3, list: Array) -> void:
	var hub := Node3D.new()
	hub.position = at
	parent.add_child(hub)
	_cyl(hub, r, w, Vector3.ZERO, _mat("tyre", Color(0.06, 0.06, 0.06), 0.95))
	_cyl(hub, r * 0.55, w + 0.02, Vector3.ZERO, _mat("rim", Color(0.85, 0.7, 0.1), 0.5, 0.3))
	# Tread blocks so the wheel visibly turns.
	for k in 6:
		var a := float(k) * TAU / 6.0
		_box(hub, Vector3(0.12, 0.08, w + 0.03), Vector3(cos(a) * r * 0.97, sin(a) * r * 0.97, 0), _mat("tread", Color(0.12, 0.12, 0.12), 0.95))
	list.append([hub, r])


func _beacon(parent: Node3D, at: Vector3, list: Array) -> void:
	var b := _cyl(parent, 0.16, 0.22, at, _mat("beacon_off", Color(0.6, 0.3, 0.02), 0.4), false)
	list.append(b)


## Marshals' tractor: orange body, big rear wheels, glass cab with a white
## roof and a beacon, a counterweight on the nose and a hitch at the back.
func _build_tractor() -> Dictionary:
	var node := Node3D.new()
	node.name = "RecoveryTractor"
	var wheels := []
	var beacons := []
	var body := _mat("tractor", Color(0.95, 0.42, 0.05), 0.55)
	var dark := _mat("chassis", Color(0.12, 0.12, 0.13), 0.8)
	_box(node, Vector3(3.6, 0.5, 1.0), Vector3(0.0, 0.75, 0.0), dark)                 # chassis
	_box(node, Vector3(2.0, 0.85, 1.05), Vector3(0.95, 1.25, 0.0), body)               # bonnet
	_box(node, Vector3(0.5, 0.6, 1.4), Vector3(2.05, 0.8, 0.0), dark)                  # weights
	_box(node, Vector3(1.55, 0.25, 2.2), Vector3(-1.0, 1.2, 0.0), body)                # mudguards
	_box(node, Vector3(1.45, 1.35, 1.55), Vector3(-0.95, 2.05, 0.0), _mat("glass", Color(0.12, 0.17, 0.2, 1.0), 0.1, 0.4))
	_box(node, Vector3(1.65, 0.12, 1.75), Vector3(-0.95, 2.78, 0.0), _mat("roof", Color(0.95, 0.95, 0.95), 0.5))
	_box(node, Vector3(1.66, 0.1, 1.76), Vector3(-0.95, 2.68, 0.0), _mat("stripe", Color(1.0, 0.8, 0.1)))
	_box(node, Vector3(0.12, 0.9, 0.12), Vector3(0.6, 1.9, 0.3), dark)                 # exhaust
	_box(node, Vector3(0.3, 0.2, 0.3), Vector3(-2.15, 0.55, 0.0), dark)                # hitch
	_beacon(node, Vector3(-0.6, 2.95, 0.45), beacons)
	_beacon(node, Vector3(-0.6, 2.95, -0.45), beacons)
	_wheel(node, 0.8, 0.55, Vector3(-1.0, 0.8, 1.05), wheels)
	_wheel(node, 0.8, 0.55, Vector3(-1.0, 0.8, -1.05), wheels)
	_wheel(node, 0.48, 0.38, Vector3(1.25, 0.48, 0.85), wheels)
	_wheel(node, 0.48, 0.38, Vector3(1.25, 0.48, -0.85), wheels)
	var strap := _unit_box(self, _mat("strap", Color(1.0, 0.75, 0.0), 0.6))
	strap.visible = false
	node.tree_exiting.connect(strap.queue_free)
	return {"node": node, "kind": "tractor", "wheels": wheels, "beacons": beacons, "strap": strap}


## Crane truck: red cab, long chassis with a flatbed at the back, a yellow
## turret behind the cab with a telescopic boom, outrigger legs, cable,
## hook block and slings.
func _build_crane() -> Dictionary:
	var node := Node3D.new()
	node.name = "RecoveryCrane"
	var wheels := []
	var beacons := []
	var cab := _mat("crane_cab", Color(0.78, 0.08, 0.06), 0.45)
	var yellow := _mat("crane_yellow", Color(1.0, 0.78, 0.05), 0.5)
	var dark := _mat("chassis", Color(0.12, 0.12, 0.13), 0.8)
	var bed := _mat("bed", Color(0.42, 0.44, 0.46), 0.7, 0.3)
	_box(node, Vector3(9.0, 0.45, 1.3), Vector3(0.0, 0.85, 0.0), dark)                 # chassis
	_box(node, Vector3(2.0, 2.0, 2.45), Vector3(3.6, 1.9, 0.0), cab)                   # cab
	_box(node, Vector3(0.9, 0.9, 2.3), Vector3(4.2, 2.4, 0.0), _mat("glass", Color(0.12, 0.17, 0.2, 1.0), 0.1, 0.4))
	_box(node, Vector3(2.05, 0.1, 2.5), Vector3(3.6, 2.95, 0.0), _mat("roof", Color(0.95, 0.95, 0.95), 0.5))
	_box(node, Vector3(5.6, 0.2, 2.5), Vector3(-1.65, 1.15, 0.0), bed)                 # flatbed
	for z in [-1.2, 1.2]:
		_box(node, Vector3(5.6, 0.12, 0.08), Vector3(-1.65, 1.27, z), _mat("stripe", Color(1.0, 0.8, 0.1)))
	_beacon(node, Vector3(3.6, 3.12, 0.8), beacons)
	_beacon(node, Vector3(3.6, 3.12, -0.8), beacons)
	_beacon(node, Vector3(-4.4, 1.45, 1.1), beacons)
	_beacon(node, Vector3(-4.4, 1.45, -1.1), beacons)
	for x in [3.6, 0.2, -1.4, -3.4]:
		_wheel(node, 0.55, 0.45, Vector3(x, 0.55, 1.15), wheels)
		_wheel(node, 0.55, 0.45, Vector3(x, 0.55, -1.15), wheels)
	# Outrigger legs (slide out sideways when lifting).
	var legs := []
	for x in [1.8, -4.0]:
		for side in [1.0, -1.0]:
			var leg := Node3D.new()
			leg.position = Vector3(x, 0.0, side * 1.25)
			node.add_child(leg)
			_box(leg, Vector3(0.35, 0.3, 1.2), Vector3(0.0, 0.85, -side * 0.5), yellow)
			_box(leg, Vector3(0.6, 0.12, 0.6), Vector3(0.0, 0.06, 0.0), dark)
			_box(leg, Vector3(0.2, 0.85, 0.2), Vector3(0.0, 0.45, 0.0), yellow)
			legs.append([leg, side])
	# Turret: turns to face the boom.
	var turret := Node3D.new()
	turret.position = Vector3(CRANE_PIVOT, 1.25, 0.0)
	node.add_child(turret)
	_cyl(turret, 1.0, 0.45, Vector3(0, 0.2, 0), yellow, false)
	_box(turret, Vector3(1.6, 0.9, 1.3), Vector3(-0.3, 0.8, 0.0), yellow)
	_box(turret, Vector3(0.9, 0.7, 0.7), Vector3(0.3, 1.0, 0.75), _mat("glass", Color(0.12, 0.17, 0.2, 1.0), 0.1, 0.4))
	var boom := _unit_box(self, yellow)
	var cable := _unit_box(self, dark)
	var block := _box(self, Vector3(0.45, 0.6, 0.45), Vector3.ZERO, yellow)
	var slings := []
	for k in 4:
		slings.append(_unit_box(self, _mat("strap", Color(1.0, 0.75, 0.0), 0.6)))
	for extra in [boom, cable, block] + slings:
		node.tree_exiting.connect((extra as Node).queue_free)
	return {"node": node, "kind": "crane", "wheels": wheels, "beacons": beacons, "legs": legs,
		"turret": turret, "boom": boom, "cable": cable, "block": block, "slings": slings}
