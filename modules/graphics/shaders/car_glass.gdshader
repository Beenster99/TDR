shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;
// Car glass on any car. Crumples with the body
// (car_deform.gdshaderinc), and a separate windscreen (derby cars) cracks from where it was hit:
// a spider web of radial cracks and rings that spreads with `crack` (0..1);
// past 0.85 it's crazed white all over (shattered, held by the laminate).
// The side and rear glass only get the crumple.

#include "res://modules/graphics/shaders/car_deform.gdshaderinc"

uniform vec4 tint : source_color = vec4(0.03, 0.04, 0.06, 0.62);
uniform float crack = 0.0;
uniform vec3 crack_at = vec3(1.0, 1.2, 0.2);   // car space, where the web starts
uniform float seed = 0.0;

varying vec3 lp;

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7)) + seed) * 43758.5453);
}

// Distance to the nearest edge of a jittered cell pattern (crazing).
float cells(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float d1 = 9.0;
	float d2 = 9.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = vec2(h21(i + g), h21(i + g + 17.0));
			float d = length(g + o - f);
			if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
		}
	}
	return d2 - d1;
}

void vertex() {
	lp = VERTEX;
	apply_crumple(VERTEX, NORMAL);
}

void fragment() {
	vec3 c = tint.rgb;
	float a = tint.a;
	float rough = 0.03;
	if (crack > 0.001) {
		// Work in the plane of the glass seen from above/front: (z, height+x).
		vec2 p = vec2(lp.z, lp.y + lp.x * 0.6);
		vec2 c0 = vec2(crack_at.z, crack_at.y + crack_at.x * 0.6);
		vec2 d = p - c0;
		float r = length(d);
		float ang = atan(d.y, d.x);
		float reach = crack * 1.6;
		float inside = 1.0 - smoothstep(reach * 0.8, reach, r);
		// radial cracks
		float spokes = abs(sin(ang * 9.0 + h21(vec2(floor(ang * 3.0), 1.0)) * 3.0 + r * 2.0));
		float radial = 1.0 - smoothstep(0.0, 0.06 + 0.02 / max(r, 0.05), spokes);
		// rings
		float ring = 1.0 - smoothstep(0.0, 0.05, abs(fract(r * 5.0 + h21(vec2(floor(ang * 2.0), 3.0)) * 0.3) - 0.5) - 0.45);
		// crazing near the hit and everywhere once shattered
		float craze = 1.0 - smoothstep(0.0, 0.035, cells(p * 14.0));
		float shatter = smoothstep(0.82, 1.0, crack);
		float line = max(max(radial, ring * 0.7) * inside, craze * max(shatter, (1.0 - smoothstep(0.0, 0.25, r)) * crack));
		c = mix(c, vec3(0.85, 0.88, 0.9), line * 0.9);
		c = mix(c, vec3(0.55, 0.58, 0.6), shatter * 0.55);
		a = mix(a, 0.95, max(line * 0.8, shatter * 0.8));
		rough = mix(rough, 0.6, max(line, shatter));
	}
	ALBEDO = c;
	ALPHA = a;
	ROUGHNESS = rough;
	METALLIC = 0.2;
	SPECULAR = 0.9;
}
