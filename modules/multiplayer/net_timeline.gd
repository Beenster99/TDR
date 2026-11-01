class_name NetTimeline
extends RefCounted
## Buffer of one remote car's states, stamped with the sender's clock (as in
## Torque Shed's NetTimeline). Remote cars are drawn a little in the past
## (DELAY) so there are always two states to blend between, however bunched
## up or late the packets arrive; past the newest state it extrapolates
## briefly along the velocity.

const DELAY := 0.1          ## seconds behind the sender
const MAX_EXTRAPOLATE := 0.25
const KEEP := 24

var _times: PackedFloat64Array = []
var _states: Array[PackedFloat32Array] = []
var _offset := 0.0          ## sender clock - our clock (smoothed)
var _have_offset := false
var received := 0


func add(sent: float, local_now: float, state: PackedFloat32Array) -> void:
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


## Writes the blended state for "now" into the car.
func apply(car: CarState, local_now: float) -> void:
	if _times.is_empty():
		return
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
