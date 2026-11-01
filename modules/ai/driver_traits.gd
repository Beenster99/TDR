class_name DriverTraits
extends RefCounted
## A driver's personality, every value 0..1 (higher = better at it, except
## aggression, which is a style). Read from the "traits" dictionary of a
## driver in modules/ai/data/drivers.json (also what RaceEntry.traits holds).
##
## Older names still work: "skill" is read as pace, "racecraft" as
## overtaking/defending when those are missing.

## Order used by the UI and the catalog.
const NAMES := ["pace", "consistency", "aggression", "overtaking", "defending",
	"tyre_management", "wet_skill", "composure"]

const LABELS := {
	"pace": "Pace",
	"consistency": "Consistency",
	"aggression": "Aggression",
	"overtaking": "Overtaking",
	"defending": "Defending",
	"tyre_management": "Tyre management",
	"wet_skill": "Wet weather",
	"composure": "Composure",
}

const HELP := {
	"pace": "Raw speed: how close to the grip limit they corner and how late they brake.",
	"consistency": "How repeatable their laps are, and how rarely they make mistakes.",
	"aggression": "How hard they race: later braking, smaller gaps, bolder moves and blocks.",
	"overtaking": "How well they set up and finish a pass.",
	"defending": "How well they cover the inside and hold a position.",
	"tyre_management": "How well they keep tyres in their temperature window.",
	"wet_skill": "How much of their pace they keep on a damp or wet track.",
	"composure": "How well they avoid mistakes with a car right behind or alongside.",
}

var pace := 0.9
var consistency := 0.9
var aggression := 0.5
var overtaking := 0.6
var defending := 0.6
var tyre_management := 0.6
var wet_skill := 0.6
var composure := 0.7


static func from_dict(d: Dictionary) -> DriverTraits:
	var t := DriverTraits.new()
	var racecraft := float(d.get("racecraft", 0.6))
	t.pace = float(d.get("pace", d.get("skill", t.pace)))
	t.consistency = float(d.get("consistency", t.consistency))
	t.aggression = float(d.get("aggression", t.aggression))
	t.overtaking = float(d.get("overtaking", racecraft))
	t.defending = float(d.get("defending", racecraft))
	t.tyre_management = float(d.get("tyre_management", t.tyre_management))
	t.wet_skill = float(d.get("wet_skill", t.wet_skill))
	t.composure = float(d.get("composure", t.consistency * 0.8))
	for n in NAMES:
		t.set(n, clampf(t.get(n), 0.0, 1.0))
	return t


func to_dict() -> Dictionary:
	var d := {}
	for n in NAMES:
		d[n] = get(n)
	return d


## A host difficulty (0 = rookie .. 1 = alien) pulls every skill towards a
## level, keeping each driver's character: the order of the field stays the
## same, the gaps shrink at the top and grow at the bottom. Aggression is a
## style, not a skill, so it is left alone.
func with_difficulty(difficulty: float) -> DriverTraits:
	var t := DriverTraits.from_dict(to_dict())
	var level := clampf(difficulty, 0.0, 1.0)
	# 0.75 ("pro") leaves the roster as written.
	var shift := (level - 0.75) * 0.8
	for n in NAMES:
		if n == "aggression":
			continue
		var v: float = t.get(n)
		if shift >= 0.0:
			v = lerpf(v, 1.0, shift)
		else:
			v *= 1.0 + shift
		t.set(n, clampf(v, 0.0, 1.0))
	return t


## One number for sorting / showing a rating (0..100).
func rating() -> int:
	return int(round(100.0 * (pace * 0.4 + consistency * 0.15 + overtaking * 0.1 + defending * 0.1
		+ tyre_management * 0.1 + wet_skill * 0.05 + composure * 0.1)))
