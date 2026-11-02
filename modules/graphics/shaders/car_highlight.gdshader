shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
// A soft glowing outline on the ground round a car, to pick out a player:
// the local player's own car, or another human player online (not the AI).
//   UV : 0..1 across the quad, which is the car's footprint plus a margin.

uniform vec4 tint : source_color = vec4(1.0, 0.82, 0.25, 1.0);
uniform float strength = 0.55;
uniform vec2 half_size = vec2(2.6, 1.15);   // the car's footprint, half length / half width (m)
uniform vec2 quad_half = vec2(4.0, 2.6);    // half size of the quad (m)
uniform float corner = 0.6;                 // rounding of the outline (m)
uniform float width = 0.35;                 // outline thickness (m), grows when zoomed out
uniform float pulse = 0.0;                  // 1 = breathe gently (own car)

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 * quad_half;
	vec2 q = abs(p) - (half_size - vec2(corner));
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;   // signed distance to the footprint
	float ring = exp(-pow(max(d, 0.0) / max(width, 0.01), 2.0) * 1.6) * step(-0.15, d);
	float inner = smoothstep(-0.15, 0.1, d);
	float breathe = 1.0 - pulse * 0.25 * (0.5 + 0.5 * sin(TIME * 3.0));
	float a = ring * inner * strength * breathe;
	ALBEDO = tint.rgb;
	ALPHA = a;
}
