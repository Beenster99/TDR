shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
// The driving line aid (Forza-style): a soft band along the racing line,
// coloured by the car's speed against the speed it should have there:
// green = fine, yellow = lift / get ready, red = brake now.
//   UV.x  : across the band (-1 .. 1), faded towards the edges
//   UV.y  : reference speed at this point (m/s), DrivingLine.speed
//   UV2.x : distance along the line (m)

uniform float car_dist = 0.0;      // the car's distance along the line (m)
uniform float car_speed = 0.0;     // m/s
uniform float line_length = 1000.0;
uniform float show_full = 1.0;     // 1 = whole line ahead, 0 = only braking zones
uniform float show_colours = 1.0;  // 0 = plain line, no braking colours
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
	float zone = mix(1.0, smoothstep(0.9, 0.96, r), (1.0 - show_full) * show_colours);
	float edge = 1.0 - smoothstep(0.25, 1.0, abs(UV.x));
	ALBEDO = c;
	ALPHA = opacity * vis * zone * edge;
}
