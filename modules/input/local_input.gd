class_name LocalInput
extends RefCounted
## Reads keyboard / gamepad into a CarInput once per physics tick.
## Gamepad: analog triggers and stick pass straight through (with a response
## curve on steering). Keyboard: digital keys are smoothed so steering ramps
## like a stick, and steering lock is reduced with speed as a driving aid.

const KEY_STEER_RATE := 3.5     ## per second, at low speed
const KEY_STEER_RATE_FAST := 1.6 ## per second, flat out (a tap is a small correction)
const KEY_CENTER_RATE := 6.0
## Speed-sensitive lock: share of full lock left at speed (v in m/s), so
## the same stick or key moves the car about as much at 250 km/h as at 80.
const LOCK_SPEED := 16.0
const LOCK_MIN := 0.14
const KEY_PEDAL_RATE := 8.0
const PAD_STEER_RATE := 7.0     ## per second: takes the twitch out of stick flicks

var _steer := 0.0
var _throttle := 0.0
var _brake := 0.0
## The throttle sent last tick (for engine sound).
var last_throttle := 0.0
## Manual gearbox on: the shift buttons change gear, and on a pad X stops
## working as the brake (the trigger does that).
var manual_gears := false


func read(dt: float, speed_mps: float) -> CarInput:
	var inp := CarInput.new()
	var pad := _pad_active()
	var steer_target := Input.get_axis("steer_left", "steer_right")
	var thr_target := Input.get_action_strength("accelerate")
	var brk_target := Input.get_action_strength("brake")
	inp.handbrake = Input.is_action_pressed("handbrake")
	if manual_gears:
		inp.shift_up = Input.is_action_just_pressed("shift_up")
		inp.shift_down = Input.is_action_just_pressed("shift_down")
		if pad:
			thr_target = _trigger(JOY_AXIS_TRIGGER_RIGHT, "accelerate")
			brk_target = _trigger(JOY_AXIS_TRIGGER_LEFT, "brake")
	if pad:
		# Mild expo so small stick movements are precise at speed.
		var curved := signf(steer_target) * pow(absf(steer_target), 1.6)
		_steer = move_toward(_steer, curved, PAD_STEER_RATE * dt)
		_throttle = thr_target
		_brake = brk_target
	else:
		_steer = key_steer(_steer, steer_target, speed_mps, dt)
		_throttle = move_toward(_throttle, thr_target, KEY_PEDAL_RATE * dt)
		_brake = move_toward(_brake, brk_target, KEY_PEDAL_RATE * dt)
	inp.steer = _steer * steer_lock(speed_mps)
	inp.throttle = _throttle
	inp.brake = _brake
	last_throttle = _throttle
	return inp.quantized()


## Speed-sensitive steering: full lock at low speed, less at high speed.
static func steer_lock(speed_mps: float) -> float:
	return clampf(1.0 / (1.0 + speed_mps / LOCK_SPEED), LOCK_MIN, 1.0)


## Keyboard steering: a held key winds the steering on like a stick (slower
## at speed), letting go or the other key brings it back quickly.
static func key_steer(current: float, target: float, speed_mps: float, dt: float) -> float:
	var rate := KEY_CENTER_RATE
	if absf(target) >= absf(current) and signf(target) == signf(current) or current == 0.0:
		rate = lerpf(KEY_STEER_RATE, KEY_STEER_RATE_FAST, clampf(speed_mps / 60.0, 0.0, 1.0))
	return move_toward(current, target, rate * dt)


## A pedal from the pad trigger only (plus the keyboard keys), not the face buttons.
func _trigger(axis: JoyAxis, action: String) -> float:
	var v := ActivePad.axis(axis)
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey and Input.is_physical_key_pressed(ev.physical_keycode):
			v = 1.0
	return clampf(v, 0.0, 1.0) if v > 0.05 else 0.0


## Only the controller in use counts (see ActivePad): a stray device with an
## axis resting off centre must not switch the keyboard over to pad steering.
func _pad_active() -> bool:
	return absf(ActivePad.axis(JOY_AXIS_LEFT_X)) > 0.15 \
			or ActivePad.axis(JOY_AXIS_TRIGGER_RIGHT) > 0.05 \
			or ActivePad.axis(JOY_AXIS_TRIGGER_LEFT) > 0.05
