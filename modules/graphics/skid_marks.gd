class_name SkidMarks
extends MultiMeshInstance3D
## Dark rubber laid on the road by sliding, spinning or locked tyres, and
## torn-up earth where a car slides across the grass. Each mark is a short
## flat strip from where the wheel was to where it is now, kept in a ring
## buffer (the oldest marks make way for new ones). Purely visual: the race
## never sees them.

const MAX_MARKS := 12000
const STEP_M := 0.45          ## a new strip every this many metres of travel
const LIFT_M := 0.075         ## above the road (kerbs sit at +0.06)

## What a wheel is sliding on, for the colour of its mark.
enum Kind { RUBBER, EARTH }

var _mm: MultiMesh
var _next := 0
var _used := 0
var _last := {}               ## wheel key -> Vector3 where its mark last ended


func setup(area: Rect2) -> void:
	name = "SkidMarks"
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	var pm := PlaneMesh.new()
	pm.size = Vector2(1.0, 1.0)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.roughness = 0.75
	m.albedo_texture = _streak_texture()
	pm.material = m
	_mm.mesh = pm
	_mm.instance_count = MAX_MARKS
	_mm.visible_instance_count = 0
	multimesh = _mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# One fixed box round the whole circuit, so adding a mark never makes
	# Godot re-measure thousands of instances.
	custom_aabb = AABB(Vector3(area.position.x, -2000.0, area.position.y), Vector3(area.size.x, 4000.0, area.size.y))


## A wheel at world point p (on the ground) leaving a mark this strong
## (0 = none, 1 = full lock or full slide), width in metres. Call every frame
## for every wheel that can leave marks; strength 0 lifts the wheel's "pen".
func mark(key: int, p: Vector3, strength: float, width: float, kind: int = Kind.RUBBER) -> void:
	if strength <= 0.02:
		_last.erase(key)
		return
	if not _last.has(key):
		_last[key] = p
		return
	var a: Vector3 = _last[key]
	var d := p - a
	var len := d.length()
	if len < STEP_M:
		return
	_last[key] = p
	if len > 25.0:         # jumped (respawn, snapshot correction)
		return
	var along := d / len
	var side := along.cross(Vector3.UP).normalized()
	if side.length_squared() < 0.5:
		return
	var up := side.cross(along).normalized()
	# Overlap the strips a little so the line has no gaps on curves.
	var basis := Basis(along * (len + 0.08), up, side * width)
	_mm.set_instance_transform(_next, Transform3D(basis, (a + p) * 0.5 + Vector3(0, LIFT_M, 0)))
	var col := Color(0.02, 0.02, 0.025, 0.8 * clampf(strength, 0.0, 1.0)) if kind == Kind.RUBBER \
		else Color(0.22, 0.15, 0.08, 0.7 * clampf(strength, 0.0, 1.0))
	_mm.set_instance_color(_next, col)
	_next = (_next + 1) % MAX_MARKS
	_used = mini(_used + 1, MAX_MARKS)
	_mm.visible_instance_count = _used


func count() -> int:
	return _used


## Rubber isn't a flat stripe: darker in the middle, ragged at the edges.
static func _streak_texture() -> Texture2D:
	var img := Image.create(16, 64, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in 64:
		var edge := 1.0 - absf(float(y) / 63.0 * 2.0 - 1.0)   # 0 at the sides, 1 in the middle
		for x in 16:
			var a := clampf(smoothstep(0.0, 0.3, edge) * rng.randf_range(0.7, 1.0), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
