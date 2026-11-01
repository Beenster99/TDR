class_name LocalInput
extends RefCounted
## Reads keyboard / gamepad into a CarInput once per physics tick.
## Gamepad: analog triggers and stick pass straight through (with a response
## curve on steering). Keyboard: digital keys are smoothed so steering ramps
## like a stick, and steering lock is reduced with speed as a driving aid.

const KEY_STEER_RATE := 3.5     ## per second
const KEY_CENTER_RATE := 6.0
const KEY_PEDAL_RATE := 8.0
const PAD_STEER_RATE := 7.0     ## per second: takes the twitch out of stick flicks

var _steer := 0.0
var _throttle := 0.0
var _brake := 0.0
## The throttle sent last tick (for engine sound).
var last_throttle := 0.0


func read(dt: float, speed_mps: float) -> CarInput:
	var inp := CarInput.new()
	var pad := _pad_active()
	var steer_target := Input.get_axis("steer_left", "steer_right")
	var thr_target := Input.get_action_strength("accelerate")
	var brk_target := Input.get_action_strength("brake")
	if pad:
		# Mild expo so small stick movements are precise at speed.
		var curved := signf(steer_target) * pow(absf(steer_target), 1.6)
		_steer = move_toward(_steer, curved, PAD_STEER_RATE * dt)
		_throttle = thr_target
		_brake = brk_target
	else:
		var rate := KEY_CENTER_RATE if absf(steer_target) < absf(_steer) or signf(steer_target) != signf(_steer) else KEY_STEER_RATE
		_steer = move_toward(_steer, steer_target, rate * dt)
		_throttle = move_toward(_throttle, thr_target, KEY_PEDAL_RATE * dt)
		_brake = move_toward(_brake, brk_target, KEY_PEDAL_RATE * dt)
	# Speed-sensitive steering: full lock at low speed, less at high speed.
	var lock := clampf(1.0 / (1.0 + speed_mps / 24.0), 0.25, 1.0)
	inp.steer = _steer * lock
	inp.throttle = _throttle
	inp.brake = _brake
	last_throttle = _throttle
	return inp.quantized()


func _pad_active() -> bool:
	for dev in Input.get_connected_joypads():
		if absf(Input.get_joy_axis(dev, JOY_AXIS_LEFT_X)) > 0.15 \
				or Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT) > 0.05 \
				or Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT) > 0.05:
			return true
	return false
