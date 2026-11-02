class_name TeamRadio
extends Control
## Quick radio calls between a car's driver and its pit wall (co-op): a small
## controller-friendly menu of ready-made calls. The pit wall sends orders and
## warnings ("Box this lap", "Rain coming"); the driver answers ("Copy",
## "Tyres are gone"). Messages go out with RaceSession.send_team_radio and
## arrive at every member of the car's crew as the session's team_radio signal.
##
## D-pad / arrows choose, A / Enter sends, B / Esc / V closes. Number keys
## 1-9 send a call straight away.

signal sent(msg: Dictionary)

## [code, label shown in the menu, text heard by the other side]
const CREW_CALLS := [
	["box_now", "Box this lap", "Box, box. Box this lap."],
	["stay_out", "Stay out", "Stay out, stay out."],
	["push", "Push now", "Push now, we need the pace."],
	["save_tyres", "Look after the tyres", "Manage the tyres, they have to last."],
	["save_fuel", "Save fuel", "Save fuel: lift and coast where you can."],
	["defend", "Defend", "Car behind is closing. Defend."],
	["gap", "Gap behind: free stop", "You have the gap behind for a free stop."],
	["rain", "Rain coming", "Rain is coming, be ready for a tyre call."],
	["swap", "Driver change at this stop", "Driver change at this stop."],
]
const DRIVER_CALLS := [
	["copy", "Copy", "Copy."],
	["box_q", "Box this lap?", "Should I box this lap?"],
	["tyres_gone", "Tyres are gone", "The tyres are gone, I'm losing grip."],
	["damage", "I have damage", "I have damage, check the car."],
	["wet", "Track is getting wet", "It's getting wet out here."],
	["negative", "Negative, staying out", "Negative, I'm staying out."],
	["traffic", "Stuck in traffic", "I'm stuck in traffic."],
	["fuel_q", "How's the fuel?", "How's my fuel?"],
]
const YELLOW := Color(1.0, 0.88, 0.35)

var session: RaceSession
var car: int = -1
var as_driver := false
var selected := 0
var font: Font


func setup(p_session: RaceSession, p_car: int, p_as_driver: bool) -> void:
	session = p_session
	car = p_car
	as_driver = p_as_driver
	font = ThemeDB.fallback_font
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	visible = false


func calls() -> Array:
	return DRIVER_CALLS if as_driver else CREW_CALLS


func open() -> void:
	selected = 0
	visible = true


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


## The message a call makes (also used by the pit crew for automatic calls).
static func make_message(code: String, text: String, from_name: String, role: String) -> Dictionary:
	return {"kind": "radio" if code == "" else "ping", "code": code, "text": text, "from": from_name, "role": role}


## Sends call k (an index into calls()). Returns the message sent.
func send(k: int) -> Dictionary:
	var list := calls()
	if k < 0 or k >= list.size() or session == null or car < 0:
		return {}
	var role := RaceEntry.ROLE_DRIVER if as_driver else str(session.local_role)
	var msg := make_message(list[k][0], list[k][2], my_name(), role)
	session.send_team_radio(car, msg)
	sent.emit(msg)
	close()
	return msg


func my_name() -> String:
	if session == null or car < 0:
		return "Pit wall"
	var e := session.sim.entries[car]
	for m in e.crew:
		if int(m.get("peer_id", 0)) == session.local_peer:
			return str(m.get("name", "Pit wall"))
	return e.driver_name if as_driver else "Pit wall"


func _input(event: InputEvent) -> void:
	if not visible or not event.is_pressed():
		return
	var n := calls().size()
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("team_radio"):
		close()
	elif event.is_action_pressed("ui_up", true):
		selected = posmod(selected - 1, n)
	elif event.is_action_pressed("ui_down", true):
		selected = posmod(selected + 1, n)
	elif event.is_action_pressed("ui_accept"):
		send(selected)
	elif event is InputEventKey and event.keycode >= KEY_1 and event.keycode <= KEY_9:
		send(int(event.keycode - KEY_1))
	else:
		return
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if visible:
		size = get_viewport_rect().size
		queue_redraw()


func _draw() -> void:
	var list := calls()
	var w := 440.0
	var rh := 38.0
	var h := 64.0 + list.size() * rh + 34.0
	var r := Rect2((size.x - w) * 0.5, (size.y - h) * 0.5, w, h)
	draw_rect(r, Color(0.02, 0.04, 0.07, 0.94))
	draw_rect(r, Color(1, 0.88, 0.35, 0.5), false, 2.0)
	var title := "RADIO TO THE PIT WALL" if as_driver else "RADIO TO THE DRIVER"
	draw_string(font, r.position + Vector2(18, 38), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, YELLOW)
	for k in list.size():
		var y := r.position.y + 58 + k * rh
		var row := Rect2(r.position.x + 10, y, w - 20, rh - 4)
		if k == selected:
			draw_rect(row, Color(1, 0.88, 0.35, 0.18))
			draw_rect(row, Color(1, 0.88, 0.35, 0.7), false, 1.5)
		draw_string(font, Vector2(row.position.x + 10, y + 24), str(k + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.45))
		draw_string(font, Vector2(row.position.x + 38, y + 24), list[k][1], HORIZONTAL_ALIGNMENT_LEFT, w - 70, 18, Color.WHITE)
	draw_string(font, Vector2(r.position.x + 18, r.end.y - 12), "↑↓ choose   A send   B close", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.5))
