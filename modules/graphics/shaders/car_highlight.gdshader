shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;
// A subtle, crisp outline traced round a car's footprint, to pick out a car:
// the local player's own car, another human player online (not the AI), the
// car race control says to give a place back to, or the safety car.
//
// The line is a fixed number of screen pixels wide at every zoom (scaled
// with the screen's height, so it looks the same at 1080p and 4K), with a
// faint dark edge either side so it reads on light and dark ground alike.
//
// It sits on the ground round the car but is drawn pulled towards the camera
// (`lift`, metres), so kerbs, cambers and bumps in the ground never cut
// through it; the camera looks down, so it still lands in the same place on
// screen.
//   UV : 0..1 across the quad, which is the car's footprint plus a margin.

uniform vec4 tint : source_color = vec4(1.0, 0.82, 0.25, 1.0);
uniform float strength = 0.55;              // overall opacity (also does the timed fade)
uniform vec2 half_size = vec2(2.6, 1.15);   // the car's footprint, half length / half width (m)
uniform vec2 quad_half = vec2(4.0, 2.6);    // half size of the quad (m)
uniform float corner = 0.6;                 // rounding of the outline (m)
uniform float gap = 0.1;                    // space between the car and the line (m), grows when zoomed out
uniform float line_px = 2.0;                // line width in pixels at 1080p
uniform float lift = 1.5;                   // drawn this many metres towards the camera
uniform float pulse = 0.0;                  // 1 = breathe (own car; the car to give a place back to), 2 = flash fast (safety car)
uniform float pulse_rate = 3.0;             // breaths per 2 pi seconds (faster = more urgent)

void vertex() {
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX += normalize(-VERTEX) * lift;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 * quad_half;
	vec2 q = abs(p) - (half_size - vec2(corner));
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;   // signed distance to the footprint (m)
	float px = max(length(fwidth(p)) * 0.7071, 1e-4);                   // metres per screen pixel here
	float scale = VIEWPORT_SIZE.y / 1080.0;
	float w = line_px * scale * px;                                     // line width (m)
	float g = max(gap, 2.0 * scale * px);                               // never closer than 2 px to the car
	float c = abs(d - g - w * 0.5);                                     // distance from the line's centre
	float line = 1.0 - smoothstep(w * 0.5 - px * 0.5, w * 0.5 + px * 0.5, c);
	float edge = 1.0 - smoothstep(w * 0.5 + px * 0.5, w * 0.5 + px * 1.5 * scale, c);
	float breathe = pulse > 1.5 ? 0.35 + 0.65 * step(0.0, sin(TIME * 10.5)) : 1.0 - pulse * 0.25 * (0.5 + 0.5 * sin(TIME * pulse_rate));
	float a = max(line, edge * 0.45) * strength * breathe;
	ALBEDO = mix(vec3(0.0), tint.rgb, line);
	ALPHA = a;
}
