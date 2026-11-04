extends Node
## How many pieces one car is drawn with: mesh instances, surfaces (each a
## draw call), shadow casters and triangles, per car model.
##   godot --headless --path . res://tests/car_cost_probe.tscn -- [car ids...]

func _ready() -> void:
	var ids: Array = Array(OS.get_cmdline_user_args())
	if ids.is_empty():
		ids = ["bmw_m4_gt3", "porsche_963", "ferrari_296_gt3"]
	for id in ids:
		if not GameData.cars.has(id):
			print("[car] no car %s" % id)
			continue
		var d: CarDefinition = GameData.cars[id]
		var v := CarView.new()
		v.setup(d, CarState.new(), "X", false, 7)
		add_child(v)
		var st := {"mi": 0, "surf": 0, "shadow": 0, "tris": 0, "other": 0}
		var names := []
		_count(v, st, names)
		print("[car] %s: %d mesh instances, %d surfaces (draws), %d shadow-casting surfaces, %dk triangles, %d other visuals" % [id, st["mi"], st["surf"], st["shadow"], st["tris"] / 1000, st["other"]])
		print("[car]   ", ", ".join(names))
		v.queue_free()
	get_tree().quit()


func _count(n: Node, st: Dictionary, names: Array) -> void:
	for c in n.get_children():
		_count(c, st, names)
	if n is MeshInstance3D and (n as MeshInstance3D).mesh and (n as MeshInstance3D).is_visible_in_tree():
		var mi := n as MeshInstance3D
		var sc := mi.mesh.get_surface_count()
		st["mi"] += 1
		st["surf"] += sc
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			st["shadow"] += sc
		var tris := 0
		for s in sc:
			var arr := mi.mesh.surface_get_arrays(s) if not (mi.mesh is PrimitiveMesh) else []
			if arr.size() > 0:
				var idx = arr[Mesh.ARRAY_INDEX]
				tris += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
		st["tris"] += tris
		names.append("%s(%d%s)" % [mi.name, sc, "" if mi.cast_shadow else ",ns"])
	elif n is GeometryInstance3D and (n as Node3D).is_visible_in_tree():
		st["other"] += 1
