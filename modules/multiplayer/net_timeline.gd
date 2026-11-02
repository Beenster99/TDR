class_name NetTimeline
extends RefCounted
## Buffer of one remote car's states, stamped with the sender's clock (as in
## Torque Shed's NetTimeline).
##
## Two ways to place a remote car:
##   - PRESENT (the normal case, once the clocks are synced with the host, see
##     Net.clock_offset): the car is put where it is *now* on its owner's
##     machine, by carrying its newest state forward over the time the packet
##     took to arrive (speed, turn rate and braking). Every player's machine
##     then has every car in nearly the same place at the same moment, so a
##     contact on one screen is a contact on the others. When a fresher state
##     shows the guess was a little off, the difference is eased out over a
##     few frames instead of jumping.
##   - DELAYED (fallback while the clocks aren't synced): drawn a little in the
##     past (DELAY) blended between two states. Smooth, but a car seen this way
##     is several metres behind where its driver has it at racing speed, which
##     made contacts happen where the cars didn't touch on the other screen.

const DELAY := 0.1          ## seconds behind the sender (fallback mode)
const MAX_EXTRAPOLATE := 0.25
## Present mode: how far ahead of the newest state we will guess (s).
const MAX_PREDICT := 0.35
## How quickly a correction is eased out (1/s): 63% gone in 1/SMOOTH_RATE s.
const SMOOTH_RATE := 12.0
## A correction bigger than this (m) is a jump (pit handover, crane): snap.
const SNAP_DIST := 6.0
## A sender whose stamps are this far from our clock isn't synced (s).
const SYNC_TOLERANCE := 1.0
const KEEP := 24

var _times: PackedFloat64Array = []
var _states: Array[PackedFloat32Array] = []
var _offset := 0.0          ## sender clock - our clock (smoothed)
var _have_offset := false
var received := 0

# Present mode: easing out corrections.
var _err_pos := Vector2.ZERO
var _err_heading := 0.0
var _shown_pos := Vector2.ZERO
var _shown_heading := 0.0
var _shown_vel := Vector2.ZERO
var _shown_yaw := 0.0
var _shown_at := -1.0
var _shown_received := -1


func add(sent: float, local_now: float, state: PackedFloat32Array) -> void:
	if not _times.is_empty() and absf(sent - _times[-1]) > SYNC_TOLERANCE * 2.0:
		# The sender switched clocks (it just synced with the host): start over.
		_times.clear()
		_states.clear()
		_have_offset = false
		_shown_at = -1.0
	if not _times.is_empty() and sent <= _times[-1]:
		return  # duplicate or out of order
	var off := sent - local_now
	# Track the lowest-latency packets: offset only grows quickly, drifts down slowly.
	if not _have_offset or off > _offset:
		_offset = off
		_have_offset = true
	else:
		_offset = lerpf(_offset, off, 0.02)
	received += 1
	_times.append(sent)
	_states.append(state)
	if _times.size() > KEEP:
		_times.remove_at(0)
		_states.remove_at(0)


func has_data() -> bool:
	return not _times.is_empty()


## True when the sender's stamps are on the same (host) clock as ours, so the
## car can be placed in the present.
func clocks_agree() -> bool:
	return _have_offset and absf(_offset) < SYNC_TOLERANCE


## Writes the car's state for "now" into the car. synced: now is on the host's
## clock (Net.clock_offset is known), so the present can be predicted.
func apply(car: CarState, local_now: float, synced := false) -> void:
	if _times.is_empty():
		return
	if synced and clocks_agree():
		_apply_present(car, local_now)
	else:
		_apply_delayed(car, local_now)


func _apply_present(car: CarState, now: float) -> void:
	var n := _times.size()
	var base := _states[n - 1]
	car.unpack_net(base, 0)
	predict(car, now - _times[n - 1])
	# Ease out the jump a fresher state causes, so the car glides instead of
	# hopping, but stays where it really is within a few frames.
	var dt := clampf(now - _shown_at, 0.0, 0.1) if _shown_at >= 0.0 else 0.0
	if _shown_at >= 0.0:
		if received != _shown_received:
			var expect_pos := _shown_pos + _shown_vel * dt
			var expect_heading := _shown_heading + _shown_yaw * dt
			_err_pos = expect_pos - car.pos
			_err_heading = angle_difference(car.heading, expect_heading)
		var keep := exp(-SMOOTH_RATE * dt)
		_err_pos *= keep
		_err_heading *= keep
		if _err_pos.length() > SNAP_DIST or absf(_err_heading) > 1.2:
			_err_pos = Vector2.ZERO
			_err_heading = 0.0
		car.pos += _err_pos
		car.heading += _err_heading
	_shown_pos = car.pos
	_shown_heading = car.heading
	_shown_vel = car.vel
	_shown_yaw = car.yaw_rate
	_shown_at = now
	_shown_received = received


## Carries a car's state ahead by lead seconds: turning at its yaw rate and
## speeding up or braking at its longitudinal acceleration (dead reckoning).
static func predict(car: CarState, lead: float) -> void:
	lead = clampf(lead, 0.0, MAX_PREDICT)
	if lead <= 0.0:
		return
	var turn := car.yaw_rate * lead
	var fwd := car.forward()
	var speed := car.vel.length()
	# Don't brake past standstill.
	var acc := car.ax
	if acc < 0.0 and speed > 0.01:
		acc = maxf(acc, -speed / lead)
	var v_mid := car.vel.rotated(turn * 0.5) + fwd.rotated(turn * 0.5) * acc * lead * 0.5
	car.pos += v_mid * lead
	car.vel = car.vel.rotated(turn) + fwd.rotated(turn) * acc * lead
	car.heading += turn


func _apply_delayed(car: CarState, local_now: float) -> void:
	_shown_at = -1.0
	var t := local_now + _offset - DELAY
	var n := _times.size()
	if t <= _times[0]:
		car.unpack_net(_states[0], 0)
		return
	for k in range(1, n):
		if t <= _times[k]:
			var f := (t - _times[k - 1]) / maxf(_times[k] - _times[k - 1], 0.0001)
			car.unpack_net(_states[k], 0)
			var a := _states[k - 1]
			var b := _states[k]
			car.pos = Vector2(lerpf(a[0], b[0], f), lerpf(a[1], b[1], f))
			car.heading = lerp_angle(a[2], b[2], f)
			car.vel = Vector2(lerpf(a[3], b[3], f), lerpf(a[4], b[4], f))
			car.steer_angle = lerpf(a[6], b[6], f)
			return
	car.unpack_net(_states[n - 1], 0)
	var ahead := minf(t - _times[n - 1], MAX_EXTRAPOLATE)
	car.pos += car.vel * ahead
	car.heading += car.yaw_rate * ahead
