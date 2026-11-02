class_name OnboardPip
extends RefCounted
## Draws the onboard camera picture-in-picture (graphics' OnboardCamera) on
## the pit wall screens: the live picture in a frame, with a strip naming
## the car and which camera it is. Shared by CrewConsole and
## StrategistScreen.

const SIZE := Vector2(352, 198)    ## 16:9, in the 1600x900 canvas


## The picture's size in real screen pixels (the canvas is scaled to the
## window, so a 4K screen gets a 4K-sharp picture).
static func pixel_size(ci: CanvasItem, r: Rect2) -> Vector2i:
	var k := ci.get_viewport().get_final_transform().get_scale()
	return Vector2i(roundi(r.size.x * absf(k.x)), roundi(r.size.y * absf(k.y)))


## Asks the camera for car i's view this frame (call from _process).
static func feed(ci: CanvasItem, cam: OnboardCamera, r: Rect2, car: int, rear: bool) -> void:
	if cam and car >= 0:
		cam.show_car(car, OnboardCamera.View.REAR if rear else OnboardCamera.View.FRONT, pixel_size(ci, r))


## Draws the picture and its label strip. hint: a short controls line.
static func draw(ci: CanvasItem, font: Font, cam: OnboardCamera, r: Rect2, session: RaceSession, car: int, rear: bool, hint := "") -> void:
	ci.draw_rect(r.grow(3), Color(0.02, 0.04, 0.07, 0.92))
	if cam and cam.is_live():
		ci.draw_texture_rect(cam.get_texture(), r, false)
	else:
		ci.draw_rect(r, Color(0.05, 0.07, 0.1))
		ci.draw_string(font, Vector2(r.position.x, r.get_center().y + 5), "camera starting…", HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 13,
			Color(1, 1, 1, 0.5))
	var col: Color = session.sim.defs[car].colour if car >= 0 else Color.WHITE
	ci.draw_rect(r.grow(2), Color(col, 0.9), false, 2.0)
	var strip := Rect2(r.position, Vector2(r.size.x, 22))
	ci.draw_rect(strip, Color(0, 0, 0, 0.6))
	var cam_txt := "REAR" if rear else "FRONT"
	ci.draw_string(font, strip.position + Vector2(8, 16), "● %s" % cam_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.35, 0.3))
	if car >= 0:
		var e := session.sim.entries[car]
		ci.draw_string(font, strip.position + Vector2(70, 16), "P%d  %s" % [e.position, e.at_wheel()], HORIZONTAL_ALIGNMENT_LEFT,
			r.size.x - 78, 13, Color.WHITE)
	if hint != "":
		ci.draw_string(font, Vector2(r.position.x, r.end.y + 16), hint, HORIZONTAL_ALIGNMENT_RIGHT, r.size.x, 12, Color(1, 1, 1, 0.6))
