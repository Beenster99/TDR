class_name CarInput
extends RefCounted
## One tick of driver intent. This is the ONLY thing a client sends to the
## server in multiplayer. Humans, AI and (later) network peers all produce it.

var throttle: float = 0.0   ## 0..1
var brake: float = 0.0      ## 0..1 (also reverse when stopped)
var steer: float = 0.0      ## -1 (left) .. 1 (right)
var shift_up: bool = false  ## reserved for manual gearbox (wave 2+)
var shift_down: bool = false
var pit_request: bool = false ## reserved for fuel/pits (wave 3)
var handbrake: bool = false   ## locks the rear wheels while held


static func neutral() -> CarInput:
	return CarInput.new()


func sanitized() -> CarInput:
	## Server must never trust client values: clamp everything.
	var c := CarInput.new()
	c.throttle = clampf(throttle, 0.0, 1.0)
	c.brake = clampf(brake, 0.0, 1.0)
	c.steer = clampf(steer, -1.0, 1.0)
	c.shift_up = shift_up
	c.shift_down = shift_down
	c.pit_request = pit_request
	c.handbrake = handbrake
	return c


## Compact wire format: throttle/brake/steer quantised to bytes + a flags byte.
func to_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b[0] = int(round(clampf(throttle, 0.0, 1.0) * 255.0))
	b[1] = int(round(clampf(brake, 0.0, 1.0) * 255.0))
	b[2] = int(round((clampf(steer, -1.0, 1.0) * 0.5 + 0.5) * 254.0))
	b[3] = int(shift_up) | (int(shift_down) << 1) | (int(pit_request) << 2) | (int(handbrake) << 3)
	return b


static func from_bytes(b: PackedByteArray) -> CarInput:
	var c := CarInput.new()
	if b.size() < 4:
		return c
	c.throttle = b[0] / 255.0
	c.brake = b[1] / 255.0
	c.steer = (b[2] / 254.0 - 0.5) * 2.0
	c.shift_up = (b[3] & 1) != 0
	c.shift_down = (b[3] & 2) != 0
	c.pit_request = (b[3] & 4) != 0
	c.handbrake = (b[3] & 8) != 0
	return c


## Quantise in place so a local/AI input is bit-identical to what the server
## would decode from the wire. Keeps replays and server sims in lockstep.
func quantized() -> CarInput:
	return CarInput.from_bytes(to_bytes())
