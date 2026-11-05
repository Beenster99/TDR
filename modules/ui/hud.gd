class_name RaceHud
extends Control
## Race HUD drawn immediate-mode: timing, standings, tyre temps, speed/gear,
## minimap and countdown. Reads the session's sim every frame.
##
## Every item (ITEMS) can be moved, resized, hidden and brought back by the
## driver in the HUD layout editor (HudEditor: F2 in a race, or Settings >
## Gameplay > Edit HUD layout), saved in GameData.prefs["hud_layout"]
## (HudLayout). Each item draws itself from (0, 0) in its own box; the HUD
## places and scales that box.

var session: RaceSession
var message := ""
var message_time := 0.0
var font: Font
var _minimap_pts := PackedVector2Array()
var _mm_rect := Rect2()
## Damage last seen on the player's car, to flash a warning when it changes.
var _seen_worst := 0.0
var _seen_punctures := 0
var _seen_engine_failed := false
## Timing tower (left column): position, badge, driver, last lap, gap to the
## car ahead. On/off is the player's choice, GameData.prefs["hud_timing_tower"]
## (Settings > Gameplay, or H in a race).
const PREF_TOWER := "hud_timing_tower"
const TOWER_W := 352.0
const TOWER_ROW := 24.0
## How long a finished lap's sectors stay up before the next lap's go live.
const LAP_HOLD_S := 4.0
const SECTOR_PURPLE := Color(0.78, 0.45, 1.0)
const SECTOR_GREEN := Color(0.35, 0.95, 0.45)
const SECTOR_YELLOW := Color(1.0, 0.82, 0.25)
## Gap trend to the cars ahead and behind, sampled every couple of seconds.
var _gap_sample := Vector2(-1, -1)
var _gap_trend := Vector2.ZERO
var _gap_sample_t := -99.0

## The HUD items, in drawing order (later ones draw on top): [id, name].
const ITEMS := [
	["map", "Track map"],
	["tower", "Timing tower"],
	["standings", "Compact standings"],
	["timing", "Position and laps"],
	["pit", "Pit panel"],
	["damage", "Damage"],
	["tyres", "Tyres and grip"],
	["conditions", "Time, weather and track"],
	["fuel", "Fuel"],
	["sectors", "Sectors and gaps"],
	["speed", "Speed, gear and revs"],
	["hint", "Pit wall hint"],
	["pitguide", "Pit lane guide"],
	["lights", "Start lights"],
	["flags", "Flags and race control"],
	["radio", "Team radio"],
	["messages", "Messages"],
]
## Items about the player's own car (a placeholder when spectating).
const CAR_ITEMS := ["timing", "pit", "damage", "tyres", "fuel", "sectors", "speed", "pitguide"]
## Where the player put each item, how big, shown or not.
var layout := HudLayout.new()
## True while the HUD layout editor is open: every item that's switched on is
## drawn, with sample content when there's nothing to show right now.
var editing := false
var editor: HudEditor = null
## Co-op driver (sharing the car with team mates): the co-op layout is in use
## (HudLayout.PREF_COOP, minimal by default), and it keeps the timing tower's
## on/off in the layout instead of the solo pref.
var coop := false
## Settings preview: the HUD runs its own (all-AI) race session.
var drives_session := false
## The editor was closed (saved: true, or cancelled).
signal edit_finished(saved: bool)


func setup(p_session: RaceSession) -> void:
	session = p_session
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	coop = is_coop_driver()
	load_layout()
	_build_minimap()


static func item_ids() -> Array:
	return ITEMS.map(func(it): return it[0])


## Driving a car shared with other players (co-op crew).
func is_coop_driver() -> bool:
	if session == null or drives_session or session.local_car < 0:
		return false
	return session.sim.entries[session.local_car].human_crew().size() > 1


## The pref the layout in use is saved in.
func layout_pref() -> String:
	return HudLayout.PREF_COOP if coop else HudLayout.PREF


func load_layout() -> void:
	layout = HudLayout.load_from(_prefs(), coop, item_ids())


## Back to the designed layout (solo: everything; co-op: the minimal set).
func reset_layout() -> void:
	if coop:
		layout = HudLayout.coop_default(item_ids())
	else:
		layout.reset_all()
		set_show_tower(true)


func save_layout() -> void:
	var gd := get_node_or_null("/root/GameData")
	if gd != null and gd.has_method("set_pref"):
		gd.call("set_pref", layout_pref(), layout.to_value())


## The player's prefs (GameData autoload, looked up by path so this class
## also loads in the headless tests, where autoloads aren't registered).
func _prefs() -> Dictionary:
	var gd := get_node_or_null("/root/GameData")
	return gd.prefs if gd != null else {}


func show_tower() -> bool:
	return bool(_prefs().get(PREF_TOWER, true))


func set_show_tower(on: bool) -> void:
	var gd := get_node_or_null("/root/GameData")
	if gd == null:
		return
	gd.prefs[PREF_TOWER] = on
	if gd.has_method("save_prefs"):
		gd.call("save_prefs")


func _unhandled_input(event: InputEvent) -> void:
	if editing:
		return
	if event.is_action_pressed("hud_tower"):
		if get_node_or_null("/root/GameData") == null or not is_visible_in_tree():
			return   # hidden (spectating, results): the key is theirs
		set_item_on("tower", not item_on("tower"))
		if coop:
			save_layout()
		flash("Timing tower " + ("on" if item_on("tower") else "off"), 1.2)


## Opens the HUD layout editor over the race.
func open_editor() -> void:
	if editing or session == null:
		return
	editing = true
	editor = HudEditor.new()
	add_child(editor)
	editor.setup(self)
	editor.closed.connect(func(saved: bool):
		editing = false
		editor = null
		edit_finished.emit(saved))


# --- Layout: which items show, where and how big ---------------------------------

static func item_name(id: String) -> String:
	for it in ITEMS:
		if it[0] == id:
			return it[1]
	return id


## Switched on by the player (the tower follows its own pref; the compact
## standings only show while the tower is off).
func item_on(id: String) -> bool:
	if id == "tower" and not coop:
		return show_tower()
	return layout.is_on(id)


func set_item_on(id: String, on: bool) -> void:
	if id == "tower" and not coop:
		set_show_tower(on)
		return
	layout.set_on(id, on)
	if id == "standings" and on:
		set_item_on("tower", false)


## Drawn now: switched on, and (outside the editor) something to show.
func item_shown(id: String) -> bool:
	if session == null or not item_on(id):
		return false
	if id == "standings" and item_on("tower"):
		return false
	if editing:
		return true
	var sim := session.sim
	var me := session.local_car
	if id in CAR_ITEMS and me < 0:
		return false
	match id:
		"pit": return sim.pits.enabled and _pit_panel_height(me) > 0.0
		"hint": return sim.settings.has_pit_wall()   # no pit wall in rallycross or derby
		"damage": return sim.damage_level != CarDamage.Level.OFF
		"fuel": return sim.settings.fuel_enabled
		"flags": return _flag_lines(me)[0] != "" or _flag_lines(me)[1] != ""
		"radio": return radio_time > 0.0 and not radio_msg.is_empty()
		"messages": return message_time > 0.0
		"lights": return sim.phase == RaceSim.Phase.COUNTDOWN
		"pitguide": return pit_guide_on and _pit_guide_shown(me)
	return true


## The pit lane guide panel: while the driver is at the wheel for part of a
## stop (into the lane, out of the box) and while the crew work; not while
## the guide takes the car to the box.
func _pit_guide_shown(me: int) -> bool:
	var pits := session.sim.pits
	if not pits.drives_in(me):
		return false
	var stage := str(pits.guide_info(me)["stage"])
	return stage != "" and (stage == "service" or not pits.controls(me))


## An item's size at 100 %, in HUD units (1600 x 900 screen).
func item_size(id: String) -> Vector2:
	var sim := session.sim
	var me := session.local_car
	match id:
		"map":
			var scale_f: float = get_meta("mm_scale", 1.0)
			return _mm_rect.size * scale_f + Vector2(20, 20)
		"tower": return Vector2(TOWER_W, _tower_height())
		"standings": return Vector2(330, 34 + _standings_rows() * 22)
		"timing": return Vector2(300, _timing_height(me))
		"pit":
			var h := _pit_panel_height(me) if me >= 0 and sim.pits.enabled else 0.0
			return Vector2(300, maxf(h, 136.0) if editing else h)
		"damage": return Vector2(300, 116)
		"tyres": return Vector2(136, 164)
		"conditions": return Vector2(260, 84.0 if _forecast_text(sim.env) == "" else 106.0)
		"fuel": return Vector2(200, 56)
		"sectors": return Vector2(_sectors_width(), 82)
		"speed": return Vector2(250, 120)
		"hint": return Vector2(260, 20)
		"pitguide": return Vector2(440, 74)
		"lights": return Vector2(224, 44)
		"flags": return Vector2(520, 84.0 if _giving_back(me) else 58.0)
		"radio": return _radio_size()
		"messages": return Vector2(1000, 50)
	return Vector2.ZERO


## The designed spot (top-left corner, 100 %) of an item on a `vp` screen.
## Items the player hasn't moved keep following each other as before: the
## timing panel sits beside the tower, the map under the compact standings.
func default_pos(id: String, sz: Vector2, vp: Vector2) -> Vector2:
	var lx := 10.0
	if id in ["timing", "pit", "damage"] and item_shown("tower") and not layout.has_pos("tower"):
		lx = item_rect("tower").end.x + 10.0
	match id:
		"map":
			var y := 10.0
			if item_shown("standings") and not layout.has_pos("standings"):
				y = item_rect("standings").end.y + 10.0
			return Vector2(vp.x - sz.x - 10.0, y)
		"tower": return Vector2(10, 10)
		"standings": return Vector2(vp.x - 340, 10)
		"timing": return Vector2(lx, 10)
		"pit": return Vector2(lx, 20.0 + _timing_height(session.local_car))
		"damage": return Vector2(lx, vp.y - 322)
		"tyres": return Vector2(10, vp.y - 174)
		"conditions": return Vector2(vp.x - 270, vp.y - 246)
		"fuel": return Vector2(156, vp.y - 66)
		"sectors": return Vector2((vp.x - sz.x) * 0.5, vp.y - 110)
		"speed": return Vector2(vp.x - 260, vp.y - 130)
		"hint": return Vector2((vp.x - sz.x) * 0.5, vp.y - 28)
		"pitguide": return Vector2((vp.x - sz.x) * 0.5, vp.y - 200)
		"lights": return Vector2((vp.x - sz.x) * 0.5, 48)
		"flags": return Vector2((vp.x - sz.x) * 0.5, 70)
		"radio": return Vector2((vp.x - sz.x) * 0.5, 196)
		"messages": return Vector2((vp.x - sz.x) * 0.5, 115)
	return Vector2.ZERO


## Where an item is on screen now (scaled), or an empty rect.
func item_rect(id: String) -> Rect2:
	var sz := item_size(id)
	if sz.x <= 0.0 or sz.y <= 0.0:
		return Rect2()
	var vp := size
	var s := layout.scale_of(id)
	var frac := layout.pos(id) if layout.has_pos(id) else HudLayout.frac_of(default_pos(id, sz, vp), sz, vp)
	return Rect2(HudLayout.place(frac, sz * s, vp), sz * s)


## Puts an item's (scaled) top-left corner at `top_left`.
func move_item(id: String, top_left: Vector2) -> void:
	var r := item_rect(id)
	if r.size == Vector2.ZERO:
		return
	layout.set_pos(id, HudLayout.frac_of(top_left, r.size, size))


## Resizes an item, keeping the point `keep` (0..1 across its box) still.
func scale_item(id: String, s: float, keep := Vector2(0.5, 0.5)) -> void:
	var r := item_rect(id)
	if r.size == Vector2.ZERO:
		return
	var pin := r.position + r.size * keep
	layout.set_scale(id, s)
	var nsz := item_size(id) * layout.scale_of(id)
	layout.set_pos(id, HudLayout.frac_of(pin - nsz * keep, nsz, size))


# --- Messages and drawing -------------------------------------------------------

## Team radio from the pit wall (co-op): shown as a banner for a few seconds.
var radio_msg: Dictionary = {}
var radio_time := 0.0


func show_radio(msg: Dictionary, secs := 5.0) -> void:
	radio_msg = msg
	radio_time = secs


func flash(text: String, secs := 2.0) -> void:
	message = text
	message_time = secs


func _process(delta: float) -> void:
	size = get_viewport_rect().size
	message_time -= delta
	radio_time -= delta
	_watch_release(delta)
	# A driver change can put this player at the wheel of a shared car (or take
	# them out of it): switch to the matching layout.
	if not editing and is_coop_driver() != coop:
		coop = not coop
		load_layout()
	_watch_damage()
	queue_redraw()


func _physics_process(_delta: float) -> void:
	if drives_session and session != null:
		session.tick(null)
## Flashes a warning when the player's car gets hurt (works the same online,
## where the player's own car is simulated on their machine).
func _watch_damage() -> void:
	if session == null or session.local_car < 0 or session.sim.damage_level == CarDamage.Level.OFF:
		return
	var c := session.sim.cars[session.local_car]
	var p := CarDamage.punctures(c)
	var failed := CarDamage.engine_failed(c)
	if failed and not _seen_engine_failed:
		flash("ENGINE FAILURE", 4.0)
	elif p > _seen_punctures:
		flash("PUNCTURE! Box for new tyres", 3.0)
	elif CarDamage.worst(c) - _seen_worst > 0.15:
		flash("DAMAGE: " + _worst_part(c), 2.5)
	_seen_punctures = p
	_seen_engine_failed = failed
	_seen_worst = CarDamage.worst(c)


static func _worst_part(c: CarState) -> String:
	var parts := {"aero": c.damage_aero, "suspension": c.damage_suspension, "steering alignment": absf(c.alignment),
		"engine": c.damage_engine, "gearbox": c.damage_gearbox}
	var best := "bodywork"
	var v := 0.05
	for k in parts:
		if parts[k] > v:
			v = parts[k]
			best = k
	return best.to_upper()


static func fmt_time(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	return "%d:%06.3f" % [int(t) / 60, fmod(t, 60.0)]


func _text(pos: Vector2, s: String, size := 18, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(font, pos + Vector2(1, 1), s, align, width, size, Color(0, 0, 0, 0.6))
	draw_string(font, pos, s, align, width, size, col)


func _panel(r: Rect2) -> void:
	draw_rect(r, Color(0, 0, 0, 0.45))




func _draw() -> void:
	if session == null:
		return
	var me := session.local_car
	for it in ITEMS:
		var id: String = it[0]
		if not item_shown(id):
			continue
		var r := item_rect(id)
		if r.size == Vector2.ZERO:
			continue
		var s := layout.scale_of(id)
		draw_set_transform(r.position, 0.0, Vector2(s, s))
		_draw_item(id, me, r.size / s)
	draw_set_transform(Vector2.ZERO)
	if not editing:
		_draw_give_back_pointer(me)
	if me < 0 and not editing:
		_text(Vector2(20, 40), "SPECTATING", 22)
	if me >= 0 and not editing:
		_draw_release_countdown()


# --- Pit stop release countdown ------------------------------------------------

const RELEASE_COUNT_S := 3.0     ## the countdown shows over the last seconds of a stop
const RELEASE_GO_S := 0.9        ## then GO for this long once the car is the driver's
var _release_left := -1.0        ## PitRules.release_in for this player's car, last frame
var _release_go := 0.0


## Notes when the crew release this player's car (for GO).
func _watch_release(delta: float) -> void:
	_release_go = maxf(_release_go - delta, 0.0)
	if session == null or session.local_car < 0:
		_release_left = -1.0
		return
	var me := session.local_car
	var r := session.sim.pits.release_in(me)
	if r < 0.0 and _release_left >= 0.0 and _release_left <= 1.0 \
			and session.sim.pits.phase(me) == PitRules.PHASE_LEAVE:
		_release_go = RELEASE_GO_S
	_release_left = r


## 3, 2, 1, GO in the middle of the screen as the crew finish a stop: the
## moment the driver has the car back.
func _draw_release_countdown() -> void:
	var r := _release_left
	var txt := ""
	var col := Color(1, 0.82, 0.2)
	if r >= 0.0 and r <= RELEASE_COUNT_S:
		txt = str(maxi(ceili(r), 1))
		col = Color(1, 0.3, 0.2) if r > 2.0 else Color(1, 0.82, 0.2)
	elif _release_go > 0.0:
		txt = "GO"
		col = Color(0.35, 0.95, 0.45)
	if txt == "":
		return
	var k := size.y / 900.0
	var w := 260.0 * k
	var c := Vector2(size.x * 0.5, size.y * 0.27)
	draw_rect(Rect2(c - Vector2(w * 0.5, 96.0 * k), Vector2(w, 150.0 * k)), Color(0, 0, 0, 0.45))
	_text(c + Vector2(-w * 0.5, -66.0 * k), "RELEASE" if txt != "GO" else "YOUR CAR", roundi(16.0 * k),
		Color(1, 1, 1, 0.75), HORIZONTAL_ALIGNMENT_CENTER, w)
	_text(c + Vector2(-w * 0.5, 36.0 * k), txt, roundi(96.0 * k), col, HORIZONTAL_ALIGNMENT_CENTER, w)


## Draws one item from (0, 0) in its own box of `sz` (100 % units).
func _draw_item(id: String, me: int, sz: Vector2) -> void:
	var sim := session.sim
	if id in CAR_ITEMS and me < 0:
		_placeholder(sz, item_name(id), "your car's " + item_name(id).to_lower())
		return
	match id:
		"map": _draw_minimap(Vector2(10, 10))
		"tower": _draw_tower(me)
		"standings": _draw_standings(me)
		"timing": _draw_timing(me)
		"pit":
			if sim.pits.enabled:
				_draw_pit_panel(me)
			else:
				_placeholder(sz, "Pit panel", "shows in races with pit stops")
		"damage":
			if sim.damage_level != CarDamage.Level.OFF:
				_draw_damage(sim.cars[me], sim.damage_level == CarDamage.Level.FULL)
			else:
				_placeholder(sz, "Damage", "shows in races with damage on")
		"tyres": _draw_tyres(me)
		"conditions": _draw_conditions()
		"fuel":
			if sim.settings.fuel_enabled:
				_draw_fuel(me)
			else:
				_placeholder(sz, "Fuel", "shows in races with fuel on")
		"sectors": _draw_sectors_and_gaps(me)
		"speed": _draw_speed(me)
		"hint": _text(Vector2(0, 14), InputPrompt.key("strategy_screen") + "  Pit wall", 13, Color(1, 1, 1, 0.45), HORIZONTAL_ALIGNMENT_CENTER, sz.x)
		"lights": _draw_lights()
		"pitguide": _draw_pit_guide(me)
		"flags": _draw_race_control(me)
		"radio": _draw_radio()
		"messages":
			var txt := message if message_time > 0.0 else "Lap 3  1:42.315"
			_text(Vector2(0, 38), txt, 40, Color(1, 0.9, 0.3), HORIZONTAL_ALIGNMENT_CENTER, sz.x)


## Editor stand-in for an item with nothing to show right now.
func _placeholder(sz: Vector2, title: String, note: String) -> void:
	_panel(Rect2(Vector2.ZERO, sz))
	_text(Vector2(0, sz.y * 0.5 - 2), title.to_upper(), 15, Color(1, 1, 1, 0.8), HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	_text(Vector2(0, sz.y * 0.5 + 18), "(" + note + ")", 12, Color(1, 1, 1, 0.5), HORIZONTAL_ALIGNMENT_CENTER, sz.x)


## Start lights: four reds lighting up through the countdown.
func _draw_lights() -> void:
	var sim := session.sim
	var lit := 2
	if sim.phase == RaceSim.Phase.COUNTDOWN:
		var remaining := sim.settings.countdown_s - sim.phase_time
		lit = clampi(int(sim.settings.countdown_s - remaining) + 1, 0, 4)
	for k in 4:
		var c := Vector2(22 + k * 60, 22)
		draw_circle(c, 22, Color(0.1, 0.1, 0.1, 0.8))
		draw_circle(c, 18, Color(0.9, 0.1, 0.1) if k < lit else Color(0.25, 0.05, 0.05))


## Position, lap, current / last / best lap time.
## The position panel's height: one row, plus a second for a penalty or the
## rallycross joker.
func _timing_height(me: int) -> float:
	return 84.0 if _timing_extra_row(me) else 56.0


func _timing_extra_row(me: int) -> bool:
	if me < 0:
		return false
	var sim := session.sim
	var e := sim.entries[me]
	return e.penalty_s > 0.0 or (sim.settings.is_rallycross() and sim.track.has_joker() and not e.finished)


## Position and lap count (lap times are on the timing tower and the
## sectors panel).
func _draw_timing(me: int) -> void:
	var sim := session.sim
	var e := sim.entries[me]
	_panel(Rect2(0, 0, 300, _timing_height(me)))
	_text(Vector2(14, 42), "P%d / %d" % [e.position, sim.car_count()], 34)
	var lap_now := mini(e.laps_done + 1, sim.settings.laps)
	_text(Vector2(160, 40), "LAP %d/%d" % [lap_now, sim.settings.laps], 20)
	if e.penalty_s > 0.0:
		_text(Vector2(14, 72), "+%d s penalty" % int(e.penalty_s), 16, Color(1, 0.55, 0.3))
	# Rallycross: has the joker been taken yet? Amber until it has, and a
	# warning on the last lap it can still be taken.
	if sim.settings.is_rallycross() and sim.track.has_joker() and not e.finished:
		var done := e.jokers >= sim.settings.joker_laps
		var last_lap := sim.settings.laps - (1 if sim.track.joker_entry_s > sim.track.joker_exit_s and sim.settings.laps > 1 else 0)
		var col := Color(0.45, 1.0, 0.55) if done else (Color(1, 0.35, 0.25) if lap_now >= last_lap else Color(1, 0.75, 0.3))
		_text(Vector2(160, 72), "JOKER " + ("DONE" if done else ("NOW!" if lap_now >= last_lap else "TO DO")), 16, col)


const JOKER_COLOUR := Color(1.0, 0.55, 0.1)

## Rallycross: the joker lane on the minimap, in orange, with where it leaves
## the lap and "J". It pulses while the local car still has to take it.
func _draw_minimap_joker(origin: Vector2, scale_f: float) -> void:
	var sim := session.sim
	var t := sim.track
	var js := PackedVector2Array()
	for p in t.joker_path:
		js.append(origin + (p - _mm_rect.position) * scale_f)
	var col := JOKER_COLOUR
	var me := session.local_car
	if me >= 0 and not editing and sim.entries[me].jokers < sim.settings.joker_laps:
		col.a = 0.65 + 0.35 * sin(Time.get_ticks_msec() * 0.006)
	draw_polyline(js, Color(0, 0, 0, 0.7), 7.0)
	draw_polyline(js, col, 4.0)
	var entry := js[0]
	draw_circle(entry, 5.0, Color(0, 0, 0, 0.7))
	draw_circle(entry, 3.5, JOKER_COLOUR)
	# "J" beside the middle of the lane, on the side away from the lap.
	var mid := js[js.size() / 2]
	var lap_mid := origin + (t.position_at(t.joker_entry_s + fposmod(t.joker_exit_s - t.joker_entry_s, t.length) * 0.5) - _mm_rect.position) * scale_f
	var away := (mid - lap_mid).normalized() if mid.distance_to(lap_mid) > 0.5 else Vector2.UP
	var span := _mm_rect.size * scale_f
	var at := (mid + away * 12.0).clamp(origin + Vector2(6, 8), origin + span - Vector2(6, 2))
	_text(at + Vector2(-5, 5), "J", 14, JOKER_COLOUR)


## Speed, gear and the rev bar.
func _draw_speed(me: int) -> void:
	var sim := session.sim
	var c := sim.cars[me]
	var br := Vector2.ZERO
	var sz := Vector2(250, 120)
	# Like a GT3 car's TFT dash: the whole screen shows the flag colour,
	# held steady (no flashing) for as long as the flag is out.
	var flag := dash_preview if dash_preview.a > 0.0 else dash_flag(me)
	var lit := flag.a > 0.0
	var ink := Color.WHITE
	if lit:
		draw_rect(Rect2(br, sz), Color(flag, 0.92))
		ink = Color(0.04, 0.04, 0.04) if flag.get_luminance() > 0.45 else Color.WHITE
	else:
		_panel(Rect2(br, sz))
	var dim := Color(ink, 0.7)
	_text(br + Vector2(14, 56), "%3d" % int(Units.speed_value(c.speed())), 48, ink)
	_text(br + Vector2(120, 56), Units.speed_unit(), 16, dim)
	_text(br + Vector2(190, 58), "R" if c.gear < 0 else str(c.gear), 44, ink if lit else Color(1, 0.9, 0.3))
	var d := sim.defs[me]
	var frac := clampf(c.rpm / d.redline_rpm, 0.0, 1.0)
	draw_rect(Rect2(br + Vector2(14, 78), Vector2(222, 12)), Color(0, 0, 0, 0.3) if lit else Color(1, 1, 1, 0.15))
	var rev := Color(1, 0.25, 0.2) if frac > 0.92 else Color(0.4, 0.85, 1)
	draw_rect(Rect2(br + Vector2(14, 78), Vector2(222 * frac, 12)), Color(0.05, 0.05, 0.05) if lit else rev)
	_text(br + Vector2(14, 110), "%5d rpm" % int(c.rpm), 14, dim)
	if c.surface >= TrackData.Surface.GRASS:
		_text(br + Vector2(120, 110), "OFF TRACK", 14, ink if lit else Color(1, 0.5, 0.3))


## Dash flag colours (GT3 TFT style).
const DASH_YELLOW := Color(1.0, 0.85, 0.05)
const DASH_RED := Color(0.95, 0.1, 0.1)
const DASH_BLUE := Color(0.15, 0.45, 1.0)
const DASH_WHITE := Color(1, 1, 1)
const DASH_GREEN := Color(0.2, 0.85, 0.3)
## How long the dash shows green once a yellow, VSC or safety car ends.
const DASH_GREEN_S := 3.0
## A car this close behind (m) that has lapped us shows a blue flag.
const DASH_BLUE_M := 80.0

var _dash_was_yellow := false
## Screenshot tools set this to show a flag on the dash (alpha 0: off).
var dash_preview := Color(0, 0, 0, 0)
var _dash_green_until := -1.0


## Which flag the dash shows for car `me` right now (alpha 0: none).
## Priority: red, yellow (local yellows, VSC, safety car), blue, white
## (chequered flag is out), then a short green when the track goes clear.
func dash_flag(me: int) -> Color:
	var sim := session.sim
	if me < 0 or me >= sim.cars.size():
		return Color(0, 0, 0, 0)
	var rc := sim.race_control
	var state := rc.neutralisation()
	var e := sim.entries[me]
	# Yellow: safety car, VSC, or a local yellow where we are now.
	var yellow := not e.finished and (state == "sc" or state == "vsc"
		or (state == "yellow" and rc.yellow_at(sim.cars[me].track_s)))
	var now := sim.race_time
	if _dash_was_yellow and not yellow and not e.finished:
		_dash_green_until = now + DASH_GREEN_S   # track clear again
	_dash_was_yellow = yellow
	var chequered := e.finished or sim.phase == RaceSim.Phase.CHEQUERED or sim.phase == RaceSim.Phase.FINISHED
	# There's no red flag in race control yet: a "red" state lights it.
	return dash_flag_colour(state == "red", yellow, not chequered and _blue_flag(me), chequered,
		now < _dash_green_until)


## The colour for a set of flags, highest priority first.
static func dash_flag_colour(red: bool, yellow: bool, blue: bool, chequered: bool, green: bool) -> Color:
	if red:
		return DASH_RED
	if yellow:
		return DASH_YELLOW
	if blue:
		return DASH_BLUE
	if chequered:
		return DASH_WHITE
	if green:
		return DASH_GREEN
	return Color(0, 0, 0, 0)


## Blue flag: a car that has lapped us is right behind (not under the safety
## car or VSC, and not in the pit lane).
func _blue_flag(me: int) -> bool:
	var sim := session.sim
	if sim.race_control.safety_car_active() or sim.phase != RaceSim.Phase.RACING or sim.in_pit_lane(me):
		return false
	var mine := sim.entries[me].distance
	var lap_len := sim.track.length
	for j in sim.cars.size():
		if j == me or sim.entries[j].finished or sim.entries[j].dnf or sim.in_pit_lane(j):
			continue
		if sim.entries[j].distance <= mine + lap_len * 0.5:
			continue
		var gap := fposmod(sim.cars[me].track_s - sim.cars[j].track_s, lap_len)
		if gap > 0.0 and gap < DASH_BLUE_M:
			return true
	return false


## Grip, then each tyre's temperature (and wear) in a 2 x 2 grid.
func _draw_tyres(me: int) -> void:
	var sim := session.sim
	var c := sim.cars[me]
	var env := sim.env
	var tc := sim.compounds[me]
	_panel(Rect2(0, 0, 136, 164))
	var avg := 0.0
	for k in 4:
		avg += tc.temp_grip_factor(c.tyre_temp[k])
	var off_line := c.lateral_offset - env.raceline_offset(c.track_idx)
	var grip := avg / 4.0 * env.grip_factor(tc, off_line, c.speed())
	_text(Vector2(12, 24), "GRIP %d%%" % int(grip * 100.0), 18, Color(0.6, 1, 0.6) if grip > 0.85 else Color(1, 0.7, 0.4))
	_text(Vector2(12, 40), tc.display_name.to_upper(), 11, Color(1, 1, 1, 0.6), HORIZONTAL_ALIGNMENT_LEFT, 116)
	var pos := [Vector2(14, 50), Vector2(74, 50), Vector2(14, 106), Vector2(74, 106)]
	for k in 4:
		var t := c.tyre_temp[k]
		var r := Rect2(pos[k], Vector2(48, 48))
		draw_rect(r, _temp_colour(t, tc))
		_text(r.position + Vector2(0, 30), "%d°" % roundi(Units.temp_value(t)), 16, Color.BLACK, HORIZONTAL_ALIGNMENT_CENTER, 48)
		if sim.settings.tyre_wear_enabled:
			_text(r.position + Vector2(0, 46), "%d%%" % roundi((1.0 - c.tyre_wear[k]) * 100.0), 11, Color(0, 0, 0, 0.75), HORIZONTAL_ALIGNMENT_CENTER, 48)


## Time of day and weather, the track's state, air and track temperature,
## and the forecast.
func _draw_conditions() -> void:
	var env := session.sim.env
	var forecast := _forecast_text(env)
	_panel(Rect2(0, 0, 260, 84.0 if forecast == "" else 106.0))
	var h := env.time_of_day_h
	_text(Vector2(14, 26), "%02d:%02d  %s" % [int(h), int(fmod(h, 1.0) * 60.0), SimEnvironment.weather_name(env.weather)], 15)
	_text(Vector2(14, 48), _surface_text(env), 15, Color(0.6, 0.85, 1) if env.wetness > 0.05 else Color.WHITE)
	_text(Vector2(14, 70), "Air %s  Track %s" % [Units.temp(env.ambient_c), Units.temp(env.track_c)], 15)
	if forecast != "":
		_text(Vector2(14, 92), forecast, 14, Color(1, 0.85, 0.5))


## Fuel on board and the laps it's good for.
func _draw_fuel(me: int) -> void:
	var sim := session.sim
	var fl := sim.pits.fuel_laps(me)
	_panel(Rect2(0, 0, 200, 56))
	_text(Vector2(12, 20), "FUEL", 12, Color(1, 1, 1, 0.6))
	_text(Vector2(12, 44), "%s  %s" % [Units.fuel(sim.cars[me].fuel_l), "(%.1f laps)" % fl if fl < 99.0 else ""], 18,
		Color(1, 0.5, 0.3) if fl < 1.5 else Color.WHITE)


## The pit panel's height (0: nothing to show).
func _pit_panel_height(me: int) -> float:
	if me < 0:
		return 0.0
	var sim := session.sim
	var e := sim.entries[me]
	var p: Dictionary = e.pit
	var busy: bool = p["phase"] != PitRules.PHASE_NONE or p["box"] or p["limiter"]
	var h := 114 if sim.settings.mandatory_pit_stops > 0 or busy or sim.settings.fuel_enabled or sim.settings.tyre_wear_enabled else 0
	if e.crew.size() > 1:
		h = 136
	if editing:
		h = maxi(h, 114)
	return h + (22.0 if e.penalty_s > 0.0 else 0.0)

## The pit lane guide cues for a driver driving in themselves (Settings >
## Gameplay > Pit stops): distance to the pit limit line, the box or the end
## of the limit, and when to brake (PitRules.guide_info). pit_guide_on:
## Settings > Gameplay > Pit lane guide.
var pit_guide_on := true
## The car race control told us to give a place back to (-1 none, -2 the
## safety car); the race scene keeps it up to date. car_screen_pos(i) gives
## that car's spot on screen (null when it can't), for the pointer to it.
var give_back_to := -1
var car_screen_pos: Callable
const GIVE_BACK_COL := Color(1.0, 0.42, 0.2)
const SAMPLE_GUIDE := {"stage": "approach", "to_limit": 180.0, "limit": 16.67, "speed": 52.0, "brake_at": 135.0}


func _draw_pit_guide(me: int) -> void:
	var sim := session.sim
	var g: Dictionary = sim.pits.guide_info(me) if me >= 0 else {}
	if str(g.get("stage", "")) == "":
		g = SAMPLE_GUIDE
	var sz := item_size("pitguide")
	_panel(Rect2(Vector2.ZERO, sz))
	var lim := float(g.get("limit", sim.track.pit_speed_limit))
	var v := float(g.get("speed", 0.0))
	var title := ""
	var dist := 0.0
	var cue := ""
	var cue_col := Color(0.35, 0.95, 0.45)
	match str(g["stage"]):
		"approach":
			dist = float(g["to_limit"])
			title = "PIT LIMIT " + Units.speed(lim).to_upper()
			var brake_at := float(g.get("brake_at", 0.0))
			if v <= lim + 0.3:
				cue = "AT THE LIMIT"
				cue_col = Color(0.4, 0.8, 1.0)
			elif dist <= brake_at + 5.0:
				cue = "BRAKE"
				cue_col = Color(1, 0.25, 0.2)
			elif dist <= brake_at * 1.35 + 30.0:
				cue = "GET READY"
				cue_col = Color(1, 0.82, 0.2)
			else:
				cue = "FOLLOW THE PIT LINE"
				cue_col = Color(0.4, 0.8, 1.0)
		"box":
			dist = float(g["to_box"])
			title = "YOUR BOX"
			if bool(g.get("on_marks", false)):
				cue = "STOP" if v > 1.0 else "ON YOUR MARKS"
				cue_col = Color(0.35, 0.95, 0.45)
			elif absf(float(g.get("across", 0.0))) >= PitRules.BOX_STOP_WIDE and dist < 15.0:
				cue = "PULL INTO YOUR BOX"
				cue_col = Color(1, 0.82, 0.2)
			elif dist < -PitRules.BOX_STOP_LONG:
				cue = "OVERSHOT: STOP NOW"
				cue_col = Color(1, 0.25, 0.2)
			elif dist <= float(g.get("brake_at", 0.0)) + 3.0:
				cue = "BRAKE"
				cue_col = Color(1, 0.25, 0.2)
			else:
				cue = "LIMITER ON"
				cue_col = Color(0.4, 0.8, 1.0)
		"leave":
			dist = float(g["to_end"])
			title = "MISSED YOUR BOX: END OF LIMIT" if bool(g.get("missed", false)) else "END OF PIT LIMIT"
			cue = "LIMITER ON"
			cue_col = Color(0.4, 0.8, 1.0)
		"service":
			title = "IN YOUR BOX"
			cue = "CREW AT WORK"
			cue_col = Color(1, 0.82, 0.2)
	_text(Vector2(14, 24), title, 15, Color(1, 0.85, 0.2))
	if str(g["stage"]) != "service":
		_text(Vector2(14, 60), "%d m" % maxi(roundi(dist), 0) if dist >= 0.0 else "%d m past" % roundi(-dist), 30, Color.WHITE)
	_text(Vector2(0, 60), cue, 22, cue_col, HORIZONTAL_ALIGNMENT_RIGHT, sz.x - 14)
	# Speed against the limit: a bar that fills to the limit mark.
	var bar := Rect2(230, 15, sz.x - 244, 6)
	draw_rect(bar, Color(1, 1, 1, 0.12))
	var top := maxf(lim * 3.0, v)
	var mark := bar.position.x + bar.size.x * lim / top
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(v / top, 0.0, 1.0), bar.size.y)),
		Color(0.4, 0.8, 1.0) if v <= lim + 0.3 else Color(1, 0.5, 0.3))
	draw_rect(Rect2(mark - 1.0, bar.position.y - 4.0, 2.0, bar.size.y + 8.0), Color.WHITE)


## Pit panel (left, under the timing): pit call, limiter, plan, stops, stop time.
func _draw_pit_panel(me: int) -> void:
	var o := Vector2.ZERO
	var sim := session.sim
	var pits := sim.pits
	var e := sim.entries[me]
	var p: Dictionary = e.pit
	var plan: Dictionary = p["plan"]
	var phase: String = p["phase"]
	var need := sim.settings.mandatory_pit_stops
	var mates := e.crew.size() > 1
	var full := _pit_panel_height(me)
	var h := full - (22.0 if e.penalty_s > 0.0 else 0.0)
	if full <= 0.0:
		return
	_panel(Rect2(o, Vector2(300, full)))
	var y := o.y + 22
	if h > 0:
		var head := "PIT"
		var hc := Color(1, 1, 1, 0.7)
		match phase:
			PitRules.PHASE_APPROACH: head = "BOXING: FOLLOW THE PIT LINE" if pits.drives_in(me) else "BOXING: CAR DRIVING TO THE PITS"
			PitRules.PHASE_ENTRY: head = "PIT LANE: %d KM/H LIMIT" % roundi(sim.track.pit_speed_limit * 3.6)
			PitRules.PHASE_LIMIT: head = "STOP ON YOUR BOX" if pits.self_drives(me) else "PIT LANE, TO YOUR BOX"
			PitRules.PHASE_SERVICE: head = PitRules.service_text(p, "PIT STOP")
			PitRules.PHASE_LEAVE, PitRules.PHASE_EXIT: head = "PIT EXIT"
			_:
				if p["box"]:
					head = "BOX THIS LAP"
		if phase != PitRules.PHASE_NONE or p["box"]:
			hc = Color(1, 0.85, 0.2)
		_text(Vector2(o.x + 14, y), head, 15, hc)
		if p["limiter"]:
			_text(Vector2(o.x + 214, y), "LIMITER", 15, Color(0.4, 0.9, 1))
		y += 22
		if need > 0:
			var done := int(p["window_stops"])
			_text(Vector2(o.x + 14, y), "Stops %d/%d  window laps %d-%d" % [done, need, pits.window_open, pits.window_close], 14,
				Color(0.6, 1, 0.6) if done >= need else Color.WHITE)
		else:
			_text(Vector2(o.x + 14, y), "Stops %d" % int(p["stops"]), 14)
		y += 22
		var fuel_txt := ""
		if sim.settings.fuel_enabled:
			fuel_txt = "  fuel " + fuel_plan_text(float(plan["fuel"]))
		var work := pits.service_for(me, plan)
		_text(Vector2(o.x + 14, y), "Next: tyres %s%s" % [stop_tyres_text(sim, me, plan, work), fuel_txt], 14, Color(1, 1, 1, 0.85),
			HORIZONTAL_ALIGNMENT_LEFT, 280)
		y += 22
		var rj := sim.pits.rejoin_estimate(me) if (p["box"] or phase != PitRules.PHASE_NONE) else {}
		if not rj.is_empty() and phase != PitRules.PHASE_EXIT:
			_text(Vector2(o.x + 14, y), rejoin_text(sim, rj), 14, rejoin_colour(rj), HORIZONTAL_ALIGNMENT_LEFT, 280)
		else:
			_text(Vector2(o.x + 14, y), "Stop about %.0f s%s" % [work["total_s"], "  + repairs" if float(work["repair_s"]) > 0.0 else ""], 14, Color(1, 1, 1, 0.7))
		y += 22
		if mates:
			var pend := session.pending_swap(me)
			var txt := "Driver change: no (%s)" % InputPrompt.key("pit_driver")
			var col := Color(1, 1, 1, 0.7)
			if not pend.is_empty():
				var other := int(pend["b"]) if int(pend["a"]) == session.local_peer else int(pend["a"])
				txt = "Driver change: %s takes over" % _crew_name(e, other)
				col = Color(1, 0.85, 0.2)
			_text(Vector2(o.x + 14, y), txt, 14, col, HORIZONTAL_ALIGNMENT_LEFT, 280)
			y += 22
	if e.penalty_s > 0.0:
		_text(Vector2(o.x + 14, y), "Penalties +%d s" % int(e.penalty_s), 14, Color(1, 0.5, 0.3))


## Where a clean stop rejoins (PitRules.rejoin_estimate), in a few words.
static func rejoin_text(sim: RaceSim, rj: Dictionary) -> String:
	var txt := "Rejoin P%d" % int(rj["position"])
	if int(rj["ahead"]) >= 0 and float(rj["gap_ahead"]) < 3.0:
		txt += ", %.1f s behind %s" % [rj["gap_ahead"], short_name(sim.entries[int(rj["ahead"])].at_wheel())]
	elif int(rj["behind"]) >= 0 and float(rj["gap_behind"]) < 3.0:
		txt += ", %.1f s ahead of %s" % [rj["gap_behind"], short_name(sim.entries[int(rj["behind"])].at_wheel())]
	else:
		txt += ", clear air"
	return txt


## Green: clear air at the rejoin; amber: a car within 1.5 s; red: within 0.6 s.
static func rejoin_colour(rj: Dictionary) -> Color:
	var near := INF
	for k in ["gap_ahead", "gap_behind"]:
		if float(rj.get(k, -1.0)) >= 0.0:
			near = minf(near, float(rj[k]))
	if near < 0.6:
		return Color(1.0, 0.35, 0.3)
	if near < 1.5:
		return Color(1.0, 0.7, 0.25)
	return Color(0.4, 1.0, 0.5)


## Sample radio call shown in the HUD layout editor.
const SAMPLE_RADIO := {"from": "Pit wall", "role": "strategist", "text": "Box this lap, box box"}


func _radio_line() -> String:
	var msg := radio_msg if radio_time > 0.0 and not radio_msg.is_empty() else SAMPLE_RADIO
	var who := str(msg.get("from", "Pit wall"))
	var role := str(msg.get("role", "")).replace("_", " ")
	return "%s%s: %s" % [who, (" (%s)" % role) if role != "" else "", msg.get("text", "")]


func _radio_width() -> float:
	return minf(font.get_string_size(_radio_line(), HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 120, size.x - 40)


## The radio item's size: one line, or a pit stop plan (one job per line).
func _radio_size() -> Vector2:
	var lines := _plan_lines()
	if lines.size() <= 1:
		return Vector2(_radio_width(), 44)
	var w := 560.0
	for ln in lines:
		w = maxf(w, font.get_string_size(str(ln), HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x + 60)
	return Vector2(minf(w, size.x - 40), 52.0 + lines.size() * 28.0)


func _plan_lines() -> Array:
	return radio_msg.get("lines", []) if radio_time > 0.0 else []


func _draw_radio() -> void:
	var lines := _plan_lines()
	if lines.size() > 1:
		_draw_radio_plan(lines)
		return
	var line := _radio_line()
	var w := _radio_width()
	var r := Rect2(0, 0, w, 44)
	var a := clampf(radio_time / 0.5, 0.0, 1.0) if radio_time > 0.0 else 1.0
	draw_rect(r, Color(0.02, 0.04, 0.08, 0.8 * a))
	draw_rect(r, Color(1, 0.88, 0.35, 0.8 * a), false, 2.0)
	_text(r.position + Vector2(14, 30), "RADIO", 16, Color(1, 0.88, 0.35, a))
	_text(r.position + Vector2(84, 30), line, 22, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_LEFT, w - 96)


## A pit stop plan from the strategist: a box with one line per job.
func _draw_radio_plan(lines: Array) -> void:
	var sz := _radio_size()
	var w := sz.x
	var r := Rect2(Vector2.ZERO, sz)
	var who := str(radio_msg.get("from", "Pit wall"))
	var role := str(radio_msg.get("role", "")).replace("_", " ")
	var a := clampf(radio_time / 0.5, 0.0, 1.0)
	draw_rect(r, Color(0.02, 0.04, 0.08, 0.86 * a))
	draw_rect(r, Color(1, 0.88, 0.35, 0.8 * a), false, 2.0)
	_text(Vector2(16, 28), "RADIO  ·  PIT STOP PLAN", 16, Color(1, 0.88, 0.35, a))
	_text(Vector2(w - 16, 28), "%s%s" % [who, (" (%s)" % role) if role != "" else ""], 15,
		Color(1, 1, 1, 0.7 * a), HORIZONTAL_ALIGNMENT_RIGHT, w * 0.5)
	for k in lines.size():
		var y := 62 + k * 28
		var col := Color(1, 0.88, 0.35, a) if k == 0 else Color(1, 1, 1, a)
		_text(Vector2(20, y), str(lines[k]) if k == 0 else "•  " + str(lines[k]), 20, col,
			HORIZONTAL_ALIGNMENT_LEFT, w - 40)


static func _crew_name(e: RaceEntry, peer_id: int) -> String:
	for m in e.crew:
		if int(m.get("peer_id", 0)) == peer_id:
			return str(m.get("name", "?"))
	return "?"


## Which tyres a plan's wheel choice changes, in words ("fronts", "all four").
static func wheels_text(choice: String) -> String:
	return PitRules.WHEEL_LABELS.get(choice, "all four")


## The tyres a stop will fit, with which ones: "Soft (fronts)", "no change".
## work: PitRules.service_for (a new compound always fits all four).
static func stop_tyres_text(sim: RaceSim, car: int, plan: Dictionary, work: Dictionary) -> String:
	var t := tyre_plan_text(sim, car, str(plan["tyre"]))
	var wheels: Array = work.get("wheels", [])
	if str(work.get("tyre", "")) == "" or wheels.is_empty():
		return t
	if wheels.size() == 4:
		return t + " (all four)"
	for k in PitRules.WHEEL_CHOICES:
		if PitRules.wheels_of(k) == wheels:
			return "%s (%s)" % [t, wheels_text(k)]
	return "%s (%d tyres)" % [t, wheels.size()]


## The driver's "driver change" button (N, or Y on the pit wall): hand the
## wheel to the next crew mate at the next stop (the AI co-driver, or a co-op
## team mate), or take back a change that is waiting. Returns the line to show.
static func toggle_driver_change(session: RaceSession, me: int) -> String:
	if not session.pending_swap(me).is_empty():
		session.cancel_role_swap(me)
		return "Driver change cancelled"
	var mates := session.sim.entries[me].crew.filter(func(m): return int(m.get("peer_id", 0)) != session.local_peer)
	if mates.is_empty():
		return "No co-driver in this car (Drivers per car, in the race settings)"
	var m: Dictionary = mates[0]
	session.request_role_swap(me, session.local_peer, int(m["peer_id"]))
	return "Driver change at the next stop: %s takes over" % m.get("name", "?")


static func tyre_plan_text(sim: RaceSim, car: int, choice: String) -> String:
	match choice:
		PitRules.TYRE_AUTO:
			var id := sim.pits.compound_for_conditions(car)
			return "auto (%s)" % (sim.tyre_defs[id].display_name if sim.tyre_defs.has(id) else id)
		PitRules.TYRE_KEEP:
			return "no change"
		PitRules.TYRE_DRY:
			var dry := sim.dry_compound[car]
			return sim.tyre_defs[dry].display_name if sim.tyre_defs.has(dry) else "dry"
	return sim.tyre_defs[choice].display_name if sim.tyre_defs.has(choice) else choice


static func fuel_plan_text(fuel: float) -> String:
	if fuel < 0.0:
		return "to the end"
	if fuel == 0.0:
		return "none"
	return "+%d L" % int(fuel)


## Litres a stop with this fuel plan would really put in car i (as
## PitRules.service_for works it out: "to the end" is enough to finish with a
## little spare, and never more than the tank has room for).
static func fuel_added_l(sim: RaceSim, car: int, plan_fuel: float) -> float:
	if not sim.settings.fuel_enabled:
		return 0.0
	var room := maxf(sim.defs[car].fuel_capacity_l - sim.cars[car].fuel_l, 0.0)
	var want := plan_fuel
	if want < 0.0:
		want = maxf((sim.pits.laps_after_this(car) + 1.15) * sim.pits.fuel_per_lap(car) - sim.cars[car].fuel_l, 0.0)
	return minf(want, room)


## Laps that fuel adds to car i, in a few words ("+4.2 laps"); "" with fuel off.
static func fuel_laps_text(sim: RaceSim, car: int, plan_fuel: float) -> String:
	var fpl := sim.pits.fuel_per_lap(car)
	if fpl <= 0.0:
		return ""
	return "+%.1f laps" % (fuel_added_l(sim, car, plan_fuel) / fpl)


## A fuel choice with what it does: "+23 L (+4.2 laps)", "to the end (31 L)".
static func fuel_choice_text(sim: RaceSim, car: int, plan_fuel: float) -> String:
	if plan_fuel < 0.0:
		return "to the end (%d L)" % roundi(fuel_added_l(sim, car, plan_fuel))
	if plan_fuel == 0.0:
		return "none"
	var laps := fuel_laps_text(sim, car, plan_fuel)
	var added := fuel_added_l(sim, car, plan_fuel)
	var txt := "+%d L" % int(plan_fuel)
	if added < plan_fuel - 0.5:
		txt += ", fills at %d L" % roundi(added)   # the tank has less room than that now
	return txt + ("  (%s)" % laps if laps != "" else "")


## Damage panel: a top view of the car with each zone coloured by how bent
## it is, flat tyres in red, and (full damage) each system's state.
func _draw_damage(c: CarState, full: bool) -> void:
	var o := Vector2.ZERO
	_panel(Rect2(o, Vector2(300, 116)))
	_text(o + Vector2(14, 22), "DAMAGE", 14, Color(1, 1, 1, 0.7))
	var car := Rect2(o + Vector2(36, 32), Vector2(40, 74))  # nose at the top
	var b := c.body_damage
	draw_rect(car, Color(0.25, 0.25, 0.28))
	draw_rect(Rect2(car.position, Vector2(car.size.x, 16)), _damage_colour(b[CarDamage.FRONT]))
	draw_rect(Rect2(car.position + Vector2(0, car.size.y - 16), Vector2(car.size.x, 16)), _damage_colour(b[CarDamage.REAR]))
	draw_rect(Rect2(car.position + Vector2(0, 18), Vector2(9, car.size.y - 36)), _damage_colour(b[CarDamage.LEFT]))
	draw_rect(Rect2(car.position + Vector2(car.size.x - 9, 18), Vector2(9, car.size.y - 36)), _damage_colour(b[CarDamage.RIGHT]))
	var wheels := [Vector2(-10, 8), Vector2(car.size.x + 2, 8), Vector2(-10, car.size.y - 26), Vector2(car.size.x + 2, car.size.y - 26)]
	for w in 4:
		var flat := c.puncture[w] > 0.5
		draw_rect(Rect2(car.position + wheels[w], Vector2(8, 18)), Color(1, 0.15, 0.1) if flat else Color(0.08, 0.08, 0.08))
	if not full:
		_text(o + Vector2(110, 60), "Visual only", 15, Color(1, 1, 1, 0.6))
		return
	var rows := [["Aero", c.damage_aero], ["Suspension", maxf(c.damage_suspension, absf(c.alignment))],
		["Engine", c.damage_engine], ["Gearbox", c.damage_gearbox]]
	for k in rows.size():
		var y := o.y + 26 + k * 20
		var v: float = rows[k][1]
		_text(Vector2(o.x + 110, y + 12), rows[k][0], 14)
		draw_rect(Rect2(o.x + 196, y + 1, 90, 12), Color(1, 1, 1, 0.12))
		draw_rect(Rect2(o.x + 196, y + 1, 90 * v, 12), _damage_colour(v))
	var note := ""
	if CarDamage.engine_failed(c):
		note = "ENGINE FAILED"
	elif CarDamage.punctures(c) > 0:
		note = "PUNCTURE"
	elif absf(c.alignment) > 0.1:
		note = "Pulls " + ("right" if c.alignment > 0.0 else "left")
	if note != "":
		_text(Vector2(o.x + 110, o.y + 110), note, 14, Color(1, 0.55, 0.35))


static func _damage_colour(v: float) -> Color:
	if v < 0.02:
		return Color(0.3, 0.8, 0.4, 0.9)
	if v < 0.5:
		return Color(0.3, 0.8, 0.4).lerp(Color(1.0, 0.85, 0.2), v / 0.5)
	return Color(1.0, 0.85, 0.2).lerp(Color(1.0, 0.2, 0.15), clampf((v - 0.5) / 0.5, 0.0, 1.0))


static func _surface_text(env: SimEnvironment) -> String:
	if env.wetness < 0.05:
		return "Track dry"
	var s := "Track %s %d%%" % ["soaked" if env.wetness > 0.75 else ("wet" if env.wetness > 0.3 else "damp"), int(env.wetness * 100.0)]
	if env.dry_line > 0.35 and env.rain < 0.1:
		s += ", dry line"
	return s


static func _forecast_text(env: SimEnvironment) -> String:
	var t := env.next_change_in()
	if t < 0.0 or t > 300.0:
		return ""
	var nxt := env.next_weather()
	if nxt == env.weather:
		return ""
	return "%s in %d:%02d" % [SimEnvironment.weather_name(nxt), int(t) / 60, int(t) % 60]


func _temp_colour(t: float, tc: TyreCompound) -> Color:
	var x := (t - tc.optimal_temp_c) / tc.temp_window_c
	if x < 0.0:
		return Color(0.3, 0.55, 1.0).lerp(Color(0.3, 0.9, 0.4), clampf(1.0 + x, 0.0, 1.0))
	return Color(0.3, 0.9, 0.4).lerp(Color(1.0, 0.3, 0.2), clampf(x, 0.0, 1.0))


## [title, line, colour] for the flag board (top centre): yellow flags, VSC,
## safety car, restart, and what the player has to do (keep the delta, give a
## place back...). Title and line are "" when there's nothing to show.
func _flag_lines(me: int) -> Array:
	var sim := session.sim
	var rc := sim.race_control
	var state := rc.neutralisation()
	var line := rc.instruction_for(me) if me >= 0 else ""
	var title := ""
	var col := Color(1, 0.85, 0.1)
	match state:
		"sc":
			title = "SAFETY CAR"
			if rc.stage == "in_this_lap":
				title = "SAFETY CAR IN THIS LAP"
				col = Color(0.3, 0.9, 0.4)   # its lights have gone green
			elif rc.stage == "restart":
				title = "RESTART"
				col = Color(0.3, 0.9, 0.4)
		"vsc":
			title = "VSC ENDING" if rc.stage == "ending" else "VIRTUAL SAFETY CAR"
		"yellow":
			if me >= 0 and rc.double_yellow_at(sim.cars[me].track_s):
				title = "DOUBLE YELLOW"
			elif me >= 0 and rc.yellow_at(sim.cars[me].track_s):
				title = "YELLOW FLAG"
	return [title, line, col]


## How opaque the flag board is (0..1): see-through over the track.
const FLAG_BOARD_ALPHA := 0.55


func _draw_race_control(me: int) -> void:
	var rc := session.sim.race_control
	var fl := _flag_lines(me)
	var title: String = fl[0]
	var line: String = fl[1]
	var col: Color = fl[2]
	var sample := title == "" and line == ""
	if sample:   # layout editor
		title = "YELLOW FLAG"
		line = "Race control: slow down, no overtaking"
	var w := 520.0
	var r := Rect2(0, 0, w, 58 if line != "" and title != "" else 34)
	# See-through, so the track ahead still shows under it.
	if title != "":
		draw_rect(r, Color(0, 0, 0, FLAG_BOARD_ALPHA * 0.6))
		var flash := int(Time.get_ticks_msec() / 400) % 2 == 0 or rc.neutralisation() == "sc" or sample
		var bar := col if flash else col.darkened(0.35)
		bar.a = FLAG_BOARD_ALPHA
		draw_rect(Rect2(r.position, Vector2(w, 34)), bar)
		_text(r.position + Vector2(0, 25), title, 22, Color(0, 0, 0, 0.9), HORIZONTAL_ALIGNMENT_CENTER, w)
	if line != "" and line.to_upper() != title:
		var y := r.position.y + (52 if title != "" else 24)
		if title == "":
			draw_rect(r, Color(0, 0, 0, FLAG_BOARD_ALPHA * 0.6))
		var warn := rc.give_back.has(me)
		_text(Vector2(r.position.x, y), line, 17, Color(1, 0.5, 0.3) if warn else Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, w)
		if _giving_back(me):
			_draw_give_back_row(me, Vector2(0, y + 6), w)


## Is our car under orders to give a place back (and to whom we know)?
func _giving_back(me: int) -> bool:
	return me >= 0 and give_back_to != -1 and session.sim.race_control.give_back.has(me)


## Under the give-back order: the car to let past (its colour, model and
## where it is from us), in the same orange-red as its outline on track.
func _draw_give_back_row(me: int, at: Vector2, w: float) -> void:
	var sim := session.sim
	draw_rect(Rect2(at.x, at.y, w, 24), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(at.x, at.y, 4, 24), GIVE_BACK_COL)
	var what := ""
	var gap := 0.0
	if give_back_to == RaceControl.GIVE_BACK_SC:
		what = "Safety car"
		gap = sim.race_control.gap_to_sc(me)
		if gap > sim.track.length * 0.5:
			gap -= sim.track.length
	else:
		var j := give_back_to
		draw_rect(Rect2(at.x + 12, at.y + 5, 14, 14), sim.defs[j].colour)
		what = "%s  P%d" % [sim.defs[j].display_name, sim.running_order.find(j) + 1]
		gap = sim.entries[j].distance - sim.entries[me].distance
	var where := "alongside"
	if gap > 4.0:
		where = "%d m ahead" % roundi(gap)
	elif gap < -4.0:
		where = "%d m behind you" % roundi(-gap)
	_text(Vector2(at.x, at.y + 18), "LET PAST:  %s  -  %s" % [what, where], 15, GIVE_BACK_COL, HORIZONTAL_ALIGNMENT_CENTER, w)


## When the car to let past is off screen, an arrow on the screen's edge
## points to it (the 3D "LET PAST" tag marks it once it's in view).
func _draw_give_back_pointer(me: int) -> void:
	if not _giving_back(me) or not car_screen_pos.is_valid():
		return
	var sp = car_screen_pos.call(give_back_to)
	if not (sp is Vector2):
		return
	var view := Rect2(Vector2.ZERO, size)
	if view.grow(-30.0).has_point(sp):
		return
	var c := view.get_center()
	var d: Vector2 = sp - c
	if d.length() < 1.0:
		return
	var inner := view.grow(-44.0)
	var half := inner.size * 0.5
	var k := minf(half.x / maxf(absf(d.x), 0.001), half.y / maxf(absf(d.y), 0.001))
	var tip := c + d * k
	var dir := d.normalized()
	var side := dir.orthogonal()
	var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.007)
	var col := Color(GIVE_BACK_COL, pulse)
	draw_colored_polygon(PackedVector2Array([tip + dir * 18.0, tip - dir * 10.0 + side * 16.0, tip - dir * 10.0 - side * 16.0]), col)
	draw_polyline(PackedVector2Array([tip + dir * 18.0, tip - dir * 10.0 + side * 16.0, tip - dir * 10.0 - side * 16.0, tip + dir * 18.0]),
		Color(0, 0, 0, 0.7), 2.0)
	var label_at := tip - dir * 40.0 + Vector2(-60, 5)
	_text(label_at, "LET PAST", 14, col, HORIZONTAL_ALIGNMENT_CENTER, 120)


func _leader_lap() -> int:
	var sim := session.sim
	if sim.running_order.is_empty():
		return 0
	var e := sim.entries[sim.running_order[0]]
	return mini(e.laps_done + 1, sim.settings.laps)


func _build_minimap() -> void:
	var t := session.sim.track
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in t.points:
		lo = lo.min(p)
		hi = hi.max(p)
	for p in t.joker_path:
		lo = lo.min(p)
		hi = hi.max(p)
	var span := hi - lo
	var scale_f := 200.0 / maxf(span.x, span.y)
	_mm_rect = Rect2(lo, span)
	for i in range(0, t.point_count(), 4):
		_minimap_pts.append((t.points[i] - lo) * scale_f)
	_minimap_pts.append(_minimap_pts[0])
	set_meta("mm_scale", scale_f)


func _draw_minimap(origin: Vector2) -> void:
	var scale_f: float = get_meta("mm_scale", 1.0)
	var span := _mm_rect.size * scale_f
	_panel(Rect2(origin - Vector2(10, 10), span + Vector2(20, 20)))
	var pts := PackedVector2Array()
	for p in _minimap_pts:
		pts.append(origin + p)
	draw_polyline(pts, Color(1, 1, 1, 0.7), 3.0)
	var sim := session.sim
	var rc := sim.race_control
	var t := sim.track
	if t.has_joker():
		_draw_minimap_joker(origin, scale_f)
	# Yellow flag zones along the track, and the safety car.
	for y in rc.yellows:
		var zone := PackedVector2Array()
		var from: float = y["from"]
		var to: float = y["to"]
		var span_m := fposmod(to - from, t.length)
		for k in 9:
			zone.append(origin + (t.position_at(from + span_m * k / 8.0) - _mm_rect.position) * scale_f)
		draw_polyline(zone, Color(1, 0.85, 0.1), 5.0)
	# (The rejoin band is the strategist's: not on the driver's map.)
	# Double yellows where marshals are out: a thicker band (circuits only).
	for job in (rc.marshal_jobs if rc.flags_used() else []):
		var zone := PackedVector2Array()
		var from := float(job["s"]) - TrackMarshals.DOUBLE_BEFORE_M
		var span_m := TrackMarshals.DOUBLE_BEFORE_M + TrackMarshals.DOUBLE_AFTER_M
		for k in 9:
			zone.append(origin + (t.position_at(from + span_m * k / 8.0) - _mm_rect.position) * scale_f)
		draw_polyline(zone, Color(1, 0.85, 0.1), 9.0)
	if rc.sc_visible:
		var sp := origin + (rc.sc_pos - _mm_rect.position) * scale_f
		draw_rect(Rect2(sp - Vector2(5, 5), Vector2(10, 10)), Color(1, 0.6, 0.1))
		_text(sp + Vector2(7, 4), "SC", 11, Color(1, 0.75, 0.3))
	for i in sim.car_count():
		var p := origin + (sim.cars[i].pos - _mm_rect.position) * scale_f
		draw_circle(p, 5.0 if i == session.local_car else 3.5, sim.defs[i].colour)
		if i == session.local_car:
			draw_arc(p, 7.0, 0, TAU, 16, Color.WHITE, 1.5)


## The compact standings list (top right), used when the timing tower is off.
func _standings_rows() -> int:
	return mini(session.sim.running_order.size(), 16)


func _draw_standings(me: int) -> void:
	var sim := session.sim
	var x0 := 10.0
	var rows := _standings_rows()
	_panel(Rect2(0, 0, 330, 34 + rows * 22))
	_text(Vector2(x0, 22), "LAP %d / %d" % [_leader_lap(), sim.settings.laps], 16, Color(1, 1, 1, 0.8))
	for p in rows:
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var kind := row_kind(i, me)
		var col := row_text_colour(kind)
		if kind != ROW_AI:
			_draw_player_row(Rect2(x0 - 6, 30 + p * 22, 320, 20), kind)
		var right := _status_text(i)
		if right == "" and p > 0:
			var gap := sim.entries[sim.running_order[0]].distance - e.distance
			right = "+%.0f m" % gap if gap < sim.track.length else "+%d lap" % int(gap / sim.track.length)
		draw_rect(Rect2(x0, 32 + p * 22, 8, 14), sim.defs[i].colour)
		_text(Vector2(x0 + 14, 45 + p * 22), "%2d  %s" % [p + 1, e.at_wheel().left(18)], 15, col)
		if sim.pits.enabled and int(e.pit.get("stops", 0)) > 0:
			_text(Vector2(x0 + 172, 45 + p * 22), str(e.pit["stops"]), 12, Color(1, 1, 1, 0.55))
		if e.penalty_s > 0.0:
			_text(Vector2(x0 + 140, 45 + p * 22), "+%ds" % int(e.penalty_s), 13, Color(1, 0.55, 0.3))
		_text(Vector2(x0 + 200, 45 + p * 22), right, 15, col, HORIZONTAL_ALIGNMENT_RIGHT, 110)


## PIT / FIN / DNF for a car, or "" while it's racing.
func _status_text(i: int) -> String:
	var sim := session.sim
	var e := sim.entries[i]
	if e.finished:
		return "FIN"
	if e.dnf:
		return "DNF"
	if sim.in_pit_lane(i):
		return "PIT"
	if sim.cars[i].in_joker:
		return "JKR"
	return ""


## Which rows of the running order the tower shows: everyone if they fit,
## otherwise the top three and a window around the player.
static func tower_rows(order_size: int, my_pos: int, max_rows: int) -> Array[int]:
	var out: Array[int] = []
	if order_size <= max_rows:
		for p in order_size:
			out.append(p)
		return out
	var top := 3
	for p in top:
		out.append(p)
	var span := max_rows - top
	var from := clampi(my_pos - span / 2, top, order_size - span)
	for p in range(from, from + span):
		out.append(p)
	return out


## Timing tower (left column): position, manufacturer badge, driver, last lap
## and the gap to the car ahead. The player's row is highlighted.
## How many rows the tower has room for (keeping clear of the tyre panel).
func _tower_max_rows() -> int:
	return maxi(int((size.y / layout.scale_of("tower") - 206.0 - 84.0) / TOWER_ROW), 6)


func _tower_height() -> float:
	var n := session.sim.running_order.size()
	var rows := mini(n, _tower_max_rows())
	return 62.0 + rows * TOWER_ROW + (6.0 if rows < n else 0.0)


func _draw_tower(me: int) -> void:
	var sim := session.sim
	var tel := session.telemetry
	var n := sim.running_order.size()
	var my_pos := sim.running_order.find(me)
	var shown := tower_rows(n, maxi(my_pos, 0), _tower_max_rows())
	var x := 0.0
	var top := 0.0
	var h := _tower_height()
	_panel(Rect2(x, top, TOWER_W, h))
	_text(Vector2(x + 12, top + 26), "LAP %d / %d" % [_leader_lap(), sim.settings.laps], 18, Color.WHITE)
	_text(Vector2(x + 12, top + 26), "%d CARS" % n, 14, Color(1, 1, 1, 0.55), HORIZONTAL_ALIGNMENT_RIGHT, TOWER_W - 24)
	var head := Color(1, 1, 1, 0.45)
	_text(Vector2(x + 12, top + 50), "POS", 11, head)
	_text(Vector2(x + 86, top + 50), "DRIVER", 11, head)
	_text(Vector2(x + 202, top + 50), "LAST", 11, head)
	_text(Vector2(x + 274, top + 50), "GAP", 11, head, HORIZONTAL_ALIGNMENT_RIGHT, 66)
	var y := top + 58.0
	var prev := -1
	for p in shown:
		if prev >= 0 and p != prev + 1:
			draw_line(Vector2(x + 12, y + 2), Vector2(x + TOWER_W - 12, y + 2), Color(1, 1, 1, 0.25), 1.0)
			y += 6.0
		prev = p
		var i := sim.running_order[p]
		var e := sim.entries[i]
		var kind := row_kind(i, me)
		var mine := kind == ROW_ME
		var row := Rect2(x + 2, y, TOWER_W - 4, TOWER_ROW)
		if mine:
			_draw_player_row(row, kind)
		elif i == give_back_to and _giving_back(me):
			draw_rect(row, Color(GIVE_BACK_COL, 0.3))
		elif kind != ROW_AI:
			_draw_player_row(row, kind)
		elif p % 2 == 1:
			draw_rect(row, Color(1, 1, 1, 0.04))
		var col := row_text_colour(kind)
		var base := y + TOWER_ROW - 6.0
		draw_rect(Rect2(x + 4, y + 3, 4, TOWER_ROW - 6), sim.defs[i].colour)
		if kind != ROW_AI:   # position in a solid tag, like a TV graphic
			draw_rect(Rect2(x + 11, y + 2, 30, TOWER_ROW - 4), ROW_ME_COLOUR if mine else ROW_PLAYER_COLOUR)
			draw_string(font, Vector2(x + 12, base), str(p + 1), HORIZONTAL_ALIGNMENT_RIGHT, 26, 16, Color(0.05, 0.05, 0.08))
		else:
			_text(Vector2(x + 12, base), str(p + 1), 16, col, HORIZONTAL_ALIGNMENT_RIGHT, 26)
		draw_badge(Rect2(x + 44, y + 3, 36, TOWER_ROW - 6), sim.defs[i])
		_text(Vector2(x + 86, base), short_name(e.at_wheel()), 16 if mine else 15, col)
		var tc: CarTelemetry = tel.cars[i] if tel != null and i < tel.cars.size() else null
		var last := e.lap_times[-1] if e.lap_times.size() > 0 else 0.0
		var last_col := Color(1, 1, 1, 0.8)
		if last > 0.0 and tel != null and tel.fastest_lap > 0.0 and absf(last - tel.fastest_lap) < 0.0005:
			last_col = SECTOR_PURPLE
		_text(Vector2(x + 202, base), fmt_lap(last), 15, last_col)
		var gap := _status_text(i)
		var gap_col := Color(1, 0.6, 0.3) if gap == "PIT" else Color(1, 1, 1, 0.8)
		if gap == "":
			if p == 0:
				gap = "Leader"
				gap_col = Color(1, 1, 1, 0.55)
			else:
				gap = _interval_text(sim.running_order[p - 1], i, tc.interval if tc != null else 0.0)
		_text(Vector2(x + 274, base), gap, 15, gap_col, HORIZONTAL_ALIGNMENT_RIGHT, 66)
		if e.penalty_s > 0.0:
			_text(Vector2(x + 166, base), "+%ds" % int(e.penalty_s), 11, Color(1, 0.55, 0.3))
		y += TOWER_ROW


## Tower and standings rows: this player's car (or the team's car on the pit
## wall), a car another person online is driving, or an AI car.
const ROW_AI := 0
const ROW_ME := 1
const ROW_PLAYER := 2
const ROW_ME_COLOUR := Color(1.0, 0.8, 0.22)
const ROW_PLAYER_COLOUR := Color(0.3, 0.75, 1.0)


func row_kind(i: int, me: int) -> int:
	var mine := me if me >= 0 else session.team_car
	if i == mine:
		return ROW_ME
	var e := session.sim.entries[i]
	if not e.is_ai or e.is_player_driving():
		return ROW_PLAYER
	return ROW_AI


static func row_text_colour(kind: int) -> Color:
	match kind:
		ROW_ME: return Color(1, 0.95, 0.7)
		ROW_PLAYER: return Color(0.8, 0.92, 1)
	return Color.WHITE


## A player's row stands right out: a strong tinted band with a bright frame
## and a solid edge stripe, gold for you (gently breathing so the eye finds
## it), blue for other people online.
func _draw_player_row(r: Rect2, kind: int) -> void:
	var c := ROW_ME_COLOUR if kind == ROW_ME else ROW_PLAYER_COLOUR
	var glow := 1.0
	if kind == ROW_ME:
		glow = 0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.004)
	draw_rect(r, Color(c, 0.42 * glow))
	draw_rect(r.grow(-1.0), Color(c, 0.95), false, 2.0)
	draw_rect(Rect2(r.end.x - 7.0, r.position.y, 7.0, r.size.y), c)


## Gap from car `behind` to car `ahead`: whole laps when it's been lapped,
## otherwise the timed interval ("+1.234").
func _interval_text(ahead: int, behind: int, secs: float) -> String:
	var sim := session.sim
	var laps := int((sim.entries[ahead].distance - sim.entries[behind].distance) / sim.track.length)
	if laps >= 1:
		return "+%d LAP%s" % [laps, "S" if laps > 1 else ""]
	if secs <= 0.0:
		return "--"
	return "+%.3f" % secs if secs < 100.0 else "+%.0f" % secs


## Bottom centre: this lap's sector times (purple = fastest of anyone, green =
## personal best, yellow = slower; white is the sector being driven now),
## flanked by the gap to the car ahead (left) and behind (right).
const SECTOR_BOX_W := 108.0
const GAP_W := 210.0


func _sectors_width() -> float:
	var n := session.sim.track.sectors.size()
	return GAP_W * 2.0 + n * SECTOR_BOX_W + (n - 1) * 6.0 + 24.0


func _draw_sectors_and_gaps(me: int) -> void:
	var sim := session.sim
	var e := sim.entries[me]
	var n := sim.track.sectors.size()
	var box_w := SECTOR_BOX_W
	var gap_w := GAP_W
	var w := _sectors_width()
	var r := Rect2(0, 0, w, 82)
	_panel(r)
	# Sectors
	var since_line := sim.race_time - e.sector_start_time
	var hold := e.sector_times.is_empty() and e.last_sector_times.size() == n and e.laps_done > 0 \
		and (since_line < LAP_HOLD_S or e.finished)
	var x := r.position.x + 12.0 + gap_w
	for k in n:
		var br := Rect2(x + k * (box_w + 6.0), r.position.y + 10, box_w, 62)
		var t := 0.0
		var col := Color(1, 1, 1, 0.35)
		var bar := Color(1, 1, 1, 0.12)
		if hold:
			t = e.last_sector_times[k]
			col = sector_colour(k, t, me)
			bar = col
		elif k < e.sector_times.size():
			t = e.sector_times[k]
			col = sector_colour(k, t, me)
			bar = col
		elif k == e.sector_times.size() and e.started_lap and not e.finished and sim.phase == RaceSim.Phase.RACING:
			t = since_line
			col = Color.WHITE
			bar = Color(1, 1, 1, 0.5)
		elif k < e.last_sector_times.size():
			t = e.last_sector_times[k]  # last lap's time, dimmed, until this lap gets there
		draw_rect(br, Color(0, 0, 0, 0.35))
		draw_rect(Rect2(br.position, Vector2(br.size.x, 5)), bar)
		_text(br.position + Vector2(0, 24), "S%d" % (k + 1), 13, Color(1, 1, 1, 0.6), HORIZONTAL_ALIGNMENT_CENTER, box_w)
		_text(br.position + Vector2(0, 52), fmt_sector(t), 22, col, HORIZONTAL_ALIGNMENT_CENTER, box_w)
	# Gaps
	_sample_gap_trend(me)
	var my_pos := sim.running_order.find(me)
	var ahead := sim.running_order[my_pos - 1] if my_pos > 0 else -1
	var behind := sim.running_order[my_pos + 1] if my_pos >= 0 and my_pos + 1 < sim.running_order.size() else -1
	var tc: CarTelemetry = session.telemetry.cars[me] if session.telemetry != null and me < session.telemetry.cars.size() else null
	var left := Rect2(r.position.x + 12, r.position.y + 10, gap_w - 12, 62)
	var right := Rect2(r.end.x - gap_w, r.position.y + 10, gap_w - 12, 62)
	# Car behind on the left, car in front on the right (the way you're going).
	_draw_gap(right, "AHEAD", ahead, my_pos, _interval_text(ahead, me, tc.interval if tc != null else 0.0) if ahead >= 0 else "", -_gap_trend.x, HORIZONTAL_ALIGNMENT_RIGHT)
	var behind_txt := ""
	if behind >= 0:
		behind_txt = _interval_text(me, behind, tc.gap_behind if tc != null else 0.0).replace("+", "-")
	_draw_gap(left, "BEHIND", behind, my_pos + 2, behind_txt, _gap_trend.y, HORIZONTAL_ALIGNMENT_LEFT)


## One side of the gap readout. `trend` > 0 means the gap is growing in the
## player's favour (green), < 0 means they're losing time (red).
func _draw_gap(r: Rect2, label: String, car: int, pos: int, gap: String, trend: float, align: HorizontalAlignment) -> void:
	var sim := session.sim
	if car < 0:
		_text(r.position + Vector2(0, 22), label, 12, Color(1, 1, 1, 0.45), align, r.size.x)
		_text(r.position + Vector2(0, 50), "LEADING" if label == "AHEAD" else "—", 20, Color(1, 1, 1, 0.5), align, r.size.x)
		return
	_text(r.position + Vector2(0, 22), "%s  P%d  %s" % [label, pos, short_name(sim.entries[car].at_wheel())], 13, Color(1, 1, 1, 0.65), align, r.size.x)
	var col := Color.WHITE
	if trend > 0.05:
		col = SECTOR_GREEN
	elif trend < -0.05:
		col = Color(1, 0.45, 0.4)
	_text(r.position + Vector2(0, 54), gap, 28, col, align, r.size.x)


## Every 2 s: did the gaps to the cars ahead and behind shrink or grow?
func _sample_gap_trend(me: int) -> void:
	var tel := session.telemetry
	if tel == null or me >= tel.cars.size():
		return
	var now := session.sim.race_time
	if now - _gap_sample_t < 2.0 and now >= _gap_sample_t:
		return
	var tc := tel.cars[me]
	var cur := Vector2(tc.interval, tc.gap_behind)
	if _gap_sample.x > 0.0 and cur.x > 0.0:
		_gap_trend.x = cur.x - _gap_sample.x   # ahead: growing gap is bad
	else:
		_gap_trend.x = 0.0
	if _gap_sample.y > 0.0 and cur.y > 0.0:
		_gap_trend.y = cur.y - _gap_sample.y   # behind: growing gap is good
	else:
		_gap_trend.y = 0.0
	_gap_sample = cur
	_gap_sample_t = now


## Purple for the fastest sector anyone has done, green for a personal best,
## yellow for slower.
func sector_colour(k: int, t: float, car: int) -> Color:
	var tel := session.telemetry
	if t <= 0.0 or tel == null:
		return Color.WHITE
	var overall := tel.best_sectors[k] if k < tel.best_sectors.size() else 0.0
	var personal := 0.0
	if car < tel.cars.size() and k < tel.cars[car].best_sectors.size():
		personal = tel.cars[car].best_sectors[k]
	if overall <= 0.0 or t <= overall + 0.0005:
		return SECTOR_PURPLE
	if personal <= 0.0 or t <= personal + 0.0005:
		return SECTOR_GREEN
	return SECTOR_YELLOW


static func fmt_sector(t: float) -> String:
	if t <= 0.0:
		return "--.---"
	if t >= 60.0:
		return fmt_time(t)
	return "%.3f" % t


static func fmt_lap(t: float) -> String:
	return "--:--.---" if t <= 0.0 else fmt_time(t)


## "Max Verstappen" -> "M. Verstappen", kept short enough for the tower.
static func short_name(full: String) -> String:
	var parts := full.strip_edges().split(" ", false)
	var s := full.strip_edges()
	if s.length() > 15 and parts.size() >= 2:
		s = "%s. %s" % [parts[0].left(1), " ".join(parts.slice(1))]
	return s.left(15)


## Manufacturer badges, drawn as monograms in the brand's colours (we don't
## ship real logos). Keyed by a lower-case word found in the car's name or its
## "manufacturer" field.
const BADGES := {
	"bmw": ["BMW", Color(1, 1, 1), Color(0.0, 0.4, 0.8)],
	"ferrari": ["FER", Color(1.0, 0.85, 0.0), Color(0.05, 0.05, 0.05)],
	"porsche": ["POR", Color(0.08, 0.08, 0.08), Color(0.85, 0.7, 0.3)],
	"lamborghini": ["LAM", Color(0.08, 0.08, 0.08), Color(0.9, 0.75, 0.3)],
	"mclaren": ["McL", Color(1.0, 0.5, 0.0), Color(0.05, 0.05, 0.05)],
	"mercedes": ["AMG", Color(0.75, 0.77, 0.8), Color(0.05, 0.05, 0.05)],
	"amg": ["AMG", Color(0.75, 0.77, 0.8), Color(0.05, 0.05, 0.05)],
	"lotus": ["LOT", Color(0.0, 0.4, 0.2), Color(1.0, 0.85, 0.1)],
	"aston": ["AM", Color(0.0, 0.33, 0.25), Color(0.85, 1.0, 0.6)],
	"audi": ["AUDI", Color(0.1, 0.1, 0.1), Color(0.9, 0.9, 0.9)],
	"toyota": ["TOY", Color(0.9, 0.1, 0.15), Color(1, 1, 1)],
	"cadillac": ["CAD", Color(0.1, 0.1, 0.15), Color(0.85, 0.75, 0.4)],
	"peugeot": ["PEU", Color(0.12, 0.12, 0.12), Color(0.6, 1.0, 0.3)],
	"alpine": ["ALP", Color(0.0, 0.35, 0.8), Color(1, 1, 1)],
	"acura": ["ACU", Color(0.1, 0.1, 0.1), Color(0.95, 0.2, 0.2)],
	"oreca": ["ORE", Color(0.0, 0.25, 0.55), Color(1, 1, 1)],
	"ligier": ["LIG", Color(0.0, 0.2, 0.45), Color(0.95, 0.95, 0.95)],
	"corvette": ["CORV", Color(0.95, 0.8, 0.1), Color(0.05, 0.05, 0.05)],
	"ford": ["FORD", Color(0.0, 0.2, 0.55), Color(1, 1, 1)],
	"lexus": ["LEX", Color(0.1, 0.1, 0.1), Color(0.85, 0.85, 0.85)],
	"bentley": ["BEN", Color(0.0, 0.25, 0.15), Color(0.9, 0.9, 0.9)],
	"nissan": ["NIS", Color(0.75, 0.0, 0.1), Color(1, 1, 1)],
	"honda": ["HON", Color(0.85, 0.0, 0.1), Color(1, 1, 1)],
	"volkswagen": ["VW", Color(0.0, 0.2, 0.45), Color(1, 1, 1)],
	"renault": ["REN", Color(1.0, 0.8, 0.0), Color(0.05, 0.05, 0.05)],
	"hyundai": ["HYU", Color(0.0, 0.17, 0.37), Color(1, 1, 1)],
	"skoda": ["ŠKO", Color(0.3, 0.65, 0.3), Color(1, 1, 1)],
	"škoda": ["ŠKO", Color(0.3, 0.65, 0.3), Color(1, 1, 1)],
}


## The badge [text, background, text colour] for a car.
static func badge_for(def: CarDefinition) -> Array:
	var maker := str(def.raw.get("manufacturer", "")).to_lower()
	var name := def.display_name.to_lower().replace("-", " ")
	for key in BADGES:
		if maker.contains(key) or name.begins_with(key) or name.contains(" " + key + " "):
			return BADGES[key]
	var word := maker if maker != "" else (name.split(" ", false)[0] if name != "" else "?")
	return [word.left(3).to_upper(), def.colour.darkened(0.2), Color.WHITE]


func draw_badge(r: Rect2, def: CarDefinition) -> void:
	var b := badge_for(def)
	draw_rect(r, b[1])
	draw_rect(r, Color(1, 1, 1, 0.35), false, 1.0)
	var fs := 12 if str(b[0]).length() <= 3 else 10
	draw_string(font, Vector2(r.position.x, r.position.y + r.size.y * 0.5 + fs * 0.36), str(b[0]),
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, b[2])
