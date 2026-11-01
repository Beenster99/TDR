class_name RaceFeed
extends RefCounted
## The pit wall's message feed: other teams' radio calls and strategy, plus
## timing, pit-window, tyre, weather and incident calls worked out from the
## race data. Newest last.
##
## Item: {t (race seconds), lap (leader's lap), kind, car (-1 = none),
##        car2 (optional), topic (optional), text}

const MAX_ITEMS := 300
const KINDS := ["radio", "strategy", "timing", "pit", "tyres", "weather", "incident"]

var items: Array = []
var version: int = 0   ## goes up on every add, so views know when to redraw


func add(item: Dictionary) -> void:
	items.append(item)
	if items.size() > MAX_ITEMS:
		items.remove_at(0)
	version += 1


## Newest n items, newest first, optionally only of some kinds.
func latest(n: int, kinds: Array = []) -> Array:
	var out := []
	for k in range(items.size() - 1, -1, -1):
		if kinds.is_empty() or items[k].get("kind", "") in kinds:
			out.append(items[k])
			if out.size() >= n:
				break
	return out


func count_kind(kind: String) -> int:
	var n := 0
	for it in items:
		if it.get("kind", "") == kind:
			n += 1
	return n
