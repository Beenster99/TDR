class_name PointerHider
extends Node
## Hides the mouse pointer while the player is driving (game module).
## The race scene says when that is (`driving`): at the wheel, with no menu,
## pit wall, planner, radio, HUD editor, results or pit crew job open. The
## pointer comes back as soon as the mouse moves or clicks, and hides again
## after IDLE_HIDE seconds without moving. Everywhere else (menus, lobby,
## pause menu, strategist and the other pit wall roles) it stays visible.

const IDLE_HIDE := 1.5
## Mouse moves smaller than this (pixels) are jitter and don't wake it.
const MOVE_SHOW := 3.0

## -> bool: is the player driving with nothing for the mouse on screen?
var driving: Callable
var hidden := false
var _idle := 0.0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # offline the pause menu pauses the tree


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.relative.length() >= MOVE_SHOW:
		wake()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index != MOUSE_BUTTON_WHEEL_UP and event.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		wake()   # the wheel zooms while driving: leave the pointer hidden


func _process(delta: float) -> void:
	step(delta, driving.is_valid() and bool(driving.call()))


func _exit_tree() -> void:
	_set_hidden(false)   # back to the menus with a pointer


## The mouse was used: show the pointer and start the idle clock again.
func wake() -> void:
	_idle = 0.0
	_set_hidden(false)


func step(delta: float, is_driving: bool) -> void:
	if not is_driving:
		_idle = 0.0
		_set_hidden(false)
		return
	_idle += delta
	_set_hidden(_idle >= IDLE_HIDE)


func _set_hidden(h: bool) -> void:
	if h == hidden:
		return
	hidden = h
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if h else Input.MOUSE_MODE_VISIBLE
