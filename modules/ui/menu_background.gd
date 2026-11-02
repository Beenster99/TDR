class_name MenuBackground
extends Control
## Behind the main menu: a loop of race highlights filmed in the game
## (media/highlights.ogv, made by tools/record_highlights.sh), darkened on
## the left where the menu sits. Falls back to the key art when the video is
## switched off (Settings > Graphics > Menu background), missing, or the game
## runs headless.

const VIDEO := "res://modules/ui/media/highlights.ogv"
const STILL := "res://modules/ui/media/splash.jpg"

var _video: VideoStreamPlayer


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.055, 0.06)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_fill()
	_add_shade()
	GameData.pref_changed.connect(_on_pref)


func _on_pref(key: String, _v) -> void:
	if key == "menu_video":
		for c in get_children():
			c.queue_free()
		_ready.call_deferred()
		GameData.pref_changed.disconnect(_on_pref)


func _fill() -> void:
	var want_video := bool(GameData.prefs.get("menu_video", true)) and DisplayServer.get_name() != "headless"
	if want_video and ResourceLoader.exists(VIDEO):
		var stream = load(VIDEO)
		if stream is VideoStream:
			_video = VideoStreamPlayer.new()
			_video.stream = stream
			_video.expand = true
			_video.volume_db = -80.0
			_video.loop = true
			_video.mouse_filter = MOUSE_FILTER_IGNORE
			add_child(_video)
			_video.finished.connect(_video.play)
			_cover.call_deferred()
			resized.connect(_cover)
			_video.play()
			return
	var still := TextureRect.new()
	still.texture = load(STILL)
	still.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	still.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	still.modulate = Color(0.75, 0.75, 0.75)
	still.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(still)
	still.set_anchors_and_offsets_preset(PRESET_FULL_RECT)


## Scales the video to cover the window (cropping, never letterboxing).
func _cover() -> void:
	if _video == null or _video.get_video_texture() == null:
		return
	var vs := Vector2(_video.get_video_texture().get_size())
	if vs.x <= 0 or vs.y <= 0:
		return
	var k := maxf(size.x / vs.x, size.y / vs.y)
	_video.size = vs * k
	_video.position = (size - vs * k) * 0.5


func _add_shade() -> void:
	# Dark on the left (menu), clear on the right (the racing), a touch of
	# darkening top and bottom.
	for spec in [[Vector2(0, 0), Vector2(1, 0), Color(0.02, 0.025, 0.03, 0.9), Color(0.02, 0.025, 0.03, 0.05), 0.0, 0.62],
			[Vector2(0, 0), Vector2(0, 1), Color(0, 0, 0, 0.45), Color(0, 0, 0, 0.0), 0.0, 0.22],
			[Vector2(0, 1), Vector2(0, 0), Color(0, 0, 0, 0.55), Color(0, 0, 0, 0.0), 0.0, 0.25]]:
		var g := Gradient.new()
		g.set_color(0, spec[2])
		g.set_color(1, spec[3])
		g.set_offset(0, spec[4])
		g.set_offset(1, spec[5])
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill_from = spec[0]
		gt.fill_to = spec[1]
		gt.width = 256
		gt.height = 256
		var t := TextureRect.new()
		t.texture = gt
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.mouse_filter = MOUSE_FILTER_IGNORE
		add_child(t)
		t.set_anchors_and_offsets_preset(PRESET_FULL_RECT)


func _process(_dt: float) -> void:
	if _video and _video.size.x < size.x - 1.0:
		_cover()
