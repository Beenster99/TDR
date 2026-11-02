class_name OnboardCamera
extends SubViewport
## A live onboard camera on any car, for the strategist's picture-in-picture
## window. It renders the same 3D world as the main view (WorldView's
## World3D, so cars, weather, lights and the time of day all match) through
## a second camera mounted on the car's roof, looking forward (FRONT) or
## back over the rear wing (REAR).
##
## It only draws while a screen asks for it: call show_car() every frame the
## picture is on screen, and draw `get_texture()`. A frame or two after the
## last call it stops rendering, so it costs nothing while nobody watches.
## Works the same for offline, host and client: every machine has every
## car's view.

enum View { FRONT, REAR }

const MAX_PX := Vector2i(1280, 720)   ## render size cap (a 4K screen's PiP)
const MIN_PX := Vector2i(160, 90)

var world: WorldView
var camera: Camera3D
var car := -1                 ## car index being shown
var view := View.FRONT
var _asked_frame := -100
var _on := false


func setup(p_world: WorldView) -> void:
	world = p_world
	world_3d = world.get_world_3d()
	size = Vector2i(640, 360)
	transparent_bg = false
	msaa_3d = Viewport.MSAA_2X
	screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	audio_listener_enable_3d = false
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	process_priority = 100    # after the CarViews have moved this frame
	camera = Camera3D.new()
	camera.fov = 62.0
	camera.near = 0.1
	camera.far = 2500.0
	add_child(camera)
	camera.current = true


## Shows car `i` from its front (or rear) camera. px: the picture's size on
## screen in real pixels, so it stays sharp at 4K. Call every frame it's
## on screen.
func show_car(i: int, p_view: View, px := Vector2i(640, 360)) -> void:
	if world == null or DisplayServer.get_name() == "headless":
		return
	car = i
	view = p_view
	var want := Vector2i(clampi(px.x, MIN_PX.x, MAX_PX.x), clampi(px.y, MIN_PX.y, MAX_PX.y))
	if want != size:
		size = want
	_asked_frame = Engine.get_process_frames()
	if not _on:
		_on = true
		render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_place()


## True while the picture is being drawn.
func is_live() -> bool:
	return _on


func _process(_delta: float) -> void:
	if not _on:
		return
	if Engine.get_process_frames() - _asked_frame > 2:
		_on = false
		render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	_place()


## Where the camera sits: on the roof, a little forward of the middle,
## looking along the car (or back over the wing), tipped down a touch so
## the road fills the lower part of the picture.
func _place() -> void:
	if car < 0 or car >= world.cars.size():
		return
	var cv := world.cars[car]
	var t := cv.global_transform
	var fwd := t.basis.x.normalized()
	var up := t.basis.y.normalized()
	var length := cv.def.length if cv.def else 4.6
	var look := fwd if view == View.FRONT else -fwd
	var pos := t.origin + up * 1.55 + fwd * (length * (0.06 if view == View.FRONT else -0.12))
	var dip := deg_to_rad(5.0 if view == View.FRONT else 9.0)
	var aim := (look * cos(dip) - up * sin(dip)).normalized()
	camera.look_at_from_position(pos, pos + aim * 10.0, up)
