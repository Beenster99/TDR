class_name PauseOptions
extends RefCounted
## What the in-race pause menu (PauseMenu) offers, and which settings it lets
## the player change in a race (SettingsScreen.in_race). Pure data, no nodes or
## autoloads, so the headless tests can check it.

## Settings sections shown in a race: the garage (car upgrades) is left out.
const RACE_SECTIONS := ["gameplay", "controller", "graphics", "sound", "debug"]
## Settings that change how the car drives (or what the co-op crew agreed):
## shown greyed out in a race, changeable again from the main menu.
const LOCKED_IN_RACE := ["driving_help", "aid_track_assist", "manual_gears", "pit_crew_coop"]
const LOCKED_HELP := "Locked during a race: change it from the main menu's Settings before the next race."


## The buttons shown, in order.
static func button_ids(online: bool, host: bool) -> Array:
	var ids := ["resume", "restart", "settings"]
	if online and host:
		ids.append("lobby")
	ids.append_array(["menu", "desktop"])
	return ids


static func label_for(id: String, online: bool, host: bool) -> String:
	match id:
		"resume": return "Resume"
		"restart": return "Restart race (everyone)" if online else "Restart race"
		"settings": return "Settings"
		"lobby": return "End race: everyone back to the lobby"
		"menu":
			if online and host:
				return "Quit to menu (closes the online race)"
			return "Leave race, quit to menu" if online else "Quit to menu"
		"desktop": return "Quit to desktop"
	return id


## The "Are you sure?" popup for the buttons that can't be undone:
## [question, what happens, yes label]. Empty for the other buttons.
static func confirm_text(id: String, online: bool, host: bool) -> Array:
	match id:
		"restart":
			return ["Restart the race?", "Everyone starts again from the grid. This race's results are lost." if online
				else "You start again from the grid. This race's progress is lost.", "Yes, restart"]
		"lobby":
			return ["End the race for everyone?", "The race stops and everyone goes back to the lobby.", "Yes, end the race"]
		"menu":
			if online and host:
				return ["Quit to the menu?", "This closes the online race for everyone.", "Yes, quit to menu"]
			if online:
				return ["Leave the race?", "You leave the online race and go back to the main menu.", "Yes, leave"]
			return ["Quit to the menu?", "This race's progress is lost.", "Yes, quit to menu"]
		"desktop":
			return ["Quit to the desktop?", "The game closes and this race is lost." + (" The online race closes for everyone." if online and host else ""),
				"Yes, quit the game"]
	return []
