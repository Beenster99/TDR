class_name ProfileBadge
extends Button
## The player's profile, top right of the menus: a round badge with their
## initials in their colour, their name, and the team's budget and garage.
## Pressing it opens the profile page (name and colour).

const COLOURS := [["#e8412f", "Race red"], ["#f2a900", "Amber"], ["#2f9e44", "Green"], ["#1c7ed6", "Blue"],
	["#7048e8", "Violet"], ["#e64980", "Pink"], ["#e9ecef", "White"], ["#343a40", "Graphite"]]

var _name := ""
var _line2 := ""


func _ready() -> void:
	flat = true
	focus_mode = FOCUS_ALL
	custom_minimum_size = Vector2(330, 64)
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -360
	offset_right = -28
	offset_top = 22
	offset_bottom = 86
	tooltip_text = "Your profile"


## name: the driver name; profile: their team (money, garage).
func show_profile(p_name: String, profile: TeamProfile) -> void:
	_name = p_name if p_name.strip_edges() != "" else "Driver"
	var n := profile.owned_ids().size() if profile else 0
	_line2 = "%s  ·  %d car%s" % [UpgradeCatalog.format_money(profile.money if profile else 0), n, "" if n == 1 else "s"]
	queue_redraw()


static func colour() -> Color:
	return Color(str(GameData.prefs.get("profile_colour", "#e8412f")))


static func initials(p_name: String) -> String:
	var parts := p_name.strip_edges().split(" ", false)
	if parts.is_empty():
		return "?"
	var s := parts[0].substr(0, 1)
	if parts.size() > 1:
		s += parts[-1].substr(0, 1)
	return s.to_upper()


func _draw() -> void:
	var font := get_theme_default_font()
	var r := Rect2(Vector2.ZERO, size)
	var bg := Color(0.05, 0.06, 0.07, 0.72 if not has_focus() else 0.92)
	draw_rect(r, bg)
	if has_focus() or is_hovered():
		draw_rect(r, Color(1, 1, 1, 0.5), false, 2.0)
	var c := colour()
	var centre := Vector2(size.x - 34, size.y * 0.5)
	draw_circle(centre, 24, c)
	draw_arc(centre, 24, 0, TAU, 48, Color(1, 1, 1, 0.8), 2.0, true)
	var ini := initials(_name)
	var tc := Color.BLACK if c.get_luminance() > 0.6 else Color.WHITE
	var w := font.get_string_size(ini, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	draw_string(font, centre + Vector2(-w * 0.5, 7), ini, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, tc)
	var right := size.x - 70
	var nw := font.get_string_size(_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	draw_string(font, Vector2(right - minf(nw, right - 10), 28), _name, HORIZONTAL_ALIGNMENT_LEFT, right - 10, 20, Color.WHITE)
	var lw := font.get_string_size(_line2, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	draw_string(font, Vector2(right - minf(lw, right - 10), 50), _line2, HORIZONTAL_ALIGNMENT_LEFT, right - 10, 15, Color(0.55, 0.95, 0.6))
