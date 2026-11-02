extends SceneTree
## Compares each car model's footprint (seen from above, in car space with the
## CG at the origin) with the physics capsule used for car-to-car contact.
##   godot --headless --path . -s tests/hitbox_probe.gd

func _init() -> void:
	var dir := DirAccess.open("res://modules/cars/data")
	for f in dir.get_files():
		if not f.ends_with(".json") or f.begins_with("_"):
			continue
		var d = JSON.parse_string(FileAccess.get_file_as_string("res://modules/cars/data/" + f))
		if not (d is Dictionary) or not d.has("length_m"):
			continue
		var def := CarDefinition.from_dict(d)
		var path := "res://modules/graphics/cars/%s.glb" % def.id
		if not ResourceLoader.exists(path):
			print("%-26s no model" % def.id)
			continue
		var root: Node3D = (load(path) as PackedScene).instantiate()
		var box := AABB()
		var first := true
		for n in _meshes(root):
			var mi := n as MeshInstance3D
			if not (str(mi.name) in ["body", "bumper_front", "bumper_rear", "cabin"]):
				continue
			var aabb := _xform(mi) * mi.get_aabb()
			box = aabb if first else box.merge(aabb)
			first = false
		root.free()
		print("%-26s model x[%.2f..%.2f] z[%.2f..%.2f] len %.2f wid %.2f | capsule len %.2f wid %.2f offset %.2f | model centre x %.2f" % [
			def.id, box.position.x, box.end.x, box.position.z, box.end.z, box.size.x, box.size.z,
			def.length, def.width, def.body_offset, box.get_center().x])
	quit()


func _meshes(n: Node) -> Array:
	var out := []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _xform(n: Node3D) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t
