class_name SplashScreen
extends Control
## Intro screen: the key art, the title, and a GT3 car flat out past the
## camera. Any key, button or click skips it; it moves on by itself after a
## few seconds. Skipped straight away when the game is started with command
## line options (test bots, servers), headless, or with Settings > Debug >
## Intro screen set to Skip. Also applies the saved settings for the session.

const ART := "res://modules/ui/media/splash.jpg"
const HOLD_S := 6.5

var _leaving := false
var _art: TextureRect
var _title: Control
var _prompt: Label
var _t := 0.0


func _ready() -> void:
	SettingsRuntime.ensure(get_tree())
	var automation := GameData.args.keys().any(func(k): return not k in ["profile", "settings", "splash-shot"])
	if automation or DisplayServer.get_name() == "headless" or bool(GameData.prefs.get("skip_splash", false)):
		_go.call_deferred()
		return
	_build()
	modulate = Color(1, 1, 1, 0)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.7)
	if bool(GameData.prefs.get("splash_sound", true)):
		get_tree().create_timer(0.35).timeout.connect(func(): Sound.passby(2.0))
	if GameData.arg("splash-shot"):   # screenshots for the release notes
		get_tree().create_timer(2.5).timeout.connect(func():
			get_viewport().get_texture().get_image().save_png(str(GameData.arg("splash-shot")))
			get_tree().quit())
		return
	get_tree().create_timer(HOLD_S).timeout.connect(_leave)


func _build() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	add_child(bg)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_art = TextureRect.new()
	_art.texture = load(ART)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	add_child(_art)
	_art.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_art.pivot_offset = Vector2(800, 450)
	# Darken the bottom so the title reads.
	var shade := TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0, 0, 0, 0.85))
	g.set_offset(0, 0.45)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	shade.texture = gt
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(shade)
	shade.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.anchor_left = 0.0
	box.anchor_right = 1.0
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 80
	box.offset_top = -230
	box.offset_bottom = -50
	box.add_theme_constant_override("separation", 2)
	add_child(box)
	_title = box
	var title := Label.new()
	title.text = "TOP DOWN RACER"
	title.add_theme_font_override("font", title_font())
	title.add_theme_font_size_override("font_size", 86)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	title.add_theme_constant_override("outline_size", 10)
	box.add_child(title)
	var stripe := ColorRect.new()
	stripe.color = Color(0.94, 0.26, 0.2)
	stripe.custom_minimum_size = Vector2(420, 6)
	stripe.size_flags_horizontal = SIZE_SHRINK_BEGIN
	box.add_child(stripe)
	var tag := Label.new()
	tag.text = "Drive it. Run the pit wall. Win the race."
	tag.add_theme_font_size_override("font_size", 24)
	tag.modulate = Color(1, 1, 1, 0.85)
	box.add_child(tag)
	_prompt = Label.new()
	InputPrompt.live(_prompt, func(): _prompt.text = InputPrompt.pick("Press any key", "Press any button"))
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_prompt)


## The heavy italic face used for big titles (the menu uses it too).
static func title_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Arial Black", "Helvetica Neue", "Segoe UI", "Arial", "Liberation Sans", "DejaVu Sans"])
	f.font_weight = 900
	f.font_italic = true
	return f


func _process(delta: float) -> void:
	_t += delta
	if _art:
		# A slow push in on the key art.
		_art.scale = Vector2.ONE * (1.0 + 0.035 * minf(_t / HOLD_S, 1.0))
		_art.pivot_offset = _art.size * 0.5
	if _prompt:
		_prompt.modulate.a = 0.35 + 0.3 * sin(_t * 3.0)


func _input(event: InputEvent) -> void:
	var pressed := (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton) \
		and event.is_pressed() and not event.is_echo()
	if pressed and _t > 0.3:
		get_viewport().set_input_as_handled()
		_leave()


func _leave() -> void:
	if _leaving:
		return
	_leaving = true
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.45)
	tw.tween_callback(_go)


func _go() -> void:
	get_tree().change_scene_to_file(GameData.SCENE_MENU)
