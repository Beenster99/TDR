shader_type spatial;
// Car paint with a procedural livery, drawn from the car-space position so
// every body part (body, bumpers, cabin, mirrors, ducktail) lines up.
// Car space: +X forward, +Y up, +Z right, metres, origin at the CG.
// A painted livery texture (UV0 unwrap from the Blender builder) can be laid
// over the pattern with livery_tex / use_livery_tex.

uniform vec3 primary : source_color = vec3(0.8, 0.05, 0.05);
uniform vec3 secondary : source_color = vec3(1.0);
uniform vec3 accent : source_color = vec3(0.05);
uniform int pattern = 0;          // 0 solid, 1 stripes, 2 split, 3 sash, 4 chevron, 5 m-stripes, 6 halves
uniform float x_front = 2.3;      // nose x
uniform float car_length = 4.6;
uniform float half_width = 1.0;
uniform float metallic_flake = 0.35;
uniform float roughness_paint = 0.26;
uniform sampler2D livery_tex : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic;
uniform bool use_livery_tex = false;
uniform float dirt = 0.0;
uniform vec4 damage = vec4(0.0);  // front, rear, left, right bodywork damage 0..1         // 0 clean .. 1 filthy (later: race distance / rain)

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

float band(float v, float c, float hw, float aa) {
	return 1.0 - smoothstep(hw - aa, hw + aa, abs(v - c));
}

void fragment() {
	float t = (x_front - lp.x) / car_length;     // 0 nose .. 1 tail
	float y = lp.z / half_width;                  // -1 left .. 1 right
	float ay = abs(y);
	float aa = 0.004;
	vec3 c = primary;
	if (pattern == 1) {            // twin stripes nose to tail
		float s = band(ay, 0.13, 0.065, aa);
		float e = band(ay, 0.13, 0.08, aa) - s;
		c = mix(c, accent, clamp(e, 0.0, 1.0));
		c = mix(c, secondary, s);
	} else if (pattern == 2) {     // front / rear split with a sweep
		float k = smoothstep(-aa, aa, t - 0.52 - 0.12 * ay + 0.06 * lp.y);
		c = mix(primary, secondary, k);
		c = mix(c, accent, band(t - 0.12 * ay + 0.06 * lp.y, 0.52, 0.012, aa));
	} else if (pattern == 3) {     // diagonal sash
		float d = (t - 0.42) + 0.28 * y;
		c = mix(c, accent, band(d, 0.0, 0.085, aa));
		c = mix(c, secondary, band(d, 0.0, 0.06, aa));
	} else if (pattern == 4) {     // chevron
		float d = t - 0.18 - 0.22 * ay;
		c = mix(c, secondary, band(d, 0.0, 0.05, aa));
		c = mix(c, accent, band(d, 0.11, 0.02, aa));
	} else if (pattern == 5) {     // three thin stripes over the car, side to side
		float d = t - 0.30 + 0.05 * y;
		c = mix(c, vec3(0.0, 0.55, 0.85), band(d, -0.03, 0.012, aa));
		c = mix(c, accent, band(d, 0.0, 0.012, aa));
		c = mix(c, vec3(0.86, 0.1, 0.12), band(d, 0.03, 0.012, aa));
		c = mix(c, secondary, smoothstep(0.55 - aa, 0.55 + aa, t) * (1.0 - smoothstep(0.38, 0.4, lp.y)));
	} else if (pattern == 6) {     // two-tone: lower body in the second colour
		c = mix(primary, secondary, 1.0 - smoothstep(0.42, 0.44, lp.y));
	}
	if (use_livery_tex) {
		vec4 lt = texture(livery_tex, UV);
		c = mix(c, lt.rgb, lt.a);
	}
	// a little road grime low down and towards the back
	float grime = dirt * (1.0 - smoothstep(0.15, 0.5, lp.y)) * 0.6;
	c = mix(c, vec3(0.12, 0.11, 0.1), grime);
	// damage: scuffs and scorched carbon showing through where it was hit
	float zone = damage.x * smoothstep(0.75, 0.95, 1.0 - t) + damage.y * smoothstep(0.75, 0.95, t)
		+ damage.z * smoothstep(0.6, 0.9, -y) + damage.w * smoothstep(0.6, 0.9, y);
	float scratch = fract(sin(dot(floor(lp.xz * vec2(9.0, 23.0) + lp.y * 7.0), vec2(12.9898, 78.233))) * 43758.5453);
	float hurt = clamp(zone * 1.4, 0.0, 1.0) * step(0.55 - zone * 0.4, scratch);
	c = mix(c, vec3(0.04), hurt * 0.85);
	ALBEDO = c;
	METALLIC = mix(metallic_flake, 0.1, hurt);
	ROUGHNESS = mix(mix(roughness_paint, 0.7, grime), 0.6, hurt);
	CLEARCOAT = (1.0 - grime) * (1.0 - hurt);
	CLEARCOAT_ROUGHNESS = 0.08;
}
