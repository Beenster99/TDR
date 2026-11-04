class_name CarTelemetry
extends RefCounted
## Everything the pit wall knows about one car: its lap-by-lap log, the
## current gaps, tyre state and what a pit stop now would do.

const AVG_LAPS := 5

var car: int = 0
## Lap log, one Dictionary per completed lap:
## {lap, time, sectors: [s1, s2, s3], position, gap_leader, tyre_avg_c,
##  tyre_temps: [fl, fr, rl, rr], fuel_l, weather, wetness, race_time,
##  compound (the tyre id on the car at the line), stops (pit stops so far),
##  pitted (true = stopped in this lap), tyre_wear: [fl, fr, rl, rr] (0 = new,
##  1 = worn out, at the line)}
var laps: Array = []
## Where the car started (1 = pole; 0 = not known yet).
var grid_pos: int = 0
## Every pit stop: {lap, stationary_s, tyre, fuel_l, driver, in_window}.
var stops: Array = []
var best_sectors: PackedFloat64Array = []   ## personal best per sector
var last5_avg: float = 0.0                   ## mean of the last 5 green-flag laps (lap 1 excluded)
var gap_leader: float = 0.0                  ## seconds behind the leader (laps_down counts separately)
var laps_down: int = 0
var interval: float = 0.0                    ## seconds behind the car ahead (0 for the leader)
var gap_behind: float = -1.0                 ## seconds to the car behind (-1 = nobody)
var tyre_state: String = "cold"              ## "cold" | "ok" | "hot"
var tyre_grip: float = 1.0                   ## 0..1 average temperature grip
var span_times: Array = []                   ## recent times over the pit-lane span of the track
## Pit analysis (PitWindow): what stopping this lap would do.
var pit: Dictionary = {}


func last_lap() -> float:
	return laps[-1]["time"] if not laps.is_empty() else 0.0


func best_lap() -> float:
	var b := 0.0
	for l in laps:
		if b <= 0.0 or l["time"] < b:
			b = l["time"]
	return b


func last_sectors() -> Array:
	return laps[-1]["sectors"] if not laps.is_empty() else []


## Recompute the rolling average from the lap log.
func update_average() -> void:
	last5_avg = avg_last(AVG_LAPS)


## Mean of the last n laps (lap 1, off the grid, left out); 0 with no laps.
## Fewer laps than n so far: the mean of those there are.
func avg_last(n: int) -> float:
	var sum := 0.0
	var got := 0
	for k in range(laps.size() - 1, -1, -1):
		if laps[k]["lap"] <= 1:
			break
		sum += laps[k]["time"]
		got += 1
		if got >= n:
			break
	return sum / got if got > 0 else 0.0


## How many laps avg_last(n) is over (to show "3 laps" vs "2 so far").
func laps_in_avg(n: int) -> int:
	var got := 0
	for k in range(laps.size() - 1, -1, -1):
		if laps[k]["lap"] <= 1 or got >= n:
			break
		got += 1
	return got


## Lap times trend: positive = getting slower (s per lap) over the last laps.
func trend() -> float:
	var n := mini(laps.size(), AVG_LAPS)
	if n < 3:
		return 0.0
	var xs := 0.0
	var ys := 0.0
	var xy := 0.0
	var xx := 0.0
	for k in n:
		var y: float = laps[laps.size() - n + k]["time"]
		xs += k
		ys += y
		xy += k * y
		xx += k * k
	var d := n * xx - xs * xs
	return (n * xy - xs * ys) / d if d != 0.0 else 0.0


## How fast each tyre is wearing: worn fraction per lap for FL, FR, RL, RR,
## the mean of up to the last n laps on the tyre that's on now (a lap where
## the wear went down had a new tyre fitted, and starts again). 0 = no lap
## on this tyre yet, or no wear.
func wear_per_lap(n := 3) -> PackedFloat64Array:
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for w in 4:
		var sum := 0.0
		var got := 0
		for k in range(laps.size() - 1, -1, -1):
			var now: Array = laps[k].get("tyre_wear", [])
			if now.size() < 4:
				break
			var before := 0.0
			if k > 0:
				var prev: Array = laps[k - 1].get("tyre_wear", [])
				if prev.size() < 4:
					break
				before = float(prev[w])
			var d := float(now[w]) - before
			if d < 0.0:
				break        # a new tyre went on in this lap
			sum += d
			got += 1
			if got >= n:
				break
		out[w] = sum / got if got > 0 else 0.0
	return out


## Laps until a tyre with this much wear is worn out at this rate per lap
## (INF when it isn't wearing).
static func laps_to_worn(wear: float, rate: float) -> float:
	return (1.0 - clampf(wear, 0.0, 1.0)) / rate if rate > 1e-5 else INF


func to_net() -> Array:
	return [gap_leader, laps_down, interval, gap_behind, pit]


func apply_net(a: Array) -> void:
	gap_leader = a[0]
	laps_down = a[1]
	interval = a[2]
	gap_behind = a[3]
	pit = a[4]


func to_dict() -> Dictionary:
	return {"car": car, "laps": laps, "grid_pos": grid_pos, "stops": stops, "best_sectors": Array(best_sectors), "last5_avg": last5_avg,
		"gap_leader": gap_leader, "laps_down": laps_down, "interval": interval}
