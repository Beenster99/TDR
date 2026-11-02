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
uniform vec4 damage = vec4(0.0);  // front, rear, left, right bodywork damage 0..1
// 0 = livery paint, 1 = bare carbon (rear wing: same decals, no pattern)
uniform int base_mode = 0;

// Sponsor decals from the atlas (tools/build_decals.py): up to 16 per car.
// R = lettering (decal_fg), G = sticker panel (decal_bg), B = second colour.
// decal_box: centre (car-space x, then z for top decals / y for side ones),
//   half size along the text and across it, metres.
// decal_info: atlas cell, projection (0 top along the car, 1 top across the
//   car, 2 sides, both mirrored so they read), min and max height (car y).
uniform sampler2D decal_atlas : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic, repeat_disable;
uniform int decal_count = 0;
uniform vec4 decal_box[16];
uniform vec4 decal_info[16];
uniform vec3 decal_fg[16];   // linear colours
uniform vec3 decal_bg[16];
uniform vec3 decal_ac[16];
uniform vec2 atlas_grid = vec2(4.0, 16.0);
// Race number on both doors: a rounded panel with up to 3 digits.
uniform sampler2D digits : source_color, hint_default_transparent, filter_linear_mipmap_anisotropic, repeat_disable;
uniform int race_number = 0;
uniform vec4 number_box = vec4(0.0, 0.55, 0.17, 0.17);   // x, y, half width, half height
uniform vec3 number_fg : source_color = vec3(0.04);
uniform vec3 number_bg : source_color = vec3(0.95);

varying vec3 lp;
varying vec3 ln;

void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}

// The door number (both sides, reads nose-wards).
vec4 number_at() {
	if (race_number <= 0 || abs(ln.z) < 0.5) {
		return vec4(0.0);
	}
	float s = sign(lp.z);
	vec2 q = vec2(s * (lp.x - number_box.x) / number_box.z, (lp.y - number_box.y) / number_box.w);
	vec2 e = abs(q) - vec2(0.72);
	float panel = length(max(e, 0.0)) - 0.28;
	if (panel > 0.0) {
		return vec4(0.0);
	}
	int n = race_number;
	int nd = n >= 100 ? 3 : (n >= 10 ? 2 : 1);
	float dw = 0.62;                       // digit width / height
	float h = 1.5;                         // digit height in q units
	float total = float(nd) * dw * h * 0.82;
	float u = (q.x + total * 0.5) / (dw * h * 0.82);
	float v = (q.y + h * 0.5) / h;
	vec4 col = vec4(number_bg, 1.0);
	if (u >= 0.0 && u < float(nd) && v >= 0.0 && v <= 1.0) {
		int k = int(floor(u));
		int p10 = nd - 1 - k;
		int digit = (n / (p10 == 2 ? 100 : (p10 == 1 ? 10 : 1))) % 10;
		float fu = (fract(u) - 0.5) / 0.82 + 0.5;
		if (fu >= 0.0 && fu <= 1.0) {
			float al = texture(digits, vec2((float(digit) + fu) / 10.0, 1.0 - v)).a;
			col.rgb = mix(number_bg, number_fg, al);
		}
	}
	return col;
}

// One decal's colour and coverage at this point (alpha 0 = not here).
vec4 decal_at(int i) {
	vec4 box = decal_box[i];
	vec4 info = decal_info[i];
	if (lp.y < info.z || lp.y > info.w) {
		return vec4(0.0);
	}
	int proj = int(info.y + 0.5);
	vec2 uv;
	if (proj == 3) {            // on top of both sides, read from outside
		if (ln.y < 0.4) { return vec4(0.0); }
		float s3 = sign(lp.z);
		uv = vec2(s3 * (lp.x - box.x) / box.z, (box.y - abs(lp.z)) / box.w);
	} else if (proj == 0) {            // on top, text along the car, read from its left
		if (ln.y < 0.4) { return vec4(0.0); }
		uv = vec2((lp.x - box.x) / box.z, (-lp.z - box.y) / box.w);
	} else if (proj == 1) {     // on top, text across the car, read from behind
		if (ln.y < 0.4) { return vec4(0.0); }
		uv = vec2((lp.z - box.y) / box.z, (lp.x - box.x) / box.w);
	} else {                    // on both sides, text reads nose-wards
		if (abs(ln.z) < 0.5) { return vec4(0.0); }
		float s = sign(lp.z);
		uv = vec2(s * (lp.x - box.x) / box.z, (lp.y - box.y) / box.w);
	}
	uv = uv * 0.5 + 0.5;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return vec4(0.0);
	}
	float cell = info.x;
	bool no_panel = cell > 99.5;    // cell + 100: lettering only, no sticker panel
	cell = no_panel ? cell - 100.0 : cell;
	vec2 c = vec2(mod(cell, atlas_grid.x), floor(cell / atlas_grid.x));
	vec2 a = (c + vec2(uv.x, 1.0 - uv.y)) / atlas_grid;
	vec4 t = texture(decal_atlas, a);
	if (no_panel) {
		t.g = 0.0;
		t.a = max(t.r, t.b);
	}
	vec3 col = decal_bg[i];
	col = mix(col, decal_ac[i], t.b / max(t.a, 1e-3));
	col = mix(col, decal_fg[i], t.r / max(t.a, 1e-3));
	return vec4(col, t.a);
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
	if (base_mode == 1) {
		c = vec3(0.025, 0.025, 0.028);
	} else if (pattern == 1) {            // twin stripes nose to tail
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
	float sticker = 0.0;
	for (int i = 0; i < decal_count; i++) {
		vec4 d = decal_at(i);
		c = mix(c, d.rgb, d.a);
		sticker = max(sticker, d.a);
	}
	vec4 nb = number_at();
	c = mix(c, nb.rgb, nb.a);
	sticker = max(sticker, nb.a);
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
	float base_metal = base_mode == 1 ? 0.2 : metallic_flake;
	float base_rough = base_mode == 1 ? 0.32 : roughness_paint;
	METALLIC = mix(mix(base_metal, 0.05, sticker), 0.1, hurt);
	ROUGHNESS = mix(mix(mix(base_rough, 0.35, sticker), 0.7, grime), 0.6, hurt);
	CLEARCOAT = (1.0 - grime) * (1.0 - hurt);
	CLEARCOAT_ROUGHNESS = 0.08;
}
