shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
// The pit guide line (PitGuideView): a dashed band from the track into the
// pit lane and onto the driver's box, coloured by the car's speed against
// the speed it should have there: pit-lane blue = fine (so it never looks
// like the green racing line), yellow = lift / get ready, red = brake now.
//   UV.x  : across the band (-1 .. 1), faded towards the edges
//   UV.y  : speed to be doing at this point (m/s)
//   UV2.x : guide metres along the line
//   UV2.y : 1 inside the pit speed-limit zone (unused for now)

uniform float car_dist = 0.0;      // the car's guide metres
uniform float car_speed = 0.0;     // m/s
uniform float end_dist = 100000.0; // nothing drawn beyond this (the box, on the way in)
uniform float reach = 420.0;       // metres ahead shown
uniform float opacity = 0.72;

void fragment() {
	float ahead = UV2.x - car_dist;
	float vis = smoothstep(-2.0, 6.0, ahead) * (1.0 - smoothstep(reach * 0.75, reach, ahead));
	vis *= 1.0 - smoothstep(end_dist - 0.5, end_dist + 0.5, UV2.x);
	float r = car_speed / max(UV.y, 0.6);
	vec3 yellow = vec3(1.0, 0.82, 0.12);
	vec3 red = vec3(0.95, 0.12, 0.1);
	vec3 blue = vec3(0.3, 0.75, 1.0);
	vec3 c = mix(blue, yellow, smoothstep(0.88, 0.96, r));
	c = mix(c, red, smoothstep(0.99, 1.04, r));
	// Dashes, so it reads as a guide rather than the racing line.
	float dash = mix(1.0, 0.55, step(0.5, fract(UV2.x / 6.0)));
	float edge = 1.0 - smoothstep(0.3, 1.0, abs(UV.x));
	ALBEDO = c;
	ALPHA = opacity * vis * edge * dash;
}
