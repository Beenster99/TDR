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
	var ids := ["resume"]
	if online and host:
		ids.append("resume_all")   # don't wait for a player who's gone quiet
	ids.append_array(["restart", "settings"])
	if online and host:
		ids.append("lobby")
	ids.append_array(["menu", "desktop"])
	return ids


static func label_for(id: String, online: bool, host: bool) -> String:
	match id:
		"resume": return "Resume"
		"resume_all": return "Resume for everyone now"
		"restart": return "Restart race (everyone)" if online else "Restart race"
		"settings": return "Settings"
		"lobby": return "End race: everyone back to the lobby"
		"menu":
			if online and host:
				return "Quit to menu (closes the online race)"
			return "Leave race, quit to menu" if online else "Quit to menu"
		"desktop": return "Quit to desktop"
	return id
