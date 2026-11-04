extends SceneTree
## How often does race control order a place to be given back, and why?
##   godot --headless --path . --script res://tests/give_back_probe.gd -- [races] [laps] [cars] [first seed] [track]
## One car (the "player") ignores the overtaking rules, like a human racing on
## through the yellows; every other car is a normal AI. Prints each order with
## the state of both cars, then totals for the player and for the AI.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var races := int(args[0]) if args.size() > 0 else 6
	var laps := int(args[1]) if args.size() > 1 else 5
	var ncars := int(args[2]) if args.size() > 2 else 14
	var seed0 := int(args[3]) if args.size() > 3 else 100
	var track: String = args[4] if args.size() > 4 else ""
	var tracks := ["spa", "brands_hatch", "silverstone", "monza", "budapest", "spielberg"]
	var cars := CarCatalog.load_all()
	var tot := {"player": 0, "player_pen": 0, "ai": 0, "ai_pen": 0}
	var whys := {}
	for r in races:
		var settings := RaceSettings.new()
		settings.ai_count = ncars
		settings.laps = laps
		settings.seed = seed0 + r
		settings.track_id = track if track != "" else tracks[r % tracks.size()]
		var start := RaceFactory.plan(settings, [], cars, DriverCatalog.load_all())
		var sim := RaceFactory.build_sim(start, cars, TyreCatalog.load_all())
		var ai := AIDriver.for_all_ai(sim)
		var n := sim.car_count()
		var player := n / 2
		ai[player].ignore_flags = true
		var rc := sim.race_control
		var known := {}
		var orders := 0
		while sim.phase != RaceSim.Phase.FINISHED and sim.tick < 60 * 60 * 40:
			var inputs := []
			for i in n:
				inputs.append(ai[i].get_input(sim, i))
			sim.step(inputs)
			for e in sim.events:
				if e.get("type", "") == "penalty" or (e.get("type", "") == "warning" and str(e.get("text", "")).begins_with("Place given")):
					pass
			for i in rc.give_back.keys():
				if known.has(i):
					continue
				var g: Dictionary = rc.give_back[i]
				known[i] = g
				var j := int(g["victim"])
				orders += 1
				var who := "player" if i == player else "ai"
				tot[who] += 1
				whys["%s %s" % [who, g["why"]]] = whys.get("%s %s" % [who, g["why"]], 0) + 1
				var info := ""
				if j >= 0:
					var ci := sim.cars[i]
					var cj := sim.cars[j]
					var cause := false
					for y in rc.yellows:
						if int(y["car"]) == j:
							cause = true
					info = "v %.0f/%.0f m/s surf %d/%d victim_cause %s gap %.1f" % [ci.speed(), cj.speed(), ci.surface, cj.surface, cause, sim.entries[i].distance - sim.entries[j].distance]
				print("  %s L%d t=%.0f %s car %d -> %d  %s  %s" % [settings.track_id, sim.entries[i].laps_done + 1, sim.race_time, who, i, j, g["why"], info])
			for i in known.keys():
				if not rc.give_back.has(i):
					known.erase(i)
			for e in sim.events:
				if e.get("type", "") == "penalty":
					var c := int(e.get("car", -1))
					tot["player_pen" if c == player else "ai_pen"] += 1
		print("race %d %s: %d orders" % [r, settings.track_id, orders])
	print("TOTAL ", tot)
	for k in whys:
		print("  ", k, ": ", whys[k])
	quit()
