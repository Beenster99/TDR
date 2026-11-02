class_name SettingsRuntime
extends CanvasLayer
## Applies the player's settings (GameData.prefs) to the game and keeps them
## applied: display mode, v-sync, frame rate cap, 3D resolution, anti-aliasing,
## shadows and the other looks (GfxSettings), and the audio bus volumes.
## Lives under the scene tree root for the whole session (ensure()), so it
## outlasts scene changes, and draws the debug frame rate counter.

const BUS_FOR := {"vol_master": "Master", "vol_engine": "Engine", "vol_effects": "Effects", "vol_ui": "UI"}
const SHADOW_ATLAS := [2048, 4096, 8192, 8192]
const SHADOW_SOFT := [0, 1, 2, 3]

var _fps: Label
var _fps_t := 0.0


## Adds the runtime under the root once and applies every setting.
static func ensure(tree: SceneTree) -> SettingsRuntime:
	var existing := tree.root.get_node_or_null("SettingsRuntime")
	if existing:
		return existing
	var rt := SettingsRuntime.new()
	rt.name = "SettingsRuntime"
	tree.root.add_child.call_deferred(rt)
	rt.apply_all(tree)
	return rt


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_fps = Label.new()
	_fps.position = Vector2(8, 4)
	_fps.add_theme_font_size_override("font_size", 14)
	_fps.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_fps.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps.add_theme_constant_override("outline_size", 4)
	add_child(_fps)
	GameData.pref_changed.connect(_on_pref_changed)
	_fps.visible = bool(GameData.prefs.get("show_fps", false))


func _process(delta: float) -> void:
	if not _fps.visible:
		return
	_fps_t -= delta
	if _fps_t <= 0.0:
		_fps_t = 0.5
		_fps.text = "%d fps  %.1f ms" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)]


func _on_pref_changed(key: String, _value) -> void:
	apply(get_tree(), key)
	if key == "pad_deadzone":
		InputSetup.set_deadzone(float(GameData.prefs["pad_deadzone"]) / 100.0)
	elif key == "controls" and GameData.prefs["controls"] is Dictionary:
		InputSetup.apply_bindings(GameData.prefs["controls"])
		InputSetup.set_deadzone(float(GameData.prefs.get("pad_deadzone", 12)) / 100.0)
	if key == "show_fps":
		_fps.visible = bool(GameData.prefs.get("show_fps", false))


func apply_all(tree: SceneTree) -> void:
	for e in GameData.settings_catalog:
		apply(tree, e["key"])


## Applies one setting now. Ones read when a race is built (trees) take
## effect at the next race.
static func apply(tree: SceneTree, key: String) -> void:
	var v = GameData.prefs.get(key)
	var root := tree.root
	var windowed_ok := DisplayServer.get_name() != "headless" and GameData.persist_prefs
	match key:
		"display_mode":
			if windowed_ok:
				var mode: int = {"fullscreen": DisplayServer.WINDOW_MODE_FULLSCREEN,
					"exclusive": DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN}.get(v, DisplayServer.WINDOW_MODE_WINDOWED)
				if DisplayServer.window_get_mode() != mode:
					DisplayServer.window_set_mode(mode)
		"vsync":
			if windowed_ok:
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if v else DisplayServer.VSYNC_DISABLED)
		"max_fps":
			Engine.max_fps = int(v)
		"render_scale":
			var s := clampf(float(v) / 100.0, 0.5, 1.0)
			root.scaling_3d_scale = s
			root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if s < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR
		"msaa":
			root.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_8X][clampi(int(v), 0, 3)]
		"shadows":
			var q := clampi(int(v), 0, 3)
			GfxSettings.sun_shadows = q > 0
			RenderingServer.directional_shadow_atlas_set_size(SHADOW_ATLAS[q], true)
			RenderingServer.directional_soft_shadow_filter_set_quality(SHADOW_SOFT[q])
		"ssao":
			GfxSettings.ssao = bool(v)
		"glow":
			GfxSettings.glow = bool(v)
		"trees":
			GfxSettings.trees = float(v)
		"real_scenery":
			GfxSettings.real_scenery = bool(v)
		"camera_tilt":
			GfxSettings.tilt_deg = float(v)
		_:
			if BUS_FOR.has(key):
				var bus := _bus(BUS_FOR[key])
				var lin := clampf(float(v) / 100.0, 0.0, 1.0)
				AudioServer.set_bus_volume_db(bus, linear_to_db(lin) + (-6.0 if key == "vol_ui" else 0.0))
				AudioServer.set_bus_mute(bus, lin <= 0.001)


## The index of an audio bus, made (sending to Master) if it isn't there yet.
static func _bus(bus_name: String) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	return idx
