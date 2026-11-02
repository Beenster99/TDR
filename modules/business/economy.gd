class_name Economy
extends RefCounted
## Prize money. The default table (data/upgrades.json "prizes"): the winner
## gets base x tier x a distance factor, the last finisher a share of that,
## linear in between; retired cars get a small share.


## position: 1 = winner (0 or less = did not finish). field_size: cars in the
## race. race_km: race distance (-1 = a full-length race, factor 1). tier:
## multiplier a season can use for bigger events.
static func race_prize(position: int, field_size: int, race_km := -1.0, tier := 1.0) -> int:
	var p: Dictionary = UpgradeCatalog.data().get("prizes", {})
	var base: float = p.get("base", 40000)
	var factor := 1.0
	if race_km >= 0.0:
		factor = clampf(race_km / float(p.get("reference_km", 40.0)), p.get("min_factor", 0.25), p.get("max_factor", 1.5))
	var top := base * tier * factor
	var share: float
	if position <= 0:
		share = p.get("dnf_share", 0.08)
	elif field_size <= 1:
		share = 1.0
	else:
		var k := float(clampi(position, 1, field_size) - 1) / float(field_size - 1)
		share = lerpf(1.0, p.get("last_share", 0.15), k)
	return int(round(top * share / 100.0)) * 100
