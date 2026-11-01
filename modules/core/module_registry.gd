class_name ModuleRegistry
extends RefCounted
## The game's modules (modules/<id>/module.json): what each one is, its
## version, what it depends on and its public API. See docs/MODULES.md.
##
## Version rules (semantic versioning, "major.minor.patch"):
##   patch - fixes, no API change
##   minor - API added, nothing removed or changed
##   major - API removed or changed; every module that depends on it must be
##           checked and its "depends" entry updated to the new major
## A module's "depends" maps each module it uses to the major version it was
## written against, e.g. {"cars": "1"}.

const ROOT := "res://modules"


## module id -> manifest Dictionary
static func load_all() -> Dictionary:
	var out := {}
	var dirs := DirAccess.get_directories_at(ROOT)
	dirs.sort()
	for dir in dirs:
		var m = JsonData.load_json("%s/%s/module.json" % [ROOT, dir])
		if m is Dictionary:
			out[m.get("id", dir)] = m
	return out


static func major(version: String) -> String:
	return version.split(".")[0]


## Problems with the manifests themselves: unknown or wrong-version
## dependencies, and dependency cycles. Empty when all is well.
static func check(mods: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	for id in mods:
		var deps: Dictionary = mods[id].get("depends", {})
		for dep in deps:
			if not mods.has(dep):
				problems.append("%s depends on unknown module %s" % [id, dep])
			elif major(mods[dep]["version"]) != str(deps[dep]):
				problems.append("%s was written for %s %s.x, but %s is now %s" % [
					id, dep, deps[dep], dep, mods[dep]["version"]])
	for id in mods:
		var cycle := _find_cycle(mods, id, [id])
		if not cycle.is_empty():
			problems.append("dependency cycle: %s" % " -> ".join(cycle))
			break
	return problems


static func _find_cycle(mods: Dictionary, id: String, path: Array) -> Array:
	for dep in mods.get(id, {}).get("depends", {}):
		if dep == path[0]:
			return path + [dep]
		if dep in path or not mods.has(dep):
			continue
		var c := _find_cycle(mods, dep, path + [dep])
		if not c.is_empty():
			return c
	return []


## Modules in build order: each one after everything it depends on.
static func ordered(mods: Dictionary) -> Array:
	var out := []
	var ids := mods.keys()
	ids.sort()
	while out.size() < ids.size():
		var added := false
		for id in ids:
			if id in out:
				continue
			var ready := true
			for dep in mods[id].get("depends", {}):
				if mods.has(dep) and not dep in out:
					ready = false
			if ready:
				out.append(id)
				added = true
		if not added:
			break  # cycle; check() reports it
	return out
