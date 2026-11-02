class_name PitWindow
extends RefCounted
## Pit-window analysis: how much time a stop costs on this track (the pit
## lane loss), and for every car, where it would rejoin if it stopped this
## lap and whether that's into clear air.
##
## Pit lane loss = time down the pit lane (speed-limited zone at the limit,
## the entry and exit roads at a typical pace, slowing into and leaving the
## box) + time stood still - the time the car would have taken on track
## between the pit entry and exit points. The on-track part is measured from
## each car's own laps once it has done some; until then it's estimated.

const CLEAR_AHEAD_S := 2.0     ## rejoin at least this far behind the next car
const CLEAR_BEHIND_S := 1.0    ## and this far ahead of the car behind
const LANE_ROAD_SPEED := 35.0  ## m/s on the entry/exit roads outside the limit
const BOX_IN_OUT_S := 3.0      ## braking into the box and pulling away
const NO_LANE_LOSS_S := 25.0   ## a track without pit lane data

## Seconds stood in the box: each car's planned pit work (tyres, fuel,
## repairs) from the race's PitRules, set per car during analyse().
var stop_time_s: float = 8.0
var has_lane := false
var lane_time: float = 0.0     ## seconds from pit entry to exit, excluding the stop
var span_m: float = 0.0        ## track distance the pit lane bypasses
var entry_s: float = 0.0
var exit_s: float = 0.0


func setup(track: TrackData) -> void:
	has_lane = track.has_pit_lane()
	if not has_lane:
		span_m = 0.0
		return
	var zone := clampf(track.pit_limit_end - track.pit_limit_start, 0.0, track.pit_length)
	var road := track.pit_length - zone
	lane_time = zone / maxf(track.pit_speed_limit, 1.0) + road / LANE_ROAD_SPEED + BOX_IN_OUT_S
	entry_s = track.pit_entry_s
	exit_s = track.pit_exit_s
	span_m = fposmod(exit_s - entry_s, track.length)


## The car's time on track over the pit-lane span: median of its measured
## times, or an estimate from its pace (the pit straight is quicker than the
## lap average, hence 0.85).
func span_time(c: CarTelemetry, track_length: float) -> float:
	if c.span_times.size() > 0:
		var s: Array = c.span_times.duplicate()
		s.sort()
		return s[s.size() / 2]
	var lap := c.last5_avg if c.last5_avg > 0.0 else c.best_lap()
	if lap > 0.0:
		return span_m / (track_length / lap) * 0.85
	return span_m / 50.0


func loss_for(c: CarTelemetry, track_length: float) -> float:
	if not has_lane:
		return NO_LANE_LOSS_S + stop_time_s
	return maxf(lane_time + stop_time_s - span_time(c, track_length), stop_time_s)


## Fills cars[i].pit for every running car.
## pit = {loss, need, rejoin_pos, lost, ahead_after (s to the car ahead after
##        rejoining, -1 = none), behind_after (-1 = none), clear_air, ideal}
func analyse(cars: Array, sim: RaceSim) -> void:
	var order := sim.running_order
	for p in order.size():
		var i := order[p]
		var e := sim.entries[i]
		var c: CarTelemetry = cars[i]
		if e.finished or e.dnf or not e.started_lap:
			c.pit = {}
			continue
		# Time stood still: the car's own planned stop (tyres, fuel, repairs).
		if sim.pits != null and sim.pits.enabled:
			stop_time_s = sim.pits.service_for(i, e.pit["plan"])["total_s"]
		var loss := loss_for(c, sim.track.length)
		# Time gaps to every running car behind, nearest first.
		var lost := 0
		var ahead_after := -1.0
		var behind_after := -1.0
		var last_passed_gap := -1.0
		for q in range(p + 1, order.size()):
			var j := order[q]
			var ej := sim.entries[j]
			if ej.finished or ej.dnf:
				continue
			var g: float = cars[j].gap_leader - c.gap_leader
			if g < 0.0:
				continue
			if g < loss:
				lost += 1
				last_passed_gap = g
			else:
				behind_after = g - loss
				break
		if lost > 0:
			ahead_after = loss - last_passed_gap
		elif p > 0:
			ahead_after = c.interval + loss
		var clear := (ahead_after < 0.0 or ahead_after >= CLEAR_AHEAD_S) \
			and (behind_after < 0.0 or behind_after >= CLEAR_BEHIND_S)
		c.pit = {"loss": snappedf(loss, 0.01), "need": snappedf(loss + CLEAR_BEHIND_S, 0.01),
			"rejoin_pos": e.position + lost, "lost": lost,
			"ahead_after": snappedf(ahead_after, 0.01), "behind_after": snappedf(behind_after, 0.01),
			"clear_air": clear, "ideal": clear and lost == 0}
