shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
// The driving line aid (Forza-style): a soft band along the racing line,
// coloured by the car's speed against the speed it should have there:
// green = fine, yellow = lift / get ready, red = brake now.
//   UV.x  : across the band (-1 .. 1), faded towards the edges
//   UV.y  : reference speed at this point (m/s), DrivingLine.speed
//   UV2.x : distance along the line (m)
//   UV2.y : 1 in and through a corner, 0 on a straight (DrivingLine.corner)
//   COLOR.r: rallycross joker line, 1 where it leaves the lap (DrivingLine.branch)

uniform float car_dist = 0.0;      // the car's distance along the line (m)
uniform float car_speed = 0.0;     // m/s
uniform float line_length = 1000.0;
uniform float show_full = 1.0;     // 1 = whole line ahead, 0 = only braking zones
uniform float show_colours = 1.0;  // 0 = plain line, no braking colours
uniform float corners_only = 0.0;  // 1 = only into and through the corners
uniform float branch_only = 0.0;   // 1 = joker line: only where it leaves the lap
uniform float reach = 320.0;       // metres ahead shown
uniform float opacity = 0.62;

void fragment() {
	float ahead = mod(UV2.x - car_dist + line_length, line_length);
	float vis = smoothstep(2.0, 10.0, ahead) * (1.0 - smoothstep(reach * 0.7, reach, ahead));
	float r = car_speed / max(UV.y, 1.0);
	vec3 green = vec3(0.18, 0.85, 0.32);
	vec3 yellow = vec3(1.0, 0.82, 0.12);
	vec3 red = vec3(0.95, 0.12, 0.1);
	vec3 plain = vec3(0.92, 0.94, 1.0);
	vec3 c = mix(green, yellow, smoothstep(0.9, 0.97, r));
	c = mix(c, red, smoothstep(0.99, 1.04, r));
	c = mix(plain, c, show_colours);
	// Braking zones only: show the line where it is yellow or red.
	float braking = smoothstep(0.9, 0.96, r) * show_colours;
	float zone = mix(1.0, braking, (1.0 - show_full) * show_colours);
	// Corners only: hide the straights, but never a warning to brake.
	zone = mix(zone, max(UV2.y, braking), corners_only * show_full);
	float edge = 1.0 - smoothstep(0.25, 1.0, abs(UV.x));
	ALBEDO = c;
	// Joker branch beside the lap's line: dashed, so the fork reads as the
	// other way round (5 m dashes), with the braking colours kept.
	float dash = 0.3 + 0.7 * step(0.4, fract(UV2.x / 5.0));
	zone *= mix(1.0, COLOR.r * dash, branch_only);
	ALPHA = opacity * vis * zone * edge;
}
