class_name NetPause
extends RefCounted
## The shared pause of an online race (pure, so the headless tests can check
## it): who is still in the pause menu. Any player's Esc puts every player in
## it; the race goes again once all of them have pressed Resume, or the host
## resumes it for everyone. Net keeps the list on the host and shares it.


## The players still in the menu after player id pressed Esc (on) or Resume.
## all: the host resumes for everyone. players: every player's peer id.
static func next(waiting: Array, players: Array, id: int, on: bool, all := false) -> Array:
	var w := waiting.duplicate()
	if on:
		if w.is_empty():
			w = players.duplicate()
			w.sort()
		if not w.has(id) and players.has(id):
			w.append(id)
	elif all:
		w = []
	else:
		w.erase(id)
	return w
