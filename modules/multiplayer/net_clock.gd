class_name NetClock
extends RefCounted
## Works out the host's race clock from pings (NTP-style), so every machine
## stamps car states on the same clock and can place remote cars where they
## are now (see NetTimeline). A client pings the host twice a second; each
## reply says what the host's clock read half a round trip ago.

const KEEP := 12

## The host's clock minus ours (s).
var offset := 0.0
var synced := false
## Quickest recent round trip (s).
var rtt := 0.0
var _samples: Array = []         ## recent [rtt, offset]


func reset() -> void:
	offset = 0.0
	synced = false
	rtt = 0.0
	_samples.clear()


## A ping sent at our t0 came back at our now, carrying the host's host_t.
## Uses the quickest recent pings, whose two halves are the most even.
func add_pong(t0: float, host_t: float, now: float) -> void:
	var trip := now - t0
	if trip < 0.0 or trip > 2.0:
		return
	var sample := host_t + trip * 0.5 - now
	# The true offset is within half a round trip of any sample. A sample that
	# rules out our estimate means a clock jumped (a hitch while loading):
	# start again from the fresh samples.
	if synced and absf(sample - offset) > trip * 0.5 + 0.02:
		_samples.clear()
	_samples.append([trip, sample])
	if _samples.size() > KEEP:
		_samples.remove_at(0)
	var best := _samples.duplicate()
	best.sort_custom(func(a, b): return a[0] < b[0])
	var use := mini(3, best.size())
	var sum := 0.0
	for k in use:
		sum += float(best[k][1])
	offset = sum / use
	rtt = float(best[0][0])
	synced = true
