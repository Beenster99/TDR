class_name RejoinMarker
extends Node3D
## A glowing band across the circuit where our car would come back out after
## a clean pit stop: the stretch of track whose traffic will be passing the
## pit exit as the car leaves the lane. It slides along to the pit exit as
## the stop goes on. Green: clear air; amber: a car close by; red: right in
## the middle of someone. The race scene feeds it (PitRules.rejoin_estimate).

const SEGMENTS := 18
const LIFT := 0.12             ## above the road and the driving line
const EDGE := 0.6              ## metres of brighter edge at each end of the band

var track_view: TrackView
var track: TrackData
var _mesh := ImmediateMesh.new()
var _mat := StandardMaterial3D.new()
var _mi := MeshInstance3D.new()
var _last := Vector4(-1, -1, -1, -1)
var _widen := 0.0


func setup(tv: TrackView) -> void:
	track_view = tv
	track = tv.track
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.vertex_color_use_as_albedo = true
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.no_depth_test = false
	_mat.render_priority = 2
	_mi.mesh = _mesh
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)
	visible = false


## Shows the band from track metres s - back to s + front in this colour,
## or hides it (show = false). widen: metres past each track edge (so it
## still reads when the camera is far out).
func show_at(show: bool, s: float = 0.0, back: float = 30.0, front: float = 15.0, col: Color = Color(0.4, 1.0, 0.5), widen := 0.0) -> void:
	visible = show
	if not show:
		return
	_mat.albedo_color = Color(1, 1, 1, 1)
	var key := Vector4(snappedf(s, 0.5), snappedf(back + front, 1.0), col.r * 10.0 + col.g, snappedf(widen, 1.0))
	if key == _last:
		return
	_last = key
	_widen = widen
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var from := s - back
	var span := back + front
	for k in SEGMENTS:
		var s0 := from + span * k / SEGMENTS
		var s1 := from + span * (k + 1) / SEGMENTS
		# Fades in from behind, solid at the front edge (the direction of travel).
		var a0 := lerpf(0.3, 0.75, float(k) / SEGMENTS)
		var a1 := lerpf(0.3, 0.75, float(k + 1) / SEGMENTS)
		_strip(s0, s1, Color(col, a0), Color(col, a1))
	# A bright line at the front edge.
	var edge := maxf(EDGE, (back + front) * 0.06)
	_strip(s + front - edge, s + front, Color(col.lightened(0.5), 1.0), Color(col.lightened(0.5), 1.0))
	_mesh.surface_end()


func _strip(s0: float, s1: float, c0: Color, c1: Color) -> void:
	var i0 := track.index_at(s0)
	var i1 := track.index_at(s1)
	var l0 := -track.width_left[i0] - _widen
	var r0 := track.width_right[i0] + _widen
	var l1 := -track.width_left[i1] - _widen
	var r1 := track.width_right[i1] + _widen
	var a := _v(s0, l0)
	var b := _v(s0, r0)
	var c := _v(s1, l1)
	var d := _v(s1, r1)
	for v in [[a, c0], [b, c0], [c, c1], [b, c0], [d, c1], [c, c1]]:
		_mesh.surface_set_color(v[1])
		_mesh.surface_add_vertex(v[0])


func _v(s: float, off: float) -> Vector3:
	var p := track.position_at(s, off)
	var y := track_view.height(s, off) if track_view.has_elevation() else 0.0
	return Vector3(p.x, y + LIFT, p.y)
