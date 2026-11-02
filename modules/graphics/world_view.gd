class_name WorldView
extends Node3D
## The 3D world for a race: track, trackside, cars, sun, sky and the camera.
## The race scene keeps its camera maths in 2D (centre in metres, zoom in
## pixels per metre like Camera2D.zoom, rotation) and passes them to
## set_camera; WorldView turns that into a 3D camera looking down, so the
## picture lines up with the old 2D view at every zoom.
##
## Everything is real 3D at every zoom (no icons). Small car parts hide when
## far away and trees use simpler meshes in the distance.
##
## Effects: tyre smoke and rubber marks (SkidMarks), bits flying off cars in
## crashes and sparks (Debris, impact), and the pit crews who do each stop
## (PitCrews, add_pit_crew / set_pit_stop).

var track: TrackData
var env: SimEnvironment
var track_view: TrackView
var trackside: Trackside
var skid_marks: SkidMarks
var debris: Debris
var pit_crews: PitCrews          ## null on a dedicated server or a track without a pit lane
var cars: Array[CarView] = []
var safety_car: CarView           ## made on first use
var driving_line: DrivingLineView ## the driving line aid (add_driving_aids)
var brake_boards: BrakeBoards
var rejoin_marker: RejoinMarker  ## where a pit stop rejoins (made on first use)
var _sc_state: CarState
var camera: Camera3D
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var _sky_mat: ProceduralSkyMaterial
var _cam_dist := 100.0


func setup(p_track: TrackData, p_env: SimEnvironment = null) -> void:
	track = p_track
	env = p_env
	track_view = TrackView.new()
	track_view.name = "Track"
	add_child(track_view)
	track_view.setup(track, env)
	trackside = Trackside.new()
	trackside.name = "Trackside"
	add_child(trackside)
	if DisplayServer.get_name() != "headless":   # a dedicated server draws nothing
		trackside.setup(track_view)
	skid_marks = SkidMarks.new()
	add_child(skid_marks)
	skid_marks.setup(track_view.bounds)
	debris = Debris.new()
	debris.ground = track_view.surface_height
	add_child(debris)
	if DisplayServer.get_name() != "headless" and track.has_pit_lane():
		pit_crews = PitCrews.new()
		add_child(pit_crews)
		pit_crews.setup(track_view)
	_build_environment()
	camera = Camera3D.new()
	camera.fov = GfxSettings.fov_deg
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	add_child(camera)
	camera.make_current()
	if env:
		var rain := WeatherView.new()
		rain.name = "Rain"
		add_child(rain)
		rain.setup(env)
	_apply_conditions()


## Driving aids from Settings > Gameplay: the driving line (show_line) with
## braking colours (show_brake), plus the brake marker boards, which are
## always there. line: DrivingLine for the player's car. Call once after setup.
func add_driving_aids(line: DrivingLine, show_line: bool, show_brake: bool) -> void:
	brake_boards = BrakeBoards.new()
	brake_boards.name = "BrakeBoards"
	add_child(brake_boards)
	brake_boards.setup(line, track_view)
	driving_line = DrivingLineView.new()
	driving_line.name = "DrivingLineAid"
	add_child(driving_line)
	driving_line.setup(line, track_view, show_line, show_brake)


## Every frame: the player's car for the driving line colours.
func update_driving_line(pos: Vector2, speed: float) -> void:
	if driving_line:
		driving_line.update(pos, speed)


## The band on the circuit where our car would rejoin after a clean pit
## stop (see RejoinMarker): track metres s, back / front metres of band
## behind / ahead of it, colour, metres past the track edges. show = false hides it.
func set_rejoin(show: bool, s := 0.0, back := 30.0, front := 15.0, col := Color(0.4, 1.0, 0.5), widen := 0.0) -> void:
	if rejoin_marker == null:
		if not show:
			return
		rejoin_marker = RejoinMarker.new()
		rejoin_marker.name = "RejoinMarker"
		add_child(rejoin_marker)
		rejoin_marker.setup(track_view)
	rejoin_marker.show_at(show, s, back, front, col, widen)


## Adds a car. number = race number on the roof (0 = none); livery
## overrides the car's default ({"pattern", "primary", "secondary", "accent"}).
func add_car(def: CarDefinition, state: CarState, label: String, is_local: bool, number := 0, livery := {}) -> CarView:
	var v := CarView.new()
	v.setup(def, state, label, is_local, number, livery)
	v.set_environment(env)
	v.ground = track_view.surface_height
	v.ground_normal = track_view.surface_normal
	v.terrain = track_view.terrain_mesh_height
	v.marks = skid_marks
	v.debris = debris
	add_child(v)
	cars.append(v)
	return v


## The safety car (Mercedes-AMG GT Black Series with a roof light bar).
## pos/heading as CarState, speed in m/s, lights "off", "amber" or "green".
## Call every frame from race_control.sc_visible / sc_pos / sc_heading /
## sc_speed / sc_lights.
func set_safety_car(p_visible: bool, pos: Vector2, p_heading: float, speed: float, lights: String) -> void:
	if safety_car == null:
		if not p_visible:
			return
		var def := CarCatalog.load_safety_car()
		if def == null:
			return
		_sc_state = CarState.new()
		safety_car = CarView.new()
		safety_car.setup(def, _sc_state, "Safety car", false)
		safety_car.set_environment(env)
		safety_car.ground = track_view.surface_height
		safety_car.ground_normal = track_view.surface_normal
		add_child(safety_car)
		safety_car.add_roof_text("SAFETY\nCAR")
	safety_car.visible = p_visible
	if not p_visible:
		return
	_sc_state.track_idx = track_view.nearest_index(pos)
	_sc_state.pos = pos
	_sc_state.heading = p_heading
	_sc_state.vel = Vector2.from_angle(p_heading) * speed
	safety_car.set_light_bar(lights)


## Car i's team crew at pit box `box` (the race's box for that car), in the
## car's colours. Call once per car after add_car, then fill_pit_lane.
func add_pit_crew(i: int, box: int) -> void:
	if pit_crews and i < cars.size():
		pit_crews.add_team(i, box, cars[i].paint_colour(), cars[i].def)


## People in every other garage too, so the pit lane is busy.
func fill_pit_lane() -> void:
	if pit_crews:
		pit_crews.fill_garages()


## What car i's pit stop is doing (PitCrews.Stop: NONE, COMING = boxing this
## lap and in the lane, SERVICE = stopped in the box, LEAVING), seconds since
## it stopped, and the work {tyre_s, fuel_s, repair_s, total_s}.
func set_pit_stop(i: int, state: int, elapsed := 0.0, work := {}) -> void:
	if pit_crews:
		pit_crews.set_stop(i, state, elapsed, work)


var _impacts: Array = []   ## [pos, time] of recent impacts, to thin out repeats


## A hit at pos (2D metres): sparks, and chips of carbon if hard enough.
## vel = the cars' velocity (m/s, 2D), strength 0..1+ (about 1 = a big hit).
func impact(pos: Vector2, vel: Vector2, strength: float, sparks := true) -> void:
	var now := Time.get_ticks_msec() * 0.001
	for k in range(_impacts.size() - 1, -1, -1):
		if now - float(_impacts[k][1]) > 0.25:
			_impacts.remove_at(k)
		elif (_impacts[k][0] as Vector2).distance_to(pos) < 4.0:
			return
	_impacts.append([pos, now])
	var p := Vector3(pos.x, track_view.surface_height(pos) + 0.3, pos.y)
	var v := Vector3(vel.x, 0.0, vel.y)
	if strength > 0.35:
		debris.burst(p, v, clampi(int(strength * 6.0), 1, 8), Color(0.08, 0.08, 0.09), clampf(strength, 0.3, 1.2))
	elif sparks:
		debris.sparks(p, v, strength)


## Every car's paint for a race: car_ids[i], the paint each car's player chose
## (own[i], {} = the model's livery) and whether a person races it
## (players[i]). Depends only on these, so every machine in an online race
## paints the field the same. A player's own scheme wins; when a model is in
## the field more than once, players' cars keep the model's livery first and
## the others get their own colour schemes (livery_variant).
static func field_liveries(car_ids: Array, own: Array, players: Array) -> Array:
	var out := []
	out.resize(car_ids.size())
	var order := []
	for pass_players in [true, false]:
		for i in car_ids.size():
			if bool(players[i]) == pass_players:
				order.append(i)
	var seen := {}
	for i in order:
		if own[i] is Dictionary and not (own[i] as Dictionary).is_empty():
			out[i] = own[i]
			continue
		var id := str(car_ids[i])
		var k: int = seen.get(id, 0)
		seen[id] = k + 1
		out[i] = livery_variant(k, id)
	return out


## A different colour scheme for the k-th car of the same model in a field,
## so identical cars can be told apart (k = 0 keeps the car's own livery).
## car_id spreads the schemes so different models don't share the same
## second, third... schemes.
static func livery_variant(k: int, car_id := "") -> Dictionary:
	if k <= 0:
		return {}
	var schemes := [
		{"pattern": "split", "primary": "#f2f2f2", "secondary": "#0b3d91", "accent": "#e10600"},
		{"pattern": "stripes", "primary": "#111111", "secondary": "#ffd100", "accent": "#ffd100"},
		{"pattern": "sash", "primary": "#0a7d3b", "secondary": "#ffffff", "accent": "#111111"},
		{"pattern": "chevron", "primary": "#5b2c83", "secondary": "#ff8c00", "accent": "#ffffff"},
		{"pattern": "halves", "primary": "#87ceeb", "secondary": "#ff7f00", "accent": "#111111"},
		{"pattern": "stripes", "primary": "#b00020", "secondary": "#ffffff", "accent": "#111111"},
		{"pattern": "split", "primary": "#ffd100", "secondary": "#111111", "accent": "#ffffff"},
		{"pattern": "sash", "primary": "#1e90ff", "secondary": "#f2f2f2", "accent": "#ff1493"},
		{"pattern": "chevron", "primary": "#f2f2f2", "secondary": "#00a19b", "accent": "#111111"},
		{"pattern": "halves", "primary": "#ff5a00", "secondary": "#1d1d1d", "accent": "#ffffff"},
		{"pattern": "split", "primary": "#2b2b2b", "secondary": "#c6ff00", "accent": "#ffffff"},
		{"pattern": "sash", "primary": "#c9a646", "secondary": "#111111", "accent": "#ffffff"},
		{"pattern": "stripes", "primary": "#ec407a", "secondary": "#ffffff", "accent": "#1a237e"},
		{"pattern": "bmw", "primary": "#f2f2f2", "secondary": "#14213d", "accent": "#fca311"},
		{"pattern": "halves", "primary": "#00838f", "secondary": "#e3f2fd", "accent": "#111111"},
		{"pattern": "chevron", "primary": "#7f0000", "secondary": "#ffd100", "accent": "#111111"},
	]
	var off := 0 if car_id == "" else absi(hash(car_id)) % schemes.size()
	return schemes[(k - 1 + off) % schemes.size()]


## centre: point of the track in the middle of the screen (2D metres).
## zoom: pixels per metre (as Camera2D.zoom.x), rotation: screen rotation
## (radians, as Camera2D.rotation; 0 = north up).
func set_camera(centre: Vector2, zoom: float, rotation_rad := 0.0) -> void:
	if camera == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var view_h := vp.y / maxf(zoom, 1e-4)                  # metres top to bottom
	var half_fov := deg_to_rad(GfxSettings.fov_deg) * 0.5
	_cam_dist = view_h * 0.5 / tan(half_fov)
	var ground_y := track_view.terrain_height(centre)
	var target := Vector3(centre.x, ground_y, centre.y)
	# Screen "up" in the 2D view is -Y (2D) = -Z (3D), turned by rotation.
	var up := Vector3(sin(rotation_rad), 0.0, -cos(rotation_rad))
	var tilt := deg_to_rad(clampf(GfxSettings.tilt_deg, 0.0, 30.0))
	var dir := (Vector3.UP * cos(tilt) - up * sin(tilt)).normalized()
	camera.look_at_from_position(target + dir * _cam_dist, target, up)
	camera.near = clampf(_cam_dist * 0.02, 0.5, 200.0)
	camera.far = _cam_dist * 3.0 + 4000.0
	if sun:
		sun.directional_shadow_max_distance = clampf(_cam_dist * 2.2, 150.0, 12000.0)
	if pit_crews:
		pit_crews.set_camera(centre, _cam_dist)
	var hk := _cam_dist / 60.0
	for v in cars:
		if v.highlight != CarView.Highlight.NONE:
			v.set_highlight_zoom(hk)


func _process(_delta: float) -> void:
	_apply_conditions()
	if pit_crews:
		for i in cars.size():
			pit_crews.set_car_pose(i, cars[i].pos2, cars[i].heading)
			cars[i].pit_lift = pit_crews.car_lift(i)
			cars[i].wheels_off_mask = pit_crews.wheels_off_mask(i)


# --- Sun, sky and post-processing -------------------------------------------------

func _build_environment() -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = GfxSettings.sun_shadows
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_blur = 1.5
	sun.light_angular_distance = 0.5
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	add_child(sun)
	_sky_mat = ProceduralSkyMaterial.new()
	_sky_mat.sky_top_color = Color(0.32, 0.5, 0.78)
	_sky_mat.sky_horizon_color = Color(0.68, 0.75, 0.84)
	_sky_mat.ground_horizon_color = Color(0.6, 0.62, 0.6)
	_sky_mat.ground_bottom_color = Color(0.25, 0.28, 0.22)
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 1.0
	e.ambient_light_energy = 0.75
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_exposure = 1.0
	e.ssao_enabled = GfxSettings.ssao
	e.ssao_radius = 1.2
	e.ssao_intensity = 1.6
	e.ssao_power = 1.4
	e.glow_enabled = GfxSettings.glow
	e.glow_intensity = 0.5
	e.glow_bloom = 0.02
	e.glow_hdr_threshold = 1.4
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.08
	e.adjustment_contrast = 1.04
	world_env = WorldEnvironment.new()
	world_env.environment = e
	add_child(world_env)


## Sun position and colour from the time of day; clouds, rain and night
## dim it; the road gets darker and shinier as it gets wet.
func _apply_conditions() -> void:
	var h := env.time_of_day_h if env else 14.0
	var cloud := env.cloud if env else 0.1
	var rain := env.rain if env else 0.0
	var dark := env.darkness() if env else 0.0
	# Sun arc: rises in the east (+X) at 06:00, sets in the west at 19:00.
	var day := clampf((h - 6.0) / 13.0, 0.0, 1.0)
	var elev := deg_to_rad(maxf(GfxSettings.sun_max_elevation_deg * sin(PI * day), 6.0))
	var az := lerpf(deg_to_rad(100.0), deg_to_rad(260.0), day)
	var to_sun := Vector3(cos(az) * cos(elev), sin(elev), sin(az) * cos(elev))
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)
	var low := clampf(1.0 - sin(elev) / 0.5, 0.0, 1.0)
	var col := Color(1.0, 0.97, 0.92).lerp(Color(1.0, 0.78, 0.55), low * 0.6)
	sun.light_color = col
	sun.light_energy = lerpf(1.25, 0.25, cloud * 0.8 + rain * 0.2) * (1.0 - dark * 0.92)
	sun.shadow_opacity = lerpf(1.0, 0.25, cloud)
	var e := world_env.environment
	e.ambient_light_energy = lerpf(0.55, 0.5, cloud) * (1.0 - dark * 0.75) + 0.05
	_sky_mat.sky_top_color = Color(0.42, 0.55, 0.74).lerp(Color(0.55, 0.58, 0.62), cloud).lerp(Color(0.03, 0.04, 0.09), dark)
	_sky_mat.sky_horizon_color = Color(0.72, 0.74, 0.76).lerp(Color(0.66, 0.68, 0.7), cloud).lerp(Color(0.06, 0.07, 0.12), dark)
	_sky_mat.sky_energy_multiplier = 1.0 - dark * 0.85
	e.ssr_enabled = env != null and env.wetness > 0.2
	if env:
		track_view.set_conditions(env.wetness, env.dry_line)
	track_view.set_light_dir(to_sun)
