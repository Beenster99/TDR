class_name CarPreview
extends SubViewportContainer
## A car turning slowly on a lit stand, in its livery: the garage's stage and
## the car picker on the race setup pages. show_car() swaps the car; the 3D
## view only renders while it's on screen.

var spin_speed := 0.35            ## radians per second
var _viewport: SubViewport
var _stand: Node3D
var _cam: Camera3D
var _view: CarView
var _state: CarState
var _spin := 0.6
var _key := ""                    ## what's on the stand (skip identical rebuilds)
var _length := 4.6


func _ready() -> void:
	resized.connect(_frame)


func _init() -> void:
	stretch = true
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.transparent_bg = false
	add_child(_viewport)
	_build_stage()


## def: the car (with any upgrade overrides applied); livery: paint, merged
## over the model's own livery.
func show_car(def: CarDefinition, livery := {}) -> void:
	if def == null:
		return
	var l := CarView.default_livery(def)
	l.merge(livery, true)
	var key := "%s|%s|%s" % [def.id, JSON.stringify(def.raw.get("visual", {})), JSON.stringify(l)]
	if key == _key:
		return
	_key = key
	if _view:
		_view.queue_free()
	_state = CarState.new()
	_state.heading = _spin
	_view = CarView.new()
	_view.setup(def, _state, "preview", true, 0, l)
	_stand.add_child(_view)
	_length = def.length
	_frame()


func _process(delta: float) -> void:
	if _state and is_visible_in_tree():
		_spin = wrapf(_spin + delta * spin_speed, -PI, PI)
		_state.heading = _spin


## A lit stand with a camera looking down at three quarters, like the race
## camera but closer.
func _build_stage() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.16, 0.2, 0.26)
	mat.sky_horizon_color = Color(0.4, 0.42, 0.45)
	mat.ground_bottom_color = Color(0.05, 0.05, 0.05)
	mat.ground_horizon_color = Color(0.3, 0.3, 0.3)
	sky.sky_material = mat
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.1, 0.11, 0.12)
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = true
	env.environment = e
	_viewport.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	_viewport.add_child(sun)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-4, 3.5, -4)
	fill.omni_range = 14
	fill.light_energy = 0.6
	_viewport.add_child(fill)
	var floor_mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 3.6
	cyl.bottom_radius = 3.7
	cyl.height = 0.06
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.17, 0.18, 0.19)
	fm.roughness = 0.6
	fm.metallic = 0.2
	cyl.material = fm
	floor_mi.mesh = cyl
	floor_mi.position.y = -0.031
	_viewport.add_child(floor_mi)
	_cam = Camera3D.new()
	_cam.fov = 27.0
	_viewport.add_child(_cam)
	_aim(Vector3(7.4, 5.6, 7.4))
	_stand = Node3D.new()
	_viewport.add_child(_stand)


## Long prototypes and short road cars both fill the frame, and a narrow
## frame moves the camera back so the car fits across it as it turns.
func _frame() -> void:
	var aspect := size.x / maxf(size.y, 1.0) if size.y > 0.0 else 1.73
	var d := clampf(_length / 4.6, 0.85, 1.25) * maxf(1.0, 1.4 / maxf(aspect, 0.3))
	_aim(Vector3(7.4, 5.6, 7.4) * d)


func _aim(pos: Vector3) -> void:
	_cam.transform = Transform3D(Basis.looking_at(Vector3(0, 0.45, 0) - pos), pos)
